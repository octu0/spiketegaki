import XCTest
import MLX
import Spiketegaki
@testable import SpiketegakiTraining

/// 合成データの過学習テスト。学習の配線 (損失・勾配・Adam・学習率) が
/// 実際に動いていることを、学習データの正解率で確かめる。
final class OverfitTests: XCTestCase {

    private let classCount = 10
    private let samplesPerClass = 8
    private let side = 32
    private let frameCount = 32
    private let frameDim = 64
    private let maxSteps = 200
    private let targetAccuracy: Float = 0.95
    /// 末尾 8 フレームのロジット平均で学習・評価する。
    /// 既定 (32 = 全フレーム平均) ではなく、末尾だけを読む経路を明示的に踏ませる
    private let readoutFrames = 8

    /// 決定的な疑似乱数 (線形合同法)
    private struct SeededRandom {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func nextUnit() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 33) % 1_000_003) / 1_000_003.0
        }
        /// Box-Muller の片側。ガウスノイズ用
        mutating func nextGaussian() -> Float {
            let u1 = max(1e-6, nextUnit())
            let u2 = nextUnit()
            return sqrt(-2.0 * log(u1)) * cos(2.0 * Float.pi * u2)
        }
    }

    /// クラス k の疑似画像: 行 k % 32 と列 k / 32 に 1 が立つ 32x32
    private func baseImage(forClass k: Int) -> [Float] {
        var pixels = [Float](repeating: 0.0, count: side * side)
        let row = k % side
        let col = k / side
        var x = 0
        while x < side {
            pixels[row * side + x] = 1.0
            x += 1
        }
        var y = 0
        while y < side {
            pixels[y * side + col] = 1.0
            y += 1
        }
        return pixels
    }

    /// スキャンライン符号化: フレーム t = 行 t ++ 列 t。
    /// 別ワーカーの `ScanlineEncoder` には依存せず、このテストの中で同じ規約を作る。
    private func encode(_ pixels: [Float]) -> [[Float]] {
        var frames: [[Float]] = []
        var t = 0
        while t < side {
            var frame = [Float](repeating: 0.0, count: frameDim)
            var x = 0
            while x < side {
                frame[x] = pixels[t * side + x]
                x += 1
            }
            var y = 0
            while y < side {
                frame[side + y] = pixels[y * side + t]
                y += 1
            }
            frames.append(frame)
            t += 1
        }
        return frames
    }

    /// クラス x 拡張サンプルの学習データ。拡張はガウスノイズ (σ = 0.05) のみ。
    private func makeDataset() -> (features: [[[Float]]], labels: [Int]) {
        var rng = SeededRandom(seed: 31337)
        var features: [[[Float]]] = []
        var labels: [Int] = []
        var k = 0
        while k < classCount {
            let base = baseImage(forClass: k)
            var n = 0
            while n < samplesPerClass {
                var noisy = base
                var i = 0
                while i < noisy.count {
                    // 最初の 1 件はノイズなしの原画像にする
                    if 0 < n {
                        var value = noisy[i] + rng.nextGaussian() * 0.05
                        if value < 0.0 { value = 0.0 }
                        if 1.0 < value { value = 1.0 }
                        noisy[i] = value
                    }
                    i += 1
                }
                features.append(encode(noisy))
                labels.append(k)
                n += 1
            }
            k += 1
        }
        return (features, labels)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try MLXTestEnvironment.skipIfMetallibUnavailable()
    }

    func testOverfitsSyntheticData() {
        MLXRandom.seed(31337)
        let dataset = makeDataset()
        XCTAssertEqual(dataset.features.count, classCount * samplesPerClass)
        XCTAssertEqual(dataset.features[0].count, frameCount)
        XCTAssertEqual(dataset.features[0][0].count, frameDim)

        let network = MLXSpikingNetwork(
            numLayers: 2,
            inputDim: frameDim,
            maxHiddenDim: 128,
            outputDim: classCount,
            timeSteps: 4,
            lifConfig: LIFConfig(),
            readoutFrames: readoutFrames
        )
        XCTAssertEqual(network.readoutFrames, 8, "明示指定した readoutFrames 8 で学習すること")
        let trainer = MLXClassificationTrainer(
            network: network,
            config: ClassificationTrainingConfig(learningRate: 0.01, clipNorm: 5.0)
        )

        var accuracy: Float = 0.0
        var lastLoss: Float = 0.0
        // 目標正解率に早く届くと 10 ステップごとの記録が 1 点しか残らないので、
        // 毎ステップの学習損失も残して推移を見られるようにする
        var lossTrace: [Float] = []
        var step = 1
        while step <= maxSteps {
            lastLoss = trainer.trainBatch(features: dataset.features, labels: dataset.labels)
            lossTrace.append(lastLoss)
            print("[Overfit] step \(step): train loss = \(lastLoss)")
            if step % 10 == 0 {
                let evaluated = trainer.evaluateBatch(features: dataset.features, labels: dataset.labels)
                accuracy = Float(evaluated.correct) / Float(dataset.labels.count)
                print("[Overfit] step \(step) 評価: eval loss = \(evaluated.loss), accuracy = \(accuracy) (\(evaluated.correct)/\(dataset.labels.count))")
                if targetAccuracy <= accuracy {
                    break
                }
            }
            step += 1
        }

        let runSteps = min(step, maxSteps)
        let final = trainer.evaluateBatch(features: dataset.features, labels: dataset.labels)
        accuracy = Float(final.correct) / Float(dataset.labels.count)
        print("[Overfit] 損失推移 = \(lossTrace)")
        print("[Overfit] 最終: step \(runSteps), loss = \(final.loss), accuracy = \(accuracy) (\(final.correct)/\(dataset.labels.count))")
        XCTAssertFalse(lastLoss.isNaN, "損失が NaN")
        XCTAssertGreaterThanOrEqual(
            accuracy, targetAccuracy,
            "\(maxSteps) ステップで学習データの正解率が \(targetAccuracy) に届かなかった (実測 \(accuracy))"
        )
    }

    /// 重みが本当に更新されていること (学習ステップが空回りしていない)
    func testTrainBatchUpdatesWeights() {
        MLXRandom.seed(11)
        let network = MLXSpikingNetwork(
            numLayers: 1, inputDim: frameDim, maxHiddenDim: 32, outputDim: classCount, timeSteps: 2
        )
        let trainer = MLXClassificationTrainer(network: network)
        let dataset = makeDataset()
        let before = network.exportWeights().wOut
        let loss = trainer.trainBatch(features: dataset.features, labels: dataset.labels)
        let after = network.exportWeights().wOut
        XCTAssertFalse(loss.isNaN)
        XCTAssertEqual(before.count, after.count)
        var changed = 0
        var i = 0
        while i < before.count {
            if before[i] != after[i] {
                changed += 1
            }
            i += 1
        }
        XCTAssertGreaterThan(changed, 0, "1 ステップ学習しても wOut が変わっていない")
    }

    /// 空バッチでも落ちない
    func testEmptyBatchIsSafe() {
        MLXRandom.seed(12)
        let network = MLXSpikingNetwork(
            numLayers: 1, inputDim: frameDim, maxHiddenDim: 16, outputDim: classCount, timeSteps: 2
        )
        let trainer = MLXClassificationTrainer(network: network)
        XCTAssertEqual(trainer.trainBatch(features: [], labels: []), 0.0)
        let evaluated = trainer.evaluateBatch(features: [], labels: [])
        XCTAssertEqual(evaluated.loss, 0.0)
        XCTAssertEqual(evaluated.correct, 0)
    }
}
