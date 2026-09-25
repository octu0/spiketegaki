import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Spiketegaki

// PNG 1 枚の top-5 表示と、DatasetFile の CPU 独立評価。
// ImageIO を使うのはこのターゲットだけ (推論ライブラリは Foundation のみに依存する)。

func logLine(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

// MARK: - 引数

struct Options {
    var weightsPath: String?
    var randomWeights = false
    var layers = 4
    var hidden = 512
    var timeSteps = 4
    var seed: UInt64 = 20260924
    var invert = false          // 既定は黒字白地。--invert で白字黒地
    var topK = 5
    var datasetPath: String?
    var benchPath: String?
    var limit = 0               // 0 = 全件 (--bench では 0 を弾く)
    var limitSpecified = false  // --limit を明示したか (--bench の既定 1000 と区別する)
    var dumpSamplesDir: String?
    var dumpCount = 20
    var dumpScale = 8
    var exportWeightsPath: String?
    var pngPaths: [String] = []

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        func next(_ flag: String) -> String {
            i += 1
            if i >= args.count {
                fail("\(flag) に値がありません")
            }
            return args[i]
        }
        func int(_ flag: String, min lower: Int) -> Int {
            let s = next(flag)
            guard let v = Int(s), v >= lower else {
                fail("\(flag) には \(lower) 以上の整数を渡してください: \(s)")
            }
            return v
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--weights":        o.weightsPath = next(a)
            case "--random-weights": o.randomWeights = true
            case "--layers":         o.layers = int(a, min: 1)
            case "--hidden":         o.hidden = int(a, min: 1)
            case "--time-steps":     o.timeSteps = int(a, min: 1)
            case "--seed":           o.seed = UInt64(int(a, min: 0))
            case "--invert":         o.invert = true
            case "--top-k":          o.topK = int(a, min: 1)
            case "--dataset":        o.datasetPath = next(a)
            case "--bench":          o.benchPath = next(a)
            case "--limit":
                o.limit = int(a, min: 0)
                o.limitSpecified = true
            case "--dump-samples":   o.dumpSamplesDir = next(a)
            case "--dump-count":     o.dumpCount = int(a, min: 1)
            case "--dump-scale":     o.dumpScale = int(a, min: 1)
            case "--export-weights": o.exportWeightsPath = next(a)
            case "--help", "-h":     printUsage(); exit(0)
            default:
                if a.hasPrefix("--") {
                    fail("未知の引数: \(a)  (--help を見てください)")
                }
                o.pngPaths.append(a)
            }
            i += 1
        }
        return o
    }
}

func printUsage() {
    print("""
    recognize — 32x32 手書き文字の認識と評価

      swift run -c release recognize --weights <json> [--invert] <png...>
      swift run -c release recognize --weights <json> --dataset <stgk> [--limit N]
      swift run -c release recognize --weights <json> --bench <stgk> [--limit N]
      swift run -c release recognize --random-weights --layers 4 --hidden 512 --dataset <stgk>
      swift run -c release recognize --weights <json> --export-weights <stgw>

      --weights <json>        SpikingNetworkWeights の JSON
      --random-weights        重みを乱数で作る (動作確認用。正解率はチャンスレベルになる)
      --layers <n>            --random-weights のときの層数 (既定 4)
      --hidden <n>            --random-weights のときの隠れ次元 (既定 512)
      --time-steps <n>        --random-weights のときの内部時間ステップ (既定 4)
      --seed <n>              --random-weights の乱数シード (既定 20260924)
      --invert                PNG が白字黒地のとき指定する (既定は黒字白地)
      --top-k <n>             PNG モードで表示する候補数 (既定 5)
      --dataset <stgk>        DatasetFile を CPU 分類器で評価する
      --bench <stgk>          推論速度 (ms/件・RTF) と層ごとの発火率を測る
      --limit <n>             評価するサンプル数の上限 (既定 0 = 全件)
                              --bench では既定 1000、0 は明示エラー
      --dump-samples <dir>    --dataset のサンプルを PNG に書き出す
      --dump-count <n>        書き出す枚数 (既定 20)
      --dump-scale <n>        書き出し時の拡大率 (既定 8 -> 256x256)
      --export-weights <stgw> 重みをバイナリ形式 (STGW v1) に書き出して終了する
    """)
}

// MARK: - ネットワークの用意

