import Foundation

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
        var logits = [Float](repeating: 0.0, count: outputDim)
        var probabilities = [Float](repeating: 0.0, count: outputDim)
        var accumulated = [Float](repeating: 0.0, count: outputDim)
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
                logits: &logits,
                probabilities: &probabilities,
                scratch: scratch
            )
            if firstReadoutIndex <= t {
                var c = 0
                while c < outputDim {
                    accumulated[c] += logits[c]
                    c += 1
                }
            }
            t += 1
        }

        // 逆数を掛けず除算する。学習側 MLX の mean(axis: 1) と同じ丸めになる
        let divisor = Float(usedFrames)
        var c = 0
        while c < outputDim {
            accumulated[c] /= divisor
            c += 1
        }
        return accumulated
    }
}
