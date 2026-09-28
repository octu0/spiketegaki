import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Spiketegaki

// フォント → グリフ描画 → ImageNormalizer → Augmenter → DatasetFile。
// CoreText / CoreGraphics を使うのはこのターゲットだけ (推論ライブラリはフォントに依存しない)。
//
// 「豆腐」(.notdef) とフォールバック描画を学習データに入れないため、次の 3 段で弾く:
//   1. フォントの取得時に PostScript 名が要求と一致するか / ファイル URL が一致するかを見る
//   2. 文字ごとに CTFontGetGlyphsForCharacters が true かつ glyph != 0 か見る
//   3. 描いた結果に墨が 1 画素も無ければ捨てる

// MARK: - ログ

func logLine(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

// MARK: - 引数

struct Options {
    var outDir = ".tmp/datasets"
    var name = "dataset"
    var fontsDir = ".tmp/fonts"
    /// nil = 明示指定なし。その場合は <fonts-dir>/system-fonts.txt から読む。
    var systemFonts: [String]?
    var holdoutFonts: [String] = []
    var scripts: [ScriptCategory] = ScriptCategory.allCases
    var sizes: [Int] = [18, 36, 64]
    var augment = 0
    var seed: UInt64 = 20260924
    var limitPerClass = 0        // 0 = 無制限
    var listFonts = false
    var listFontsTSV = ".tmp/reports/fonts_list.tsv"
    var listFacesTSV: String?    // 重複排除前の全 face (ファイル -> PostScript 名) を書き出す
    var dryRun = false           // フォントの解決と train/eval の振り分けだけ出して書き込まない
    var contactSheetDir: String? // 全書体の目視確認シートの出力先
    var maxFonts = 0             // 0 = 無制限
    var fontFilter: String?      // PostScript 名 / ファイル名にかける正規表現
    var requireScripts: [ScriptCategory] = []   // この区分のグリフを持つフォントだけ使う
    var workers = 1

    /// OS 付属フォントの一覧を書いたファイルの名前。
    /// フォント名をソースに直書きしないため、実体は <fonts-dir>/ に置く。
    static let systemFontListName = "system-fonts.txt"

    /// <fonts-dir>/system-fonts.txt から PostScript 名を読む。
    /// 1 行 1 名前、'#' 以降はコメント、空行は無視。
    /// ファイルが無ければ空を返す (OS 付属フォントを使わない動作。エラーにはしない)。
    static func loadSystemFontList(fontsDir: String) -> [String] {
        let url = URL(fileURLWithPath: fontsDir).appendingPathComponent(systemFontListName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            logLine("注意: \(url.path) が無いので OS 付属フォントは使いません。"
                + " 使う場合は 1 行 1 PostScript 名で置いてください。")
            return []
        }
        var out = [String]()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") {
                line = String(line[line.startIndex ..< hash])
            }
            let name = line.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !out.contains(name) {
                out.append(name)
            }
        }
        return out
    }

    static let scriptAliases: [String: ScriptCategory] = [
        "digits": .digits,
        "ascii": .asciiSymbols,
        "asciisymbols": .asciiSymbols,
        "latin": .latinUpper,          // latin は大小両方を指す (下で展開する)
        "latinupper": .latinUpper,
        "latinlower": .latinLower,
        "hiragana": .hiragana,
        "kana": .hiragana,             // kana は平仮名 + 片仮名 (下で展開する)
        "katakana": .katakana,
        "kanji": .kanjiLevel1,
        "kanjilevel1": .kanjiLevel1
    ]

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

        while i < args.count {
            let a = args[i]
            switch a {
            case "--out-dir":       o.outDir = next(a)
            case "--name":          o.name = next(a)
            case "--fonts-dir":     o.fontsDir = next(a)
            case "--system-fonts":  o.systemFonts = splitList(next(a))
            case "--holdout-fonts": o.holdoutFonts = splitList(next(a))
            case "--scripts":       o.scripts = parseScripts(next(a))
            case "--sizes":         o.sizes = parseSizes(next(a))
            case "--augment":       o.augment = parseInt(next(a), a, min: 0)
            case "--seed":          o.seed = UInt64(parseInt(next(a), a, min: 0))
            case "--limit-per-class": o.limitPerClass = parseInt(next(a), a, min: 0)
            case "--workers":       o.workers = parseInt(next(a), a, min: 1)
            case "--max-fonts":     o.maxFonts = parseInt(next(a), a, min: 0)
            case "--font-filter":   o.fontFilter = next(a)
            case "--require-script": o.requireScripts = parseScripts(next(a))
            case "--list-fonts":    o.listFonts = true
            case "--list-fonts-tsv": o.listFontsTSV = next(a)
            case "--list-faces-tsv": o.listFacesTSV = next(a)
            case "--dry-run":       o.dryRun = true
            case "--contact-sheet": o.contactSheetDir = next(a)
            case "--help", "-h":    printUsage(); exit(0)
            default:
                fail("未知の引数: \(a)  (--help を見てください)")
            }
            i += 1
        }
        if o.sizes.isEmpty {
            fail("--sizes が空です")
        }
        if o.scripts.isEmpty {
            fail("--scripts が空です")
        }
        return o
    }

    private static func splitList(_ s: String) -> [String] {
        return s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseInt(_ s: String, _ flag: String, min lower: Int) -> Int {
        guard let v = Int(s), v >= lower else {
            fail("\(flag) には \(lower) 以上の整数を渡してください: \(s)")
        }
        return v
    }

    private static func parseSizes(_ s: String) -> [Int] {
        var out = [Int]()
        for part in splitList(s) {
            guard let v = Int(part), v > 0 else {
                fail("--sizes には正の整数を渡してください: \(part)")
            }
            out.append(v)
        }
        return out
    }

    private static func parseScripts(_ s: String) -> [ScriptCategory] {
        var set = [ScriptCategory]()
        for raw in splitList(s) {
            let key = raw.lowercased()
            if key == "all" {
                return ScriptCategory.allCases
            }
            guard let c = scriptAliases[key] else {
                fail("--scripts の値が不明です: \(raw)  (digits,ascii,latin,hiragana,katakana,kanji)")
            }
            var add = [c]
            if key == "latin" {
                add = [.latinUpper, .latinLower]
            }
            if key == "kana" {
                add = [.hiragana, .katakana]
            }
            for x in add where !set.contains(x) {
                set.append(x)
            }
        }
        // 語彙の並び順に揃える
        return ScriptCategory.allCases.filter { set.contains($0) }
    }
}

