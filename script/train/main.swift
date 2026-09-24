import Foundation
import Spiketegaki
import SpiketegakiTraining
import MLX
#if canImport(Darwin)
import Darwin
#endif

// 学習ログは行ごとに読みたいのでバッファリングを切る
setbuf(stdout, nil)

// MARK: - 既定値 (kana 実験で最も安定した組み合わせ)

enum Defaults {
    static let epochs = 20
    static let batchSize = 128
    /// 層 0 が再帰 LIF、層 1 以降が電流残差付きフィードフォワード LIF。
    /// kana 実験では 4 層 → 8 層で held-out top-1 が 63.8% → 70.7% と +6.9 ポイント改善した
    /// (幅を 512 → 1024 にする方は逆に -2.8 ポイントで、計算量に見合わなかった)
    static let numLayers = 8
    static let maxHiddenDim = 512
    /// 1 フレームあたりの LIF サブステップ数
    static let timeSteps = 4
    /// 分類ロジットに使う末尾フレーム数。32 = 全フレーム平均。
    /// kana 実験では 8 に絞ると held-out top-1 が 63.8% → 44.0% と 19.7 ポイント悪化したので全平均に戻した
    static let readoutFrames = 32
    /// clip 5.0 は kana 実験で損失スパイク (epoch 3 で正解率が 34% → 22% に反転) を起こしたので 1.0 にした。
    ///
    /// lrMax は 0.003 → 0.0015。マス目データ (R5) では lr が 0.003 のうち epoch 1〜9 が
    /// 不安定帯 (epoch 5 で損失 mean 3.97 / max 7.79 のスパイク、eval が 25〜40% を往復) で、
    /// cosine 減衰で lr が 0.0019 を切った epoch 10 以降にようやく単調改善に入った。
    ///
    /// 注意: 外接矩形データでの 2 epoch アブレーションでは lr 0.0015 単独 = 17.3% と
    /// 0.003 (39.8%) より悪かった。ただし (a) 2 epoch しか回しておらず低い lr が不利な比較で、
    /// (b) マス目データではない。0.0015 が 20 epoch でどう出るかは未検証。
    /// warmup は 0 のまま (lr 変更と同時に足すと学習が成立しなかった実績があるため一度に 1 つだけ変える)。
    static let lrMax: Float = 0.0015
    static let lrMin: Float = 0.0005
    static let clipNorm: Float = 1.0
    /// 線形 warmup のステップ数。既定は 0 (無効)。
    /// kana 実験では warmup を入れると学習が遅くなり、lr を下げた設定と併用すると学習が成立しなかった
    static let warmupSteps = 0
    static let seed: UInt64 = 42
    static let logInterval = 50
    static let lifConfig = LIFConfig()

    /// 学習セットから正解率を測る最大件数。全件測ると評価だけで学習と同じ時間がかかる
    static let maxTrainEvalSamples = 5000

    /// --synthetic の疑似データ
    static let syntheticClasses = 200
    static let syntheticTrainPerClass = 96
    static let syntheticEvalPerClass = 16
}

// MARK: - エラー終了

/// 仕様外の入力は理由を書いて終了する。クラッシュ (precondition / 強制アンラップ) で落とさない
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("エラー: \(message)\n".utf8))
    exit(1)
}

// MARK: - 決定的な乱数 (SplitMix64)

/// シャッフルと疑似データ生成に使う。seed 固定で同じ並びを再現する
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Box-Muller の片側。ガウスノイズ用
    mutating func nextGaussian() -> Float {
        let u1 = max(Float.leastNormalMagnitude, Float.random(in: 0.0 ..< 1.0, using: &self))
        let u2 = Float.random(in: 0.0 ..< 1.0, using: &self)
        return sqrt(-2.0 * log(u1)) * cos(2.0 * Float.pi * u2)
    }
}

// MARK: - コマンドライン引数

var trainPath = ""
var evalPath = ""
var epochs = Defaults.epochs
var batchSize = Defaults.batchSize
var numLayers = Defaults.numLayers
var maxHiddenDim = Defaults.maxHiddenDim
var timeSteps = Defaults.timeSteps
var lrMax = Defaults.lrMax
var lrMin = Defaults.lrMin
var seed = Defaults.seed
var exportPath: String? = nil
var importPath: String? = nil
var logInterval = Defaults.logInterval
var sampleLimit: Int? = nil
var useSynthetic = false
var warmupSteps = Defaults.warmupSteps
var clipNorm = Defaults.clipNorm
var readoutFrames = Defaults.readoutFrames

