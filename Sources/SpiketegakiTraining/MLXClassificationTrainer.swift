import Foundation
import MLX
import MLXNN
import MLXOptimizers
import Spiketegaki

/// 分類学習の設定。
public struct ClassificationTrainingConfig: Sendable {
    public let learningRate: Float
    /// 全パラメータをまとめた勾配 L2 ノルムの上限
    public let clipNorm: Float

    public init(learningRate: Float = 0.003, clipNorm: Float = 5.0) {
        self.learningRate = learningRate
        self.clipNorm = clipNorm
    }
}

/// MLX 上の 1 文字分類学習 (BPTT)。
///
/// 入力 `[B, T, inputDim]` を T フレーム全体で前向きに進め、`[B, T, outputDim]` の
/// ロジット系列をフレーム平均して `[B, outputDim]` にし、softmax 交差エントロピーを取る
/// T は 32 固定なので compile は 1 形状で足りる。
public final class MLXClassificationTrainer: @unchecked Sendable {
    public let network: MLXSpikingNetwork
    public let optimizer: ArrayLRAdam
    public let config: ClassificationTrainingConfig

    /// (バッチ件数 << 16 | フレーム数) をキーとするコンパイル済み学習ステップ
    private var compiledTrainSteps: [Int: ([MLXArray]) -> [MLXArray]] = [:]
    /// 同じキーのコンパイル済み平均ロジット (評価用、勾配なし)
    private var compiledMeanLogits: [Int: ([MLXArray]) -> [MLXArray]] = [:]

    /// MLX が使い回しのために抱えるバッファキャッシュの上限。
    public static let cacheLimitBytes = 8 << 30

    public init(
        network: MLXSpikingNetwork,
        config: ClassificationTrainingConfig = ClassificationTrainingConfig()
    ) {
        self.network = network
        self.config = config
        self.optimizer = ArrayLRAdam(learningRate: config.learningRate)
        MLX.Memory.cacheLimit = Self.cacheLimitBytes
    }

    /// 学習率を更新。配列で持つので compile 済みステップにも入力として渡る
    public func updateLearningRate(_ lr: Float) {
        self.optimizer.learningRate = MLXArray(lr)
    }

    // MARK: - フォワード

    /// 1 サブステップ分の全層 LIF 更新。
    /// 入力 [層 0 の入力電流, v_0...v_L-1, s_0...s_L-1, a_0...a_L-1]、出力 [v..., s..., a..., 最終層の読み出し]。
    /// 層 0 は再帰、層 1 以降は前層スパイクの RMSNorm 電流 + 前層電流の残差。
    /// 最終層だけハードリセットせず、閾値単位の膜電位を読んでから余りを残す
    func substep(network: MLXSpikingNetwork, arrays: [MLXArray]) -> [MLXArray] {
        let numLayers = network.numLayers
        let beta = network.lifConfig.beta
        let vTh = network.lifConfig.vTh
        let alpha = network.lifConfig.alpha
        let rho = network.lifConfig.rho
        let gamma = network.lifConfig.gamma
        let vMin = LIFNeuronEngine.vClampMin
        let vMax = LIFNeuronEngine.vClampMax
        let readoutK = LIFNeuronEngine.readoutClipInThresholdUnits

        let current0 = arrays[0]
        var v = Array(arrays[1..<(1 + numLayers)])
        var s = Array(arrays[(1 + numLayers)..<(1 + 2 * numLayers)])
        var a = Array(arrays[(1 + 2 * numLayers)..<(1 + 3 * numLayers)])
        var readout = MLXArray.zeros(like: v[0])

        var current = current0 + matmul(s[0], network.wRec)
        var l = 0
        while l < numLayers {
            if 0 < l {
                let upperIdx = l - 1
                let denseCur = matmul(s[l - 1], network.wLayers[upperIdx]) + network.bHLayers[upperIdx]
                // MLXFast.rmsNorm は valueAndGrad + compile で Metal 生存バッファ上限を超える
                let meanSq = mean(denseCur * denseCur, axis: -1, keepDims: true)
                let rms = sqrt(meanSq + rmsNormEpsilon)
                current = (denseCur / rms) * network.gammaRMS[upperIdx] + current
            }

            let isLast = (l + 1) == numLayers
            if isLast {
                v[l] = clip(v[l] * beta + current, min: vMin, max: vMax)
            } else {
                v[l] = clip((v[l] * beta) * (1.0 - s[l]) + current, min: vMin, max: vMax)
            }

            a[l] = (a[l] * rho) + (s[l] * gamma)
            let dynVTh = vTh + a[l]
            let vRel = (v[l] - dynVTh) * alpha
            let sSurrogate = 0.5 * (vRel / (1.0 + abs(vRel)) + 1.0)
            let sHard = (dynVTh .<= v[l]).asType(.float32)
            s[l] = stopGradient(sHard - sSurrogate) + sSurrogate

            if isLast {
                // 読み出しは閾値単位でクリップするが、勾配はクリップ前の値を通す (straight-through)。
                // clip の勾配は |v| >= vTh で 0 になり、発火しているニューロンから勾配が流れない
                let scaled = v[l] / vTh
                let clipped = clip(scaled, min: -readoutK, max: readoutK)
                readout = stopGradient(clipped - scaled) + scaled
                v[l] = clip(v[l] - sHard * vTh, min: vMin, max: vMax)
            }
            l += 1
        }
        return v + s + a + [readout]
    }

