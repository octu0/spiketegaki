import XCTest
@testable import Spiketegaki

final class ScanlineEncoderTests: XCTestCase {
    func testConstants() {
        XCTAssertEqual(ScanlineEncoder.frameCount, 32)
        XCTAssertEqual(ScanlineEncoder.frameDim, 64)
        XCTAssertEqual(ScanlineEncoder.frameCount, CharacterImage.side)
        XCTAssertEqual(ScanlineEncoder.frameDim, CharacterImage.side * 2)
    }

    func testShapeIs32FramesOf64() {
        let frames = ScanlineEncoder.encode(CharacterImage())
        XCTAssertEqual(frames.count, 32)
        for frame in frames {
            XCTAssertEqual(frame.count, 64)
        }
    }

    /// 1 画素だけ墨にしたとき、行のフレームと列のフレームの正しい位置にだけ現れる。
    func testSinglePixelAppearsInItsRowFrameAndColumnFrame() throws {
        let px = 3
        let py = 5
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        p[py * CharacterImage.side + px] = 1.0
        let frames = ScanlineEncoder.encode(try CharacterImage(pixels: p))

        // フレーム 5 (= 行 5) の前半 index 3
        XCTAssertEqual(frames[py][px], 1.0)
        // フレーム 3 (= 列 3) の後半 index 32 + 5
        XCTAssertEqual(frames[px][32 + py], 1.0)

        // それ以外はすべて 0
        var t = 0
        while t < 32 {
            var i = 0
            while i < 64 {
                let isRowHit = (t == py && i == px)
                let isColumnHit = (t == px && i == 32 + py)
                if !isRowHit && !isColumnHit {
                    XCTAssertEqual(frames[t][i], 0.0, "frames[\(t)][\(i)] が 0 でない")
                }
                i += 1
            }
            t += 1
        }
    }

    /// 全画素が異なる値の画像で、フレーム t の前半 = 行 t、後半 = 列 t を全要素確認する。
    func testFrameFrontHalfIsRowAndBackHalfIsColumn() throws {
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var i = 0
        while i < CharacterImage.pixelCount {
            p[i] = Float(i) / Float(CharacterImage.pixelCount - 1)
            i += 1
        }
        let image = try CharacterImage(pixels: p)
        let frames = ScanlineEncoder.encode(image)

        var t = 0
        while t < 32 {
            var k = 0
            while k < 32 {
                XCTAssertEqual(frames[t][k], image[k, t], "フレーム \(t) の前半 \(k) が行 \(t) と違う")
                XCTAssertEqual(frames[t][32 + k], image[t, k], "フレーム \(t) の後半 \(k) が列 \(t) と違う")
                k += 1
            }
            t += 1
        }
    }

    /// 横縞 (行 y が値 y/31) の画像では、前半は定数行、後半は 0..1 のランプになる。
    func testHorizontalStripesGiveConstantRowAndRampColumn() throws {
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var y = 0
        while y < 32 {
            let v = Float(y) / 31.0
            var x = 0
            while x < 32 {
                p[y * 32 + x] = v
                x += 1
            }
            y += 1
        }
        let frames = ScanlineEncoder.encode(try CharacterImage(pixels: p))
        var t = 0
        while t < 32 {
            var k = 0
            while k < 32 {
                XCTAssertEqual(frames[t][k], Float(t) / 31.0, accuracy: 1e-6)
                XCTAssertEqual(frames[t][32 + k], Float(k) / 31.0, accuracy: 1e-6)
                k += 1
            }
            t += 1
        }
    }

    func testEncodeFlatMatchesEncode() throws {
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var i = 0
        while i < CharacterImage.pixelCount {
            p[i] = Float((i * 37) % 251) / 250.0
            i += 1
        }
        let image = try CharacterImage(pixels: p)
        let frames = ScanlineEncoder.encode(image)
        let flat = ScanlineEncoder.encodeFlat(image)
        XCTAssertEqual(flat.count, 32 * 64)
        var t = 0
        while t < 32 {
            var k = 0
            while k < 64 {
                XCTAssertEqual(flat[t * 64 + k], frames[t][k])
                k += 1
            }
            t += 1
        }
    }

    /// 対角線の画像では、フレーム t の前半 t 番目と後半 32+t 番目がどちらも墨になる。
    func testDiagonalImage() throws {
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var d = 0
        while d < 32 {
            p[d * 32 + d] = 1.0
            d += 1
        }
        let frames = ScanlineEncoder.encode(try CharacterImage(pixels: p))
        var t = 0
        while t < 32 {
            XCTAssertEqual(frames[t][t], 1.0)
            XCTAssertEqual(frames[t][32 + t], 1.0)
            var sum: Float = 0.0
            for v in frames[t] {
                sum += v
            }
            XCTAssertEqual(sum, 2.0, accuracy: 1e-6, "フレーム \(t) に余分な墨がある")
            t += 1
        }
    }
}