func printUsage() {
    print("使い方: train --train <stgk> --eval <stgk> [オプション]")
    print("        train --synthetic [オプション]")
    print("")
    print("  --train <パス>        学習用 DatasetFile (.stgk)")
    print("  --eval <パス>         評価用 DatasetFile (.stgk、held-out フォント)")
    print("  --epochs <Int>        エポック数 (既定: \(Defaults.epochs)、1 以上)")
    print("  --batch <Int>         ミニバッチサイズ (既定: \(Defaults.batchSize)、1 以上)")
    print("  --layers <Int>        SNN の層数 (既定: \(Defaults.numLayers))")
    print("  --hidden <Int>        隠れ層の次元 (既定: \(Defaults.maxHiddenDim))")
    print("  --time-steps <Int>    1 フレームあたりの LIF サブステップ数 (既定: \(Defaults.timeSteps))")
    print("  --lr-max <Float>      warmup 後の最大学習率 (既定: \(Defaults.lrMax))")
    print("  --lr-min <Float>      cosine の最終学習率 (既定: \(Defaults.lrMin))")
    print("  --warmup-steps <Int>  lr-min → lr-max の線形 warmup ステップ数 (既定: \(Defaults.warmupSteps)、0 で無効)")
    print("  --clip <Float>        勾配の global norm 上限 (既定: \(Defaults.clipNorm))")
    print("  --readout-frames <Int> 分類に使う末尾フレーム数 (既定: \(Defaults.readoutFrames)、1..\(ScanlineEncoder.frameCount))")
    print("  --seed <Int>          シャッフルと初期化のシード (既定: \(Defaults.seed))")
    print("  --export <パス>       最良 top-1 の重み JSON 出力先 (一時ファイル → rename)")
    print("  --import <パス>       初期重みの JSON。読み込み直後に eval を 1 度回す")
    print("  --log-interval <Int>  何ステップごとにログを出すか (既定: \(Defaults.logInterval))")
    print("  --limit <Int>         デバッグ用の読み込みサンプル上限 (学習・評価の両方に適用)")
    print("  --synthetic           データセット無しで疑似データを作り、学習ループ全体を通す")
    print("  -h, --help            この使い方を表示")
}

/// `--foo` の次の引数を取る。無ければ理由を書いて終了する
func takeValue(_ args: [String], _ index: inout Int, _ name: String) -> String {
    if args.count <= index + 1 {
        fail("\(name) に値がありません")
    }
    index += 1
    return args[index]
}

func parseInt(_ text: String, _ name: String) -> Int {
    guard let value = Int(text) else {
        fail("\(name) は整数で指定してください (受け取った値: \(text))")
    }
    return value
}

func parseUInt64(_ text: String, _ name: String) -> UInt64 {
    guard let value = UInt64(text) else {
        fail("\(name) は 0 以上の整数で指定してください (受け取った値: \(text))")
    }
    return value
}

func parseFloat(_ text: String, _ name: String) -> Float {
    guard let value = Float(text), value.isFinite else {
        fail("\(name) は有限の実数で指定してください (受け取った値: \(text))")
    }
    return value
}

do {
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            printUsage()
            exit(0)
        case "--train":
            trainPath = takeValue(args, &i, arg)
        case "--eval":
            evalPath = takeValue(args, &i, arg)
        case "--epochs":
            epochs = parseInt(takeValue(args, &i, arg), arg)
        case "--batch":
            batchSize = parseInt(takeValue(args, &i, arg), arg)
        case "--layers":
            numLayers = parseInt(takeValue(args, &i, arg), arg)
        case "--hidden":
            maxHiddenDim = parseInt(takeValue(args, &i, arg), arg)
        case "--time-steps":
            timeSteps = parseInt(takeValue(args, &i, arg), arg)
        case "--lr-max":
            lrMax = parseFloat(takeValue(args, &i, arg), arg)
        case "--lr-min":
            lrMin = parseFloat(takeValue(args, &i, arg), arg)
        case "--warmup-steps":
            warmupSteps = parseInt(takeValue(args, &i, arg), arg)
        case "--clip":
            clipNorm = parseFloat(takeValue(args, &i, arg), arg)
        case "--readout-frames":
            readoutFrames = parseInt(takeValue(args, &i, arg), arg)
        case "--seed":
            seed = parseUInt64(takeValue(args, &i, arg), arg)
        case "--export":
            exportPath = takeValue(args, &i, arg)
        case "--import":
            importPath = takeValue(args, &i, arg)
        case "--log-interval":
            logInterval = parseInt(takeValue(args, &i, arg), arg)
        case "--limit":
            sampleLimit = parseInt(takeValue(args, &i, arg), arg)
        case "--synthetic":
            useSynthetic = true
        default:
            fail("知らないオプションです: \(arg) (--help で一覧)")
        }
        i += 1
    }
}

