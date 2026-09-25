/// 上位層の電流 RMSNorm で分散 0 のときの除算を避ける微小値 (学習側 MLX と共有)
public let rmsNormEpsilon: Float = 1e-5

/// Float32 の SNN。層 0 は再帰 LIF、層 1 以降は FF LIF。上位層は結合電流を RMSNorm してから前層電流を足す。
public final class SpikingNetwork: @unchecked Sendable {
    public let numLayers: Int
    public let inputDim: Int
    public let maxHiddenDim: Int
    public let outputDim: Int
    public let timeSteps: Int
    /// LIF / ALIF 設定 (重みインポート時に保存済みの値へ追従するため var)
    public private(set) var lifConfig: LIFConfig
    /// 分類ロジットに使う末尾フレーム数。
    /// 重みインポート時に保存済みの値へ追従するため var。
    /// 0 以下は投げずに 1 へ丸める (`numLayers` と同じ扱い。学習の途中で例外を出さないため)
    public private(set) var readoutFrames: Int

    /// 推論用の転置コピー。wRecT[j * maxHiddenDim + n] = wRec[n][j] で、
    /// 発火ニューロン j の流出重みが連続に並ぶため Event-driven 加算を SIMD 化できる
    public private(set) var wRecT: [Float] = []
    /// 層 1 以降の結合重みの転置コピー (wRecT と同じ並び)
    public private(set) var wLayersT: [[Float]] = []
    /// 推論用の転置コピー。wOutT[k * outputDim + c] = wOut[c][k]
    public private(set) var wOutT: [Float] = []

    // 層 0 (再帰 LIF 層)
    public var wIn: [Float]            // [maxHiddenDim * inputDim]
    public var wRec: [Float]           // [maxHiddenDim * maxHiddenDim]
    public var bH: [Float]             // [maxHiddenDim]

    // 層 1 以降 (前層スパイクを受けるフィードフォワード LIF 層)
    public var wLayers: [[Float]]      // [numLayers - 1][maxHiddenDim * maxHiddenDim]
    public var bHLayers: [[Float]]     // [numLayers - 1][maxHiddenDim]
    public var gammaRMS: [[Float]]     // [numLayers - 1][maxHiddenDim]

    // リードアウト
    public var wOut: [Float]           // [outputDim * maxHiddenDim]
    public var bOut: [Float]           // [outputDim]

    /// `inputDim` はスキャンライン符号化のフレーム次元 (既定 64)。
    /// `outputDim` は文字クラス数 (既定 3236)。
    /// `readoutFrames` は分類ロジットに使う末尾フレーム数 (既定 32 = 全フレーム平均)。
    /// 末尾だけに絞ると実データでは劣る: kana 実験 (2026-09-24) の held-out 正解率は 32 で 63.8%、8 で 44.0%。
    /// 0 以下を渡しても投げず 1 に丸める。
    public init(
        numLayers: Int = 1,
        inputDim: Int = 64,
        maxHiddenDim: Int = 512,
        outputDim: Int = 3236,
        timeSteps: Int = 4,
        lifConfig: LIFConfig = LIFConfig(),
        readoutFrames: Int = 32
    ) {
        self.numLayers = max(1, numLayers)
        self.inputDim = inputDim
        self.maxHiddenDim = maxHiddenDim
        self.outputDim = outputDim
        self.timeSteps = timeSteps
        self.lifConfig = lifConfig
        self.readoutFrames = max(1, readoutFrames)

        // Direct Input Current に最適化した重み初期化
        let scaleIn = sqrt(2.0 / Float(inputDim))
        var initWIn = [Float](repeating: 0.0, count: maxHiddenDim * inputDim)
        var i = 0
        while i < maxHiddenDim * inputDim {
            initWIn[i] = Float.random(in: -scaleIn...scaleIn)
            i += 1
        }

        let scaleRec = sqrt(2.0 / Float(maxHiddenDim)) * 0.2
        var initWRec = [Float](repeating: 0.0, count: maxHiddenDim * maxHiddenDim)
        i = 0
        while i < maxHiddenDim * maxHiddenDim {
            initWRec[i] = Float.random(in: -scaleRec...scaleRec)
            i += 1
        }

        let initBH = [Float](repeating: 0.35, count: maxHiddenDim)

        // 上位層パラメータの初期化
        var wLayersList: [[Float]] = []
        var bhLayersList: [[Float]] = []
        var gammaRMSList: [[Float]] = []
        let scaleLayer = sqrt(2.0 / Float(maxHiddenDim))

        var l = 1
        while l < self.numLayers {
            var initWLayer = [Float](repeating: 0.0, count: maxHiddenDim * maxHiddenDim)
            var idx = 0
            while idx < maxHiddenDim * maxHiddenDim {
                initWLayer[idx] = Float.random(in: -scaleLayer...scaleLayer)
                idx += 1
            }
            let initBHL = [Float](repeating: 0.0, count: maxHiddenDim)
            let initGamma = [Float](repeating: 1.0, count: maxHiddenDim)

            wLayersList.append(initWLayer)
            bhLayersList.append(initBHL)
            gammaRMSList.append(initGamma)
            l += 1
        }

        let scaleOut = sqrt(2.0 / Float(maxHiddenDim))
        var initWOut = [Float](repeating: 0.0, count: outputDim * maxHiddenDim)
        i = 0
        while i < outputDim * maxHiddenDim {
            initWOut[i] = Float.random(in: -scaleOut...scaleOut)
            i += 1
        }

        let initBOut = [Float](repeating: 0.0, count: outputDim)

        self.wIn = initWIn
        self.wRec = initWRec
        self.bH = initBH
        self.wLayers = wLayersList
        self.bHLayers = bhLayersList
        self.gammaRMS = gammaRMSList
        self.wOut = initWOut
        self.bOut = initBOut

        rebuildInferenceLayout()
    }

