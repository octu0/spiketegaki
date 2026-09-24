import XCTest
import MLX
import Spiketegaki
@testable import SpiketegakiTraining

/// MLX (学習) と純 Swift (推論) のロジット一致テスト。
final class ParityTests: XCTestCase {

    private let numLayers = 3
    private let inputDim = 64
    private let hidden = 128
    private let outputDim = 50
    private let timeSteps = 4
    private let frameCount = 32

    /// 決定的な疑似乱数 (線形合同法)。MLXRandom の初期値に依存せずフレーム列を作る。
    private struct SeededRandom {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func nextUnit() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 33) % 1_000_003) / 1_000_003.0
        }
    }

    /// 乱数 [0, 1] のフレーム列
    private func makeRandomSequence(inputDim: Int, seed: UInt64) -> [[Float]] {
        var rng = SeededRandom(seed: seed)
        var frames: [[Float]] = []
        var t = 0
        while t < frameCount {
            var frame = [Float](repeating: 0.0, count: inputDim)
            var d = 0
            while d < inputDim {
                frame[d] = rng.nextUnit()
                d += 1
            }
            frames.append(frame)
            t += 1
        }
        return frames
    }

    /// 検証用の 3 系列: 乱数 [0, 1]、全 0 (ゼロ画像)、全 1 (真っ黒画像)
    private func makeSequences() -> [(name: String, frames: [[Float]])] {
        let random = makeRandomSequence(inputDim: inputDim, seed: 20240924)
        let zeros = [[Float]](repeating: [Float](repeating: 0.0, count: inputDim), count: frameCount)
        let ones = [[Float]](repeating: [Float](repeating: 1.0, count: inputDim), count: frameCount)
        return [("random[0,1]", random), ("all-zero", zeros), ("all-one", ones)]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MLXTestEnvironment.skipIfMetallibUnavailable()
    }

    // MARK: - 共通の比較処理

    /// MLX の `logitsBatch` フレーム平均と CPU の `classifyLogits` を比べ、3 系列の最大絶対差を返す。
    /// 許容誤差は 1e-3 固定。
    @discardableResult
    private func runParity(
        label: String,
        numLayers: Int,
        inputDim: Int,
        hidden: Int,
        outputDim: Int,
        timeSteps: Int,
        readoutFrames: Int,
        sequences: [(name: String, frames: [[Float]])],
        mlxSeed: UInt64
    ) throws -> Float {
        MLXRandom.seed(mlxSeed)
        let mlxNet = MLXSpikingNetwork(
            numLayers: numLayers,
            inputDim: inputDim,
            maxHiddenDim: hidden,
            outputDim: outputDim,
            timeSteps: timeSteps,
            lifConfig: LIFConfig(),
            readoutFrames: readoutFrames
        )
        XCTAssertEqual(mlxNet.readoutFrames, readoutFrames)
        // 初期化直後の bH / bOut は 0 なので、バイアスにも意味のある値を入れて比べる
        let trainer = MLXClassificationTrainer(network: mlxNet)
        var seeded = mlxNet.exportWeights()
        seeded = SpikingNetworkWeights(
            inputDim: seeded.inputDim,
            maxHiddenDim: seeded.maxHiddenDim,
            outputDim: seeded.outputDim,
            timeSteps: seeded.timeSteps,
            lifConfig: seeded.lifConfig,
            wIn: seeded.wIn,
            wRec: seeded.wRec,
            bH: seeded.bH.map { $0 + 0.35 },
            wLayers: seeded.wLayers,
            bHLayers: seeded.bHLayers,
            gammaRMS: seeded.gammaRMS,
            wOut: seeded.wOut,
            bOut: seeded.bOut.map { $0 + 0.1 },
            readoutFrames: seeded.readoutFrames
        )
        mlxNet.importWeights(from: seeded)
        XCTAssertEqual(mlxNet.readoutFrames, readoutFrames, "importWeights で readoutFrames が変わった")

        let exported = mlxNet.exportWeights()
        XCTAssertEqual(exported.readoutFrames, readoutFrames, "exportWeights に readoutFrames が乗っていない")
        XCTAssertEqual(exported.numLayers, numLayers)
        XCTAssertEqual(exported.wIn.count, hidden * inputDim)
        XCTAssertEqual(exported.wOut.count, outputDim * hidden)

        let cpuNet = SpikingNetwork(weights: exported)
        XCTAssertEqual(cpuNet.numLayers, numLayers)
        XCTAssertEqual(cpuNet.maxHiddenDim, hidden)
        XCTAssertEqual(cpuNet.outputDim, outputDim)
        XCTAssertEqual(cpuNet.readoutFrames, readoutFrames, "重み経由で CPU 側に readoutFrames が伝わっていない")

        // MLX 側はバッチにまとめて 1 回で流す
        var flat = [Float](repeating: 0.0, count: sequences.count * frameCount * inputDim)
        var b = 0
        while b < sequences.count {
            var t = 0
            while t < frameCount {
                let frame = sequences[b].frames[t]
                let offset = ((b * frameCount) + t) * inputDim
                var d = 0
                while d < inputDim {
                    flat[offset + d] = frame[d]
                    d += 1
                }
                t += 1
            }
            b += 1
        }
        let featuresArray = MLXArray(flat, [sequences.count, frameCount, inputDim])
        let mlxLogits = trainer.logitsBatch(network: mlxNet, features: featuresArray)
        XCTAssertEqual(mlxLogits.shape, [sequences.count, frameCount, outputDim])
        // 末尾 readoutFrames フレームの平均 (学習・評価と同じ経路)
        let mlxMean = trainer.meanLogits(network: mlxNet, features: featuresArray)
        XCTAssertEqual(mlxMean.shape, [sequences.count, outputDim])
        eval(mlxMean)
        let mlxValues = mlxMean.asArray(Float.self)

        var worstDiff: Float = 0.0
        b = 0
        while b < sequences.count {
            let name = sequences[b].name
            let cpuLogits = try cpuNet.classifyLogits(frames: sequences[b].frames)
            XCTAssertEqual(cpuLogits.count, outputDim)

            var maxDiff: Float = 0.0
            var mlxTop = 0
            var cpuTop = 0
            var c = 0
            while c < outputDim {
                let mlxValue = mlxValues[b * outputDim + c]
                let diff = abs(mlxValue - cpuLogits[c])
                if maxDiff < diff {
                    maxDiff = diff
                }
                if mlxValues[b * outputDim + mlxTop] < mlxValue {
                    mlxTop = c
                }
                if cpuLogits[cpuTop] < cpuLogits[c] {
                    cpuTop = c
                }
                XCTAssertFalse(mlxValue.isNaN, "\(label)/\(name): MLX 側に NaN")
                XCTAssertFalse(cpuLogits[c].isNaN, "\(label)/\(name): CPU 側に NaN")
                c += 1
            }
            print("[Parity] \(label) \(name): 最大絶対差 = \(maxDiff), argmax MLX=\(mlxTop) CPU=\(cpuTop)")
            XCTAssertEqual(mlxTop, cpuTop, "\(label)/\(name): argmax が一致しない")
            XCTAssertLessThan(maxDiff, 1e-3, "\(label)/\(name): 最大絶対差 \(maxDiff) が 1e-3 を超えた")
            if worstDiff < maxDiff {
                worstDiff = maxDiff
            }
            b += 1
        }
        print("[Parity] \(label) 最大絶対差 (\(sequences.count) 系列) = \(worstDiff)")
        return worstDiff
    }

    // MARK: - 小さい構成 (3 層 / hidden 128 / 出力 50)

    /// readoutFrames 8 (末尾のみ) で 3 系列。既定値ではないので明示的に渡す
    func testMLXAndCPULogitsAgree() throws {
        let worst = try runParity(
            label: "3層/128/50 readout8",
            numLayers: numLayers,
            inputDim: inputDim,
            hidden: hidden,
            outputDim: outputDim,
            timeSteps: timeSteps,
            readoutFrames: 8,
            sequences: makeSequences(),
            mlxSeed: 20240924
        )
        print("[Parity] readoutFrames 8 / 3 系列の最大絶対差 = \(worst)")
    }

    /// readoutFrames 32 (全フレーム平均 = 既定) でも MLX と CPU が一致すること。
    /// 末尾フレームの切り出しが CPU 側だけ / MLX 側だけに入るような食い違いを検出する。
    func testMLXAndCPULogitsAgreeWithFullFrameReadout() throws {
        // MLX 側の既定値も 32 であること (CPU 側と食い違うと重み経由の一致が崩れる)
        XCTAssertEqual(
            MLXSpikingNetwork(numLayers: 1, inputDim: 4, maxHiddenDim: 8, outputDim: 2).readoutFrames,
            32
        )
        let worst = try runParity(
            label: "3層/128/50 readout32",
            numLayers: numLayers,
            inputDim: inputDim,
            hidden: hidden,
            outputDim: outputDim,
            timeSteps: timeSteps,
            readoutFrames: 32,
            sequences: makeSequences(),
            mlxSeed: 20240924
        )
        print("[Parity] readoutFrames 32 / 3 系列の最大絶対差 = \(worst)")
    }

    // MARK: - 既定構成 (4 層 / hidden 512 / 出力 3236)

    /// 実寸の回帰テスト。hidden や outputDim を変えたときに、
    /// 3236 クラスでの誤差蓄積が 1e-3 を超えないことを自動で検出する。
    /// (Wave 1 監査 §6-3 の指摘への対応)
    func testMLXAndCPULogitsAgreeAtDesignDefaultShape() throws {
        let designInputDim = 64
        let designHidden = 512
        let designOutputDim = 3236
        let sequence = makeRandomSequence(inputDim: designInputDim, seed: 987654321)
        let worst = try runParity(
            label: "4層/512/3236 readout8",
            numLayers: 4,
            inputDim: designInputDim,
            hidden: designHidden,
            outputDim: designOutputDim,
            timeSteps: 4,
            readoutFrames: 8,
            sequences: [("random[0,1]", sequence)],
            mlxSeed: 987654321
        )
        print("[Parity] 実寸構成 (4 層 / hidden 512 / 出力 3236) の最大絶対差 = \(worst)")
    }
}