// 値の検証。境界値は黙って丸めず、理由を書いて終了する
if epochs < 1 {
    fail("--epochs は 1 以上で指定してください (受け取った値: \(epochs))")
}
if batchSize < 1 {
    fail("--batch は 1 以上で指定してください (受け取った値: \(batchSize))")
}
if numLayers < 1 {
    fail("--layers は 1 以上で指定してください (受け取った値: \(numLayers))")
}
if maxHiddenDim < 1 {
    fail("--hidden は 1 以上で指定してください (受け取った値: \(maxHiddenDim))")
}
if timeSteps < 1 {
    fail("--time-steps は 1 以上で指定してください (受け取った値: \(timeSteps))")
}
if logInterval < 1 {
    fail("--log-interval は 1 以上で指定してください (受け取った値: \(logInterval))")
}
if let limit = sampleLimit, limit < 1 {
    fail("--limit は 1 以上で指定してください (受け取った値: \(limit))")
}
if lrMax <= 0.0 {
    fail("--lr-max は 0 より大きい値で指定してください (受け取った値: \(lrMax))")
}
if lrMin < 0.0 {
    fail("--lr-min は 0 以上で指定してください (受け取った値: \(lrMin))")
}
if lrMax < lrMin {
    fail("--lr-min (\(lrMin)) が --lr-max (\(lrMax)) を超えています")
}
if warmupSteps < 0 {
    fail("--warmup-steps は 0 以上で指定してください (受け取った値: \(warmupSteps))")
}
if clipNorm <= 0.0 {
    fail("--clip は 0 より大きい値で指定してください (受け取った値: \(clipNorm))")
}
if readoutFrames < 1 || ScanlineEncoder.frameCount < readoutFrames {
    fail("--readout-frames は 1..\(ScanlineEncoder.frameCount) で指定してください (受け取った値: \(readoutFrames))")
}
if !useSynthetic && trainPath.isEmpty {
    fail("--train で学習用 DatasetFile を指定してください (データセット無しで動かすなら --synthetic)")
}

// MARK: - サンプル (UInt8 のままメモリに載せる)

/// 学習サンプル 1 件。Float に展開すると 1 件 4KB になるので、
/// メモリ上は DatasetFile と同じ 0..255 の 1024 バイトで保持する
struct RawSample {
    let label: Int
    let pixels: [UInt8]
}

let vocabulary = CharacterVocabulary.shared
let vocabularyCount = vocabulary.count

/// 画素数はデータセット読み込み時 / 疑似データ生成時に 1024 で確定しているので、
/// ここで throw が起きることはない。起きたら全 0 画像ではなく落として原因を出す
func characterImage(_ pixels: [UInt8]) -> CharacterImage {
    do {
        return try CharacterImage(uint8: pixels)
    } catch {
        fail("画像の画素数が \(CharacterImage.pixelCount) ではありません: \(error)")
    }
}

func loadDataset(path: String, role: String, limit: Int?) -> [RawSample] {
    let url = URL(fileURLWithPath: path)
    if !FileManager.default.fileExists(atPath: url.path) {
        fail("\(role)データセットが見つかりません: \(path)")
    }
    let reader: DatasetReader
    do {
        reader = try DatasetReader(url: url)
    } catch {
        fail("\(role)データセットを開けません: \(path): \(error)")
    }
    defer { reader.close() }

    if reader.count == 0 {
        fail("\(role)データセットにサンプルが 1 件もありません: \(path)")
    }

    let wanted = min(reader.count, limit ?? reader.count)
    var out = [RawSample]()
    out.reserveCapacity(wanted)
    var i = 0
    while i < wanted {
        let sample: DatasetSample
        do {
            sample = try reader.sample(at: i)
        } catch {
            fail("\(role)データセットのサンプル \(i) を読めません: \(path): \(error)")
        }
        if sample.label < 0 || vocabularyCount <= sample.label {
            fail("\(role)データセットのサンプル \(i) のラベル \(sample.label) が語彙 \(vocabularyCount) の範囲外です: \(path)")
        }
        // CharacterImage.asUInt8() は init(uint8:) の逆写像なので往復で値が変わらない
        out.append(RawSample(label: sample.label, pixels: sample.image.asUInt8()))
        i += 1
    }
    return out
}