    /// 保存済み重みから構成ごと復元する
    public convenience init(weights: SpikingNetworkWeights) {
        self.init(
            numLayers: weights.numLayers,
            inputDim: weights.inputDim,
            maxHiddenDim: weights.maxHiddenDim,
            outputDim: weights.outputDim,
            timeSteps: weights.timeSteps,
            lifConfig: weights.lifConfig,
            readoutFrames: weights.readoutFrames
        )
        self.importWeights(from: weights)
    }

    /// 全体重みのエクスポート
    public func exportWeights(classLabels: [String]? = nil) -> SpikingNetworkWeights {
        return SpikingNetworkWeights(
            inputDim: inputDim,
            maxHiddenDim: maxHiddenDim,
            outputDim: outputDim,
            timeSteps: timeSteps,
            lifConfig: lifConfig,
            wIn: wIn,
            wRec: wRec,
            bH: bH,
            wLayers: wLayers,
            bHLayers: bHLayers,
            gammaRMS: gammaRMS,
            wOut: wOut,
            bOut: bOut,
            classLabels: classLabels,
            readoutFrames: readoutFrames
        )
    }

    /// 全体重みのインポート (学習時の LIF / ALIF パラメータも同時に復元)
    public func importWeights(from weightsData: SpikingNetworkWeights) {
        self.lifConfig = weightsData.lifConfig
        self.readoutFrames = max(1, weightsData.readoutFrames)
        if weightsData.wIn.count == wIn.count {
            wIn = weightsData.wIn
        }
        if weightsData.wRec.count == wRec.count {
            wRec = weightsData.wRec
        }
        if weightsData.bH.count == bH.count {
            bH = weightsData.bH
        }
        var l = 0
        while l < min(wLayers.count, weightsData.wLayers.count) {
            if weightsData.wLayers[l].count == wLayers[l].count {
                wLayers[l] = weightsData.wLayers[l]
            }
            if weightsData.bHLayers[l].count == bHLayers[l].count {
                bHLayers[l] = weightsData.bHLayers[l]
            }
            if weightsData.gammaRMS[l].count == gammaRMS[l].count {
                gammaRMS[l] = weightsData.gammaRMS[l]
            }
            l += 1
        }
        if weightsData.wOut.count == wOut.count {
            wOut = weightsData.wOut
        }
        if weightsData.bOut.count == bOut.count {
            bOut = weightsData.bOut
        }
        rebuildInferenceLayout()
    }