func makeClassifier(_ o: Options) -> CharacterClassifier {
    let vocab = CharacterVocabulary.shared
    let network: SpikingNetwork

    if let path = o.weightsPath {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: url.path) {
            fail("重みファイルがありません: \(path)")
        }
        do {
            let weights = try SpikingNetworkWeights.load(from: url)
            if weights.outputDim != vocab.count {
                fail("重みの出力次元 \(weights.outputDim) が語彙数 \(vocab.count) と違います")
            }
            if weights.inputDim != ScanlineEncoder.frameDim {
                fail("重みの入力次元 \(weights.inputDim) が \(ScanlineEncoder.frameDim) と違います")
            }
            network = SpikingNetwork(weights: weights)
        } catch {
            fail("重みを読めません: \(path): \(error)")
        }
    } else if o.randomWeights {
        // SpikingNetwork の初期化は Float.random を使うのでプロセス全体の乱数に依存する。
        // 「チャンスレベルになる」ことの確認が目的なので、シードの再現性までは求めない。
        network = SpikingNetwork(
            numLayers: o.layers,
            inputDim: ScanlineEncoder.frameDim,
            maxHiddenDim: o.hidden,
            outputDim: vocab.count,
            timeSteps: o.timeSteps
        )
        logLine("注意: --random-weights は乱数重みです。正解率はチャンスレベル (1/\(vocab.count) = \(String(format: "%.5f", 1.0 / Double(vocab.count)))) になります。")
    } else {
        fail("--weights <json> か --random-weights のどちらかを指定してください")
    }

    do {
        return try CharacterClassifier(network: network, vocabulary: vocab)
    } catch {
        fail("分類器を作れません: \(error)")
    }
}

// MARK: - PNG 入出力

enum PNGError: Error, CustomStringConvertible {
    case notFound(String)
    case unreadable(String)
    case noImage(String)
    case emptySize(String, Int, Int)
    case noInk(String)

    var description: String {
        switch self {
        case .notFound(let p):        return "ファイルがありません: \(p)"
        case .unreadable(let p):      return "画像として読めません (壊れているか PNG ではない): \(p)"
        case .noImage(let p):         return "画像フレームを取り出せません: \(p)"
        case .emptySize(let p, let w, let h): return "画像の大きさが不正です (\(w)x\(h)): \(p)"
        case .noInk(let p):           return "墨が 1 画素もありません (閾値 \(ImageNormalizer.inkThreshold) 以上の画素が無い): \(p)"
        }
    }
}

// MARK: - ビットマップと配列の相互変換

/// CGBitmapContext (8bit グレー) と「行 0 = 上」の row-major 配列との相互変換。
///
/// CGBitmapContext のデータバッファは **先頭行が画像の上端** に対応する。
/// 描画の座標系は左下原点なので `y = 0` に描いた内容はバッファの最終行に入るが、
/// バッファの並び自体は上から下なので、バッファ行 r をそのまま配列行 r に写せば
/// 「行 0 = 上」になる。
///
/// **行の向きを扱うのはこの 2 つの関数だけ。** 他の場所で行を入れ替えないこと。
enum GrayBitmap {
    /// 8bit グレーの描画先を作る。`bytesPerRow` の詰め物は呼び出し側から見えない。
    static func makeContext(width: Int, height: Int) -> CGContext? {
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
    }

    /// ビットマップ → row-major の 8bit グレー配列 (行 0 = 上)。
    static func read(_ ctx: CGContext) -> [UInt8]? {
        guard let base = ctx.data else {
            return nil
        }
        let width = ctx.width
        let height = ctx.height
        let bytesPerRow = ctx.bytesPerRow
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: width * height)
        var y = 0
        while y < height {
            let src = ptr + y * bytesPerRow
            let dst = y * width
            var x = 0
            while x < width {
                out[dst + x] = src[x]
                x += 1
            }
            y += 1
        }
        return out
    }

    /// row-major の 8bit グレー配列 (行 0 = 上) → ビットマップ。
    /// `pixel(x, y)` の y = 0 が上端。
    static func makeContext(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> UInt8
    ) -> CGContext? {
        guard let ctx = makeContext(width: width, height: height),
              let base = ctx.data else {
            return nil
        }
        let bytesPerRow = ctx.bytesPerRow
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var y = 0
        while y < height {
            let dst = ptr + y * bytesPerRow
            var x = 0
            while x < width {
                dst[x] = pixel(x, y)
                x += 1
            }
            y += 1
        }
        return ctx
    }
}

/// PNG を 8bit グレースケールの row-major で読む。上の行が先。
func loadGray(path: String) throws -> (width: Int, height: Int, gray: [UInt8]) {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || isDir.boolValue {
        throw PNGError.notFound(path)
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) > 0 else {
        throw PNGError.unreadable(path)
    }
    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw PNGError.noImage(path)
    }
    let width = cgImage.width
    let height = cgImage.height
    if width <= 0 || height <= 0 {
        throw PNGError.emptySize(path, width, height)
    }
    // 色空間・ビット深度を揃えるため、8bit グレーに描き直す
    guard let ctx = GrayBitmap.makeContext(width: width, height: height) else {
        throw PNGError.unreadable(path)
    }
    // 透明部分は白 (紙) として扱う
    ctx.setFillColor(gray: 1.0, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    // 行の向きは GrayBitmap が揃える (行 0 = 上)
    guard let out = GrayBitmap.read(ctx) else {
        throw PNGError.unreadable(path)
    }
    return (width, height, out)
}