// MARK: - 疑似データ (--synthetic)

/// 32x32 / 値域 [0, 1] / 0 = 紙・1 = 墨 という画像規約に沿った疑似画像。クラス k は
/// 行 `(k % 16) * 2` の横線と列 `(k / 16) * 2` の縦線を引いたもの。
/// スキャンライン符号化 (§3) では縦線が全フレームの行成分に、横線が全フレームの列成分に
/// 現れるので、フレーム平均ロジットでも解ける。学習ループ全体を通すための動作確認用で、
/// フォントにも実データにも依存しない。
///
/// 行と列を 2 画素おきに置くのは、線の太さを 1..2 で散らすとき隣のクラスと重ならないようにするため。
/// 1 画素刻みだと「クラス k の太さ 2」と「クラス k+1 の太さ 1」が同じ画素を塗り、
/// ラベルが原理的に決まらない分が正解率の天井になる (実測 88.4%)
func makeSyntheticSamples(
    classCount: Int,
    perClass: Int,
    rng: inout SplitMix64
) -> [RawSample] {
    let side = CharacterImage.side
    var out = [RawSample]()
    out.reserveCapacity(classCount * perClass)

    var k = 0
    while k < classCount {
        let row = (k % 16) * 2
        let col = ((k / 16) % 16) * 2
        var n = 0
        while n < perClass {
            var pixels = [UInt8](repeating: 0, count: CharacterImage.pixelCount)
            // 線の太さ 1..2、濃さ 200..255 で書き味を散らす
            let thickness = Int.random(in: 1 ... 2, using: &rng)
            let ink = Float(Int.random(in: 200 ... 255, using: &rng))

            var d = 0
            while d < thickness {
                let r = min(side - 1, row + d)
                let c = min(side - 1, col + d)
                var x = 0
                while x < side {
                    pixels[r * side + x] = UInt8(ink)
                    x += 1
                }
                var y = 0
                while y < side {
                    pixels[y * side + c] = UInt8(ink)
                    y += 1
                }
                d += 1
            }

            // ガウスノイズ σ=0.05 とごま塩 1% (実データの拡張で使うノイズと同じ強さ)
            var p = 0
            while p < CharacterImage.pixelCount {
                var v = Float(pixels[p]) + rng.nextGaussian() * 0.05 * 255.0
                if Float.random(in: 0.0 ..< 1.0, using: &rng) < 0.01 {
                    v = Bool.random(using: &rng) ? 255.0 : 0.0
                }
                pixels[p] = UInt8(max(0.0, min(255.0, v.rounded())))
                p += 1
            }
            out.append(RawSample(label: k, pixels: pixels))
            n += 1
        }
        k += 1
    }
    return out
}

// MARK: - データの用意

var trainSamples: [RawSample]
var evalSamples: [RawSample]
var datasetDescription: String

if useSynthetic {
    if Defaults.syntheticClasses > vocabularyCount {
        fail("疑似データのクラス数 \(Defaults.syntheticClasses) が語彙 \(vocabularyCount) を超えています")
    }
    var trainRNG = SplitMix64(seed: seed &+ 0x5EED_0001)
    var evalRNG = SplitMix64(seed: seed &+ 0x5EED_0002)
    trainSamples = makeSyntheticSamples(
        classCount: Defaults.syntheticClasses,
        perClass: Defaults.syntheticTrainPerClass,
        rng: &trainRNG
    )
    evalSamples = makeSyntheticSamples(
        classCount: Defaults.syntheticClasses,
        perClass: Defaults.syntheticEvalPerClass,
        rng: &evalRNG
    )
    if let limit = sampleLimit {
        trainSamples = Array(trainSamples.prefix(limit))
        evalSamples = Array(evalSamples.prefix(limit))
    }
    datasetDescription = "synthetic (\(Defaults.syntheticClasses) クラス)"
} else {
    trainSamples = loadDataset(path: trainPath, role: "学習用", limit: sampleLimit)
    if evalPath.isEmpty {
        evalSamples = []
    } else {
        evalSamples = loadDataset(path: evalPath, role: "評価用", limit: sampleLimit)
    }
    datasetDescription = trainPath
}

