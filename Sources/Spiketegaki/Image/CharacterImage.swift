public enum CharacterImageError: Error, Equatable {
    /// 画素数が `CharacterImage.pixelCount` (1024) と違う
    case invalidPixelCount(expected: Int, actual: Int)
}

/// 32x32 のグレースケール文字画像。
///
/// row-major で `pixels[y * side + x]`、値域 [0, 1]、0 = 紙 (背景)、1 = 墨。
/// 値域は型の不変条件として保証する。範囲外の値と NaN は初期化時に [0, 1] へ丸める
/// (拡張のノイズ付加などで [0, 1] を外れた値がそのまま符号化へ流れるのを防ぐため)。
public struct CharacterImage: Sendable, Equatable {
    /// 一辺の画素数
    public static let side = 32
    /// 総画素数 (32 x 32)
    public static let pixelCount = side * side

    public let pixels: [Float]

    /// 全画素が紙 (0) の画像
    public init() {
        self.pixels = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
    }

    /// 要素数が 1024 でなければ `invalidPixelCount` を投げる。
    public init(pixels: [Float]) throws {
        if pixels.count != CharacterImage.pixelCount {
            throw CharacterImageError.invalidPixelCount(
                expected: CharacterImage.pixelCount,
                actual: pixels.count
            )
        }
        var clamped = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var i = 0
        while i < CharacterImage.pixelCount {
            clamped[i] = CharacterImage.clamp01(pixels[i])
            i += 1
        }
        self.pixels = clamped
    }

    /// 0..255 の濃さから [0, 1] へ。要素数が 1024 でなければ投げる。
    public init(uint8: [UInt8]) throws {
        if uint8.count != CharacterImage.pixelCount {
            throw CharacterImageError.invalidPixelCount(
                expected: CharacterImage.pixelCount,
                actual: uint8.count
            )
        }
        var values = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var i = 0
        while i < CharacterImage.pixelCount {
            values[i] = Float(uint8[i]) * (1.0 / 255.0)
            i += 1
        }
        self.pixels = values
    }

    /// [0, 1] を 0..255 へ。四捨五入なので `init(uint8:)` との往復は完全に一致する。
    public func asUInt8() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: CharacterImage.pixelCount)
        var i = 0
        while i < CharacterImage.pixelCount {
            let scaled = (pixels[i] * 255.0).rounded()
            if scaled <= 0.0 {
                out[i] = 0
            } else if scaled >= 255.0 {
                out[i] = 255
            } else {
                out[i] = UInt8(scaled)
            }
            i += 1
        }
        return out
    }

    /// `pixels[y * 32 + x]`
    @inline(__always)
    public subscript(x: Int, y: Int) -> Float {
        return pixels[y * CharacterImage.side + x]
    }

    /// 墨の総量 (画素値の総和)。膨張や拡張の検証で使う。
    public var inkSum: Float {
        var sum: Float = 0.0
        var i = 0
        while i < CharacterImage.pixelCount {
            sum += pixels[i]
            i += 1
        }
        return sum
    }

    /// NaN は 0 に落とす。`v < 0` も `0 < v` も偽になるため最後の分岐で 0 が返る。
    @inline(__always)
    static func clamp01(_ v: Float) -> Float {
        if v > 1.0 {
            return 1.0
        }
        if v > 0.0 {
            return v
        }
        return 0.0
    }
}