func printUsage() {
    print("""
    render — フォントから 32x32 の学習データセットを作る

      swift run -c release render [オプション]

      --out-dir <dir>         出力先 (既定 .tmp/datasets)
      --name <name>           <name>_train.stgk / <name>_eval.stgk を作る (既定 dataset)
      --fonts-dir <dir>       追加フォントの置き場。直下の *.ttf / *.otf のみ見る (既定 .tmp/fonts)
      --system-fonts <a,b>    OS 付属フォントの PostScript 名。省略時は
                              <fonts-dir>/system-fonts.txt を読む (無ければ OS 付属は使わない)
      --holdout-fonts <a,b>   eval 側に回すフォント名 (PostScript 名 / ファイル名の部分一致)
      --scripts <a,b>         digits,ascii,latin,hiragana,katakana,kanji,all (既定 all)
      --sizes <a,b>           描画サイズ px (既定 18,36,64)
      --augment <N>           1 枚につき拡張を N 枚足す (既定 0)
      --seed <n>              拡張の乱数シード (既定 20260924)
      --limit-per-class <n>   1 クラスあたりの最大サンプル数 (既定 0 = 無制限)
      --workers <n>           フォント単位の並列数 (既定 1。1 なら出力順まで決定的)
      --max-fonts <n>         使うフォント数の上限。超える分は --seed でシードした乱数で抽出 (既定 0 = 無制限)
      --font-filter <regex>   PostScript 名かファイル名がこの正規表現に当たるフォントだけ使う
      --require-script <a,b>  指定した区分のグリフを 1 つ以上持つフォントだけ使う
                              (例: --require-script hiragana で日本語フォントだけに絞る)
      --list-fonts            読み込めたフォントと被覆率を表示して終了
      --list-fonts-tsv <path> --list-fonts のとき TSV を書き出す先 (既定 .tmp/reports/fonts_list.tsv)
      --contact-sheet <dir>   読み込めた全書体の目視確認シート (PNG) を書き出して終了する。
                              固定の確認文字列を 1 行に並べ、40 書体で 1 ページ
      --dry-run               フォントの解決と train / eval の振り分けだけ表示し、
                              データセットを一切書かずに終了する
      --list-faces-tsv <path> PostScript 名で重複排除する前の全 face (path と名前) を書き出して終了
                              (同じ PostScript 名を名乗るファイルの洗い出しに使う)

    対象区分のグリフを 1 つも持たないフォントは自動でスキップします
    (Latin 専用フォントに --scripts hiragana を指定した場合など)。
    """)
}

// MARK: - フォント

enum FontOrigin {
    case system
    case file(URL)

    var label: String {
        switch self {
        case .system: return "system"
        case .file(let u): return u.deletingLastPathComponent().lastPathComponent + "/" + u.lastPathComponent
        }
    }

    var shortLabel: String {
        switch self {
        case .system: return "system"
        case .file: return "fonts-dir"
        }
    }

    /// TSV 用のパス (system は空)
    var path: String {
        switch self {
        case .system: return ""
        case .file(let u): return u.path
        }
    }
}

/// 読み込みに成功したフォント 1 つ。CTFont は不変で thread-safe なのでサイズ別に作り置きする。
final class FontEntry: @unchecked Sendable {
    let postScriptName: String
    let origin: FontOrigin
    let fontsBySize: [Int: CTFont]
    /// 区分ごとの (描けるグリフ数, 語彙上の総数)
    let coverage: [ScriptCategory: (have: Int, total: Int)]
    /// 実際に描ける文字の (クラス index, スカラ)。--scripts で絞った後の集合。
    let drawable: [(index: Int, scalar: Unicode.Scalar)]

    init(
        postScriptName: String,
        origin: FontOrigin,
        fontsBySize: [Int: CTFont],
        coverage: [ScriptCategory: (have: Int, total: Int)],
        drawable: [(index: Int, scalar: Unicode.Scalar)]
    ) {
        self.postScriptName = postScriptName
        self.origin = origin
        self.fontsBySize = fontsBySize
        self.coverage = coverage
        self.drawable = drawable
    }
}

/// フォント読み込みの結果。フォールバック・置換は「読めなかった」として理由付きで返す。
enum FontLoadOutcome {
    case loaded(FontEntry)
    case rejected(String)
}

enum FontLoader {
    /// グリフが本当にあるか。CTFontGetGlyphsForCharacters が false か glyph 0 なら無い。
    static func hasGlyph(_ font: CTFont, _ scalar: Unicode.Scalar) -> Bool {
        var utf16 = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let ok = CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
        if !ok {
            return false
        }
        for g in glyphs where g == 0 {
            return false
        }
        return !glyphs.isEmpty
    }

    static func glyph(_ font: CTFont, _ scalar: Unicode.Scalar) -> CGGlyph? {
        var utf16 = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let ok = CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
        if !ok || glyphs.count != 1 || glyphs[0] == 0 {
            return nil
        }
        return glyphs[0]
    }

    /// OS 付属フォントを PostScript 名で取る。
    /// CTFontCreateWithName は名前が見つからないと別のフォントを返すので、
    /// 戻り値の PostScript 名が要求と一致しなければ「読めなかった」として弾く。
    static func loadSystem(
        _ psName: String,
        sizes: [Int],
        scripts: [ScriptCategory]
    ) -> FontLoadOutcome {
        let probe = CTFontCreateWithName(psName as CFString, CGFloat(sizes[0]), nil)
        let actual = CTFontCopyPostScriptName(probe) as String
        if actual != psName {
            return .rejected("フォールバック: \"\(psName)\" を要求したが \"\(actual)\" が返った")
        }
        var fonts = [Int: CTFont]()
        for s in sizes {
            fonts[s] = CTFontCreateWithName(psName as CFString, CGFloat(s), nil)
        }
        return .loaded(makeEntry(psName: psName, origin: .system, fonts: fonts, scripts: scripts))
    }