if trainSamples.isEmpty {
    fail("学習サンプルが 0 件です (--limit が小さすぎる可能性があります)")
}

// MARK: - ネットワークと学習器

MLXRandom.seed(seed)

var network: MLXSpikingNetwork
if let path = importPath {
    let url = URL(fileURLWithPath: path)
    if !FileManager.default.fileExists(atPath: url.path) {
        fail("--import の重み JSON が見つかりません: \(path)")
    }
    let loaded: SpikingNetworkWeights
    do {
        loaded = try SpikingNetworkWeights.load(from: url)
    } catch {
        fail("--import の重み JSON を読めません: \(path): \(error)")
    }
    // 形は JSON 側が正。CLI と食い違うなら黙って上書きせず知らせる
    if loaded.numLayers != numLayers || loaded.maxHiddenDim != maxHiddenDim || loaded.timeSteps != timeSteps {
        print("注意: --import の形 (layers \(loaded.numLayers) / hidden \(loaded.maxHiddenDim) / time-steps \(loaded.timeSteps)) を採用します "
            + "(CLI: layers \(numLayers) / hidden \(maxHiddenDim) / time-steps \(timeSteps))")
    }
    if loaded.outputDim != vocabularyCount {
        print("注意: --import の出力次元 \(loaded.outputDim) が語彙 \(vocabularyCount) と違います")
    }
    // readoutFrames は学習時と推論時で必ず一致していないといけない。
    // JSON 側を正とし、CLI と食い違うときは黙って上書きせず知らせる
    if loaded.readoutFrames != readoutFrames {
        print("注意: --import の readout-frames \(loaded.readoutFrames) を採用します (CLI: \(readoutFrames))")
    }
    readoutFrames = loaded.readoutFrames
    numLayers = loaded.numLayers
    maxHiddenDim = loaded.maxHiddenDim
    timeSteps = loaded.timeSteps
    network = MLXSpikingNetwork(weights: loaded)
} else {
    // 出力次元は常に語彙全体 (3236 クラス)。データセットに一部の区分しか無くても変えない。
    // 重みを別のデータセットへ使い回せるようにするため
    network = MLXSpikingNetwork(
        numLayers: numLayers,
        inputDim: ScanlineEncoder.frameDim,
        maxHiddenDim: maxHiddenDim,
        outputDim: vocabularyCount,
        timeSteps: timeSteps,
        lifConfig: Defaults.lifConfig,
        readoutFrames: readoutFrames
    )
}

let trainer = MLXClassificationTrainer(
    network: network,
    config: ClassificationTrainingConfig(learningRate: lrMax, clipNorm: clipNorm)
)

let outputDim = network.outputDim
let classLabels = vocabularyCount == outputDim
    ? vocabulary.allCharacters.map { String($0) }
    : nil

// MARK: - 特徴の組み立て

/// trainBatch が要求する [B][T][inputDim]
func makeFrameBatch(_ samples: ArraySlice<RawSample>) -> (features: [[[Float]]], labels: [Int]) {
    var features = [[[Float]]]()
    var labels = [Int]()
    features.reserveCapacity(samples.count)
    labels.reserveCapacity(samples.count)
    for sample in samples {
        features.append(ScanlineEncoder.encode(characterImage(sample.pixels)))
        labels.append(sample.label)
    }
    return (features, labels)
}

/// 評価用の [B, T, inputDim] MLXArray。平坦配列から一度で作る
func makeFeatureArray(_ samples: ArraySlice<RawSample>) -> MLXArray {
    let frameCount = ScanlineEncoder.frameCount
    let frameDim = ScanlineEncoder.frameDim
    let stride = frameCount * frameDim
    var flat = [Float](repeating: 0.0, count: samples.count * stride)
    var b = 0
    for sample in samples {
        let encoded = ScanlineEncoder.encodeFlat(characterImage(sample.pixels))
        let base = b * stride
        var d = 0
        while d < stride {
            flat[base + d] = encoded[d]
            d += 1
        }
        b += 1
    }
    return MLXArray(flat, [samples.count, frameCount, frameDim])
}

// MARK: - 評価

