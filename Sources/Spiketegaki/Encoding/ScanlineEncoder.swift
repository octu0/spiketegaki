import Foundation

/// 32x32 画像を 32 フレーム x 64 次元の時系列にする。
///
/// フレーム t = 行 t の 32 画素 ++ 列 t の 32 画素。
/// 行と列を同時に流すことで、再帰層が上下方向と左右方向の両方の文脈を持つ。
public enum ScanlineEncoder {
    /// フレーム数 (= 画像の一辺)
    public static let frameCount = 32
    /// フレーム次元 (行 32 + 列 32)
    public static let frameDim = 64

    /// 32 個の 64 次元フレーム。
    public static func encode(_ image: CharacterImage) -> [[Float]] {
        let side = CharacterImage.side
        var frames = [[Float]]()
        frames.reserveCapacity(frameCount)
        var t = 0
        while t < frameCount {
            var frame = [Float](repeating: 0.0, count: frameDim)
            let row = t * side
            var i = 0
            while i < side {
                frame[i] = image.pixels[row + i]          // 行 t
                frame[side + i] = image.pixels[i * side + t]  // 列 t
                i += 1
            }
            frames.append(frame)
            t += 1
        }
        return frames
    }

    /// フレームを連結した 32 * 64 = 2048 要素の平坦配列。MLX へ渡すときに使う。
    public static func encodeFlat(_ image: CharacterImage) -> [Float] {
        let side = CharacterImage.side
        var out = [Float](repeating: 0.0, count: frameCount * frameDim)
        var t = 0
        while t < frameCount {
            let base = t * frameDim
            let row = t * side
            var i = 0
            while i < side {
                out[base + i] = image.pixels[row + i]
                out[base + side + i] = image.pixels[i * side + t]
                i += 1
            }
            t += 1
        }
        return out
    }
}