    /// 推論用の転置レイアウトを再構築する。
    public func rebuildInferenceLayout() {
        let hSize = maxHiddenDim
        if wRecT.count != hSize * hSize {
            wRecT = [Float](repeating: 0.0, count: hSize * hSize)
        }
        wRec.withUnsafeBufferPointer { src in
            wRecT.withUnsafeMutableBufferPointer { dst in
                var n = 0
                while n < hSize {
                    let rowOffset = n * hSize
                    var j = 0
                    while j < hSize {
                        dst[j * hSize + n] = src[rowOffset + j]
                        j += 1
                    }
                    n += 1
                }
            }
        }
        var l = 0
        while l < wLayers.count {
            if wLayersT.count <= l {
                wLayersT.append([Float](repeating: 0.0, count: hSize * hSize))
            }
            if wLayersT[l].count != hSize * hSize {
                wLayersT[l] = [Float](repeating: 0.0, count: hSize * hSize)
            }
            let srcLayer = wLayers[l]
            srcLayer.withUnsafeBufferPointer { src in
                wLayersT[l].withUnsafeMutableBufferPointer { dst in
                    var n = 0
                    while n < hSize {
                        let rowOffset = n * hSize
                        var j = 0
                        while j < hSize {
                            dst[j * hSize + n] = src[rowOffset + j]
                            j += 1
                        }
                        n += 1
                    }
                }
            }
            l += 1
        }
        if wOutT.count != hSize * outputDim {
            wOutT = [Float](repeating: 0.0, count: hSize * outputDim)
        }
        wOut.withUnsafeBufferPointer { src in
            wOutT.withUnsafeMutableBufferPointer { dst in
                var c = 0
                while c < outputDim {
                    let rowOffset = c * hSize
                    var k = 0
                    while k < hSize {
                        dst[k * outputDim + c] = src[rowOffset + k]
                        k += 1
                    }
                    c += 1
                }
            }
        }
    }