struct EvalResult {
    var total = 0
    var top1 = 0
    var top5 = 0
    var lossSum: Float = 0.0
    /// ロジットに NaN / Inf が出たサンプル数。学習が発散したときに 0 でなくなる
    var nonFinite = 0
    var categoryTotal = [ScriptCategory: Int]()
    var categoryTop1 = [ScriptCategory: Int]()

    var top1Rate: Double {
        return total == 0 ? 0.0 : Double(top1) / Double(total) * 100.0
    }
    var top5Rate: Double {
        return total == 0 ? 0.0 : Double(top5) / Double(total) * 100.0
    }
    /// 有限だったサンプルだけの平均損失。全件 NaN なら NaN を返す (0 と区別する)
    var loss: Float {
        let finiteCount = total - nonFinite
        return finiteCount == 0 ? Float.nan : lossSum / Float(finiteCount)
    }
}

/// 1 サンプル分のロジットから top-1 / top-5 / 交差エントロピーを求める。
/// logsumexp は最大値を引いてから計算する (3236 クラスの exp が溢れないように)
func scoreSample(
    logits: UnsafePointer<Float>,
    dim: Int,
    label: Int
) -> (top1: Bool, top5: Bool, loss: Float, finite: Bool) {
    var maxValue = -Float.greatestFiniteMagnitude
    var argMaxIndex = 0
    var c = 0
    while c < dim {
        if maxValue < logits[c] {
            maxValue = logits[c]
            argMaxIndex = c
        }
        c += 1
    }

    // 学習が発散するとロジットが NaN / Inf になる。NaN は比較が全て false になるため、
    // 素通しすると「正解より大きいロジットが 0 個」= top-5 正解 と数えられ、
    // 発散したランが top-5 100% に見えてしまう。明示的に不正解として弾く
    if !maxValue.isFinite {
        return (false, false, Float.nan, false)
    }

    // 正解より大きいロジットが 5 個未満なら top-5 に入っている
    let labelLogit = (0 <= label && label < dim) ? logits[label] : -Float.greatestFiniteMagnitude
    var greater = 0
    c = 0
    while c < dim {
        if labelLogit < logits[c] {
            greater += 1
            if 5 <= greater {
                break
            }
        }
        c += 1
    }

    var sumExp: Float = 0.0
    c = 0
    while c < dim {
        sumExp += exp(logits[c] - maxValue)
        c += 1
    }
    let logSumExp = maxValue + log(sumExp)
    return (argMaxIndex == label, greater < 5, logSumExp - labelLogit, true)
}

func evaluate(samples: [RawSample], batchSize: Int) -> EvalResult {
    var result = EvalResult()
    if samples.isEmpty {
        return result
    }
    var start = 0
    while start < samples.count {
        let end = min(samples.count, start + batchSize)
        let slice = samples[start ..< end]
        let features = makeFeatureArray(slice)
        let logitsArray = trainer.meanLogits(network: trainer.network, features: features)
        eval(logitsArray)
        let host = logitsArray.asArray(Float.self)

        host.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            var b = 0
            for sample in slice {
                let scored = scoreSample(logits: base + b * outputDim, dim: outputDim, label: sample.label)
                result.total += 1
                if scored.finite {
                    if scored.top1 {
                        result.top1 += 1
                    }
                    if scored.top5 {
                        result.top5 += 1
                    }
                    result.lossSum += scored.loss
                } else {
                    result.nonFinite += 1
                }
                if 0 <= sample.label && sample.label < vocabularyCount {
                    let category = vocabulary.category(of: sample.label)
                    result.categoryTotal[category, default: 0] += 1
                    if scored.top1 {
                        result.categoryTop1[category, default: 0] += 1
                    }
                }
                b += 1
            }
        }
        start = end
    }
    return result
}

func formatPercent(_ value: Double) -> String {
    return String(format: "%.2f%%", value)
}

func printCategoryBreakdown(_ result: EvalResult, indent: String) {
    for category in ScriptCategory.allCases {
        guard let total = result.categoryTotal[category], 0 < total else {
            continue
        }
        let correct = result.categoryTop1[category] ?? 0
        let rate = Double(correct) / Double(total) * 100.0
        print("\(indent)\(category.rawValue): \(formatPercent(rate)) (\(correct)/\(total))")
    }
}

// MARK: - 重みの書き出し (一時ファイル → rename)