    /// フレーム [t0, t1) を前向きに進め、各フレームの読み出し (サブステップ平均、[B, hMax]) を返す。
    /// 1 文字 32 フレームは切り詰めずに全体を逆伝播する。
    func forwardFrames(
        network: MLXSpikingNetwork,
        currentSeq0: MLXArray,
        from t0: Int,
        to t1: Int,
        v: inout [MLXArray],
        s: inout [MLXArray],
        a: inout [MLXArray]
    ) -> [MLXArray] {
        let tSteps = network.timeSteps
        let numLayers = network.numLayers
        var readoutList: [MLXArray] = []
        readoutList.reserveCapacity(t1 - t0)

        var t = t0
        while t < t1 {
            let current0_t = currentSeq0[0..., t, 0...]
            var readoutSum = MLXArray.zeros(like: v[0])

            var step = 0
            while step < tSteps {
                var inputs: [MLXArray] = [current0_t]
                inputs.append(contentsOf: v)
                inputs.append(contentsOf: s)
                inputs.append(contentsOf: a)
                let out = substep(network: network, arrays: inputs)
                v = Array(out[0..<numLayers])
                s = Array(out[numLayers..<(2 * numLayers)])
                a = Array(out[(2 * numLayers)..<(3 * numLayers)])
                readoutSum = readoutSum + out[3 * numLayers]
                step += 1
            }

            readoutList.append(readoutSum / Float(tSteps))
            t += 1
        }
        return readoutList
    }

    /// バッチのロジット系列 [B, T, outputDim]
    public func logitsBatch(
        network: MLXSpikingNetwork,
        features: MLXArray          // [B, T, inputDim]
    ) -> MLXArray {
        let batchSize = features.shape[0]
        let seqLen = features.shape[1]
        let hMax = network.maxHiddenDim
        let numLayers = network.numLayers

        // 層 0 の入力電流系列: [B, T, hMax] = [B, T, inputDim] @ [inputDim, hMax] + bH
        let currentSeq0 = matmul(features, network.wIn) + network.bH
        var v = [MLXArray](repeating: MLXArray.zeros([batchSize, hMax]), count: numLayers)
        var s = [MLXArray](repeating: MLXArray.zeros([batchSize, hMax]), count: numLayers)
        var a = [MLXArray](repeating: MLXArray.zeros([batchSize, hMax]), count: numLayers)
        let readoutList = forwardFrames(
            network: network,
            currentSeq0: currentSeq0,
            from: 0,
            to: seqLen,
            v: &v,
            s: &s,
            a: &a
        )
        return matmul(stacked(readoutList, axis: 1), network.wOut) + network.bOut
    }

    /// 末尾 `readoutFrames` フレームを平均した分類ロジット [B, outputDim]
    /// (CPU 側 `SpikingNetwork.classifyLogits` と同じ式)。
    ///
    /// 先頭フレームは行 0..t と列 0..t しか見ていないので、そこに正解クラスを求めると
    /// 矛盾した教師になる。前向きは全 T フレーム回した上で、読み出しだけ末尾に絞る。
    public func meanLogits(
        network: MLXSpikingNetwork,
        features: MLXArray          // [B, T, inputDim]
    ) -> MLXArray {
        let logits = logitsBatch(network: network, features: features)
        let seqLen = logits.shape[1]
        let used = min(network.readoutFrames, seqLen)
        if used >= seqLen {
            return mean(logits, axis: 1)
        }
        return mean(logits[0..., (seqLen - used)..., 0...], axis: 1)
    }

    /// softmax 交差エントロピー (バッチ平均)
    public func lossBatch(
        network: MLXSpikingNetwork,
        features: MLXArray,         // [B, T, inputDim]
        labels: MLXArray            // [B] (Int32)
    ) -> MLXArray {
        let logits = meanLogits(network: network, features: features)
        return crossEntropy(logits: logits, targets: labels, reduction: .mean)
    }

