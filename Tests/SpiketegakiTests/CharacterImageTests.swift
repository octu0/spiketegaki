import XCTest
@testable import Spiketegaki

final class CharacterImageTests: XCTestCase {
    func testConstants() {
        XCTAssertEqual(CharacterImage.side, 32)
        XCTAssertEqual(CharacterImage.pixelCount, 1024)
    }

    func testEmptyInitIsAllPaper() {
        let image = CharacterImage()
        XCTAssertEqual(image.pixels.count, 1024)
        XCTAssertEqual(image.inkSum, 0.0)
    }

    func testInitRejectsWrongPixelCount() {
        for count in [0, 1, 1023, 1025, 2048] {
            XCTAssertThrowsError(try CharacterImage(pixels: [Float](repeating: 0.0, count: count))) { error in
                XCTAssertEqual(
                    error as? CharacterImageError,
                    .invalidPixelCount(expected: 1024, actual: count)
                )
            }
            XCTAssertThrowsError(try CharacterImage(uint8: [UInt8](repeating: 0, count: count)))
        }
        XCTAssertNoThrow(try CharacterImage(pixels: [Float](repeating: 0.5, count: 1024)))
    }

    func testInitClampsOutOfRangeValuesAndNaN() throws {
        var p = [Float](repeating: 0.0, count: 1024)
        p[0] = -1.5
        p[1] = 2.5
        p[2] = Float.nan
        p[3] = 0.25
        p[4] = 1.0
        let image = try CharacterImage(pixels: p)
        XCTAssertEqual(image.pixels[0], 0.0)
        XCTAssertEqual(image.pixels[1], 1.0)
        XCTAssertEqual(image.pixels[2], 0.0)
        XCTAssertEqual(image.pixels[3], 0.25)
        XCTAssertEqual(image.pixels[4], 1.0)
    }

    func testUInt8RoundTripIsExact() throws {
        var bytes = [UInt8](repeating: 0, count: 1024)
        var i = 0
        while i < 1024 {
            bytes[i] = UInt8(i % 256)
            i += 1
        }
        let image = try CharacterImage(uint8: bytes)
        XCTAssertEqual(image.asUInt8(), bytes)
        XCTAssertEqual(image.pixels[0], 0.0)
        XCTAssertEqual(image.pixels[255], 1.0, accuracy: 1e-6)
    }

    func testAsUInt8Rounding() throws {
        var p = [Float](repeating: 0.0, count: 1024)
        p[0] = 0.0
        p[1] = 1.0
        p[2] = 0.5           // 127.5 -> 128 (四捨五入)
        p[3] = 1.0 / 255.0   // -> 1
        p[4] = 0.4 / 255.0   // -> 0
        let bytes = try CharacterImage(pixels: p).asUInt8()
        XCTAssertEqual(bytes[0], 0)
        XCTAssertEqual(bytes[1], 255)
        XCTAssertEqual(bytes[2], 128)
        XCTAssertEqual(bytes[3], 1)
        XCTAssertEqual(bytes[4], 0)
    }

    func testSubscriptIsRowMajor() throws {
        var p = [Float](repeating: 0.0, count: 1024)
        p[5 * 32 + 3] = 1.0
        let image = try CharacterImage(pixels: p)
        XCTAssertEqual(image[3, 5], 1.0)
        XCTAssertEqual(image[5, 3], 0.0)
    }

    func testInkSum() throws {
        let full = try CharacterImage(pixels: [Float](repeating: 1.0, count: 1024))
        XCTAssertEqual(full.inkSum, 1024.0, accuracy: 1e-3)
        let half = try CharacterImage(pixels: [Float](repeating: 0.5, count: 1024))
        XCTAssertEqual(half.inkSum, 512.0, accuracy: 1e-3)
    }

    func testEquatable() throws {
        let a = try CharacterImage(pixels: [Float](repeating: 0.25, count: 1024))
        let b = try CharacterImage(pixels: [Float](repeating: 0.25, count: 1024))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, CharacterImage())
    }
}
