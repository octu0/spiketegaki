/// `SpikingNetwork.classifyLogits` が投げるエラー。
/// 仕様外の入力でクラッシュさせず、呼び出し側に理由を返すため。
public enum SequenceClassifierError: Error, Equatable {
    /// フレーム列が空
    case emptyFrameSequence
    /// フレームの次元がネットワークの `inputDim` と違う
    case frameDimensionMismatch(frameIndex: Int, expected: Int, actual: Int)
    /// ネットワークの形が分類に使えない (出力次元 0 など)
    case invalidNetworkShape(maxHiddenDim: Int, outputDim: Int)
}

extension SpikingNetwork {
    /// フレーム列を先頭から順に `forward` し、**末尾 `readoutFrames` フレーム**のロジットの
    /// 平均を返す。
    ///
    /// スキャンライン符号化ではフレーム t までに行 0..t と列 0..t しか見えていないので、
    /// 先頭フレームのロジットに正解クラスを求めるのは矛盾した教師になる。末尾だけを読む。
    /// 平均するのは `min(readoutFrames, frames.count)` フレーム
    /// (フレーム列が `readoutFrames` より短ければ全部)。
    ///
    /// 状態 (v, s, a) はゼロから始める。1 文字ごとに独立なので、
    /// 呼び出しをまたいで状態を持ち越さない。全フレームを forward する点は変わらない
    /// (末尾フレームは先頭フレームの状態を受け継ぐので、途中を飛ばすことはできない)。
    /// 学習側 (`MLXClassificationTrainer.meanLogits` の末尾フレーム平均) と同じ式になる。
    public func classifyLogits(frames: [[Float]]) throws -> [Float] {
        if frames.isEmpty {
            throw SequenceClassifierError.emptyFrameSequence
        }
        if maxHiddenDim <= 0 || outputDim <= 0 {
            throw SequenceClassifierError.invalidNetworkShape(
                maxHiddenDim: maxHiddenDim,
                outputDim: outputDim
            )
        }
        // forward は features.count < inputDim を黙って無視するため、先に全フレームを検査する
        var t = 0
        while t < frames.count {
            if frames[t].count != inputDim {
                throw SequenceClassifierError.frameDimensionMismatch(
                    frameIndex: t,
                    expected: inputDim,
                    actual: frames[t].count
                )
            }
            t += 1
        }

        let hSize = maxHiddenDim
        let stateSize = numLayers * hSize
        var vPrev = [Float](repeating: 0.0, count: stateSize)
        var sPrev = [Float](repeating: 0.0, count: stateSize)
        var aPrev = [Float](repeating: 0.0, count: stateSize)
        var readoutSum = [Float](repeating: 0.0, count: hSize)
        // 末尾 readoutFrames フレームぶんの readoutSum の合計。
        // ここに積んでから最後に一度だけ読み出し線形層を掛ける
        var readoutTotal = [Float](repeating: 0.0, count: hSize)
        let scratch = ForwardScratch(maxHiddenDim: hSize)

        // 平均に使うのは末尾 readoutFrames フレームだけ。ただし状態を繋ぐため forward は全フレーム回す
        let usedFrames = min(readoutFrames, frames.count)
        let firstReadoutIndex = frames.count - usedFrames

        t = 0
        while t < frames.count {
            forward(
                features: frames[t],
                vPrev: &vPrev,
                sPrev: &sPrev,
                aPrev: &aPrev,
                readoutSum: &readoutSum,
                scratch: scratch
            )
            if firstReadoutIndex <= t {
                var k = 0
                while k < hSize {
                    readoutTotal[k] += readoutSum[k]
                    k += 1
                }
            }
            t += 1
        }

        return readoutLogits(readoutTotal: readoutTotal, usedFrames: usedFrames, scratch: scratch)
    }