    // MARK: - 学習ステップ

    /// ミニバッチ学習ステップ。戻り値は損失。
    /// `features` は [B][T][inputDim]、`labels` は [B] のクラス index。
    public func trainBatch(features: [[[Float]]], labels: [Int]) -> Float {
        guard let packed = pack(features: features, labels: labels) else {
            return 0.0
        }
        let key = (packed.batchSize << 16) | packed.frameCount

        let stepFn: ([MLXArray]) -> [MLXArray]
        if let cached = compiledTrainSteps[key] {
            stepFn = cached
        } else {
            let maxNorm = config.clipNorm
            let lg = valueAndGrad(model: network) { (model: MLXSpikingNetwork, arrays: [MLXArray]) -> [MLXArray] in
                return [self.lossBatch(network: model, features: arrays[0], labels: arrays[1])]
            }
            // 学習率は最後の入力配列。トレース時にここで差し替えるので、以後の呼び出しでは
            // 入力に渡した値がそのまま更新式に使われる
            func step(arrays: [MLXArray]) -> [MLXArray] {
                let (lossValues, grads) = lg(self.network, Array(arrays[0..<2]))
                let (clippedGrads, _) = clipGradNorm(gradients: grads, maxNorm: maxNorm)
                let outerLearningRate = self.optimizer.learningRate
                self.optimizer.learningRate = arrays[2]
                self.optimizer.update(model: self.network, gradients: clippedGrads)
                self.optimizer.learningRate = outerLearningRate
                return lossValues
            }
            let newStep = compile(
                inputs: [self.network, self.optimizer],
                outputs: [self.network, self.optimizer],
                step
            )
            compiledTrainSteps[key] = newStep
            stepFn = newStep
        }

        let lossValues = stepFn([packed.features, packed.labels, optimizer.learningRate])
        // オプティマイザの状態も評価する。network と損失だけ評価すると Adam の m/v が
        // 遅延グラフとして積み上がり、Metal の生存バッファ上限に達して落ちる
        eval(network, optimizer, lossValues)
        return lossValues[0].item(Float.self)
    }

    /// 評価 (勾配なし)。損失と正解件数を返す。
    public func evaluateBatch(features: [[[Float]]], labels: [Int]) -> (loss: Float, correct: Int) {
        guard let packed = pack(features: features, labels: labels) else {
            return (0.0, 0)
        }
        let key = (packed.batchSize << 16) | packed.frameCount
        let fn: ([MLXArray]) -> [MLXArray]
        if let cached = compiledMeanLogits[key] {
            fn = cached
        } else {
            let newFn = compile(inputs: [network]) { arrays in
                return [self.meanLogits(network: self.network, features: arrays[0])]
            }
            compiledMeanLogits[key] = newFn
            fn = newFn
        }

        let logits = fn([packed.features])[0]
        let loss = crossEntropy(logits: logits, targets: packed.labels, reduction: .mean)
        let predicted = argMax(logits, axis: -1).asType(.int32)
        let correct = sum((predicted .== packed.labels).asType(.int32))
        eval(loss, correct)
        return (loss.item(Float.self), Int(correct.item(Int32.self)))
    }

    /// [B][T][inputDim] を MLXArray へ詰める。フレーム数が足りないサンプルは 0 埋め。
    private func pack(
        features: [[[Float]]],
        labels: [Int]
    ) -> (features: MLXArray, labels: MLXArray, batchSize: Int, frameCount: Int)? {
        let bSize = min(features.count, labels.count)
        if bSize == 0 {
            return nil
        }
        var maxT = 0
        var b = 0
        while b < bSize {
            if maxT < features[b].count {
                maxT = features[b].count
            }
            b += 1
        }
        if maxT == 0 {
            return nil
        }

        let inDim = network.inputDim
        var flatFeat = [Float](repeating: 0.0, count: bSize * maxT * inDim)
        var flatLabel = [Int32](repeating: 0, count: bSize)
        b = 0
        while b < bSize {
            let fSeq = features[b]
            var t = 0
            while t < fSeq.count {
                let fVec = fSeq[t]
                let offset = ((b * maxT) + t) * inDim
                var d = 0
                while d < min(inDim, fVec.count) {
                    flatFeat[offset + d] = fVec[d]
                    d += 1
                }
                t += 1
            }
            var label = labels[b]
            if label < 0 || network.outputDim <= label {
                label = 0
            }
            flatLabel[b] = Int32(label)
            b += 1
        }

        return (
            features: MLXArray(flatFeat, [bSize, maxT, inDim]),
            labels: MLXArray(flatLabel, [bSize]),
            batchSize: bSize,
            frameCount: maxT
        )
    }
}