    /// 1 フレーム分の forward。状態 (v, s, a) を 1 フレーム進め、`readoutSum` に
    /// **このフレームの閾値単位膜電位の積算** (最終層、内部 timeSteps 回ぶんの合計) を書く。
    ///
    /// ロジットは返さない。ロジットは readout に線形なので、読み出し線形層 `wOut` は
    /// 1 文字あたり 1 回だけ掛ければ足りる (`classifyLogits` を見よ)。
    /// フレームごとに `wOut` (outputDim x maxHiddenDim) を掛けて softmax まで計算していた
    /// 旧実装は、分類では捨てられる値を 32 回計算していた (2026-09-25 に削除)。
    ///
    /// `readoutSum` は呼び出しのたびにゼロから積み直す (フレームごとの値であって累積ではない)。
    public func forward(
        features: [Float],
        vPrev: inout [Float],
        sPrev: inout [Float],
        aPrev: inout [Float],
        readoutSum: inout [Float],
        scratch: ForwardScratch
    ) {
        if features.count < inputDim {
            return
        }
        let hSize = maxHiddenDim
        let totalStateSize = numLayers * hSize
        if vPrev.count < totalStateSize {
            vPrev = [Float](repeating: 0.0, count: totalStateSize)
            sPrev = [Float](repeating: 0.0, count: totalStateSize)
            aPrev = [Float](repeating: 0.0, count: totalStateSize)
        }

        // 1. 読み出し用の膜電位積算をリセット
        var i = 0
        while i < hSize {
            readoutSum[i] = 0.0
            i += 1
        }

        // 2. 入力電流の事前計算 (全タイムステップで不変のためループ外へ Hoist)。
        let hLimit = hSize - (hSize % 8)
        wIn.withUnsafeBufferPointer { wInBuf in
            features.withUnsafeBufferPointer { featBuf in
                bH.withUnsafeBufferPointer { bhBuf in
                    scratch.inputCurrents.withUnsafeMutableBufferPointer { curBuf in
                        let wIn = wInBuf.baseAddress!
                        let feat = featBuf.baseAddress!
                        let bh = bhBuf.baseAddress!
                        let cur = curBuf.baseAddress!
                        var n = 0
                        while n < hLimit {
                            var acc = SIMD8<Float>(
                                bh[n+0], bh[n+1], bh[n+2], bh[n+3],
                                bh[n+4], bh[n+5], bh[n+6], bh[n+7]
                            )
                            let r0 = (n+0) * inputDim
                            let r1 = (n+1) * inputDim
                            let r2 = (n+2) * inputDim
                            let r3 = (n+3) * inputDim
                            let r4 = (n+4) * inputDim
                            let r5 = (n+5) * inputDim
                            let r6 = (n+6) * inputDim
                            let r7 = (n+7) * inputDim
                            var d = 0
                            while d < inputDim {
                                let w = SIMD8<Float>(
                                    wIn[r0+d], wIn[r1+d], wIn[r2+d], wIn[r3+d],
                                    wIn[r4+d], wIn[r5+d], wIn[r6+d], wIn[r7+d]
                                )
                                acc = acc + (w * SIMD8<Float>(repeating: feat[d]))
                                d += 1
                            }
                            cur[n+0] = acc[0]
                            cur[n+1] = acc[1]
                            cur[n+2] = acc[2]
                            cur[n+3] = acc[3]
                            cur[n+4] = acc[4]
                            cur[n+5] = acc[5]
                            cur[n+6] = acc[6]
                            cur[n+7] = acc[7]
                            n += 8
                        }
                        while n < hSize {
                            var curr = bh[n]
                            let inOffset = n * inputDim
                            var d = 0
                            while d < inputDim {
                                curr += wIn[inOffset + d] * feat[d]
                                d += 1
                            }
                            cur[n] = curr
                            n += 1
                        }
                    }
                }
            }
        }

        // 3. 時間ステップループ (ALIF 適応型閾値 & Event-driven 疎スパイク加算)
        var t = 0
        while t < timeSteps {
            // 3.1 層 0: 直前ステップで発火したニューロンの流出重みを足す (再帰結合)。
            //     転置レイアウト wRecT により発火 j の行が連続 → SIMD 加算
            var activeCount0 = 0
            var j = 0
            while j < hSize {
                if sPrev[j] != 0.0 {
                    scratch.activeSpikes[activeCount0] = j
                    activeCount0 += 1
                }
                j += 1
            }

            scratch.stepCurrents.withUnsafeMutableBufferPointer { stepBuf in
                let step = stepBuf.baseAddress!
                scratch.inputCurrents.withUnsafeBufferPointer { inBuf in
                    step.update(from: inBuf.baseAddress!, count: hSize)
                }
                wRecT.withUnsafeBufferPointer { recBuf in
                    let recT = recBuf.baseAddress!
                    var a = 0
                    while a < activeCount0 {
                        let rowOffset = scratch.activeSpikes[a] * hSize
                        var n = 0
                        while n < hLimit {
                            let acc = SIMD8<Float>(
                                step[n+0], step[n+1], step[n+2], step[n+3],
                                step[n+4], step[n+5], step[n+6], step[n+7]
                            )
                            let w = SIMD8<Float>(
                                recT[rowOffset+n+0], recT[rowOffset+n+1],
                                recT[rowOffset+n+2], recT[rowOffset+n+3],
                                recT[rowOffset+n+4], recT[rowOffset+n+5],
                                recT[rowOffset+n+6], recT[rowOffset+n+7]
                            )
                            let sum = acc + w
                            step[n+0] = sum[0]
                            step[n+1] = sum[1]
                            step[n+2] = sum[2]
                            step[n+3] = sum[3]
                            step[n+4] = sum[4]
                            step[n+5] = sum[5]
                            step[n+6] = sum[6]
                            step[n+7] = sum[7]
                            n += 8
                        }
                        while n < hSize {
                            step[n] += recT[rowOffset + n]
                            n += 1
                        }
                        a += 1
                    }
                }
            }

            if 1 < numLayers {
                scratch.stepCurrentsPrev.withUnsafeMutableBufferPointer { prevBuf in
                    scratch.stepCurrents.withUnsafeBufferPointer { curBuf in
                        prevBuf.baseAddress!.update(from: curBuf.baseAddress!, count: hSize)
                    }
                }
            }

            vPrev.withUnsafeMutableBufferPointer { vBuf in
                sPrev.withUnsafeMutableBufferPointer { sBuf in
                    aPrev.withUnsafeMutableBufferPointer { aBuf in
                        scratch.stepCurrents.withUnsafeBufferPointer { curBuf in
                            readoutSum.withUnsafeMutableBufferPointer { sumBuf in
                                stepLayer(
                                    isLast: numLayers == 1,
                                    vPtr: vBuf.baseAddress!,
                                    sPtr: sBuf.baseAddress!,
                                    aPtr: aBuf.baseAddress!,
                                    curPtr: curBuf.baseAddress!,
                                    readoutSumPtr: sumBuf.baseAddress!,
                                    count: hSize
                                )
                            }
                        }
                    }
                }
            }

            // 3.2 層 1 以降: 前層スパイクの結合電流を RMSNorm し、前層の入力電流を加算
            //     (学習側 MLXClassificationTrainer と同じ式)
            var layerIdx = 1
            while layerIdx < numLayers {
                let prevLayerOffset = (layerIdx - 1) * hSize
                let thisLayerOffset = layerIdx * hSize
                let upperIdx = layerIdx - 1

                // 前層のスパイク発火インデックスを収集
                var activeLayerCount = 0
                var kj = 0
                while kj < hSize {
                    if sPrev[prevLayerOffset + kj] != 0.0 {
                        scratch.activeLayerSpikes[activeLayerCount] = kj
                        activeLayerCount += 1
                    }
                    kj += 1
                }

                // 結合電流 = bHLayers + wLayersT * activeSpikes
                let bData = bHLayers[upperIdx]
                let wLayerTData = wLayersT[upperIdx]
                scratch.stepCurrents.withUnsafeMutableBufferPointer { stepBuf in
                    let step = stepBuf.baseAddress!
                    bData.withUnsafeBufferPointer { bBuf in
                        step.update(from: bBuf.baseAddress!, count: hSize)
                    }
                    wLayerTData.withUnsafeBufferPointer { wBuf in
                        let wT = wBuf.baseAddress!
                        var a = 0
                        while a < activeLayerCount {
                            let rowOffset = scratch.activeLayerSpikes[a] * hSize
                            var n = 0
                            while n < hLimit {
                                let acc = SIMD8<Float>(
                                    step[n+0], step[n+1], step[n+2], step[n+3],
                                    step[n+4], step[n+5], step[n+6], step[n+7]
                                )
                                let w = SIMD8<Float>(
                                    wT[rowOffset+n+0], wT[rowOffset+n+1],
                                    wT[rowOffset+n+2], wT[rowOffset+n+3],
                                    wT[rowOffset+n+4], wT[rowOffset+n+5],
                                    wT[rowOffset+n+6], wT[rowOffset+n+7]
                                )
                                let sum = acc + w
                                step[n+0] = sum[0]
                                step[n+1] = sum[1]
                                step[n+2] = sum[2]
                                step[n+3] = sum[3]
                                step[n+4] = sum[4]
                                step[n+5] = sum[5]
                                step[n+6] = sum[6]
                                step[n+7] = sum[7]
                                n += 8
                            }
                            while n < hSize {
                                step[n] += wT[rowOffset + n]
                                n += 1
                            }
                            a += 1
                        }
                    }
                }

                let gammaData = gammaRMS[upperIdx]
                scratch.stepCurrents.withUnsafeMutableBufferPointer { stepBuf in
                    scratch.stepCurrentsPrev.withUnsafeMutableBufferPointer { prevBuf in
                        gammaData.withUnsafeBufferPointer { gammaBuf in
                            let step = stepBuf.baseAddress!
                            let prev = prevBuf.baseAddress!
                            let gamma = gammaBuf.baseAddress!

                            // RMS 計算
                            var sumSqVec = SIMD8<Float>(repeating: 0.0)
                            var n = 0
                            while n < hLimit {
                                let v = SIMD8<Float>(
                                    step[n+0], step[n+1], step[n+2], step[n+3],
                                    step[n+4], step[n+5], step[n+6], step[n+7]
                                )
                                sumSqVec = sumSqVec + (v * v)
                                n += 8
                            }
                            var totalSq = (sumSqVec[0] + sumSqVec[1] + sumSqVec[2] + sumSqVec[3]) +
                                          (sumSqVec[4] + sumSqVec[5] + sumSqVec[6] + sumSqVec[7])
                            while n < hSize {
                                totalSq += step[n] * step[n]
                                n += 1
                            }
                            let meanSq = totalSq / Float(hSize)
                            let rms = sqrt(meanSq + rmsNormEpsilon)
                            let invRms = 1.0 / rms
                            let invRmsVec = SIMD8<Float>(repeating: invRms)

                            n = 0
                            while n < hLimit {
                                let raw = SIMD8<Float>(
                                    step[n+0], step[n+1], step[n+2], step[n+3],
                                    step[n+4], step[n+5], step[n+6], step[n+7]
                                )
                                let g = SIMD8<Float>(
                                    gamma[n+0], gamma[n+1], gamma[n+2], gamma[n+3],
                                    gamma[n+4], gamma[n+5], gamma[n+6], gamma[n+7]
                                )
                                let p = SIMD8<Float>(
                                    prev[n+0], prev[n+1], prev[n+2], prev[n+3],
                                    prev[n+4], prev[n+5], prev[n+6], prev[n+7]
                                )
                                let norm = (raw * invRmsVec) * g
                                let totalCur = norm + p
                                step[n+0] = totalCur[0]
                                step[n+1] = totalCur[1]
                                step[n+2] = totalCur[2]
                                step[n+3] = totalCur[3]
                                step[n+4] = totalCur[4]
                                step[n+5] = totalCur[5]
                                step[n+6] = totalCur[6]
                                step[n+7] = totalCur[7]
                                n += 8
                            }
                            while n < hSize {
                                let norm = (step[n] * invRms) * gamma[n]
                                step[n] = norm + prev[n]
                                n += 1
                            }

                            // 次の上位層があればショートカット用に保存
                            if (layerIdx + 1) < numLayers {
                                prev.update(from: step, count: hSize)
                            }
                        }
                    }
                }

                vPrev.withUnsafeMutableBufferPointer { vBuf in
                    sPrev.withUnsafeMutableBufferPointer { sBuf in
                        aPrev.withUnsafeMutableBufferPointer { aBuf in
                            scratch.stepCurrents.withUnsafeBufferPointer { curBuf in
                                readoutSum.withUnsafeMutableBufferPointer { sumBuf in
                                    stepLayer(
                                        isLast: (layerIdx + 1) == numLayers,
                                        vPtr: vBuf.baseAddress!.advanced(by: thisLayerOffset),
                                        sPtr: sBuf.baseAddress!.advanced(by: thisLayerOffset),
                                        aPtr: aBuf.baseAddress!.advanced(by: thisLayerOffset),
                                        curPtr: curBuf.baseAddress!,
                                        readoutSumPtr: sumBuf.baseAddress!,
                                        count: hSize
                                    )
                                }
                            }
                        }
                    }
                }

                layerIdx += 1
            }

            t += 1
        }

        // 読み出し線形層はここでは掛けない。`classifyLogits` が 32 フレーム分の
        // `readoutSum` を積んでから 1 回だけ掛ける (ロジットは readout に線形なので同値)。
    }