/// 32x32 の CharacterImage を scale 倍のグレースケール PNG に書く (0 = 紙を白、1 = 墨を黒で出す)。
func writePNG(_ image: CharacterImage, to url: URL, scale: Int) throws {
    let side = CharacterImage.side
    let outSide = side * scale
    let ctx = GrayBitmap.makeContext(width: outSide, height: outSide) { x, y in
        // 墨 1.0 -> 黒 0、紙 0.0 -> 白 255。y = 0 が上端 (画像と同じ向き)
        let v = image[x / scale, y / scale]
        let g = 255.0 - v * 255.0
        return UInt8(max(0.0, min(255.0, g.rounded())))
    }
    guard let cgImage = ctx?.makeImage() else {
        throw PNGError.unreadable(url.path)
    }
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw PNGError.unreadable(url.path)
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    if !CGImageDestinationFinalize(dest) {
        throw PNGError.unreadable(url.path)
    }
}

// MARK: - PNG モード

func runPNGMode(_ o: Options, classifier: CharacterClassifier) -> Int32 {
    var exitCode: Int32 = 0
    for path in o.pngPaths {
        do {
            let (w, h, gray) = try loadGray(path: path)
            // 既定は黒字白地 -> 墨は暗い側なので反転が要る。--invert で白字黒地に切り替える
            let invert = !o.invert
            // PNG 全体を 1 文字分のマス目とみなして正規化する (学習時と同じ扱い)
            let image = try ImageNormalizer.normalize(
                width: w, height: h, gray: gray, invert: invert
            )
            if image.inkSum <= 0.0 {
                throw PNGError.noInk(path)
            }
            let top = try classifier.classify(image: image, topK: o.topK)
            print("\(path)  (\(w)x\(h), 墨 \(String(format: "%.1f", image.inkSum)) 画素相当)")
            for (rank, e) in top.enumerated() {
                print(String(
                    format: "  %d. %@  index %4d  %.4f",
                    rank + 1, String(e.character), e.index, e.probability
                ))
            }
        } catch let e as PNGError {
            logLine("error: \(e.description)")
            exitCode = 1
        } catch {
            logLine("error: \(path): \(error)")
            exitCode = 1
        }
    }
    return exitCode
}

// MARK: - データセット評価モード