    /// ファイルから読む。記述子から作ったフォントの URL が元ファイルと一致することを確かめ、
    /// 置換が起きていないことを保証する。
    static func loadFile(
        _ url: URL,
        sizes: [Int],
        scripts: [ScriptCategory]
    ) -> [FontLoadOutcome] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else {
            return [.rejected("記述子を作れない: \(url.lastPathComponent)")]
        }
        var out = [FontLoadOutcome]()
        for desc in descriptors {
            let probe = CTFontCreateWithFontDescriptor(desc, CGFloat(sizes[0]), nil)
            let psName = CTFontCopyPostScriptName(probe) as String
            // 作られたフォントが本当にこのファイル由来か確認する
            let attr = CTFontCopyAttribute(probe, kCTFontURLAttribute)
            guard let fontURL = attr as? URL else {
                out.append(.rejected("URL 属性を取れない: \(url.lastPathComponent) (\(psName))"))
                continue
            }
            if fontURL.standardizedFileURL.path != url.standardizedFileURL.path {
                out.append(.rejected("置換が起きた: \(url.lastPathComponent) -> \(fontURL.lastPathComponent)"))
                continue
            }
            var fonts = [Int: CTFont]()
            for s in sizes {
                fonts[s] = CTFontCreateWithFontDescriptor(desc, CGFloat(s), nil)
            }
            out.append(.loaded(makeEntry(psName: psName, origin: .file(url), fonts: fonts, scripts: scripts)))
        }
        return out
    }

    private static func makeEntry(
        psName: String,
        origin: FontOrigin,
        fonts: [Int: CTFont],
        scripts: [ScriptCategory]
    ) -> FontEntry {
        let vocab = CharacterVocabulary.shared
        let probeFont = fonts.values.first!
        var coverage = [ScriptCategory: (have: Int, total: Int)]()
        var drawable = [(index: Int, scalar: Unicode.Scalar)]()

        for category in ScriptCategory.allCases {
            let range = vocab.range(of: category)
            var have = 0
            var idx = range.lowerBound
            while idx < range.upperBound {
                let c = vocab.character(at: idx)
                let scalar = c.unicodeScalars.first!
                if hasGlyph(probeFont, scalar) {
                    have += 1
                    if scripts.contains(category) {
                        drawable.append((index: idx, scalar: scalar))
                    }
                }
                idx += 1
            }
            coverage[category] = (have: have, total: range.count)
        }
        return FontEntry(
            postScriptName: psName,
            origin: origin,
            fontsBySize: fonts,
            coverage: coverage,
            drawable: drawable
        )
    }
}

/// 並列読み込みの結果を集める。
final class LoadCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var loaded: [FontEntry] = []
    private(set) var rejected: [(name: String, reason: String)] = []

    func addLoaded(_ e: FontEntry) {
        lock.lock()
        loaded.append(e)
        lock.unlock()
    }

    func addRejected(_ name: String, _ reason: String) {
        lock.lock()
        rejected.append((name, reason))
        lock.unlock()
    }
}

/// --max-fonts の抽出に使う決定的な乱数 (SplitMix64)。
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) {
        state = seed &+ 0x9E3779B97F4A7C15
    }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - 描画

/// 1 文字分のマス目に描いた結果。
struct CellRender {
    /// マス目 (em x em) の 8bit グレー。row-major、上の行が先。
    let gray: [UInt8]
    /// マス目の外へ出た墨の割合 (0.0 = 収まっている, 1.0 = 全部はみ出した)
    let overflowRatio: Float
    /// マス目の中に残った墨の量 (画素値の総和。0 なら空画像)
    let insideInk: Float
}

enum GlyphRenderer {
    /// マス目の外側に取る余白 (em 単位)。はみ出した墨を測るためだけに使い、最後に切り落とす。
    static let overflowPadEm = 1

    /// 1 em 四方のマス目にグリフを描く。
    ///
    /// - 水平位置は `(em - advance) / 2` で字送り幅を中央に置く。
    /// - ベースラインはマス目の底から `|descent|` 上げた位置。
    ///   フォントの ascent + descent が em を超える場合は、その比で按分した位置にする。
    /// - マス目からはみ出した墨は切り捨て、割合を `overflowRatio` に記録する。
    ///
    /// 返す配列は row-major で行 0 が上端 (`GrayBitmap` が揃える)。
    /// グリフの外接矩形が空なら nil (空白文字など)。
    static func renderCell(font: CTFont, glyph: CGGlyph, em: Int) -> CellRender? {
        var g = glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &g, &bounds, 1)
        if bounds.width <= 0 || bounds.height <= 0 || bounds.isNull || bounds.isInfinite {
            return nil
        }

        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .default, &g, &advance, 1)

        let emF = CGFloat(em)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)   // 正の値で返る
        let total = ascent + descent
        // ascent + descent が em を超えるフォントでは、その比でマス目の中に按分する
        let baselineFromBottom: CGFloat = (total > emF && total > 0)
            ? emF * descent / total
            : descent

        // はみ出しを測るため、マス目の周囲に overflowPadEm 分の余白を取って描く
        let pad = em * overflowPadEm
        let canvas = em + 2 * pad
        guard let ctx = GrayBitmap.makeContext(width: canvas, height: canvas) else {
            return nil
        }

        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSmoothFonts(false)
        ctx.setFillColor(gray: 0.0, alpha: 1.0)

        var pos = CGPoint(
            x: CGFloat(pad) + (emF - advance.width) * 0.5,
            y: CGFloat(pad) + baselineFromBottom
        )
        CTFontDrawGlyphs(font, &g, &pos, 1, ctx)

        // 行の向きは GrayBitmap が揃える (行 0 = 上)
        guard let canvasGray = GrayBitmap.read(ctx) else {
            return nil
        }

        // マス目の中と外の墨を数えつつ、マス目の分だけ取り出す
        var cell = [UInt8](repeating: 255, count: em * em)
        var insideInk: Float = 0.0
        var totalInk: Float = 0.0
        var cy = 0
        while cy < canvas {
            let srcRow = cy * canvas
            let insideRow = (cy >= pad && cy < pad + em)
            var cx = 0
            while cx < canvas {
                let ink = Float(255 - Int(canvasGray[srcRow + cx])) * (1.0 / 255.0)
                totalInk += ink
                if insideRow && cx >= pad && cx < pad + em {
                    insideInk += ink
                    cell[(cy - pad) * em + (cx - pad)] = canvasGray[srcRow + cx]
                }
                cx += 1
            }
            cy += 1
        }

        let overflow: Float = totalInk > 0.0 ? (totalInk - insideInk) / totalInk : 0.0
        return CellRender(gray: cell, overflowRatio: overflow, insideInk: insideInk)
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

// MARK: - コンタクトシート

/// 全書体を人間が目視確認するための一覧 PNG。
/// データを増やす前に、豆腐・欠落・フォールバック・位置ずれをここで潰す。
enum ContactSheet {
    /// 確認用の固定文字列 (15 文字)。
    /// 濁点と半濁点 (ビ/ピ)、英大小文字 (c/C)、画数の多い字 (永/鬱) を必ず含める。
    /// マス目基準の正規化がこれらを区別できているかを 1 行で見るため。
    /// 小書き仮名 (ょ) は語彙から外した (DESIGN.md §4) ので親字 (よ) に置き換えてある。
    static let probe: [Character] = Array("あいうえお永鬱Aa0よビピcC")
    /// 桝を描く em
    static let em = 36
    /// 32x32 を何倍に拡大して並べるか
    static let scale = 4
    /// 1 ページあたりの書体数
    static let rowsPerPage = 40

    static let cellPx = CharacterImage.side * scale       // 128
    static let labelWidth = 470
    static let headerHeight = 160

    /// 1 桝の状態
    private enum CellState {
        case drawn(CharacterImage)
        case noGlyph
        case blank
    }