    /// 積んだ閾値単位膜電位の合計に読み出し線形層を **1 回だけ** 掛けてロジットを返す。
    ///
    /// ロジットは readout に対して線形 (`logit = bOut + wOut ・ rate`) なので
    ///
    ///     mean_t(bOut + wOut ・ rate_t) = bOut + wOut ・ mean_t(rate_t)
    ///
    /// が厳密に成り立つ (bOut の相加平均は bOut そのもの)。
    /// 旧実装は `forward` の中でフレームごとに wOut (outputDim x maxHiddenDim) を掛けてから
    /// 32 フレーム分のロジットを平均していたが、先に rate を平均してから 1 回掛ければ同値で、
    /// **読み出しの仕事がフレーム数ぶんの 1 になる**。
    /// 32 フレーム・隠れ 512・出力 3236 では読み出しが全演算の約 6 割を占めていた。
    ///
    /// 浮動小数の丸めの順序は変わるので、旧実装とビット一致はしない。
    /// 差は `SNNTests.testReadoutOncePerCharacterMatchesPerFrameReadout` で測っていて、
    /// 4 層 / 隠れ 128 / 出力 512 / 32 フレームの 9 条件で最大絶対差 8.3e-07 (許容 1e-4)。
    private func readoutLogits(
        readoutTotal: [Float],
        usedFrames: Int,
        scratch: ForwardScratch
    ) -> [Float] {
        let hSize = maxHiddenDim

        // 閾値単位膜電位の平均 = 合計 x 1/(timeSteps x usedFrames)。
        // 旧実装の「rate = readoutSum * (1/timeSteps) をフレームごとに使い、最後に usedFrames で割る」
        // と同じ量を、掛け算 1 回で出している
        let scale = 1.0 / (Float(timeSteps) * Float(usedFrames))

        var activeOutCount = 0
        var k = 0
        while k < hSize {
            let rate = readoutTotal[k] * scale
            if rate != 0.0 {
                scratch.activeReadoutIndices[activeOutCount] = k
                scratch.activeRates[activeOutCount] = rate
                activeOutCount += 1
            }
            k += 1
        }

        // 転置レイアウト wOutT により、有効ニューロン k の重み行 (出力次元方向) が
        // 連続に並ぶ。集計は k ごとに同じ順序で加算するためスカラー版とビット一致する
        if scratch.readoutSums.count < outputDim {
            scratch.readoutSums = [Float](repeating: 0.0, count: outputDim)
        }
        let outLimit = outputDim - (outputDim % 8)
        scratch.readoutSums.withUnsafeMutableBufferPointer { sumBuf in
            let sums = sumBuf.baseAddress!
            var c = 0
            while c < outputDim {
                sums[c] = 0.0
                c += 1
            }
            wOutT.withUnsafeBufferPointer { outBuf in
                let outT = outBuf.baseAddress!
                var a = 0
                while a < activeOutCount {
                    let rowOffset = scratch.activeReadoutIndices[a] * outputDim
                    let rate = SIMD8<Float>(repeating: scratch.activeRates[a])
                    var c = 0
                    while c < outLimit {
                        let acc = SIMD8<Float>(
                            sums[c+0], sums[c+1], sums[c+2], sums[c+3],
                            sums[c+4], sums[c+5], sums[c+6], sums[c+7]
                        )
                        let w = SIMD8<Float>(
                            outT[rowOffset+c+0], outT[rowOffset+c+1],
                            outT[rowOffset+c+2], outT[rowOffset+c+3],
                            outT[rowOffset+c+4], outT[rowOffset+c+5],
                            outT[rowOffset+c+6], outT[rowOffset+c+7]
                        )
                        let sum = acc + (w * rate)
                        sums[c+0] = sum[0]
                        sums[c+1] = sum[1]
                        sums[c+2] = sum[2]
                        sums[c+3] = sum[3]
                        sums[c+4] = sum[4]
                        sums[c+5] = sum[5]
                        sums[c+6] = sum[6]
                        sums[c+7] = sum[7]
                        c += 8
                    }
                    while c < outputDim {
                        sums[c] += outT[rowOffset + c] * scratch.activeRates[a]
                        c += 1
                    }
                    a += 1
                }
            }
        }

        let biasData = bOut
        var logits = [Float](repeating: 0.0, count: outputDim)
        var c = 0
        while c < outputDim {
            logits[c] = biasData[c] + scratch.readoutSums[c]
            c += 1
        }
        return logits
    }
}