func runDatasetMode(_ o: Options, classifier: CharacterClassifier, path: String) -> Int32 {
    let url = URL(fileURLWithPath: path)
    let reader: DatasetReader
    do {
        reader = try DatasetReader(url: url)
    } catch {
        fail("データセットを開けません: \(path): \(error)")
    }
    defer { reader.close() }

    let total = o.limit > 0 ? min(o.limit, reader.count) : reader.count
    if total == 0 {
        print("サンプルが 0 件です: \(path)")
        return 0
    }

    let vocab = classifier.vocabulary
    var top1 = 0
    var top5 = 0
    var perCategoryTotal = [ScriptCategory: Int]()
    var perCategoryTop1 = [ScriptCategory: Int]()
    var perCategoryTop5 = [ScriptCategory: Int]()

    // 書き出し対象を先に決める (全体から等間隔で選ぶので再現性がある)
    var dumpIndices = Set<Int>()
    if o.dumpSamplesDir != nil {
        let n = min(o.dumpCount, total)
        var k = 0
        while k < n {
            dumpIndices.insert(total * k / n)
            k += 1
        }
    }
    var dumpDirURL: URL?
    if let dir = o.dumpSamplesDir {
        let u = URL(fileURLWithPath: dir)
        do {
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        } catch {
            fail("書き出し先を作れません: \(dir): \(error)")
        }
        dumpDirURL = u
    }

    let started = Date()
    var dumpedLines = [String]()
    var worstRoundTrip: Float = 0.0
    var roundTripChecked = 0
    var i = 0
    while i < total {
        let sample: DatasetSample
        do {
            sample = try reader.sample(at: i)
        } catch {
            fail("サンプル \(i) を読めません: \(error)")
        }
        if sample.label < 0 || sample.label >= vocab.count {
            fail("サンプル \(i) のラベル \(sample.label) が語彙 \(vocab.count) の範囲外です")
        }
        let category = vocab.category(of: sample.label)
        perCategoryTotal[category, default: 0] += 1

        do {
            let top = try classifier.classify(image: sample.image, topK: 5)
            if top.first?.index == sample.label {
                top1 += 1
                perCategoryTop1[category, default: 0] += 1
            }
            if top.contains(where: { $0.index == sample.label }) {
                top5 += 1
                perCategoryTop5[category, default: 0] += 1
            }
        } catch {
            fail("サンプル \(i) を分類できません: \(error)")
        }

        if dumpIndices.contains(i), let dir = dumpDirURL {
            let ch = vocab.character(at: sample.label)
            let name = String(format: "%05d_idx%04d_U+%04X.png", i, sample.label, ch.unicodeScalars.first!.value)
            let dst = dir.appendingPathComponent(name)
            do {
                try writePNG(sample.image, to: dst, scale: o.dumpScale)
                let box = inkBoundingBox(sample.image)
                let boxText = box.map { "bbox=(\($0.minX),\($0.minY))-(\($0.maxX),\($0.maxY))" } ?? "bbox=なし"
                let ratio = Double(sample.image.inkSum) / Double(CharacterImage.pixelCount)
                // 往復検証: 書き出した PNG を読み戻して元の画像と一致するか見る。
                // writePNG (配列 -> ビットマップ) と loadGray (ビットマップ -> 配列) の
                // 行の向きが揃っていなければここで必ず差が出る。
                let roundTrip = try roundTripDifference(original: sample.image, pngPath: dst.path)
                if roundTrip > worstRoundTrip {
                    worstRoundTrip = roundTrip
                }
                roundTripChecked += 1
                dumpedLines.append(String(
                    format: "%@  文字=%@ index=%d 墨割合=%.3f %@ 往復差=%.4f",
                    name, String(ch), sample.label, ratio, boxText, roundTrip
                ))
            } catch {
                logLine("警告: PNG を書けません: \(dst.path): \(error)")
            }
        }
        i += 1
    }
    let elapsed = Date().timeIntervalSince(started)

    print("データセット: \(path)")
    print("  評価件数    : \(total) / \(reader.count)")
    print(String(format: "  top-1 正解率: %.4f  (%d / %d)", Double(top1) / Double(total), top1, total))
    print(String(format: "  top-5 正解率: %.4f  (%d / %d)", Double(top5) / Double(total), top5, total))
    print(String(format: "  チャンスレベル: %.5f (1/%d)", 1.0 / Double(vocab.count), vocab.count))
    print(String(format: "  所要時間    : %.2f 秒 (%.2f ms/件)", elapsed, elapsed * 1000.0 / Double(total)))
    print("  -- 区分ごと --")
    for c in ScriptCategory.allCases {
        guard let n = perCategoryTotal[c], n > 0 else {
            continue
        }
        let a1 = Double(perCategoryTop1[c] ?? 0) / Double(n)
        let a5 = Double(perCategoryTop5[c] ?? 0) / Double(n)
        print(String(format: "    %-14@ n=%6d  top-1 %.4f  top-5 %.4f", c.rawValue as NSString, n, a1, a5))
    }
    if roundTripChecked > 0 {
        print(String(
            format: "  -- PNG 往復検証: %d 枚すべて書き出し -> 読み戻しで比較、画素値の最大差 %.5f --",
            roundTripChecked, worstRoundTrip
        ))
    }
    if !dumpedLines.isEmpty, let dir = dumpDirURL {
        print("  -- 書き出したサンプル (\(dumpedLines.count) 枚) -> \(dir.path) --")
        for l in dumpedLines {
            print("    \(l)")
        }
    }
    return 0
}

/// 書き出した PNG を読み戻し、元の画像との画素値の最大差を返す。
///
/// `writePNG` は 32x32 を scale 倍に引き伸ばして書き、`loadGray` + `normalize` は
/// それを面積平均で 32x32 に戻すので、量子化 (1/255) の範囲で元に戻るはず。
/// 行の向きが揃っていなければ上下が入れ替わって大きな差になる。
func roundTripDifference(original: CharacterImage, pngPath: String) throws -> Float {
    let (w, h, gray) = try loadGray(path: pngPath)
    let restored = try ImageNormalizer.normalize(width: w, height: h, gray: gray, invert: true)
    var worst: Float = 0.0
    var i = 0
    while i < CharacterImage.pixelCount {
        let d = abs(restored.pixels[i] - original.pixels[i])
        if d > worst {
            worst = d
        }
        i += 1
    }
    return worst
}

/// 閾値 0.1 以上の外接矩形 (書き出したサンプルが豆腐・空画像でないことの確認に使う)
func inkBoundingBox(_ image: CharacterImage) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
    let side = CharacterImage.side
    var minX = side, minY = side, maxX = -1, maxY = -1
    var y = 0
    while y < side {
        var x = 0
        while x < side {
            if image[x, y] >= ImageNormalizer.inkThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
            x += 1
        }
        y += 1
    }
    return maxX < 0 ? nil : (minX, minY, maxX, maxY)
}