    /// 書体一覧を複数ページの PNG に書き出し、ページ数を返す。
    static func write(entries: [FontEntry], directory: String, labelFont: CTFont) throws -> Int {
        let dir = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sorted = entries.sorted { $0.postScriptName < $1.postScriptName }
        let pageCount = max(1, (sorted.count + rowsPerPage - 1) / rowsPerPage)
        var page = 0
        while page < pageCount {
            let slice = Array(sorted.dropFirst(page * rowsPerPage).prefix(rowsPerPage))
            let url = dir.appendingPathComponent(String(format: "sheet_%02d.png", page + 1))
            try writePage(slice, to: url, labelFont: labelFont, page: page + 1, of: pageCount)
            page += 1
        }
        return pageCount
    }

    private static func writePage(
        _ fonts: [FontEntry],
        to url: URL,
        labelFont: CTFont,
        page: Int,
        of pageCount: Int
    ) throws {
        let width = labelWidth + probe.count * cellPx
        let height = headerHeight + fonts.count * cellPx
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ContactSheetError.contextFailed
        }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        // 用紙は白
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // --- 凡例 (ページ上部) ---
        let legend = "\(page) / \(pageCount) ページ  —  em \(em)px でマス目に描き マス目基準で 32x32 にした画像 を \(scale) 倍表示"
        let legend2 = "灰色の桝 = グリフ無し (skip)   赤枠の桝 = 描いたが墨なし (skip)   細い枠 = マス目の境界"
        let legend3 = String(probe)
        drawText(legend, in: ctx, at: CGPoint(x: 16, y: CGFloat(height) - 44), font: labelFont, gray: 0.0)
        drawText(legend2, in: ctx, at: CGPoint(x: 16, y: CGFloat(height) - 80), font: labelFont, gray: 0.25)
        drawText("確認文字: " + legend3, in: ctx, at: CGPoint(x: 16, y: CGFloat(height) - 116), font: labelFont, gray: 0.25)

        // --- 各行 ---
        for (row, entry) in fonts.enumerated() {
            // CG は下が原点。行はページ上から並べる
            let top = CGFloat(height - headerHeight - row * cellPx)
            let bottom = top - CGFloat(cellPx)

            drawText(
                entry.postScriptName,
                in: ctx,
                at: CGPoint(x: 12, y: bottom + CGFloat(cellPx) * 0.5 - 10),
                font: labelFont,
                gray: 0.0
            )

            guard let font = entry.fontsBySize[em] ?? entry.fontsBySize.values.first else {
                continue
            }
            for (col, ch) in probe.enumerated() {
                let x = CGFloat(labelWidth + col * cellPx)
                let rect = CGRect(x: x, y: bottom, width: CGFloat(cellPx), height: CGFloat(cellPx))
                switch state(of: ch, font: font) {
                case .noGlyph:
                    ctx.setFillColor(red: 0.78, green: 0.78, blue: 0.78, alpha: 1)
                    ctx.fill(rect)
                case .blank:
                    ctx.setStrokeColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
                    ctx.setLineWidth(4)
                    ctx.stroke(rect.insetBy(dx: 2, dy: 2))
                case .drawn(let image):
                    if let cg = makeGrayImage(image) {
                        ctx.interpolationQuality = .none
                        ctx.draw(cg, in: rect)
                    }
                }
                // マス目の境界
                ctx.setStrokeColor(red: 0.8, green: 0.8, blue: 0.85, alpha: 1)
                ctx.setLineWidth(1)
                ctx.stroke(rect)
            }
        }

        guard let image = ctx.makeImage() else {
            throw ContactSheetError.imageFailed
        }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ContactSheetError.writeFailed(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) {
            throw ContactSheetError.writeFailed(url.path)
        }
    }

    private static func state(of ch: Character, font: CTFont) -> CellState {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            return .noGlyph
        }
        guard let glyph = FontLoader.glyph(font, scalar) else {
            return .noGlyph
        }
        guard let cell = GlyphRenderer.renderCell(font: font, glyph: glyph, em: em) else {
            return .blank
        }
        guard let image = try? ImageNormalizer.normalize(
            width: em, height: em, gray: cell.gray, invert: true
        ) else {
            return .blank
        }
        if image.inkSum <= 0.0 {
            return .blank
        }
        return .drawn(image)
    }

    /// 32x32 の墨画像を白地黒字の CGImage にする (拡大は呼び出し側で nearest)
    private static func makeGrayImage(_ image: CharacterImage) -> CGImage? {
        let side = CharacterImage.side
        let ctx = GrayBitmap.makeContext(width: side, height: side) { x, y in
            // 墨 1.0 -> 黒 0、紙 0.0 -> 白 255。y = 0 が上端 (画像と同じ向き)
            let v = 255.0 - image[x, y] * 255.0
            return UInt8(max(0.0, min(255.0, v.rounded())))
        }
        return ctx?.makeImage()
    }

    private static func drawText(
        _ text: String,
        in ctx: CGContext,
        at point: CGPoint,
        font: CTFont,
        gray: CGFloat
    ) {
        let color = CGColor(red: gray, green: gray, blue: gray, alpha: 1)
        // AppKit を入れないので CoreText の属性キーを直接使う
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }
}

enum ContactSheetError: Error, CustomStringConvertible {
    case contextFailed
    case imageFailed
    case writeFailed(String)

    var description: String {
        switch self {
        case .contextFailed: return "描画コンテキストを作れません"
        case .imageFailed:   return "画像を取り出せません"
        case .writeFailed(let p): return "PNG を書けません: \(p)"
        }
    }
}

// MARK: - 出力先

/// DatasetWriter への書き込みを直列化し、クラスごとの上限も見る。
final class SampleSink: @unchecked Sendable {
    private let writer: DatasetWriter
    private let lock = NSLock()
    private var perClass: [Int: Int] = [:]
    private let limitPerClass: Int
    private(set) var written = 0
    private(set) var droppedByLimit = 0
    private(set) var fontNames: [String] = []

    init(writer: DatasetWriter, limitPerClass: Int) {
        self.writer = writer
        self.limitPerClass = limitPerClass
    }

    func write(fontName: String, samples: [(label: Int, image: CharacterImage)]) throws {
        lock.lock()
        defer { lock.unlock() }
        if !fontNames.contains(fontName) {
            fontNames.append(fontName)
        }
        for s in samples {
            if limitPerClass > 0 && perClass[s.label, default: 0] >= limitPerClass {
                droppedByLimit += 1
                continue
            }
            try writer.append(label: s.label, image: s.image)
            perClass[s.label, default: 0] += 1
            written += 1
        }
    }

    /// 1 件以上書けたクラスの数
    var coveredClasses: Int {
        lock.lock()
        defer { lock.unlock() }
        return perClass.count
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        try writer.close()
    }
}

