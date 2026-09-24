import Foundation

public enum ImageNormalizerError: Error, Equatable {
    /// width か height が 0 以下
    case invalidSize(width: Int, height: Int)
    /// gray の要素数が width * height と違う
    case pixelCountMismatch(expected: Int, actual: Int)
}

/// 任意サイズのグレースケール画像を 32x32 の `CharacterImage` に揃える。
///
/// 入力画像そのものを 1 文字分のマス目 (文字枠) とみなす。切り出しはしない。
///   1. `invert` で白地黒字を墨 = 1 に反転する。
///   2. 墨 (閾値 `inkThreshold` 以上) が 1 画素も無ければ全 0 を返す。
///   3. 短辺側を中央寄せでパディングして正方形にする。
///   4. 縮小は面積平均 (box filter)、拡大は双一次補間で 32x32 にする。
///
/// 墨のマス目に対する位置と大きさがそのまま残るので、小書き仮名 (ょ/よ)、
/// 濁点と半濁点 (ビ/ピ)、英大小文字 (c/C) を区別できる。
/// マス目の外と入力画像の外はすべて紙 (0) として扱うため、パディングは
/// 中間バッファを作らず 1 回のリサンプルで済ませている。
public enum ImageNormalizer {
    /// 墨とみなす閾値
    public static let inkThreshold: Float = 0.1

    /// Float グレースケール (0 = 紙, 1 = 墨。`invert` が真なら 0 = 墨) の正規化。
    public static func normalize(
        width: Int,
        height: Int,
        gray: [Float],
        invert: Bool
    ) throws -> CharacterImage {
        if width <= 0 || height <= 0 {
            throw ImageNormalizerError.invalidSize(width: width, height: height)
        }
        let expected = width * height
        if gray.count != expected {
            throw ImageNormalizerError.pixelCountMismatch(expected: expected, actual: gray.count)
        }

        // 墨の濃さに揃える。値域外は [0, 1] に丸めてから反転する。
        var ink = [Float](repeating: 0.0, count: expected)
        var i = 0
        while i < expected {
            let v = CharacterImage.clamp01(gray[i])
            ink[i] = invert ? (1.0 - v) : v
            i += 1
        }
        return resampleToSquare(ink: ink, width: width, height: height)
    }

    /// UInt8 グレースケール (0..255) の正規化。
    public static func normalize(
        width: Int,
        height: Int,
        gray: [UInt8],
        invert: Bool
    ) throws -> CharacterImage {
        if width <= 0 || height <= 0 {
            throw ImageNormalizerError.invalidSize(width: width, height: height)
        }
        let expected = width * height
        if gray.count != expected {
            throw ImageNormalizerError.pixelCountMismatch(expected: expected, actual: gray.count)
        }
        var values = [Float](repeating: 0.0, count: expected)
        var i = 0
        while i < expected {
            values[i] = Float(gray[i]) * (1.0 / 255.0)
            i += 1
        }
        return resampleToSquare(ink: values, width: width, height: height, invert: invert)
    }

    /// 既に 32x32 のマス目になっている画像をもう一度通す。
    /// マス目基準なので切り出しは起きず、結果は入力と同じ (冪等)。
    /// 拡張の後に掛け直す用途は無い (`Augmenter` は再正規化しない)。
    public static func normalize(_ image: CharacterImage) -> CharacterImage {
        return resampleToSquare(
            ink: image.pixels,
            width: CharacterImage.side,
            height: CharacterImage.side
        )
    }

    // MARK: - 内部

    private static func resampleToSquare(
        ink rawInk: [Float],
        width: Int,
        height: Int,
        invert: Bool = false
    ) -> CharacterImage {
        var ink = rawInk
        if invert {
            var i = 0
            while i < ink.count {
                ink[i] = 1.0 - ink[i]
                i += 1
            }
        }

        // 墨が 1 画素でもあるか (無ければ全 0 を返す。クラッシュさせない)
        var hasInk = false
        var i = 0
        while i < ink.count {
            if ink[i] >= inkThreshold {
                hasInk = true
                break
            }
            i += 1
        }
        if !hasInk {
            return CharacterImage()
        }

        // 入力全体が 1 文字分のマス目。切り出さず、短辺側を中央寄せでパディングして
        // 正方形にする (入力画素の角座標系)。墨の位置と大きさがそのまま残る。
        let canvasSide = Float(max(width, height))
        let originX = (Float(width) - canvasSide) * 0.5
        let originY = (Float(height) - canvasSide) * 0.5
        let side = Float(CharacterImage.side)
        let scale = canvasSide / side

        var out = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        if scale > 1.0 {
            areaAverage(
                ink: ink, width: width, height: height,
                originX: originX, originY: originY, scale: scale,
                into: &out
            )
        } else {
            bilinearEnlarge(
                ink: ink, width: width, height: height,
                originX: originX, originY: originY, scale: scale,
                into: &out
            )
        }
        // 値域は [0, 1] に収まる (どちらも入力値の凸結合) ので init は失敗しない
        return (try? CharacterImage(pixels: out)) ?? CharacterImage()
    }