// MARK: - ベンチマークモード

/// `--bench` で `--limit` を省いたときに測る件数。
let benchDefaultLimit = 1000
/// 計測前に空回しする回数 (転置レイアウトの初回参照・ページフォールトを温める)。
let benchWarmupIterations = 20
/// RTF の基準。手書きで 1 文字を書くのにかかる時間を 1.5 秒と置く。
let benchWritingMillis = 1500.0

/// 1 件あたりの所要時間 (ms) の要約。
///
/// 中央値は件数が偶数なら中央 2 件の平均。p95 は nearest-rank
/// (昇順 n 件の `ceil(0.95 * n)` 番目)。件数 0 では作らない (呼び出し側で弾く)。
struct BenchStats {
    let mean: Double
    let median: Double
    let p95: Double
    let minimum: Double
    let maximum: Double

    init(_ values: [Double]) {
        let sorted = values.sorted()
        let n = sorted.count
        var total = 0.0
        var i = 0
        while i < n {
            total += sorted[i]
            i += 1
        }
        self.mean = total / Double(n)
        if n % 2 == 0 {
            self.median = (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
        } else {
            self.median = sorted[n / 2]
        }
        let rank = Int((0.95 * Double(n)).rounded(.up))
        self.p95 = sorted[max(0, min(n - 1, rank - 1))]
        self.minimum = sorted[0]
        self.maximum = sorted[n - 1]
    }
}

/// 端末での表示幅 (全角は 2 桁)。表の列を揃えるためだけに使う。
func benchDisplayWidth(_ s: String) -> Int {
    var width = 0
    for scalar in s.unicodeScalars {
        let v = scalar.value
        // CJK・かな・全角記号は 2 桁扱い
        if (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v)
            || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFE30...0xFE6F).contains(v) || (0xFF00...0xFF60).contains(v)
            || (0xFFE0...0xFFE6).contains(v) {
            width += 2
        } else {
            width += 1
        }
    }
    return width
}

/// 単調増加クロックで測った経過ミリ秒。
@inline(__always)
func benchElapsedMillis(since start: UInt64) -> Double {
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
}

/// 層ごとの「forward 後に発火しているニューロンの割合」をフレーム平均で返す。
///
/// `classifyLogits` と同じ順序で 32 フレームを forward する (読み出し線形層は掛けない)。
/// `forward` は内部で `timeSteps` 回まわるので、ここで読めるのは
/// **各フレームの最後の内部ステップの spike 状態**。計測用の
/// 「forward 後の spike 状態の平均」をそのまま取っているだけで、
/// 内部ステップ全体の平均ではない。計測のためにライブラリへフックは足さない。
func benchLayerFiringRates(network: SpikingNetwork, frames: [[Float]]) -> [Double] {
    let hSize = network.maxHiddenDim
    let stateSize = network.numLayers * hSize
    var vPrev = [Float](repeating: 0.0, count: stateSize)
    var sPrev = [Float](repeating: 0.0, count: stateSize)
    var aPrev = [Float](repeating: 0.0, count: stateSize)
    var readoutSum = [Float](repeating: 0.0, count: hSize)
    let scratch = ForwardScratch(maxHiddenDim: hSize)

    var rates = [Double](repeating: 0.0, count: network.numLayers)
    var t = 0
    while t < frames.count {
        network.forward(
            features: frames[t],
            vPrev: &vPrev,
            sPrev: &sPrev,
            aPrev: &aPrev,
            readoutSum: &readoutSum,
            scratch: scratch
        )
        var layer = 0
        while layer < network.numLayers {
            let base = layer * hSize
            var fired = 0
            var n = 0
            while n < hSize {
                if sPrev[base + n] != 0.0 {
                    fired += 1
                }
                n += 1
            }
            rates[layer] += Double(fired) / Double(hSize)
            layer += 1
        }
        t += 1
    }
    let divisor = Double(max(1, frames.count))
    var layer = 0
    while layer < network.numLayers {
        rates[layer] /= divisor
        layer += 1
    }
    return rates
}