func exportWeights(to path: String) {
    let url = URL(fileURLWithPath: path)
    let directory = url.deletingLastPathComponent()
    if !directory.path.isEmpty {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fail("--export の出力先ディレクトリを作れません: \(directory.path): \(error)")
        }
    }
    let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())")
    let weights = trainer.network.exportWeights(classLabels: classLabels)
    do {
        try weights.save(to: temporary)
    } catch {
        fail("重み JSON の一時ファイルを書けません: \(temporary.path): \(error)")
    }
    do {
        // 同一ディレクトリ内の rename なので、読み手が半端なファイルを見ることはない
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        fail("重み JSON を \(url.path) へ移動できません: \(error)")
    }
}

// MARK: - cosine 学習率

/// 線形 warmup (lrMin → lrMax) のあと cosine で lrMin へ落とす。step は 1 起点。
///
/// warmup は 0 ではなく lrMin から立ち上げる (spiketrans の CosineLRScheduler と同じ形)。
/// 0 から始めると最初の数十ステップが実質ゼロ更新になり、lr を下げた設定と併用したときに
/// 学習が立ち上がらなかった。既定では warmupSteps = 0 なので、この枝は使われない。
/// 学習率はトップレベルの var なので、引数で受けて nonisolated のまま使う
func scheduledLearningRate(
    step: Int,
    totalSteps: Int,
    warmupSteps: Int,
    lrMax: Float,
    lrMin: Float
) -> Float {
    if 0 < warmupSteps && step <= warmupSteps {
        let ratio = Float(step) / Float(warmupSteps)
        return lrMin + (lrMax - lrMin) * ratio
    }
    let decaySteps = max(1, totalSteps - warmupSteps)
    let progress = Float(min(max(0, step - warmupSteps), decaySteps)) / Float(decaySteps)
    let decay = 0.5 * (1.0 + cos(progress * Float.pi))
    return lrMin + (lrMax - lrMin) * decay
}

// MARK: - 学習

let stepsPerEpoch = (trainSamples.count + batchSize - 1) / batchSize
let totalSteps = stepsPerEpoch * epochs
// warmup が学習全体の半分を超えると cosine が効かなくなるので上限を切る。
// 黙って切ると原因が分からないので、切ったときは知らせる
let effectiveWarmupSteps = min(warmupSteps, max(0, totalSteps / 2))

print("train (spiketegaki \(Spiketegaki.version))")
print("  データ: \(datasetDescription)")
print("  学習 \(trainSamples.count) 件 / 評価 \(evalSamples.count) 件 / クラス \(outputDim)")
print("  layers \(numLayers) / hidden \(maxHiddenDim) / time-steps \(timeSteps) / batch \(batchSize)")
print("  epochs \(epochs) / \(stepsPerEpoch) ステップ per epoch / 総 \(totalSteps) ステップ")
let warmupLabel = 0 < effectiveWarmupSteps ? "\(lrMin) → warmup \(effectiveWarmupSteps) ステップ → " : ""
print("  lr \(warmupLabel)\(lrMax) → cosine → \(lrMin) / clip \(clipNorm) / seed \(seed)")
if effectiveWarmupSteps != warmupSteps {
    print("  注意: --warmup-steps \(warmupSteps) は総ステップ数 \(totalSteps) の半分を超えるので \(effectiveWarmupSteps) に切り詰めました")
}
print("  readout-frames \(readoutFrames) / \(ScanlineEncoder.frameCount) (末尾このフレーム数のロジットを平均して分類する)")
if let path = exportPath {
    print("  重み出力: \(path)")
}

// 学習セットの正解率は過学習/未学習の切り分けに使う。全件だと重いので先頭を抜き出す
let trainEvalSamples = Array(trainSamples.prefix(Defaults.maxTrainEvalSamples))

if importPath != nil {
    // --import した重みが書き出し時と同じ数字を出すかを確かめるための基準値
    let baseline = evaluate(samples: evalSamples.isEmpty ? trainEvalSamples : evalSamples, batchSize: batchSize)
    let target = evalSamples.isEmpty ? "train(抜粋)" : "eval"
    print("[import] \(target) top-1 \(formatPercent(baseline.top1Rate)) / top-5 \(formatPercent(baseline.top5Rate)) "
        + "/ loss \(String(format: "%.4f", baseline.loss)) (\(baseline.total) 件)")
}