    /// 縮小: 出力 1 画素が覆う入力矩形 [x0, x1) x [y0, y1) の面積平均。
    /// 入力画像の外側は紙 (0) として面積には数えるので、余白がそのまま紙になる。
    private static func areaAverage(
        ink: [Float],
        width: Int,
        height: Int,
        originX: Float,
        originY: Float,
        scale: Float,
        into out: inout [Float]
    ) {
        let side = CharacterImage.side
        let cellArea = scale * scale
        var oy = 0
        while oy < side {
            let y0 = originY + Float(oy) * scale
            let y1 = y0 + scale
            let iy0 = max(0, Int(y0.rounded(.down)))
            let iy1 = min(height, Int(y1.rounded(.up)))
            var ox = 0
            while ox < side {
                let x0 = originX + Float(ox) * scale
                let x1 = x0 + scale
                let ix0 = max(0, Int(x0.rounded(.down)))
                let ix1 = min(width, Int(x1.rounded(.up)))
                var sum: Float = 0.0
                var sy = iy0
                while sy < iy1 {
                    let top = max(y0, Float(sy))
                    let bottom = min(y1, Float(sy + 1))
                    let wy = bottom - top
                    if wy > 0.0 {
                        let row = sy * width
                        var sx = ix0
                        while sx < ix1 {
                            let left = max(x0, Float(sx))
                            let right = min(x1, Float(sx + 1))
                            let wx = right - left
                            if wx > 0.0 {
                                sum += ink[row + sx] * wx * wy
                            }
                            sx += 1
                        }
                    }
                    sy += 1
                }
                out[oy * side + ox] = sum / cellArea
                ox += 1
            }
            oy += 1
        }
    }

    /// 拡大: 出力画素の中心を入力の画素中心座標系に写して双一次補間する。
    /// 入力画像の外側は紙 (0)。
    private static func bilinearEnlarge(
        ink: [Float],
        width: Int,
        height: Int,
        originX: Float,
        originY: Float,
        scale: Float,
        into out: inout [Float]
    ) {
        let side = CharacterImage.side
        var oy = 0
        while oy < side {
            // 角座標 -> 画素中心座標 は -0.5
            let sy = originY + (Float(oy) + 0.5) * scale - 0.5
            var ox = 0
            while ox < side {
                let sx = originX + (Float(ox) + 0.5) * scale - 0.5
                out[oy * side + ox] = sampleBilinear(
                    ink: ink, width: width, height: height, x: sx, y: sy
                )
                ox += 1
            }
            oy += 1
        }
    }

    /// 画素中心座標 (x, y) の双一次補間。範囲外は 0 (紙)。
    @inline(__always)
    static func sampleBilinear(
        ink: [Float],
        width: Int,
        height: Int,
        x: Float,
        y: Float
    ) -> Float {
        let fx = x.rounded(.down)
        let fy = y.rounded(.down)
        let tx = x - fx
        let ty = y - fy
        let x0 = Int(fx)
        let y0 = Int(fy)
        let v00 = pixelOrPaper(ink: ink, width: width, height: height, x: x0, y: y0)
        let v10 = pixelOrPaper(ink: ink, width: width, height: height, x: x0 + 1, y: y0)
        let v01 = pixelOrPaper(ink: ink, width: width, height: height, x: x0, y: y0 + 1)
        let v11 = pixelOrPaper(ink: ink, width: width, height: height, x: x0 + 1, y: y0 + 1)
        let top = v00 + (v10 - v00) * tx
        let bottom = v01 + (v11 - v01) * tx
        return top + (bottom - top) * ty
    }

    @inline(__always)
    private static func pixelOrPaper(
        ink: [Float],
        width: Int,
        height: Int,
        x: Int,
        y: Int
    ) -> Float {
        if x < 0 || y < 0 || x >= width || y >= height {
            return 0.0
        }
        return ink[y * width + x]
    }
}
