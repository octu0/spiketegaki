import XCTest
@testable import Spiketegaki

/// SNN コア (CPU 推論) の単体テスト。
final class SNNTests: XCTestCase {


    // MARK: - 決定的な重み

    /// 線形合同法の疑似乱数。`SpikingNetwork.init` の `Float.random` は実行ごとに
    /// 変わるため、量子化の一致など数値に依存するテストは重みを固定してから比べる。
    private struct SeededRandom {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func nextUnit() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((state >> 33) % 1_000_003) / 1_000_003.0
        }
        mutating func next(in range: Float) -> Float {
            return (nextUnit() * 2.0 - 1.0) * range
        }
    }

    /// ネットワークの全パラメータを種から決め打ちで埋める
    private func seedWeights(_ net: SpikingNetwork, seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        func fill(_ param: Parameter, _ range: Float) {
            var i = 0
            while i < param.count {
                param.data[i] = rng.next(in: range)
                i += 1
            }
        }
        fill(net.pWIn, sqrt(2.0 / Float(net.inputDim)))
        fill(net.pWRec, sqrt(2.0 / Float(net.maxHiddenDim)) * 0.2)
        fill(net.pBH, 0.35)
        var l = 0
        while l < net.pWLayers.count {
            fill(net.pWLayers[l], sqrt(2.0 / Float(net.maxHiddenDim)))
            fill(net.pBHLayers[l], 0.1)
            var i = 0
            while i < net.pGammaRMS[l].count {
                net.pGammaRMS[l].data[i] = 1.0
                i += 1
            }
            l += 1
        }
        fill(net.pWOut, sqrt(2.0 / Float(net.maxHiddenDim)))
        fill(net.pBOut, 0.1)
        net.rebuildInferenceLayout()
    }

    // MARK: - LIF 1 ステップの手計算一致

    /// 隠れ層 LIF: v = clamp(beta * vPrev * (1 - sPrev) + I)、発火は vTh <= v
    func testLIFStepScalarMatchesHandCalculation() {
        let config = LIFConfig(beta: 0.8, vTh: 1.0, vReset: 0.0, alpha: 2.0)

        // 0.8 * 0.5 * (1 - 0) + 0.7 = 1.1 >= 1.0 -> 発火
        let fired = LIFNeuronEngine.stepScalar(config: config, vPrev: 0.5, sPrev: 0.0, inputCurrent: 0.7)
        XCTAssertEqual(fired.vNext, 1.1, accuracy: 1e-6)
        XCTAssertEqual(fired.sNext, 1.0)

        // 直前に発火していればハードリセット: 0.8 * 0.5 * (1 - 1) + 0.3 = 0.3 < 1.0 -> 非発火
        let reset = LIFNeuronEngine.stepScalar(config: config, vPrev: 0.5, sPrev: 1.0, inputCurrent: 0.3)
        XCTAssertEqual(reset.vNext, 0.3, accuracy: 1e-6)
        XCTAssertEqual(reset.sNext, 0.0)

        // 飽和: 0.8 * 0.0 + 100.0 -> +20.0 に張り付く
        let saturated = LIFNeuronEngine.stepScalar(config: config, vPrev: 0.0, sPrev: 0.0, inputCurrent: 100.0)
        XCTAssertEqual(saturated.vNext, LIFNeuronEngine.vClampMax)
        XCTAssertEqual(saturated.sNext, 1.0)
    }

    /// ALIF: a = rho * aPrev + gamma * sPrev、発火閾値は vTh + a
    func testLIFStepAdaptiveMatchesHandCalculation() {
        let config = LIFConfig(beta: 0.8, vTh: 1.0, vReset: 0.0, alpha: 2.0, rho: 0.85, gamma: 0.5)

        // v: 0.8 * 0.5 * (1 - 1) + 0.7 = 0.7
        // a: 0.85 * 0.2 + 0.5 * 1 = 0.67 -> dynVTh = 1.67 > 0.7 -> 非発火
        let res = LIFNeuronEngine.stepScalarAdaptive(
            config: config, vPrev: 0.5, sPrev: 1.0, aPrev: 0.2, inputCurrent: 0.7
        )
        XCTAssertEqual(res.vNext, 0.7, accuracy: 1e-6)
        XCTAssertEqual(res.aNext, 0.67, accuracy: 1e-6)
        XCTAssertEqual(res.sNext, 0.0)
    }

    /// 最終層: リーク積分 -> 閾値単位で読み出し -> subtractive reset (余りを残す)
    func testLIFReadoutStepMatchesHandCalculation() {
        let config = LIFConfig(beta: 0.8, vTh: 1.0, vReset: 0.0, alpha: 2.0)

        // vIntegrated = 0.8 * 0.5 + 0.7 = 1.1 -> 発火、readout は 1.0 にクリップ、v は 1.1 - 1.0 = 0.1
        let res = LIFNeuronEngine.stepReadoutScalarAdaptive(
            config: config, vPrev: 0.5, sPrev: 0.0, aPrev: 0.0, inputCurrent: 0.7
        )
        XCTAssertEqual(res.sNext, 1.0)
        XCTAssertEqual(res.readout, 1.0, accuracy: 1e-6)
        XCTAssertEqual(res.vNext, 0.1, accuracy: 1e-6)

        // 閾値下はアナログのまま: 0.8 * 0.0 + 0.4 = 0.4
        let sub = LIFNeuronEngine.stepReadoutScalarAdaptive(
            config: config, vPrev: 0.0, sPrev: 0.0, aPrev: 0.0, inputCurrent: 0.4
        )
        XCTAssertEqual(sub.sNext, 0.0)
        XCTAssertEqual(sub.readout, 0.4, accuracy: 1e-6)
        XCTAssertEqual(sub.vNext, 0.4, accuracy: 1e-6)
    }

    /// SIMD8 版とスカラー版が同じ結果を出す (端数レーンも含む)
    func testLIFSIMD8MatchesScalar() {
        let config = LIFConfig(beta: 0.8, vTh: 1.0, vReset: 0.0, alpha: 2.0, rho: 0.85, gamma: 0.3)
        let count = 19   // 8 の倍数ではない = 端数処理も通る
        var v = [Float](repeating: 0.0, count: count)
        var s = [Float](repeating: 0.0, count: count)
        var a = [Float](repeating: 0.0, count: count)
        var cur = [Float](repeating: 0.0, count: count)
        var i = 0
        while i < count {
            v[i] = Float(i % 5) * 0.31 - 0.4
            s[i] = Float(i % 2)
            a[i] = Float(i % 3) * 0.12
            cur[i] = Float((i * 7) % 11) * 0.21 - 0.5
            i += 1
        }
        let v0 = v
        let s0 = s
        let a0 = a

        v.withUnsafeMutableBufferPointer { vb in
            s.withUnsafeMutableBufferPointer { sb in
                a.withUnsafeMutableBufferPointer { ab in
                    cur.withUnsafeBufferPointer { cb in
                        LIFNeuronEngine.stepAdaptiveSIMD8(
                            config: config,
                            vPtr: vb.baseAddress!, sPtr: sb.baseAddress!, aPtr: ab.baseAddress!,
                            curPtr: cb.baseAddress!, count: count
                        )
                    }
                }
            }
        }

        i = 0
        while i < count {
            let expected = LIFNeuronEngine.stepScalarAdaptive(
                config: config, vPrev: v0[i], sPrev: s0[i], aPrev: a0[i], inputCurrent: cur[i]
            )
            XCTAssertEqual(v[i], expected.vNext, accuracy: 1e-6, "v mismatch at \(i)")
            XCTAssertEqual(s[i], expected.sNext, "s mismatch at \(i)")
            XCTAssertEqual(a[i], expected.aNext, accuracy: 1e-6, "a mismatch at \(i)")
            i += 1
        }
    }

    // MARK: - 代理勾配

    /// dS/dV = 1 / (1 + alpha * |V - Vth|)^2
    func testSurrogateGradientValues() {
        XCTAssertEqual(SurrogateGradient.derivative(v: 1.0, vTh: 1.0, alpha: 2.0), 1.0, accuracy: 1e-6)
        // |1.5 - 1.0| = 0.5 -> 1 / (1 + 1.0)^2 = 0.25
        XCTAssertEqual(SurrogateGradient.derivative(v: 1.5, vTh: 1.0, alpha: 2.0), 0.25, accuracy: 1e-6)
        // |0.0 - 1.0| = 1.0 -> 1 / 3^2 = 0.111...
        XCTAssertEqual(SurrogateGradient.derivative(v: 0.0, vTh: 1.0, alpha: 2.0), 1.0 / 9.0, accuracy: 1e-6)
        // 対称性
        XCTAssertEqual(
            SurrogateGradient.derivative(v: 0.3, vTh: 1.0, alpha: 3.0),
            SurrogateGradient.derivative(v: 1.7, vTh: 1.0, alpha: 3.0),
            accuracy: 1e-6
        )
    }

    func testSurrogateGradientSIMD8MatchesScalar() {
        let count = 19
        var v = [Float](repeating: 0.0, count: count)
        var dst = [Float](repeating: 0.0, count: count)
        var i = 0
        while i < count {
            v[i] = Float(i) * 0.17 - 1.0
            i += 1
        }
        v.withUnsafeBufferPointer { vb in
            dst.withUnsafeMutableBufferPointer { db in
                SurrogateGradient.derivativeSIMD8(
                    vPtr: vb.baseAddress!, dstPtr: db.baseAddress!, count: count, vTh: 1.0, alpha: 2.0
                )
            }
        }
        i = 0
        while i < count {
            XCTAssertEqual(
                dst[i],
                SurrogateGradient.derivative(v: v[i], vTh: 1.0, alpha: 2.0),
                accuracy: 1e-6,
                "surrogate mismatch at \(i)"
            )
            i += 1
        }
    }

    // MARK: - classifyLogits

    private func makeSmallNetwork(
        numLayers: Int = 2,
        seed: UInt64 = 5150,
        readoutFrames: Int = 32
    ) -> SpikingNetwork {
        let net = SpikingNetwork(
            numLayers: numLayers,
            inputDim: 8,
            maxHiddenDim: 16,
            outputDim: 4,
            timeSteps: 2,
            lifConfig: LIFConfig(),
            readoutFrames: readoutFrames
        )
        seedWeights(net, seed: seed)
        return net
    }

    /// 各フレームのロジットを直に回して集める参照実装 (classifyLogits を使わない)
    private func perFrameLogits(_ net: SpikingNetwork, frames: [[Float]]) -> [[Float]] {
        let hSize = net.maxHiddenDim
        var vPrev = [Float](repeating: 0.0, count: net.numLayers * hSize)
        var sPrev = [Float](repeating: 0.0, count: net.numLayers * hSize)
        var aPrev = [Float](repeating: 0.0, count: net.numLayers * hSize)
        var readoutSum = [Float](repeating: 0.0, count: hSize)
        var logits = [Float](repeating: 0.0, count: net.outputDim)
        var probs = [Float](repeating: 0.0, count: net.outputDim)
        let scratch = ForwardScratch(maxHiddenDim: hSize)
        var out: [[Float]] = []
        var t = 0
        while t < frames.count {
            net.forward(
                features: frames[t], vPrev: &vPrev, sPrev: &sPrev, aPrev: &aPrev,
                readoutSum: &readoutSum, logits: &logits, probabilities: &probs, scratch: scratch
            )
            out.append(logits)
            t += 1
        }
        return out
    }

    /// 末尾 `readoutFrames` フレームのロジット平均 (参照値)
    private func tailMean(_ perFrame: [[Float]], readoutFrames: Int, outputDim: Int) -> [Float] {
        let used = min(readoutFrames, perFrame.count)
        let first = perFrame.count - used
        var acc = [Float](repeating: 0.0, count: outputDim)
        var t = first
        while t < perFrame.count {
            var c = 0
            while c < outputDim {
                acc[c] += perFrame[t][c]
                c += 1
            }
            t += 1
        }
        let divisor = Float(used)
        var c = 0
        while c < outputDim {
            acc[c] /= divisor
            c += 1
        }
        return acc
    }

    private func makeFrames(count: Int, dim: Int, seed: UInt64) -> [[Float]] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        var frames: [[Float]] = []
        var t = 0
        while t < count {
            var frame = [Float](repeating: 0.0, count: dim)
            var d = 0
            while d < dim {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                frame[d] = Float((state >> 33) % 1000) / 1000.0
                d += 1
            }
            frames.append(frame)
            t += 1
        }
        return frames
    }

    func testClassifyLogitsShapeAndFiniteness() throws {
        let net = makeSmallNetwork()
        let frames = makeFrames(count: 5, dim: 8, seed: 42)
        let logits = try net.classifyLogits(frames: frames)
        XCTAssertEqual(logits.count, 4)
        var c = 0
        while c < logits.count {
            XCTAssertFalse(logits[c].isNaN)
            XCTAssertFalse(logits[c].isInfinite)
            c += 1
        }
    }

    /// 状態をゼロから始めるので、同じ入力なら何度呼んでも同じ結果になる
    func testClassifyLogitsIsDeterministicAcrossCalls() throws {
        let net = makeSmallNetwork()
        let frames = makeFrames(count: 32, dim: 8, seed: 7)
        let first = try net.classifyLogits(frames: frames)
        _ = try net.classifyLogits(frames: makeFrames(count: 32, dim: 8, seed: 999))
        let second = try net.classifyLogits(frames: frames)
        XCTAssertEqual(first, second)
    }

    /// 平均ロジットの定義: 末尾 `readoutFrames` フレームのロジットの相加平均。
    /// `classifyLogits` を使わずに forward を直に回した参照値と完全一致することを確かめる。
    func testClassifyLogitsEqualsTailMeanOfPerFrameLogits() throws {
        let frameCount = 32
        for readoutFrames in [1, 8, 32] {
            let net = makeSmallNetwork(seed: 11, readoutFrames: readoutFrames)
            XCTAssertEqual(net.readoutFrames, readoutFrames)
            let frames = makeFrames(count: frameCount, dim: 8, seed: 11)

            let perFrame = perFrameLogits(net, frames: frames)
            XCTAssertEqual(perFrame.count, frameCount)
            let expected = tailMean(perFrame, readoutFrames: readoutFrames, outputDim: net.outputDim)
            let actual = try net.classifyLogits(frames: frames)
            XCTAssertEqual(actual, expected, "readoutFrames = \(readoutFrames) で末尾平均と一致しない")

            // readoutFrames = 1 なら最終フレームのロジットそのもの
            if readoutFrames == 1 {
                XCTAssertEqual(actual, perFrame[frameCount - 1])
            }
        }
    }

    /// readoutFrames を変えると結果も変わる (値が使われずに無視されていないこと)
    func testDifferentReadoutFramesGiveDifferentLogits() throws {
        let frames = makeFrames(count: 32, dim: 8, seed: 11)
        let one = try makeSmallNetwork(seed: 11, readoutFrames: 1).classifyLogits(frames: frames)
        let eight = try makeSmallNetwork(seed: 11, readoutFrames: 8).classifyLogits(frames: frames)
        let all = try makeSmallNetwork(seed: 11, readoutFrames: 32).classifyLogits(frames: frames)
        XCTAssertNotEqual(one, eight)
        XCTAssertNotEqual(eight, all)
        XCTAssertNotEqual(one, all)
    }

    /// フレーム列が readoutFrames より短ければ全フレームを平均する
    func testReadoutFramesLongerThanSequenceUsesAllFrames() throws {
        let net = makeSmallNetwork(seed: 11, readoutFrames: 100)
        let frames = makeFrames(count: 5, dim: 8, seed: 11)
        let perFrame = perFrameLogits(net, frames: frames)
        let expected = tailMean(perFrame, readoutFrames: 5, outputDim: net.outputDim)
        XCTAssertEqual(try net.classifyLogits(frames: frames), expected)
    }

    /// 0 以下は投げずに 1 へ丸める (init の仕様)
    func testNonPositiveReadoutFramesIsClampedToOne() throws {
        for requested in [0, -1, -100] {
            let net = makeSmallNetwork(seed: 11, readoutFrames: requested)
            XCTAssertEqual(net.readoutFrames, 1, "readoutFrames \(requested) が 1 に丸められていない")
        }
        let net = makeSmallNetwork(seed: 11, readoutFrames: 0)
        let frames = makeFrames(count: 4, dim: 8, seed: 11)
        let perFrame = perFrameLogits(net, frames: frames)
        XCTAssertEqual(try net.classifyLogits(frames: frames), perFrame[3])
    }

    /// 既定値は 32 (全フレーム平均)。
    /// 末尾だけに絞ると実データでは劣った: kana 実験 (2026-09-24) の held-out 正解率は 32 で 63.8%、8 で 44.0%。
    func testDefaultReadoutFramesIsThirtyTwo() {
        XCTAssertEqual(SpikingNetwork(numLayers: 1, inputDim: 4, maxHiddenDim: 8, outputDim: 2).readoutFrames, 32)

        // 重み構造体のメモリ上の init も同じ既定値
        let weights = SpikingNetworkWeights(
            inputDim: 4,
            maxHiddenDim: 8,
            outputDim: 2,
            timeSteps: 2,
            lifConfig: LIFConfig(),
            wIn: [Float](repeating: 0.0, count: 8 * 4),
            wRec: [Float](repeating: 0.0, count: 8 * 8),
            bH: [Float](repeating: 0.0, count: 8),
            wOut: [Float](repeating: 0.0, count: 2 * 8),
            bOut: [Float](repeating: 0.0, count: 2)
        )
        XCTAssertEqual(weights.readoutFrames, 32)
        XCTAssertEqual(weights.readoutFrames, SpikingNetworkWeights.legacyReadoutFrames)

        // readoutFrames を渡さずに作ったネットワークは 32 フレーム全部を平均する
        // (makeSmallNetwork はヘルパ側の既定値を渡すので、ここでは直に init する)
        let net = SpikingNetwork(
            numLayers: 2, inputDim: 8, maxHiddenDim: 16, outputDim: 4, timeSteps: 2
        )
        seedWeights(net, seed: 11)
        XCTAssertEqual(net.readoutFrames, 32)
        let frames = makeFrames(count: 32, dim: 8, seed: 11)
        let perFrame = perFrameLogits(net, frames: frames)
        XCTAssertEqual(try net.classifyLogits(frames: frames),
                       tailMean(perFrame, readoutFrames: 32, outputDim: net.outputDim))
    }

    func testClassifyLogitsThrowsOnEmptyInput() {
        let net = makeSmallNetwork()
        XCTAssertThrowsError(try net.classifyLogits(frames: [])) { error in
            XCTAssertEqual(error as? SequenceClassifierError, SequenceClassifierError.emptyFrameSequence)
        }
    }

    func testClassifyLogitsThrowsOnDimensionMismatch() {
        let net = makeSmallNetwork()
        var frames = makeFrames(count: 3, dim: 8, seed: 3)
        frames[1] = [Float](repeating: 0.5, count: 7)
        XCTAssertThrowsError(try net.classifyLogits(frames: frames)) { error in
            XCTAssertEqual(
                error as? SequenceClassifierError,
                SequenceClassifierError.frameDimensionMismatch(frameIndex: 1, expected: 8, actual: 7)
            )
        }

        // 次元が多い場合も明示エラー (forward は超過分を黙って捨てるため)
        var longer = makeFrames(count: 2, dim: 8, seed: 4)
        longer[0] = [Float](repeating: 0.5, count: 9)
        XCTAssertThrowsError(try net.classifyLogits(frames: longer)) { error in
            XCTAssertEqual(
                error as? SequenceClassifierError,
                SequenceClassifierError.frameDimensionMismatch(frameIndex: 0, expected: 8, actual: 9)
            )
        }
    }

    // MARK: - 重み JSON の round-trip

    func testWeightsJSONRoundTripReproducesIdenticalLogits() throws {
        let net = SpikingNetwork(
            numLayers: 3, inputDim: 8, maxHiddenDim: 16, outputDim: 5, timeSteps: 3,
            lifConfig: LIFConfig(beta: 0.75, vTh: 1.1, vReset: 0.0, alpha: 2.5, rho: 0.8, gamma: 0.2)
        )
        seedWeights(net, seed: 2024)
        let frames = makeFrames(count: 12, dim: 8, seed: 2024)
        let expected = try net.classifyLogits(frames: frames)

        let exported = net.exportWeights(classLabels: ["あ", "い", "う", "え", "お"])
        let data = try JSONEncoder().encode(exported)
        let decoded = try JSONDecoder().decode(SpikingNetworkWeights.self, from: data)
        XCTAssertEqual(decoded, exported)
        XCTAssertEqual(decoded.classLabels, ["あ", "い", "う", "え", "お"])
        XCTAssertEqual(decoded.numLayers, 3)
        XCTAssertEqual(decoded.lifConfig, net.lifConfig)

        let restored = SpikingNetwork(weights: decoded)
        XCTAssertEqual(restored.numLayers, net.numLayers)
        XCTAssertEqual(restored.maxHiddenDim, net.maxHiddenDim)
        XCTAssertEqual(restored.outputDim, net.outputDim)
        XCTAssertEqual(restored.timeSteps, net.timeSteps)

        let actual = try restored.classifyLogits(frames: frames)
        XCTAssertEqual(actual, expected, "JSON round-trip でロジットが変わってはいけない")
    }

    /// readoutFrames が重み JSON を往復すること (CPU と MLX が必ず同じ値を使うため)
    func testWeightsJSONRoundTripPreservesReadoutFrames() throws {
        for readoutFrames in [1, 8, 32] {
            let net = makeSmallNetwork(seed: 4242, readoutFrames: readoutFrames)
            let frames = makeFrames(count: 32, dim: 8, seed: 4242)
            let expected = try net.classifyLogits(frames: frames)

            let data = try JSONEncoder().encode(net.exportWeights())
            let decoded = try JSONDecoder().decode(SpikingNetworkWeights.self, from: data)
            XCTAssertEqual(decoded.readoutFrames, readoutFrames)

            let restored = SpikingNetwork(weights: decoded)
            XCTAssertEqual(restored.readoutFrames, readoutFrames)
            XCTAssertEqual(try restored.classifyLogits(frames: frames), expected,
                           "readoutFrames = \(readoutFrames) の往復でロジットが変わった")
        }
    }

    /// `readoutFrames` キーの無い古い JSON は 32 (全フレーム平均) とみなす
    func testWeightsJSONWithoutReadoutFramesDefaultsToThirtyTwo() throws {
        let net = makeSmallNetwork(seed: 4242, readoutFrames: 8)
        let data = try JSONEncoder().encode(net.exportWeights())

        // JSON から readoutFrames キーを取り除く (古い重みファイルの再現)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("重み JSON がオブジェクトでない")
            return
        }
        XCTAssertNotNil(object["readoutFrames"], "エクスポートした JSON に readoutFrames が無い")
        object.removeValue(forKey: "readoutFrames")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SpikingNetworkWeights.self, from: legacyData)
        XCTAssertEqual(decoded.readoutFrames, 32)
        XCTAssertEqual(decoded.readoutFrames, SpikingNetworkWeights.legacyReadoutFrames)

        // 古い重みから作ったネットワークは従来どおり全フレーム平均になる
        let restored = SpikingNetwork(weights: decoded)
        XCTAssertEqual(restored.readoutFrames, 32)
        let frames = makeFrames(count: 32, dim: 8, seed: 4242)
        let perFrame = perFrameLogits(restored, frames: frames)
        let allFrameMean = tailMean(perFrame, readoutFrames: 32, outputDim: restored.outputDim)
        XCTAssertEqual(try restored.classifyLogits(frames: frames), allFrameMean)
    }

    // MARK: - QuantizedEngine

    /// `QuantizedEngine` は層 0 のみ・状態を毎回リセットする。
    /// そのため float32 側も 1 フレームごとに状態をゼロに戻して比較する。
    ///
    /// 量子化は閾値をまたぐニューロンの発火を変えるので、全フレームで argmax が
    /// 完全一致することは保証できない。20 通りの重み × 32 フレーム = 640 件での
    /// top-1 一致率で確認する (実測: int32 99.375%, int16 95.3125%, float16 99.6875%)。
    func testQuantizedEngineArgmaxMatchesFloat32() {
        let hidden = 64
        let outDim = 32
        let inDim = 64
        let seedCount = 20
        let frameCount = 32

        let cases: [(name: String, config: QuantizedConfig, minRate: Float)] = [
            ("int32", QuantizedConfig.int32Config(), 0.98),
            ("int16", QuantizedConfig.int16Config(), 0.90),
            ("float16", QuantizedConfig.float16Config(beta: 0.8, vTh: 1.0), 0.98)
        ]

        for testCase in cases {
            var matches = 0
            var total = 0
            var distinctTops = Set<Int>()

            var seed = 0
            while seed < seedCount {
                let net = SpikingNetwork(
                    numLayers: 1, inputDim: inDim, maxHiddenDim: hidden, outputDim: outDim, timeSteps: 4,
                    lifConfig: LIFConfig(beta: 0.8, vTh: 1.0, vReset: 0.0, alpha: 2.0, rho: 0.85, gamma: 0.0)
                )
                seedWeights(net, seed: UInt64(seed) &+ 1)
                let frames = makeFrames(count: frameCount, dim: inDim, seed: UInt64(seed) &+ 900)

                let engine = QuantizedEngine(
                    weights: QuantizedEngine.quantize(network: net, config: testCase.config),
                    timeSteps: 4
                )
                let workspace = QuantizedWorkspace(maxHiddenDim: hidden, inputDim: inDim, outputDim: outDim)
                var quantProbs = [Float](repeating: 0.0, count: outDim)
                var floatProbs = [Float](repeating: 0.0, count: outDim)
                var logits = [Float](repeating: 0.0, count: outDim)
                var readoutSum = [Float](repeating: 0.0, count: hidden)

                var t = 0
                while t < frames.count {
                    var vPrev = [Float](repeating: 0.0, count: hidden)
                    var sPrev = [Float](repeating: 0.0, count: hidden)
                    var aPrev = [Float](repeating: 0.0, count: hidden)
                    net.forward(
                        features: frames[t], vPrev: &vPrev, sPrev: &sPrev, aPrev: &aPrev,
                        readoutSum: &readoutSum, logits: &logits, probabilities: &floatProbs,
                        scratch: ForwardScratch(maxHiddenDim: hidden)
                    )
                    engine.predict(features: frames[t], workspace: workspace, outputProbs: &quantProbs)

                    var topFloat = 0
                    var topQuant = 0
                    var c = 1
                    while c < outDim {
                        if logits[topFloat] < logits[c] {
                            topFloat = c
                        }
                        if quantProbs[topQuant] < quantProbs[c] {
                            topQuant = c
                        }
                        c += 1
                    }
                    if topFloat == topQuant {
                        matches += 1
                    }
                    total += 1
                    distinctTops.insert(topFloat)

                    var sumP: Float = 0.0
                    c = 0
                    while c < outDim {
                        XCTAssertFalse(quantProbs[c].isNaN, "\(testCase.name): NaN が出た")
                        XCTAssertFalse(quantProbs[c].isInfinite, "\(testCase.name): Inf が出た")
                        sumP += quantProbs[c]
                        c += 1
                    }
                    XCTAssertEqual(sumP, 1.0, accuracy: 1e-4, "\(testCase.name): softmax の和が 1 でない")
                    t += 1
                }
                seed += 1
            }

            // argmax が常に同じだと一致率テストが空回りする
            XCTAssertGreaterThanOrEqual(distinctTops.count, 2, "\(testCase.name): argmax が変化していない")
            let rate = Float(matches) / Float(total)
            print("[QuantizedEngine] \(testCase.name) top-1 一致率 = \(matches)/\(total) = \(rate)")
            XCTAssertGreaterThanOrEqual(
                rate, testCase.minRate,
                "\(testCase.name): float32 との top-1 一致率 \(rate) が下限 \(testCase.minRate) を下回った"
            )
        }
    }

    // MARK: - 推論時間の計測

    /// 既定構成 (4 層・hidden 512・出力 3236・timeSteps 4) で
    /// 1 文字 (32 フレーム) あたりの CPU 推論時間を測る。数値ゲートは設けず、記録だけする。
    func testMeasureCharacterInferenceTime() throws {
        let net = SpikingNetwork(
            numLayers: 4,
            inputDim: 64,
            maxHiddenDim: 512,
            outputDim: 3236,
            timeSteps: 4,
            lifConfig: LIFConfig()
        )
        seedWeights(net, seed: 777)
        let frames = makeFrames(count: 32, dim: 64, seed: 4242)

        // 初回は転置レイアウトやページフォールトで遅いので、計測前に数回回す
        var warm = 0
        while warm < 3 {
            _ = try net.classifyLogits(frames: frames)
            warm += 1
        }

        let iterations = 100
        let start = DispatchTime.now().uptimeNanoseconds
        var i = 0
        var checksum: Float = 0.0
        while i < iterations {
            let logits = try net.classifyLogits(frames: frames)
            checksum += logits[0]
            i += 1
        }
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
        let msPerCharacter = Double(elapsedNs) / Double(iterations) / 1_000_000.0
        print("[Benchmark] 4 層 / hidden 512 / 出力 3236 / 32 フレーム: \(msPerCharacter) ms / 文字 (\(iterations) 回平均)")
        XCTAssertFalse(checksum.isNaN)
        XCTAssertGreaterThan(msPerCharacter, 0.0)
    }

}