var bestTop1 = -1.0
var bestEpoch = 0
var globalStep = 0
var movingAccuracy: Double? = nil
let runStart = Date()

var epoch = 1
while epoch <= epochs {
    let epochStart = Date()
    var order = Array(0 ..< trainSamples.count)
    // epoch ごとに並びを変えるが、seed が同じなら毎回同じ並びになる
    var shuffleRNG = SplitMix64(seed: seed &+ UInt64(epoch))
    order.shuffle(using: &shuffleRNG)

    var lossSum: Float = 0.0
    var lossCount = 0
    var windowStart = Date()
    var windowSteps = 0

    var start = 0
    while start < order.count {
        let end = min(order.count, start + batchSize)
        var batch = [RawSample]()
        batch.reserveCapacity(end - start)
        var k = start
        while k < end {
            batch.append(trainSamples[order[k]])
            k += 1
        }
        let packed = makeFrameBatch(batch[0 ..< batch.count])

        globalStep += 1
        let stepLR = scheduledLearningRate(
            step: globalStep,
            totalSteps: totalSteps,
            warmupSteps: effectiveWarmupSteps,
            lrMax: lrMax,
            lrMin: lrMin
        )
        trainer.updateLearningRate(stepLR)
        let loss = trainer.trainBatch(features: packed.features, labels: packed.labels)
        lossSum += loss
        lossCount += 1
        windowSteps += 1

        if globalStep % logInterval == 0 {
            // 学習中の正解率はログの時だけ同じバッチを勾配なしで測る (毎ステップ測ると 1.3 倍遅くなる)
            let measured = trainer.evaluateBatch(features: packed.features, labels: packed.labels)
            let accuracy = Double(measured.correct) / Double(max(1, packed.labels.count)) * 100.0
            // 測るのは log-interval ごとなので、移動平均は直近 3 回程度が効く重みにする
            // (0.9/0.1 だと 1 回の学習で数回しか更新されず、最後まで初回の値を引きずる)
            movingAccuracy = movingAccuracy.map { 0.6 * $0 + 0.4 * accuracy } ?? accuracy
            let elapsed = Date().timeIntervalSince(windowStart)
            let stepsPerSecond = 0.0 < elapsed ? Double(windowSteps) / elapsed : 0.0
            print(String(
                format: "  epoch %d step %d/%d loss %.4f acc %.2f%% (移動平均 %.2f%%) lr %.5f %.2f step/s",
                epoch, globalStep, totalSteps, loss, accuracy, movingAccuracy ?? accuracy,
                stepLR, stepsPerSecond
            ))
            windowStart = Date()
            windowSteps = 0
        }
        start = end
    }

    let epochSeconds = Date().timeIntervalSince(epochStart)
    let meanLoss = lossCount == 0 ? 0.0 : lossSum / Float(lossCount)
    let trainResult = evaluate(samples: trainEvalSamples, batchSize: batchSize)
    let evalResult = evalSamples.isEmpty ? trainResult : evaluate(samples: evalSamples, batchSize: batchSize)

    print(String(
        format: "epoch %d/%d  時間 %.1f 秒  学習損失 %.4f  train top-1 %.2f%%  eval top-1 %.2f%%  eval top-5 %.2f%%  eval loss %.4f",
        epoch, epochs, epochSeconds, meanLoss,
        trainResult.top1Rate, evalResult.top1Rate, evalResult.top5Rate, evalResult.loss
    ))
    if 0 < evalResult.nonFinite || 0 < trainResult.nonFinite {
        print("    警告: ロジットが NaN/Inf になったサンプル eval \(evalResult.nonFinite)/\(evalResult.total)"
            + " train \(trainResult.nonFinite)/\(trainResult.total) — 学習が発散しています")
    }
    printCategoryBreakdown(evalResult, indent: "    eval ")

    if bestTop1 < evalResult.top1Rate {
        bestTop1 = evalResult.top1Rate
        bestEpoch = epoch
        if let path = exportPath {
            exportWeights(to: path)
            print("    最良 top-1 を更新 → \(path) に書き出し")
        }
    }
    epoch += 1
}

let totalSeconds = Date().timeIntervalSince(runStart)
print(String(format: "完了: %.1f 秒 (最良 eval top-1 %.2f%% @ epoch %d)", totalSeconds, bestTop1, bestEpoch))
if exportPath == nil {
    print("注意: --export が無いので重みは保存していません")
}
exit(0)