/// 推論速度 (ms/件、文字/秒、µs/フレーム、RTF) と層ごとの発火率を測る。
///
/// 分類そのものは `--dataset` と同じ `CharacterClassifier.classify` / `classifyLogits` を呼ぶ。
/// 計測専用の推論経路は作らない (本番と違う経路を測っても速度の根拠にならない)。
func runBenchMode(_ o: Options, classifier: CharacterClassifier, path: String) -> Int32 {
    // --limit 0 は「全件」の意味では使わせない。件数を明示させる
    if o.limitSpecified && o.limit <= 0 {
        fail("--bench の --limit には 1 以上を渡してください (0 = 全件は使えません): \(o.limit)")
    }
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || isDir.boolValue {
        fail("ベンチ用のデータセットがありません: \(path)")
    }
    let reader: DatasetReader
    do {
        reader = try DatasetReader(url: url)
    } catch {
        fail("データセットを開けません: \(path): \(error)")
    }
    defer { reader.close() }
    if reader.count == 0 {
        fail("データセットにサンプルが 1 件もありません: \(path)")
    }

    let requested = o.limitSpecified ? o.limit : benchDefaultLimit
    let total = min(requested, reader.count)
    let network = classifier.network
    let vocab = classifier.vocabulary

    // ファイル読み込みを計測に混ぜないよう、先に全件をメモリへ載せる
    var images = [CharacterImage]()
    var labels = [Int]()
    images.reserveCapacity(total)
    labels.reserveCapacity(total)
    var i = 0
    while i < total {
        let sample: DatasetSample
        do {
            sample = try reader.sample(at: i)
        } catch {
            fail("サンプル \(i) を読めません: \(error)")
        }
        if sample.label < 0 || sample.label >= vocab.count {
            fail("サンプル \(i) のラベル \(sample.label) が語彙 \(vocab.count) の範囲外です")
        }
        images.append(sample.image)
        labels.append(sample.label)
        i += 1
    }

    func warmUp(_ body: (Int) -> Void) {
        var w = 0
        while w < benchWarmupIterations {
            body(w % total)
            w += 1
        }
    }

    // --- 計測ループ ---
    //
    // 3 区分 (符号化 / SNN 本体 / 本番経路) を **1 件ごとに続けて** 測る。
    // 区分ごとに 1000 件まとめて回す作りにすると、同じマシンで他の処理
    // (別ワーカーの MLX 学習など) が動いているとき、後に回した区分だけが遅くなって
    // 「SNN 本体が本番経路より遅い」という起こり得ない結果になる (実測でそうなった)。
    // 1 件の中で続けて測れば、外的負荷の変動は 3 区分に等しくかかる。
    //
    // SNN 本体は直前に符号化したフレームをそのまま使う (符号化の時間は含めない)。
    // 1000 件分を事前に配列へ溜めて使い回すと [Float] が 32000 本ばらまかれて
    // キャッシュの当たり方が本番経路と変わるので、溜めない。
    var fullMillis = [Double](repeating: 0.0, count: total)
    var encodeMillis = [Double](repeating: 0.0, count: total)
    var snnMillis = [Double](repeating: 0.0, count: total)
    var top1 = 0
    var top5 = 0
    warmUp { idx in
        _ = ScanlineEncoder.encode(images[idx])
        _ = try? network.classifyLogits(frames: ScanlineEncoder.encode(images[idx]))
        _ = try? classifier.classify(image: images[idx], topK: 5)
    }

    let loopStarted = DispatchTime.now().uptimeNanoseconds
    i = 0
    while i < total {
        // 1. 符号化のみ
        let encodeStarted = DispatchTime.now().uptimeNanoseconds
        let frames = ScanlineEncoder.encode(images[i])
        encodeMillis[i] = benchElapsedMillis(since: encodeStarted)
        if frames.count != ScanlineEncoder.frameCount {
            fail("符号化のフレーム数が \(frames.count) です (\(ScanlineEncoder.frameCount) を期待)")
        }

        // 2. SNN 本体のみ (32 フレーム forward + 末尾平均)
        let snnStarted = DispatchTime.now().uptimeNanoseconds
        do {
            _ = try network.classifyLogits(frames: frames)
        } catch {
            fail("サンプル \(i) の classifyLogits が失敗しました: \(error)")
        }
        snnMillis[i] = benchElapsedMillis(since: snnStarted)

        // 3. 本番経路 (--dataset と同じ呼び出し)
        let fullStarted = DispatchTime.now().uptimeNanoseconds
        let top: [(character: Character, index: Int, probability: Float)]
        do {
            top = try classifier.classify(image: images[i], topK: 5)
        } catch {
            fail("サンプル \(i) を分類できません: \(error)")
        }
        fullMillis[i] = benchElapsedMillis(since: fullStarted)

        if top.first?.index == labels[i] {
            top1 += 1
        }
        if top.contains(where: { $0.index == labels[i] }) {
            top5 += 1
        }
        i += 1
    }
    let loopMillis = benchElapsedMillis(since: loopStarted)

    // 計測中にマシンの状態が変わっていないかの目安。前半と後半で大きく違えば
    // 他の処理と取り合っている (平均より最小値・中央値を見るべき)
    var firstHalf = 0.0
    var secondHalf = 0.0
    let half = total / 2
    i = 0
    while i < total {
        if i < half {
            firstHalf += fullMillis[i]
        } else {
            secondHalf += fullMillis[i]
        }
        i += 1
    }
    let firstHalfMean = half > 0 ? firstHalf / Double(half) : 0.0
    let secondHalfMean = total - half > 0 ? secondHalf / Double(total - half) : 0.0

    // --- 層ごとの発火率 (計測対象外。時間には含めない) ---
    var firing = [Double](repeating: 0.0, count: network.numLayers)
    i = 0
    while i < total {
        let rates = benchLayerFiringRates(network: network, frames: ScanlineEncoder.encode(images[i]))
        var layer = 0
        while layer < network.numLayers {
            firing[layer] += rates[layer]
            layer += 1
        }
        i += 1
    }
    var layer = 0
    while layer < network.numLayers {
        firing[layer] /= Double(total)
        layer += 1
    }

    let full = BenchStats(fullMillis)
    let enc = BenchStats(encodeMillis)
    let snn = BenchStats(snnMillis)
    let frameCount = ScanlineEncoder.frameCount

    print("== 推論速度ベンチマーク ==")
    print("  データセット  : \(path)  (全 \(reader.count) 件のうち先頭 \(total) 件)")
    if let w = o.weightsPath {
        print("  重み          : \(w)")
    } else {
        print("  重み          : --random-weights (乱数)")
    }
    print("  ネットワーク  : \(network.numLayers) 層  隠れ次元 \(network.maxHiddenDim)  出力 \(network.outputDim)  timeSteps \(network.timeSteps)  readoutFrames \(network.readoutFrames)")
    print("  フレーム      : \(frameCount) フレーム/文字  フレーム次元 \(network.inputDim)")
    print("  実行条件      : 単一スレッド (計測経路に並列化なし)、ウォームアップ \(benchWarmupIterations) 回")
    print("")
    print("  区分                          平均 ms   中央値 ms    p95 ms    最小 ms    最大 ms")
    print(String(format: "  本番経路 (符号化+SNN+top5)  %9.3f %9.3f %9.3f %9.3f %9.3f",
                 full.mean, full.median, full.p95, full.minimum, full.maximum))
    print(String(format: "  SNN 本体 (classifyLogits)   %9.3f %9.3f %9.3f %9.3f %9.3f",
                 snn.mean, snn.median, snn.p95, snn.minimum, snn.maximum))
    print(String(format: "  符号化のみ (encode)         %9.3f %9.3f %9.3f %9.3f %9.3f",
                 enc.mean, enc.median, enc.p95, enc.minimum, enc.maximum))
    print(String(format: "  差分 (softmax + top-5 選択) %9.3f         -         -         -         -",
                 full.mean - snn.mean - enc.mean))
    print("")
    print(String(format: "  文字/秒        : %.1f  (本番経路の平均から 1000 / %.3f)", 1000.0 / full.mean, full.mean))
    print(String(format: "  µs/フレーム    : %.1f  (SNN 本体の平均 %.3f ms / %d フレーム)",
                 snn.mean * 1000.0 / Double(frameCount), snn.mean, frameCount))
    print(String(format: "  RTF            : %.5f  (本番経路の平均 %.3f ms / 筆記 %.0f ms)",
                 full.mean / benchWritingMillis, full.mean, benchWritingMillis))
    print(String(format: "  RTF (SNN 本体) : %.5f", snn.mean / benchWritingMillis))
    print(String(format: "  RTF (最小値基準): %.5f  (本番経路の最小 %.3f ms / 筆記 %.0f ms)",
                 full.minimum / benchWritingMillis, full.minimum, benchWritingMillis))
    print("")
    print(String(format: "  -- 計測の安定性 (本番経路) --"))
    print(String(format: "    前半 %d 件の平均 %.3f ms / 後半 %d 件の平均 %.3f ms  (比 %.2f)",
                 half, firstHalfMean, total - half, secondHalfMean,
                 firstHalfMean > 0.0 ? secondHalfMean / firstHalfMean : 0.0))
    print(String(format: "    計測ループ全体 %.1f 秒。比が 1.0 から大きく外れていたら他の処理と CPU を取り合っている。", loopMillis / 1000.0))
    print("")
    print("  -- 層ごとの平均発火率 (forward 後の spike 状態、\(total) 件 x \(frameCount) フレーム) --")
    var sumRate = 0.0
    layer = 0
    while layer < network.numLayers {
        let role: String
        if network.numLayers == 1 {
            role = "再帰 LIF + 読み出し"
        } else if layer == 0 {
            role = "再帰 LIF"
        } else if layer == network.numLayers - 1 {
            role = "FF LIF + 読み出し"
        } else {
            role = "FF LIF"
        }
        let label = "層 \(layer) (\(role))"
        print(String(format: "    %@%@: %.4f  (%.1f / %d ニューロン)",
                     label as NSString,
                     String(repeating: " ", count: max(1, 30 - benchDisplayWidth(label))),
                     firing[layer],
                     firing[layer] * Double(network.maxHiddenDim),
                     network.maxHiddenDim))
        sumRate += firing[layer]
        layer += 1
    }
    let meanLabel = "全層平均"
    print(String(format: "    %@%@: %.4f",
                 meanLabel as NSString,
                 String(repeating: " ", count: max(1, 30 - benchDisplayWidth(meanLabel))),
                 sumRate / Double(network.numLayers)))
    print("    注: forward 1 回は内部で timeSteps \(network.timeSteps) 回まわる。ここで読めるのは各フレームの最後の内部ステップの発火。")
    print("")
    print(String(format: "  参考: top-1 %.4f (%d / %d)  top-5 %.4f (%d / %d)",
                 Double(top1) / Double(total), top1, total,
                 Double(top5) / Double(total), top5, total))
    return 0
}

