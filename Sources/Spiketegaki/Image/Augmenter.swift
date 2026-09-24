import Foundation

/// 学習データの拡張。乱数はシード固定の xorshift64* で、
/// 同じ seed なら必ず同じ系列・同じ出力になる (`SystemRandomNumberGenerator` は使わない)。
///
/// `augment(_:)` の順序:
///   幾何変形 (せん断・回転・平行移動・拡縮、いずれもマス目中心基準) → 膨張
///   → 弾性変形 → 値域を [0, 1] にクランプ (マス目外へ出た墨は捨てる)
///   → 最後にノイズ (ガウス・ごま塩)。
///
/// マス目基準なので外接矩形の再正規化は行わない。再正規化すると墨の絶対的な
/// 位置と大きさが失われ、小書き仮名や濁点の区別が消えてしまう。
///
/// 線を太らせる変形だけを持ち、細らせる変形は持たない。線の細さのばらつきは
/// フォントのウェイト違い (Light / Thin など) で賄う。
public final class Augmenter: @unchecked Sendable {
    /// 拡張パラメータ。
    public struct Parameters: Sendable, Equatable {
        /// せん断 (斜体の代用): 水平方向 -0.3〜0.3
        public var shearRange: ClosedRange<Float>
        /// 回転: -10°〜10°
        public var rotationDegreesRange: ClosedRange<Float>
        /// 平行移動: ±2px
        public var translationRange: ClosedRange<Float>
        /// 拡縮: 0.85〜1.1
        public var scaleRange: ClosedRange<Float>
        /// 太さ: この確率で膨張する (残りは変化なし)
        public var thicknessProbability: Float
        /// 弾性変形の振幅 (px)
        public var elasticAmplitude: Float
        /// 弾性変形の変位場をぼかすガウスの σ
        public var elasticSigma: Float
        /// ガウスノイズの σ
        public var gaussianNoiseSigma: Float
        /// ごま塩ノイズの発生確率
        public var saltPepperProbability: Float

        public init(
            shearRange: ClosedRange<Float> = -0.3 ... 0.3,
            rotationDegreesRange: ClosedRange<Float> = -10.0 ... 10.0,
            translationRange: ClosedRange<Float> = -2.0 ... 2.0,
            scaleRange: ClosedRange<Float> = 0.85 ... 1.1,
            thicknessProbability: Float = 1.0 / 3.0,
            elasticAmplitude: Float = 1.5,
            elasticSigma: Float = 4.0,
            gaussianNoiseSigma: Float = 0.05,
            saltPepperProbability: Float = 0.01
        ) {
            self.shearRange = shearRange
            self.rotationDegreesRange = rotationDegreesRange
            self.translationRange = translationRange
            self.scaleRange = scaleRange
            self.thicknessProbability = thicknessProbability
            self.elasticAmplitude = elasticAmplitude
            self.elasticSigma = elasticSigma
            self.gaussianNoiseSigma = gaussianNoiseSigma
            self.saltPepperProbability = saltPepperProbability
        }
    }

    public let parameters: Parameters
    private var rngState: UInt64