    /// 隠れ層はハードリセット、最終層は閾値単位の膜電位を読んで余りを残す。
    @inline(__always)
    private func stepLayer(
        isLast: Bool,
        vPtr: UnsafeMutablePointer<Float>,
        sPtr: UnsafeMutablePointer<Float>,
        aPtr: UnsafeMutablePointer<Float>,
        curPtr: UnsafePointer<Float>,
        readoutSumPtr: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        if isLast {
            LIFNeuronEngine.stepReadoutAdaptiveSIMD8(
                config: lifConfig,
                vPtr: vPtr,
                sPtr: sPtr,
                aPtr: aPtr,
                curPtr: curPtr,
                readoutSumPtr: readoutSumPtr,
                count: count
            )
        } else {
            LIFNeuronEngine.stepAdaptiveSIMD8(
                config: lifConfig,
                vPtr: vPtr,
                sPtr: sPtr,
                aPtr: aPtr,
                curPtr: curPtr,
                count: count
            )
        }
    }
}

/// `SpikingNetwork.forward` の層間電流と次状態。呼び出し側が保持する。
public final class ForwardScratch: @unchecked Sendable {
    public var inputCurrents: [Float]
    public var stepCurrents: [Float]
    public var stepCurrentsPrev: [Float]
    public var activeSpikes: [Int]
    public var activeLayerSpikes: [Int]
    public var activeReadoutIndices: [Int]
    public var activeRates: [Float]
    public var readoutSums: [Float]

    public init(maxHiddenDim: Int) {
        let size = max(1, maxHiddenDim)
        self.inputCurrents = [Float](repeating: 0.0, count: size)
        self.stepCurrents = [Float](repeating: 0.0, count: size)
        self.stepCurrentsPrev = [Float](repeating: 0.0, count: size)
        self.activeSpikes = [Int](repeating: 0, count: size)
        self.activeLayerSpikes = [Int](repeating: 0, count: size)
        self.activeReadoutIndices = [Int](repeating: 0, count: size)
        self.activeRates = [Float](repeating: 0.0, count: size)
        self.readoutSums = []
    }
}
