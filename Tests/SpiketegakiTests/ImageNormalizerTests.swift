import XCTest
@testable import Spiketegaki

/// マス目 (文字枠) 基準の正規化の検証。
/// 入力画像そのものを 1 文字分のマス目とみなし、切り出さずに短辺を中央寄せで
/// パディングして 32x32 にする。墨の位置と大きさ (マス目に対する相対値) が残ること。
final class ImageNormalizerTests: XCTestCase {
    /// width x height の白紙に、左上 (x, y) から w x h の墨の矩形を描く。
    private func rectImage(
        width: Int, height: Int, x: Int, y: Int, w: Int, h: Int
    ) -> [Float] {
        var g = [Float](repeating: 0.0, count: width * height)
        var j = y
        while j < y + h {
            var i = x
            while i < x + w {
                g[j * width + i] = 1.0
                i += 1
            }
            j += 1
        }
        return g
    }

    /// 閾値 0.1 以上の外接矩形
    private func inkBox(_ image: CharacterImage) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        let side = CharacterImage.side
        var minX = side, minY = side, maxX = -1, maxY = -1
        var y = 0
        while y < side {
            var x = 0
            while x < side {
                if image[x, y] >= ImageNormalizer.inkThreshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                x += 1
            }
            y += 1
        }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }

    // MARK: - 位置と大きさが保たれる

    /// 64x64 のマス目の左上 16x16 の四角は、32x32 の左上 8x8 にそのまま来る。
    /// 縮小率がちょうど 2 なので面積平均の結果は厳密に 1.0 / 0.0 になる。
    func testTopLeftSquareStaysTopLeft() throws {
        let gray = rectImage(width: 64, height: 64, x: 0, y: 0, w: 16, h: 16)
        let image = try ImageNormalizer.normalize(width: 64, height: 64, gray: gray, invert: false)

        XCTAssertEqual(image.pixels.count, 1024)
        var y = 0
        while y < 32 {
            var x = 0
            while x < 32 {
                let expected: Float = (x < 8 && y < 8) ? 1.0 : 0.0
                XCTAssertEqual(image[x, y], expected, accuracy: 1e-6, "(\(x), \(y)) が違う")
                x += 1
            }
            y += 1
        }
        let box = try XCTUnwrap(inkBox(image))
        XCTAssertEqual(box.minX, 0)
        XCTAssertEqual(box.minY, 0)
        XCTAssertEqual(box.maxX, 7)
        XCTAssertEqual(box.maxY, 7)
    }

    /// 右下に置いた四角は右下のまま (旧方式なら中央に寄ってしまう)
    func testBottomRightSquareStaysBottomRight() throws {
        let gray = rectImage(width: 64, height: 64, x: 48, y: 48, w: 16, h: 16)
        let image = try ImageNormalizer.normalize(width: 64, height: 64, gray: gray, invert: false)
        let box = try XCTUnwrap(inkBox(image))
        XCTAssertEqual(box.minX, 24)
        XCTAssertEqual(box.minY, 24)
        XCTAssertEqual(box.maxX, 31)
        XCTAssertEqual(box.maxY, 31)
    }

    /// マス目に対する墨の大きさが保たれる = 小さい字と大きい字が別物になる。
    /// これがマス目基準にした理由そのもの (ょ/よ、ビ/ピ、c/C の区別)。
    func testSmallAndLargeGlyphsStayDifferent() throws {
        // 同じマス目の中央に、辺が 2 倍違う四角を置く
        let small = rectImage(width: 64, height: 64, x: 24, y: 24, w: 16, h: 16)
        let large = rectImage(width: 64, height: 64, x: 16, y: 16, w: 32, h: 32)

        let smallImage = try ImageNormalizer.normalize(width: 64, height: 64, gray: small, invert: false)
        let largeImage = try ImageNormalizer.normalize(width: 64, height: 64, gray: large, invert: false)
        // 墨の量は面積比 (4 倍) がそのまま残る
        XCTAssertEqual(smallImage.inkSum, 64.0, accuracy: 0.5)
        XCTAssertEqual(largeImage.inkSum, 256.0, accuracy: 0.5)
        XCTAssertNotEqual(smallImage.pixels, largeImage.pixels)

        // 外接矩形の広がりも 2 倍違う (どちらも枠いっぱいにはならない)
        let smallBox = try XCTUnwrap(inkBox(smallImage))
        let largeBox = try XCTUnwrap(inkBox(largeImage))
        XCTAssertEqual(smallBox.maxX - smallBox.minX + 1, 8)
        XCTAssertEqual(largeBox.maxX - largeBox.minX + 1, 16)
        XCTAssertGreaterThan(smallBox.minX, 0, "小さい字が枠いっぱいに広がっている")
        XCTAssertGreaterThan(largeBox.minX, 0, "大きい字が枠いっぱいに広がっている")
    }

    // MARK: - 非正方形は中央寄せパディング

    func testNonSquareIsCenterPadded() throws {
        // 100x40 のマス目。長辺 100 に合わせ、上下に (100-40)/2 = 30 ずつ紙を足す
        let gray = rectImage(width: 100, height: 40, x: 40, y: 10, w: 20, h: 20)
        let image = try ImageNormalizer.normalize(width: 100, height: 40, gray: gray, invert: false)

        XCTAssertEqual(image.pixels.count, 1024)
        let box = try XCTUnwrap(inkBox(image))
        // 縮小率 100/32 = 3.125。入力 x 40..60 -> 出力 12.8..19.2、y 10..30 -> (10+30)/3.125..(30+30)/3.125
        XCTAssertEqual(box.minX, 12)
        XCTAssertEqual(box.maxX, 19)
        XCTAssertEqual(box.minY, 12)
        XCTAssertEqual(box.maxY, 19)
        // 上下が均等 (中央寄せ) で、左右も均等
        XCTAssertEqual(box.minY, 31 - box.maxY)
        XCTAssertEqual(box.minX, 31 - box.maxX)

        // パディングした帯は紙のまま。入力の上端 y=0 は出力 30/3.125 = 9.6 に来るので 0..8 は完全に紙
        var x = 0
        while x < 32 {
            XCTAssertEqual(image[x, 0], 0.0, accuracy: 1e-6)
            XCTAssertEqual(image[x, 31], 0.0, accuracy: 1e-6)
            x += 1
        }
    }

    /// 縦長でも同じ (短辺が横になる)
    func testTallNonSquareIsCenterPadded() throws {
        let gray = rectImage(width: 40, height: 100, x: 10, y: 40, w: 20, h: 20)
        let image = try ImageNormalizer.normalize(width: 40, height: 100, gray: gray, invert: false)
        let box = try XCTUnwrap(inkBox(image))
        XCTAssertEqual(box.minX, 12)
        XCTAssertEqual(box.maxX, 19)
        XCTAssertEqual(box.minY, 12)
        XCTAssertEqual(box.maxY, 19)
    }

    // MARK: - 境界条件

    func testAllPaperReturnsAllZero() throws {
        let gray = [Float](repeating: 0.0, count: 50 * 30)
        let image = try ImageNormalizer.normalize(width: 50, height: 30, gray: gray, invert: false)
        XCTAssertEqual(image.pixels.count, 1024)
        XCTAssertEqual(image.inkSum, 0.0)
    }

    func testBelowThresholdInkIsTreatedAsPaper() throws {
        let gray = [Float](repeating: 0.09, count: 20 * 20)
        let image = try ImageNormalizer.normalize(width: 20, height: 20, gray: gray, invert: false)
        XCTAssertEqual(image.inkSum, 0.0)
    }

    /// 1 画素の墨は、マス目の中のその位置に残る (中央に寄せない)
    func testSinglePixelKeepsItsPosition() throws {
        var gray = [Float](repeating: 0.0, count: 40 * 40)
        gray[8 * 40 + 32] = 1.0          // 右上寄り
        let image = try ImageNormalizer.normalize(width: 40, height: 40, gray: gray, invert: false)

        XCTAssertEqual(image.pixels.count, 1024)
        for v in image.pixels {
            XCTAssertGreaterThanOrEqual(v, 0.0)
            XCTAssertLessThanOrEqual(v, 1.0)
        }
        var maxIndex = 0
        var maxValue: Float = -1.0
        for (i, v) in image.pixels.enumerated() where v > maxValue {
            maxValue = v
            maxIndex = i
        }
        let mx = maxIndex % 32
        let my = maxIndex / 32
        // 縮小率 40/32 = 1.25。入力 (32, 8) -> 出力 (25.6, 6.4) 付近
        XCTAssertTrue((25 ... 26).contains(mx), "x が \(mx) で右上に残っていない")
        XCTAssertTrue((6 ... 7).contains(my), "y が \(my) で右上に残っていない")
        // 縮小率 1.25 なので 1 入力画素は最大でも 1/1.25^2 = 0.64。
        // (32, 8) は出力画素の境界をまたぐので x に 0.5 / y に 0.75 だけ配分され
        // 0.5 * 0.75 / 1.5625 = 0.24 が最大になる
        XCTAssertEqual(maxValue, 0.24, accuracy: 0.02)
        // 中央は紙のまま (旧方式ならここに来てしまう)
        XCTAssertEqual(image[16, 16], 0.0, accuracy: 1e-6)
    }

    func testOnePixelImage() throws {
        let image = try ImageNormalizer.normalize(width: 1, height: 1, gray: [1.0], invert: false)
        XCTAssertEqual(image.pixels.count, 1024)
        // 1x1 のマス目を 32 倍に拡大する。拡大は双一次補間で、マス目の外側は紙 (0)。
        // 画素が 1 つしか無いので内側というものが無く、中央でも 1.0 にわずかに届かない
        // (実測 0.969)。縁に向かってさらに落ちる。全面が 1.0 にはならない。
        XCTAssertEqual(image[16, 16], 0.97, accuracy: 0.05)
        XCTAssertGreaterThan(image.inkSum, 400.0)
        XCTAssertLessThan(image.inkSum, 1024.0)
        for v in image.pixels {
            XCTAssertGreaterThanOrEqual(v, 0.0)
            XCTAssertLessThanOrEqual(v, 1.0)
        }
    }

    /// 拡大経路 (入力の一辺が 32 未満) では、マス目の外側を紙として補間するため
    /// 最外周がわずかに暗くなる。em 18px の描画がこの経路を通るので、
    /// 意図した挙動であることをテストで固定しておく (学習と推論で同じ処理なので偏りは生じない)。
    func testEnlargingPathDimsTheOutermostRing() throws {
        // 18x18 のマス目を全面墨にする (em 18px 相当)
        let gray = [Float](repeating: 1.0, count: 18 * 18)
        let image = try ImageNormalizer.normalize(width: 18, height: 18, gray: gray, invert: false)
        // 内側は 1.0
        XCTAssertEqual(image[16, 16], 1.0, accuracy: 1e-6)
        XCTAssertEqual(image[4, 4], 1.0, accuracy: 1e-6)
        // 最外周は 1.0 より小さいが、墨として十分残る
        XCTAssertLessThan(image[0, 0], 1.0)
        XCTAssertGreaterThan(image[0, 0], 0.5)
        // 1 画素分だけの現象で、2 画素目からは 1.0
        XCTAssertEqual(image[1, 1], 1.0, accuracy: 1e-6)
    }

    func testOnePixelPaperImage() throws {
        let image = try ImageNormalizer.normalize(width: 1, height: 1, gray: [0.0], invert: false)
        XCTAssertEqual(image.inkSum, 0.0)
    }

    // MARK: - invert と UInt8

    func testInvertAndUInt8Overload() throws {
        var bytes = [UInt8](repeating: 255, count: 64 * 64)   // 白地
        var j = 0
        while j < 16 {
            var i = 0
            while i < 16 {
                bytes[j * 64 + i] = 0                          // 左上に黒
                i += 1
            }
            j += 1
        }
        let image = try ImageNormalizer.normalize(width: 64, height: 64, gray: bytes, invert: true)
        XCTAssertEqual(image[0, 0], 1.0, accuracy: 1e-6)
        XCTAssertEqual(image[7, 7], 1.0, accuracy: 1e-6)
        XCTAssertEqual(image[8, 8], 0.0, accuracy: 1e-6)

        let floats = bytes.map { Float($0) / 255.0 }
        let viaFloat = try ImageNormalizer.normalize(width: 64, height: 64, gray: floats, invert: true)
        var i = 0
        while i < CharacterImage.pixelCount {
            XCTAssertEqual(image.pixels[i], viaFloat.pixels[i], accuracy: 1e-6)
            i += 1
        }
    }

    // MARK: - エラー

    func testPixelCountMismatchThrows() {
        XCTAssertThrowsError(
            try ImageNormalizer.normalize(width: 10, height: 10, gray: [Float](repeating: 0.0, count: 99), invert: false)
        ) { error in
            XCTAssertEqual(
                error as? ImageNormalizerError,
                .pixelCountMismatch(expected: 100, actual: 99)
            )
        }
    }

    func testNonPositiveSizeThrows() {
        XCTAssertThrowsError(
            try ImageNormalizer.normalize(width: 0, height: 10, gray: [Float](), invert: false)
        ) { error in
            XCTAssertEqual(error as? ImageNormalizerError, .invalidSize(width: 0, height: 10))
        }
        XCTAssertThrowsError(
            try ImageNormalizer.normalize(width: 10, height: -1, gray: [Float](), invert: false)
        ) { error in
            XCTAssertEqual(error as? ImageNormalizerError, .invalidSize(width: 10, height: -1))
        }
        XCTAssertThrowsError(
            try ImageNormalizer.normalize(width: 4, height: 4, gray: [UInt8](repeating: 0, count: 3), invert: false)
        )
    }
}