// MARK: - 重みのバイナリ書き出し

/// 重み JSON を STGW v1 のバイナリに変換する。wasm では JSON を通さずこれを読む。
/// 書き出した後に読み戻して元と一致することまで確かめる (黙って壊れた重みを配らない)。
func runExportWeights(_ o: Options, to outPath: String) -> Int32 {
    guard let jsonPath = o.weightsPath else {
        fail("--export-weights には --weights <json> が要ります")
    }
    let srcURL = URL(fileURLWithPath: jsonPath)
    if !FileManager.default.fileExists(atPath: srcURL.path) {
        fail("重みファイルがありません: \(jsonPath)")
    }
    let weights: SpikingNetworkWeights
    do {
        weights = try SpikingNetworkWeights.load(from: srcURL)
    } catch {
        fail("重みを読めません: \(jsonPath): \(error)")
    }

    let bytes = weights.binary()
    let dstURL = URL(fileURLWithPath: outPath)
    let dir = dstURL.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(bytes).write(to: dstURL, options: .atomic)
    } catch {
        fail("書き出せません: \(outPath): \(error)")
    }

    // 往復検証
    let restored: SpikingNetworkWeights
    do {
        let data = try Data(contentsOf: dstURL)
        restored = try SpikingNetworkWeights(binary: [UInt8](data))
    } catch {
        fail("書き出した \(outPath) を読み戻せません: \(error)")
    }
    if restored != weights {
        fail("書き出した \(outPath) が元の重みと一致しません")
    }

    let jsonSize = (try? FileManager.default.attributesOfItem(atPath: srcURL.path)[.size] as? Int) ?? nil
    print("重みを書き出しました: \(outPath)")
    print("  形式          : STGW v\(SpikingNetworkWeights.binaryVersion) (リトルエンディアン float32)")
    print("  層数          : \(weights.numLayers)  隠れ次元 \(weights.maxHiddenDim)  出力 \(weights.outputDim)")
    print("  timeSteps     : \(weights.timeSteps)  readoutFrames \(weights.readoutFrames)")
    print("  classLabels   : \(weights.classLabels?.count.description ?? "なし")")
    print("  バイト数      : \(bytes.count)  (\(String(format: "%.2f", Double(bytes.count) / 1_048_576.0)) MiB)")
    if let n = jsonSize {
        print("  元の JSON     : \(n) バイト (\(String(format: "%.2f", Double(n) / 1_048_576.0)) MiB)")
    }
    print("  往復検証      : 読み戻して元の重みと完全一致")
    return 0
}

// MARK: - 本体


func run() {
    let o = Options.parse(Array(CommandLine.arguments.dropFirst()))
    if let out = o.exportWeightsPath {
        exit(runExportWeights(o, to: out))
    }
    if o.datasetPath == nil && o.benchPath == nil && o.pngPaths.isEmpty {
        printUsage()
        fail("PNG のパスか --dataset か --bench を指定してください")
    }
    let classifier = makeClassifier(o)

    var code: Int32 = 0
    if let dataset = o.datasetPath {
        code = runDatasetMode(o, classifier: classifier, path: dataset)
    }
    if let bench = o.benchPath {
        let c = runBenchMode(o, classifier: classifier, path: bench)
        if c != 0 {
            code = c
        }
    }
    if !o.pngPaths.isEmpty {
        let c = runPNGMode(o, classifier: classifier)
        if c != 0 {
            code = c
        }
    }
    exit(code)
}

run()