    /// seed 0 は xorshift が停止するため定数に置き換える。
    public init(seed: UInt64, parameters: Parameters = Parameters()) {
        self.parameters = parameters
        self.rngState = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    /// 乱数系列を初期状態に戻す。
    public func reseed(_ seed: UInt64) {
        rngState = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    // MARK: - 拡張全体

    /// 型の doc コメントに書いた順序で 1 回分の拡張を行う。
    public func augment(_ image: CharacterImage) -> CharacterImage {
        let shearAmount = nextUniform(in: parameters.shearRange)
        let degrees = nextUniform(in: parameters.rotationDegreesRange)
        let scaleFactor = nextUniform(in: parameters.scaleRange)
        let dx = nextUniform(in: parameters.translationRange)
        let dy = nextUniform(in: parameters.translationRange)

        var out = affine(
            image,
            shear: shearAmount,
            rotationDegrees: degrees,
            scale: scaleFactor,
            dx: dx,
            dy: dy
        )

        // 太さ: 膨張 / 変化なし
        let thickness = nextFloat01()
        if thickness < parameters.thicknessProbability {
            out = dilate(out)
        }

        out = elasticDeform(
            out,
            amplitude: parameters.elasticAmplitude,
            sigma: parameters.elasticSigma
        )

        out = clampToCell(out)

        out = gaussianNoise(out, sigma: parameters.gaussianNoiseSigma)
        out = saltPepper(out, probability: parameters.saltPepperProbability)
        return out
    }

    /// 値域を [0, 1] に収める。マス目の外へ出た墨は既に捨てられている
    /// (アフィン変形も弾性変形も範囲外を紙 0 として読むため)。
    public func clampToCell(_ image: CharacterImage) -> CharacterImage {
        return (try? CharacterImage(pixels: image.pixels)) ?? CharacterImage()
    }

    // MARK: - 個別のアフィン変形 (逆写像 + 双一次補間)

    /// 水平せん断。`amount` は 1px 下がるごとに右へずれる量。
    public func shear(_ image: CharacterImage, amount: Float) -> CharacterImage {
        return affine(image, shear: amount, rotationDegrees: 0.0, scale: 1.0, dx: 0.0, dy: 0.0)
    }

    /// 画像中心まわりの回転 (度)。
    public func rotate(_ image: CharacterImage, degrees: Float) -> CharacterImage {
        return affine(image, shear: 0.0, rotationDegrees: degrees, scale: 1.0, dx: 0.0, dy: 0.0)
    }

    /// 平行移動 (px)。
    public func translate(_ image: CharacterImage, dx: Float, dy: Float) -> CharacterImage {
        return affine(image, shear: 0.0, rotationDegrees: 0.0, scale: 1.0, dx: dx, dy: dy)
    }

    /// 画像中心まわりの拡縮。
    public func scale(_ image: CharacterImage, factor: Float) -> CharacterImage {
        return affine(image, shear: 0.0, rotationDegrees: 0.0, scale: factor, dx: 0.0, dy: 0.0)
    }

    /// せん断 → 回転 → 拡縮 → 平行移動 を 1 枚の行列にまとめて掛ける。
    /// 再サンプルが 1 回で済むので、個別に 4 回掛けるよりぼけない。
    /// 変形は逆写像 (出力画素 → 入力座標) + 双一次補間。範囲外は紙 (0)。
    public func affine(
        _ image: CharacterImage,
        shear: Float,
        rotationDegrees: Float,
        scale: Float,
        dx: Float,
        dy: Float
    ) -> CharacterImage {
        let side = CharacterImage.side
        // マス目の中心。角座標では (16, 16)、画素中心座標ではその 0.5 手前の 15.5。
        // 外接矩形ではなくマス目を基準に回す。
        let center = Float(side) * 0.5 - 0.5
        let theta = rotationDegrees * Float.pi / 180.0
        let cosT = cos(theta)
        let sinT = sin(theta)

        // M = scale * Rot(theta) * Shear(shear)
        let a = scale * cosT
        let b = scale * (cosT * shear - sinT)
        let c = scale * sinT
        let d = scale * (sinT * shear + cosT)
        // det(M) = scale^2 (せん断と回転は面積を変えない)
        let det = a * d - b * c
        if det == 0.0 {
            return CharacterImage()
        }
        let invDet = 1.0 / det
        let i00 = d * invDet
        let i01 = -b * invDet
        let i10 = -c * invDet
        let i11 = a * invDet

        var out = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var y = 0
        while y < side {
            let v = Float(y) - center - dy
            var x = 0
            while x < side {
                let u = Float(x) - center - dx
                let sx = i00 * u + i01 * v + center
                let sy = i10 * u + i11 * v + center
                out[y * side + x] = ImageNormalizer.sampleBilinear(
                    ink: image.pixels, width: side, height: side, x: sx, y: sy
                )
                x += 1
            }
            y += 1
        }
        return (try? CharacterImage(pixels: out)) ?? CharacterImage()
    }

    // MARK: - 太さ (3x3 最大値フィルタ = 1px の膨張)

    /// 1px 膨張 (3x3 最大値)。画像外は紙 (0) なので墨は減らない。
    public func dilate(_ image: CharacterImage) -> CharacterImage {
        let side = CharacterImage.side
        var out = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var y = 0
        while y < side {
            var x = 0
            while x < side {
                var best: Float = 0.0
                var ky = -1
                while ky <= 1 {
                    let ny = y + ky
                    var kx = -1
                    while kx <= 1 {
                        let nx = x + kx
                        var v: Float = 0.0
                        if nx >= 0 && ny >= 0 && nx < side && ny < side {
                            v = image.pixels[ny * side + nx]
                        }
                        if v > best { best = v }
                        kx += 1
                    }
                    ky += 1
                }
                out[y * side + x] = best
                x += 1
            }
            y += 1
        }
        return (try? CharacterImage(pixels: out)) ?? CharacterImage()
    }

    // MARK: - 弾性変形

    /// 一様乱数の変位場を σ のガウスでぼかし、最大変位が `amplitude` px になるよう正規化してから
    /// 逆写像 + 双一次補間で歪ませる。ぼかし後の振幅は σ に強く依存するので、
    /// 設計書の「振幅 1.5px」を最大変位として解釈し、正規化で固定している。
    public func elasticDeform(
        _ image: CharacterImage,
        amplitude: Float,
        sigma: Float
    ) -> CharacterImage {
        let side = CharacterImage.side
        let n = CharacterImage.pixelCount
        var fieldX = [Float](repeating: 0.0, count: n)
        var fieldY = [Float](repeating: 0.0, count: n)
        var i = 0
        while i < n {
            fieldX[i] = nextFloat01() * 2.0 - 1.0
            fieldY[i] = nextFloat01() * 2.0 - 1.0
            i += 1
        }
        gaussianBlur(&fieldX, side: side, sigma: sigma)
        gaussianBlur(&fieldY, side: side, sigma: sigma)

        // 最大変位を amplitude に合わせる
        var peak: Float = 0.0
        i = 0
        while i < n {
            let ax = abs(fieldX[i])
            let ay = abs(fieldY[i])
            if ax > peak { peak = ax }
            if ay > peak { peak = ay }
            i += 1
        }
        if peak <= 0.0 {
            return image
        }
        let gain = amplitude / peak

        var out = [Float](repeating: 0.0, count: n)
        var y = 0
        while y < side {
            var x = 0
            while x < side {
                let idx = y * side + x
                let sx = Float(x) + fieldX[idx] * gain
                let sy = Float(y) + fieldY[idx] * gain
                out[idx] = ImageNormalizer.sampleBilinear(
                    ink: image.pixels, width: side, height: side, x: sx, y: sy
                )
                x += 1
            }
            y += 1
        }
        return (try? CharacterImage(pixels: out)) ?? CharacterImage()
    }

    /// 分離可能なガウス畳み込み。端は複製 (clamp) で延長する。
    private func gaussianBlur(_ field: inout [Float], side: Int, sigma: Float) {
        if sigma <= 0.0 {
            return
        }
        let radius = max(1, Int((sigma * 3.0).rounded(.up)))
        var kernel = [Float](repeating: 0.0, count: 2 * radius + 1)
        let denom = 2.0 * sigma * sigma
        var sum: Float = 0.0
        var k = -radius
        while k <= radius {
            let w = exp(-Float(k * k) / denom)
            kernel[k + radius] = w
            sum += w
            k += 1
        }
        var ki = 0
        while ki < kernel.count {
            kernel[ki] /= sum
            ki += 1
        }

        var tmp = [Float](repeating: 0.0, count: field.count)
        // 横方向
        var y = 0
        while y < side {
            let row = y * side
            var x = 0
            while x < side {
                var acc: Float = 0.0
                var t = -radius
                while t <= radius {
                    var sx = x + t
                    if sx < 0 { sx = 0 }
                    if sx >= side { sx = side - 1 }
                    acc += field[row + sx] * kernel[t + radius]
                    t += 1
                }
                tmp[row + x] = acc
                x += 1
            }
            y += 1
        }
        // 縦方向
        y = 0
        while y < side {
            var x = 0
            while x < side {
                var acc: Float = 0.0
                var t = -radius
                while t <= radius {
                    var sy = y + t
                    if sy < 0 { sy = 0 }
                    if sy >= side { sy = side - 1 }
                    acc += tmp[sy * side + x] * kernel[t + radius]
                    t += 1
                }
                field[y * side + x] = acc
                x += 1
            }
            y += 1
        }
    }

    // MARK: - ノイズ

    /// 平均 0・標準偏差 sigma のガウスノイズを加える (値域は [0, 1] に丸められる)。
    public func gaussianNoise(_ image: CharacterImage, sigma: Float) -> CharacterImage {
        if sigma <= 0.0 {
            return image
        }
        let n = CharacterImage.pixelCount
        var out = [Float](repeating: 0.0, count: n)
        var i = 0
        while i < n {
            out[i] = image.pixels[i] + nextGaussian() * sigma
            i += 1
        }
        return (try? CharacterImage(pixels: out)) ?? CharacterImage()
    }

    /// 確率 `probability` で画素を塩 (1.0) か胡椒 (0.0) に置き換える。塩と胡椒は等確率。
    public func saltPepper(_ image: CharacterImage, probability: Float) -> CharacterImage {
        if probability <= 0.0 {
            return image
        }
        let n = CharacterImage.pixelCount
        var out = image.pixels
        var i = 0
        while i < n {
            if nextFloat01() < probability {
                out[i] = nextFloat01() < 0.5 ? 1.0 : 0.0
            }
            i += 1
        }
        return (try? CharacterImage(pixels: out)) ?? CharacterImage()
    }

    // MARK: - 乱数 (xorshift64*)

    @inline(__always)
    public func nextUInt64() -> UInt64 {
        var x = rngState
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        rngState = x
        return x &* 2685821657736338717
    }

    /// [0, 1) の一様乱数。上位 24bit から作るので Float で厳密に表せる。
    @inline(__always)
    public func nextFloat01() -> Float {
        return Float(nextUInt64() >> 40) * (1.0 / 16777216.0)
    }

    /// 閉区間の一様乱数。
    @inline(__always)
    public func nextUniform(in range: ClosedRange<Float>) -> Float {
        return range.lowerBound + (range.upperBound - range.lowerBound) * nextFloat01()
    }

    /// 平均 0・標準偏差 1 の正規乱数 (Box-Muller)。1 回につき一様乱数を 2 個消費する。
    @inline(__always)
    public func nextGaussian() -> Float {
        var u1 = nextFloat01()
        if u1 <= 0.0 {
            u1 = 1.0 / 16777216.0
        }
        let u2 = nextFloat01()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * Float.pi * u2)
    }
}