/// 1 フォント分の集計
struct FontStats: Sendable {
    var font = ""
    var origin = ""
    var drawn = 0
    var skippedNoGlyph = 0
    var skippedBlank = 0
    var samples = 0
    /// マス目から 5% 以上はみ出した文字の数
    var overflowOver5 = 0
    /// はみ出し割合の合計 (平均を出すのに使う)
    var overflowSum = 0.0
    /// はみ出し割合の最大
    var overflowMax = 0.0
    var seconds = 0.0
}

final class StatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stats: [FontStats] = []
    func add(_ s: FontStats) {
        lock.lock()
        stats.append(s)
        lock.unlock()
    }
}

// MARK: - 本体

func run() {
    let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
    let vocab = CharacterVocabulary.shared
    let started = Date()

    // --- フォントの読み込み ---
    // 数百〜数千ファイルになるので、被覆率の走査 (1 フォントあたり語彙数ぶんのグリフ検索) を
    // 並列化する。CTFont は不変で thread-safe。結果は後で名前順に並べ直すので決定的。
    var entries = [FontEntry]()
    var rejected = [(name: String, reason: String)]()
    var seenPSNames = Set<String>()

    // 正規表現フィルタ (PostScript 名かファイル名に当てる)
    var filterRegex: NSRegularExpression?
    if let pattern = options.fontFilter {
        do {
            filterRegex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            fail("--font-filter の正規表現が不正です: \(pattern): \(error)")
        }
    }
    func passesFilter(name: String, fileName: String) -> Bool {
        guard let re = filterRegex else {
            return true
        }
        for s in [name, fileName] where !s.isEmpty {
            let r = NSRange(s.startIndex ..< s.endIndex, in: s)
            if re.firstMatch(in: s, options: [], range: r) != nil {
                return true
            }
        }
        return false
    }

    let fontsDirURL = URL(fileURLWithPath: options.fontsDir)
    var fileURLs = [URL]()
    if let items = try? FileManager.default.contentsOfDirectory(
        at: fontsDirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) {
        // 直下のみ。dedupe.sh が重複排除してフラットに置いた前提
        fileURLs = items
            .filter { ["ttf", "otf", "ttc"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } else {
        logLine("警告: フォントディレクトリを読めません: \(options.fontsDir)")
    }

    // ファイル名の時点でフィルタを掛け、読み込む本数自体を減らす
    let targetFileURLs = fileURLs.filter { passesFilter(name: "", fileName: $0.lastPathComponent) }
    // 明示指定が無ければ <fonts-dir>/system-fonts.txt から読む (ソースに名前を持たない)
    let systemFontNames = options.systemFonts ?? Options.loadSystemFontList(fontsDir: options.fontsDir)
    let targetSystemNames = systemFontNames.filter { passesFilter(name: $0, fileName: "") }
    let skippedByFilter = (fileURLs.count - targetFileURLs.count)
        + (systemFontNames.count - targetSystemNames.count)

    let collector = LoadCollector()
    let loadWidth = max(1, min(options.workers, max(1, targetSystemNames.count + targetFileURLs.count)))
    let totalToLoad = targetSystemNames.count + targetFileURLs.count
    logLine("== フォント読み込み: system \(targetSystemNames.count) + ファイル \(targetFileURLs.count) 件 (並列 \(loadWidth))")

    DispatchQueue.concurrentPerform(iterations: loadWidth) { chunk in
        var i = chunk
        while i < totalToLoad {
            if i < targetSystemNames.count {
                let psName = targetSystemNames[i]
                switch FontLoader.loadSystem(psName, sizes: options.sizes, scripts: options.scripts) {
                case .loaded(let e):  collector.addLoaded(e)
                case .rejected(let w): collector.addRejected(psName, w)
                }
            } else {
                let url = targetFileURLs[i - targetSystemNames.count]
                for r in FontLoader.loadFile(url, sizes: options.sizes, scripts: options.scripts) {
                    switch r {
                    case .loaded(let e):  collector.addLoaded(e)
                    case .rejected(let w): collector.addRejected(url.lastPathComponent, w)
                    }
                }
            }
            i += loadWidth
        }
    }

    // PostScript 名で重複排除。並列で集めたので名前順に並べてから決定的に選ぶ。
    // system を優先し、その後はファイル名順。
    let loadedSorted = collector.loaded.sorted { a, b in
        if a.postScriptName != b.postScriptName {
            return a.postScriptName < b.postScriptName
        }
        let aSystem = a.origin.shortLabel == "system"
        let bSystem = b.origin.shortLabel == "system"
        if aSystem != bSystem {
            return aSystem
        }
        return a.origin.path < b.origin.path
    }
    // --list-faces-tsv: 重複排除する前の全 face を書き出して終了する。
    // 可変フォントは名前付きインスタンスごとに 1 行になる。
    if let facesPath = options.listFacesTSV {
        var t = "postscript_name\torigin\tpath\n"
        for e in loadedSorted {
            t += e.postScriptName + "\t" + e.origin.shortLabel + "\t" + e.origin.path + "\n"
        }
        let u = URL(fileURLWithPath: facesPath)
        do {
            try FileManager.default.createDirectory(
                at: u.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try t.write(to: u, atomically: true, encoding: .utf8)
        } catch {
            fail("face TSV を書けません: \(facesPath): \(error)")
        }
        let names = loadedSorted.map { $0.postScriptName }
        let dupes = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }
        print("face 総数: \(loadedSorted.count)")
        print("ユニークな PostScript 名: \(Set(names).count)")
        print("2 つ以上のファイルが名乗る PostScript 名: \(dupes.count)")
        print("出力: \(facesPath)")
        return
    }

    rejected = collector.rejected
    for e in loadedSorted {
        if seenPSNames.contains(e.postScriptName) {
            let who = e.origin.path.isEmpty ? e.postScriptName : (e.origin.path as NSString).lastPathComponent
            rejected.append((who, "PostScript 名 \(e.postScriptName) が重複 (先に読んだものを使う)"))
            continue
        }
        seenPSNames.insert(e.postScriptName)
        entries.append(e)
    }

    // 対象区分のグリフを 1 つも持たないフォントは自動でスキップする
    // (Latin 専用フォントに --scripts hiragana を指定した場合など)。
    // --list-fonts のときは被覆率を見せたいので落とさない。
    var skippedNoCoverage = 0
    if !options.listFonts {
        let before = entries.count
        entries = entries.filter { !$0.drawable.isEmpty }
        skippedNoCoverage = before - entries.count
    }

    // --require-script: 指定区分のグリフを持たないフォントを落とす
    var skippedByRequire = 0
    if !options.requireScripts.isEmpty && !options.listFonts {
        let before = entries.count
        entries = entries.filter { e in
            for c in options.requireScripts where (e.coverage[c]?.have ?? 0) > 0 {
                return true
            }
            return false
        }
        skippedByRequire = before - entries.count
    }
    if skippedByRequire > 0 {
        logLine("   --require-script \(options.requireScripts.map { $0.rawValue }.joined(separator: ",")) により \(skippedByRequire) 件を除外")
    }

    // held-out の照合はファミリー単位で行う。
    // ファミリー名 = PostScript 名の最初の '-' より前 (例 "Foo-SemiBold" -> "Foo")。
    // 指定側も同じ規則で切り出すので、"Foo" でも "Foo-Regular.ttf" でも同じ結果になる。
    // 前方一致なので、そのファミリーの全ウェイト・全バージョンがまとめて eval 側へ回る
    // (同じ書体の別ウェイトが train と eval に割れると held-out の意味が無くなるため)。
    func familyName(_ raw: String) -> String {
        var name = raw
        for ext in [".ttf", ".otf", ".ttc"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        if let i = name.firstIndex(of: "-") {
            name = String(name[name.startIndex ..< i])
        }
        return name.lowercased()
    }

    func matches(_ e: FontEntry, _ needle: String) -> Bool {
        return familyName(e.postScriptName).hasPrefix(familyName(needle))
    }

    func isHoldout(_ e: FontEntry) -> Bool {
        for needle in options.holdoutFonts where matches(e, needle) {
            return true
        }
        return false
    }

    // --max-fonts: シード付きの決定的な抽出 (並び順に依存しないよう名前順に並べてから引く)。
    // held-out に指定されたフォントは必ず残し、残り枠を train 候補から引く
    // (抽出で holdout が落ちると eval が空になってしまうため)。
    var sampledOut = 0
    if options.maxFonts > 0 && entries.count > options.maxFonts && !options.listFonts {
        let keep = entries.filter { isHoldout($0) }.sorted { $0.postScriptName < $1.postScriptName }
        var pool = entries.filter { !isHoldout($0) }.sorted { $0.postScriptName < $1.postScriptName }
        let slots = max(0, options.maxFonts - keep.count)
        if slots < pool.count {
            var rng = SplitMix64(seed: options.seed)
            var i = 0
            while i < slots {
                let j = i + Int(rng.next() % UInt64(pool.count - i))
                pool.swapAt(i, j)
                i += 1
            }
            pool = Array(pool.prefix(slots))
        }
        sampledOut = entries.count - (keep.count + pool.count)
        entries = (keep + pool).sorted { $0.postScriptName < $1.postScriptName }
        if keep.count > 0 {
            logLine("   --max-fonts: held-out \(keep.count) 件は抽出対象から外して必ず残す")
        }
    }

    if skippedByFilter > 0 {
        logLine("   --font-filter で除外 \(skippedByFilter) 件")
    }
    if skippedNoCoverage > 0 {
        logLine("   対象区分のグリフが 0 のため自動スキップ \(skippedNoCoverage) 件")
    }
    if sampledOut > 0 {
        logLine("   --max-fonts \(options.maxFonts) により \(sampledOut) 件を抽出で除外 (seed \(options.seed))")
    }

    if entries.isEmpty {
        fail("読み込めたフォントが 1 つもありません (--list-fonts で確認してください)")
    }

    // --- --list-fonts ---
    if options.listFonts {
        printFontTable(entries: entries, rejected: rejected, scripts: options.scripts, tsvPath: options.listFontsTSV)
        return
    }

    // --- train / eval の振り分け ---
    let evalEntries = entries.filter { isHoldout($0) }
    let trainEntries = entries.filter { !isHoldout($0) }

    for needle in options.holdoutFonts {
        var hit = false
        for e in evalEntries where matches(e, needle) {
            hit = true
        }
        if !hit {
            logLine("警告: --holdout-fonts \"\(needle)\" に一致するフォントがありません")
        }
    }

    if trainEntries.isEmpty {
        fail("train 側のフォントが 0 です (--holdout-fonts が全フォントに一致しています)")
    }
    if !options.holdoutFonts.isEmpty && evalEntries.isEmpty {
        fail("eval 側のフォントが 0 です (--holdout-fonts が 1 つも一致しません)")
    }

    // --- --contact-sheet: 目視確認シートを書いて終了する ---
    if let sheetDir = options.contactSheetDir {
        // ラベルの描画に使うフォントは system-fonts.txt の先頭。
        // 読めなければ CoreText の既定 UI フォント (どちらもソースに名前を持たない)。
        var labelFont = CTFontCreateUIFontForLanguage(.system, 26.0, nil)
            ?? CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes([:] as CFDictionary), 26.0, nil)
        if let first = Options.loadSystemFontList(fontsDir: options.fontsDir).first {
            let candidate = CTFontCreateWithName(first as CFString, 26.0, nil)
            if (CTFontCopyPostScriptName(candidate) as String) == first {
                labelFont = candidate
            }
        }
        do {
            let pages = try ContactSheet.write(
                entries: entries, directory: sheetDir, labelFont: labelFont
            )
            print("コンタクトシート: \(entries.count) 書体 / \(pages) ページ -> \(sheetDir)")
            print("  確認文字列: \(String(ContactSheet.probe)) (\(ContactSheet.probe.count) 文字)")
            print("  桝: em \(ContactSheet.em)px で描き マス目基準で 32x32 にした画像 を \(ContactSheet.scale) 倍")
        } catch {
            fail("コンタクトシートを書けません: \(error)")
        }
        return
    }

    // --- --dry-run: ここまでの解決結果だけ出して終了する (ファイルを一切作らない) ---
    if options.dryRun {
        print("dry-run: 何も書き込みません")
        print("対象フォント \(entries.count) 件 (train \(trainEntries.count) / eval \(evalEntries.count))")
        print("区分 \(options.scripts.map { $0.rawValue }.joined(separator: ",")) / サイズ \(options.sizes.map(String.init).joined(separator: ",")) / 拡張 \(options.augment)")
        if options.holdoutFonts.isEmpty {
            print("--holdout-fonts の指定なし")
        } else {
            print("")
            print("--holdout-fonts \(options.holdoutFonts.joined(separator: ",")) で eval に回るフォント (\(evalEntries.count) 件):")
            for e in evalEntries.sorted(by: { $0.postScriptName < $1.postScriptName }) {
                let file = e.origin.path.isEmpty ? "(system)" : (e.origin.path as NSString).lastPathComponent
                print("  \(e.postScriptName.padding(toLength: 34, withPad: " ", startingAt: 0)) ファミリー=\(familyName(e.postScriptName).padding(toLength: 18, withPad: " ", startingAt: 0)) \(file)")
            }
        }
        print("")
        print("train に残るフォント \(trainEntries.count) 件 (先頭 10)")
        for e in trainEntries.sorted(by: { $0.postScriptName < $1.postScriptName }).prefix(10) {
            print("  \(e.postScriptName)")
        }
        return
    }

    // --- 出力先 ---
    let outDir = URL(fileURLWithPath: options.outDir)
    do {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    } catch {
        fail("出力先を作れません: \(options.outDir): \(error)")
    }
    let trainURL = outDir.appendingPathComponent("\(options.name)_train.stgk")
    let evalURL = outDir.appendingPathComponent("\(options.name)_eval.stgk")

    let trainSink: SampleSink
    let evalSink: SampleSink?
    do {
        trainSink = SampleSink(writer: try DatasetWriter(url: trainURL), limitPerClass: options.limitPerClass)
        evalSink = evalEntries.isEmpty
            ? nil
            : SampleSink(writer: try DatasetWriter(url: evalURL), limitPerClass: options.limitPerClass)
    } catch {
        fail("データセットを開けません: \(error)")
    }

    logLine("== render: フォント \(entries.count) 件 (train \(trainEntries.count) / eval \(evalEntries.count))")
    logLine("   区分 \(options.scripts.map { $0.rawValue }.joined(separator: ",")) / サイズ \(options.sizes.map(String.init).joined(separator: ",")) / 拡張 \(options.augment) / workers \(options.workers)")

    let statsBox = StatsBox()

    // 1 フォント分の生成。拡張の乱数シードはフォント固定なのでスレッドの割り当てに依存しない。
    @Sendable func process(entry: FontEntry, fontIndex: Int, sink: SampleSink) {
        let t0 = Date()
        var stats = FontStats()
        stats.font = entry.postScriptName
        stats.origin = entry.origin.shortLabel

        let augmenter = Augmenter(seed: options.seed &+ UInt64(fontIndex) &* 0x9E3779B97F4A7C15)
        let vocabCount = vocab.count

        for size in options.sizes {
            guard let font = entry.fontsBySize[size] else {
                continue
            }
            // 1 em 四方がマス目。em = 描画サイズ (18 / 36 / 64 px)
            let em = max(8, size)
            var batch = [(label: Int, image: CharacterImage)]()
            batch.reserveCapacity(entry.drawable.count * (1 + options.augment))

            for item in entry.drawable {
                if item.index < 0 || item.index >= vocabCount {
                    continue
                }
                guard let glyph = FontLoader.glyph(font, item.scalar) else {
                    stats.skippedNoGlyph += 1
                    continue
                }
                guard let cell = GlyphRenderer.renderCell(font: font, glyph: glyph, em: em) else {
                    stats.skippedBlank += 1
                    continue
                }
                stats.overflowSum += Double(cell.overflowRatio)
                if Double(cell.overflowRatio) > stats.overflowMax {
                    stats.overflowMax = Double(cell.overflowRatio)
                }
                if cell.overflowRatio >= 0.05 {
                    stats.overflowOver5 += 1
                }
                guard let base = try? ImageNormalizer.normalize(
                    width: em, height: em, gray: cell.gray, invert: true
                ) else {
                    stats.skippedBlank += 1
                    continue
                }
                if base.inkSum <= 0.0 {
                    // 描いたが墨が 1 画素も無い (空白グリフ・小さすぎて潰れた)
                    stats.skippedBlank += 1
                    continue
                }
                stats.drawn += 1
                batch.append((label: item.index, image: base))
                var a = 0
                while a < options.augment {
                    batch.append((label: item.index, image: augmenter.augment(base)))
                    a += 1
                }
            }

            do {
                try sink.write(fontName: entry.postScriptName, samples: batch)
            } catch {
                fail("書き込みに失敗: \(entry.postScriptName) size \(size): \(error)")
            }
            stats.samples += batch.count
        }

        stats.seconds = Date().timeIntervalSince(t0)
        statsBox.add(stats)
        let namePad = entry.postScriptName.padding(toLength: 34, withPad: " ", startingAt: 0)
        let originPad = stats.origin.padding(toLength: 9, withPad: " ", startingAt: 0)
        let overflowAvg = stats.drawn > 0 ? stats.overflowSum / Double(stats.drawn) : 0.0
        logLine("   [\(namePad)] \(originPad) 描画 \(stats.drawn) / グリフ無し \(stats.skippedNoGlyph)"
            + " / 空画像 \(stats.skippedBlank) / サンプル \(stats.samples)"
            + " / はみ出し 5%以上 \(stats.overflowOver5) (平均 \(String(format: "%.3f", overflowAvg))"
            + " 最大 \(String(format: "%.3f", stats.overflowMax)))"
            + " / \(String(format: "%.1f", stats.seconds)) 秒")
    }

    // --- 並列実行 (フォント単位。--workers で束ねる数を決める) ---
    func runGroup(_ list: [FontEntry], offset: Int, sink: SampleSink) {
        if list.isEmpty {
            return
        }
        let width = max(1, min(options.workers, list.count))
        if width == 1 {
            for (i, e) in list.enumerated() {
                process(entry: e, fontIndex: offset + i, sink: sink)
            }
            return
        }
        DispatchQueue.concurrentPerform(iterations: width) { chunk in
            var i = chunk
            while i < list.count {
                process(entry: list[i], fontIndex: offset + i, sink: sink)
                i += width
            }
        }
    }

    runGroup(trainEntries, offset: 0, sink: trainSink)
    if let evalSink {
        runGroup(evalEntries, offset: trainEntries.count, sink: evalSink)
    }

    // --- 後始末とメタ ---
    do {
        try trainSink.close()
        try evalSink?.close()
    } catch {
        fail("データセットを閉じられません: \(error)")
    }

    let scriptNames = options.scripts.map { $0.rawValue }
    do {
        try DatasetMeta(
            fonts: trainEntries.map { $0.postScriptName }.sorted(),
            augmentations: options.augment,
            scripts: scriptNames
        ).write(to: DatasetMeta.sidecarURL(for: trainURL))
        if evalSink != nil {
            try DatasetMeta(
                fonts: evalEntries.map { $0.postScriptName }.sorted(),
                augmentations: options.augment,
                scripts: scriptNames
            ).write(to: DatasetMeta.sidecarURL(for: evalURL))
        }
    } catch {
        fail("メタ JSON を書けません: \(error)")
    }

    // --- まとめ ---
    let elapsed = Date().timeIntervalSince(started)
    var totalDrawn = 0
    var totalNoGlyph = 0
    var totalBlank = 0
    var totalOverflow5 = 0
    var totalOverflowSum = 0.0
    var globalOverflowMax = 0.0
    for s in statsBox.stats {
        totalDrawn += s.drawn
        totalNoGlyph += s.skippedNoGlyph
        totalBlank += s.skippedBlank
        totalOverflow5 += s.overflowOver5
        totalOverflowSum += s.overflowSum
        if s.overflowMax > globalOverflowMax {
            globalOverflowMax = s.overflowMax
        }
    }

    logLine("")
    logLine("== 完了 (\(String(format: "%.1f", elapsed)) 秒)")
    logLine("   train: \(trainSink.written) サンプル / \(trainSink.coveredClasses) クラス -> \(trainURL.path)")
    if let evalSink {
        logLine("   eval : \(evalSink.written) サンプル / \(evalSink.coveredClasses) クラス -> \(evalURL.path)")
    }
    logLine("   描画成功 \(totalDrawn) / グリフ無しスキップ \(totalNoGlyph) / 空画像スキップ \(totalBlank)")
    let avgOverflow = totalDrawn > 0 ? totalOverflowSum / Double(totalDrawn) : 0.0
    let pct = totalDrawn > 0 ? 100.0 * Double(totalOverflow5) / Double(totalDrawn) : 0.0
    logLine("   マス目からのはみ出し: 5%以上 \(totalOverflow5) 件 (\(String(format: "%.2f", pct))%)"
        + " / 平均 \(String(format: "%.4f", avgOverflow)) / 最大 \(String(format: "%.3f", globalOverflowMax))")
    if options.limitPerClass > 0 {
        let dropped = trainSink.droppedByLimit + (evalSink?.droppedByLimit ?? 0)
        logLine("   --limit-per-class \(options.limitPerClass) による除外 \(dropped)")
    }
    if !rejected.isEmpty {
        logLine("   読み込めなかったフォント \(rejected.count) 件:")
        for r in rejected {
            logLine("     \(r.name): \(r.reason)")
        }
    }

    // 標準出力には機械可読な 1 行だけ出す
    print("train=\(trainSink.written) eval=\(evalSink?.written ?? 0) fonts=\(entries.count) seconds=\(String(format: "%.1f", elapsed))")
}

func printFontTable(
    entries: [FontEntry],
    rejected: [(name: String, reason: String)],
    scripts: [ScriptCategory],
    tsvPath: String
) {
    let order: [ScriptCategory] = ScriptCategory.allCases
    let sorted = entries.sorted { $0.postScriptName < $1.postScriptName }

    // --- TSV (全件。数千行になるのでファイルへ) ---
    var tsv = "postscript_name\torigin\tpath"
    for c in order {
        tsv += "\t" + c.rawValue
    }
    tsv += "\tdrawable_in_scope\n"
    for e in sorted {
        tsv += e.postScriptName + "\t" + e.origin.shortLabel + "\t" + e.origin.path
        for c in order {
            let cov = e.coverage[c] ?? (have: 0, total: 0)
            tsv += "\t\(cov.have)/\(cov.total)"
        }
        tsv += "\t\(e.drawable.count)\n"
    }
    let tsvURL = URL(fileURLWithPath: tsvPath)
    do {
        try FileManager.default.createDirectory(
            at: tsvURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try tsv.write(to: tsvURL, atomically: true, encoding: .utf8)
    } catch {
        logLine("警告: TSV を書けません: \(tsvPath): \(error)")
    }

    // --- 標準出力には要約だけ ---
    let jp = sorted.filter { ($0.coverage[.hiragana]?.have ?? 0) >= 80 }
    let kanjiFull = sorted.filter { ($0.coverage[.kanjiLevel1]?.have ?? 0) >= 2965 }
    let kanjiSome = sorted.filter { ($0.coverage[.kanjiLevel1]?.have ?? 0) > 0 }
    let latinOnly = sorted.filter {
        ($0.coverage[.hiragana]?.have ?? 0) == 0
            && ($0.coverage[.kanjiLevel1]?.have ?? 0) == 0
            && ($0.coverage[.latinUpper]?.have ?? 0) > 0
    }

    print("読み込めたフォント: \(sorted.count) 件")
    print("  日本語被覆あり (hiragana >= 80) : \(jp.count) 件")
    print("  第一水準漢字を全部持つ (2965)   : \(kanjiFull.count) 件")
    print("  漢字を 1 字でも持つ             : \(kanjiSome.count) 件")
    print("  Latin 専用 (かな 0 / 漢字 0)    : \(latinOnly.count) 件")
    print("  対象区分: \(scripts.map { $0.rawValue }.joined(separator: ","))")
    print("  描ける文字数 (対象区分のみ) の合計: \(sorted.reduce(0) { $0 + $1.drawable.count })")
    print("  全件の被覆率 TSV: \(tsvPath)")

    func sample(_ list: [FontEntry], _ label: String, _ n: Int) {
        if list.isEmpty {
            return
        }
        print("")
        print("  -- \(label) の例 (先頭 \(min(n, list.count)) 件) --")
        var header = "     " + "PostScript 名".padding(toLength: 34, withPad: " ", startingAt: 0)
        header += " " + "出自".padding(toLength: 10, withPad: " ", startingAt: 0)
        for h in ["digit", "ascii", "upper", "lower", "hira", "kata", "kanji"] {
            header += " " + h.padding(toLength: 11, withPad: " ", startingAt: 0)
        }
        print(header)
        for e in list.prefix(n) {
            var line = "     " + e.postScriptName.padding(toLength: 34, withPad: " ", startingAt: 0)
            line += " " + e.origin.shortLabel.padding(toLength: 10, withPad: " ", startingAt: 0)
            for c in order {
                let cov = e.coverage[c] ?? (have: 0, total: 0)
                line += " " + "\(cov.have)/\(cov.total)".padding(toLength: 11, withPad: " ", startingAt: 0)
            }
            print(line)
        }
    }

    sample(jp, "日本語被覆あり", 20)
    sample(latinOnly, "Latin 専用", 10)

    if !rejected.isEmpty {
        // 全件はファイルへ (PostScript 名の重複 = 同名だが内容の違うファイルの一覧になる)
        let rejURL = URL(fileURLWithPath: tsvPath + ".rejected.tsv")
        var rt = "source\treason\n"
        for r in rejected.sorted(by: { $0.name < $1.name }) {
            rt += r.name + "\t" + r.reason + "\n"
        }
        try? rt.write(to: rejURL, atomically: true, encoding: .utf8)

        print("")
        print("読み込めなかった / 除外したフォント: \(rejected.count) 件 (フォールバックしたものはこの表に載せない)")
        print("  全件: \(rejURL.path)")
        for r in rejected.prefix(15) {
            print("  \(r.name): \(r.reason)")
        }
        if rejected.count > 15 {
            print("  ... 残り \(rejected.count - 15) 件は上のファイルを参照")
        }
    }
}

run()
exit(0)
