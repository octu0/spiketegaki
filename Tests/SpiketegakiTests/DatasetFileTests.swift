import XCTest
@testable import Spiketegaki

final class DatasetFileTests: XCTestCase {
    /// 中間生成物は .tmp/ 配下に置く。
    private var workDirectory: URL!

    override func setUpWithError() throws {
        let here = URL(fileURLWithPath: #filePath)
        let root = here
            .deletingLastPathComponent()   // Tests/SpiketegakiTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // パッケージルート
        workDirectory = root
            .appendingPathComponent(".tmp/tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = workDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func url(_ name: String) -> URL {
        return workDirectory.appendingPathComponent(name)
    }

    /// 決まった模様の画像 (uint8 由来なので書き読みで完全一致する)
    private func makeImage(_ seed: Int) throws -> CharacterImage {
        var bytes = [UInt8](repeating: 0, count: CharacterImage.pixelCount)
        var i = 0
        while i < bytes.count {
            bytes[i] = UInt8((i &* 7 &+ seed &* 13) % 256)
            i += 1
        }
        return try CharacterImage(uint8: bytes)
    }

    private func readBytes(_ u: URL) throws -> [UInt8] {
        return [UInt8](try Data(contentsOf: u))
    }

    // MARK: - 往復

    func testRoundTripOfThreeSamples() throws {
        let file = url("three.stgk")
        let labels = [0, 1234, CharacterVocabulary.shared.count - 1]
        var images = [CharacterImage]()

        let writer = try DatasetWriter(url: file)
        for (i, label) in labels.enumerated() {
            let image = try makeImage(i + 1)
            images.append(image)
            try writer.append(label: label, image: image)
        }
        XCTAssertEqual(writer.count, 3)
        try writer.close()

        let reader = try DatasetReader(url: file)
        defer { reader.close() }
        XCTAssertEqual(reader.count, 3)

        let all = try reader.readAll()
        XCTAssertEqual(all.count, 3)
        for (i, sample) in all.enumerated() {
            XCTAssertEqual(sample.label, labels[i])
            XCTAssertEqual(sample.image.asUInt8(), images[i].asUInt8(), "サンプル \(i) の画素が違う")
            XCTAssertEqual(sample.image.pixels, images[i].pixels, "サンプル \(i) の画素が違う")
        }
    }

    func testRandomAccessMatchesSequentialRead() throws {
        let file = url("random.stgk")
        let writer = try DatasetWriter(url: file)
        var i = 0
        while i < 7 {
            try writer.append(label: i * 100, image: try makeImage(i))
            i += 1
        }
        try writer.close()

        let reader = try DatasetReader(url: file)
        defer { reader.close() }
        let all = try reader.readAll()
        // 逆順・飛び飛びで引いても同じ
        for index in [6, 0, 3, 5, 1, 4, 2] {
            let s = try reader.sample(at: index)
            XCTAssertEqual(s.label, all[index].label)
            XCTAssertEqual(s.image.pixels, all[index].image.pixels)
        }
        // ランダムアクセスの後でも readAll は先頭から読み直す
        XCTAssertEqual(try reader.readAll().map { $0.label }, all.map { $0.label })
    }

    func testDatasetSampleAppendOverload() throws {
        let file = url("overload.stgk")
        let writer = try DatasetWriter(url: file)
        let sample = DatasetSample(label: 42, image: try makeImage(9))
        try writer.append(sample)
        try writer.close()
        let reader = try DatasetReader(url: file)
        defer { reader.close() }
        XCTAssertEqual(try reader.sample(at: 0), sample)
    }

    // MARK: - ヘッダと count の書き戻し

    func testHeaderBytesAndCountWriteBack() throws {
        let file = url("header.stgk")
        let writer = try DatasetWriter(url: file)

        // close 前は count が 0 のまま
        let beforeClose = try readBytes(file)
        XCTAssertEqual(Array(beforeClose[0 ..< 4]), DatasetFormat.magic)
        XCTAssertEqual(DatasetReader.readLittleEndian32(beforeClose, at: 8), 0)

        var i = 0
        while i < 5 {
            try writer.append(label: i, image: try makeImage(i))
            i += 1
        }
        // append しただけではまだ 0
        XCTAssertEqual(DatasetReader.readLittleEndian32(try readBytes(file), at: 8), 0)

        try writer.close()

        let bytes = try readBytes(file)
        XCTAssertEqual(Array(bytes[0 ..< 4]), [0x53, 0x54, 0x47, 0x4B])  // "STGK"
        XCTAssertEqual(DatasetReader.readLittleEndian32(bytes, at: 4), 1)   // version
        XCTAssertEqual(DatasetReader.readLittleEndian32(bytes, at: 8), 5)   // count が書き戻された
        XCTAssertEqual(bytes[12], 32)                                        // side
        XCTAssertEqual(Array(bytes[13 ..< 16]), [0, 0, 0])                   // reserved
        XCTAssertEqual(bytes.count, 16 + 5 * 1026)
        XCTAssertEqual(DatasetFormat.headerSize, 16)
        XCTAssertEqual(DatasetFormat.sampleSize, 1026)
    }

    func testLabelIsLittleEndianUInt16() throws {
        let file = url("label.stgk")
        let writer = try DatasetWriter(url: file)
        try writer.append(label: 0x0102, image: CharacterImage())
        try writer.close()
        let bytes = try readBytes(file)
        XCTAssertEqual(bytes[16], 0x02)
        XCTAssertEqual(bytes[17], 0x01)
    }

    func testCloseIsIdempotentAndAppendAfterCloseThrows() throws {
        let file = url("close.stgk")
        let writer = try DatasetWriter(url: file)
        try writer.append(label: 1, image: CharacterImage())
        try writer.close()
        try writer.close()  // 2 回目は何もしない
        XCTAssertThrowsError(try writer.append(label: 2, image: CharacterImage()))
    }

    // MARK: - 0 サンプル

    func testZeroSampleFile() throws {
        let file = url("empty.stgk")
        let writer = try DatasetWriter(url: file)
        XCTAssertEqual(writer.count, 0)
        try writer.close()

        XCTAssertEqual(try readBytes(file).count, 16)

        let reader = try DatasetReader(url: file)
        defer { reader.close() }
        XCTAssertEqual(reader.count, 0)
        XCTAssertEqual(try reader.readAll().count, 0)
        XCTAssertThrowsError(try reader.sample(at: 0)) { error in
            XCTAssertEqual(error as? DatasetFileError, .indexOutOfRange(index: 0, count: 0))
        }
    }

    // MARK: - 不正なファイル

    func testWrongMagicThrows() throws {
        let file = url("badmagic.stgk")
        let writer = try DatasetWriter(url: file)
        try writer.append(label: 0, image: CharacterImage())
        try writer.close()

        var bytes = try readBytes(file)
        bytes[0] = 0x58  // "X"
        try Data(bytes).write(to: file)

        XCTAssertThrowsError(try DatasetReader(url: file)) { error in
            XCTAssertEqual(error as? DatasetFileError, .invalidMagic([0x58, 0x54, 0x47, 0x4B]))
        }
    }

    func testWrongVersionThrows() throws {
        let file = url("badversion.stgk")
        let writer = try DatasetWriter(url: file)
        try writer.close()
        var bytes = try readBytes(file)
        bytes[4] = 9
        try Data(bytes).write(to: file)
        XCTAssertThrowsError(try DatasetReader(url: file)) { error in
            XCTAssertEqual(error as? DatasetFileError, .unsupportedVersion(9))
        }
    }

    func testWrongSideThrows() throws {
        let file = url("badside.stgk")
        let writer = try DatasetWriter(url: file)
        try writer.close()
        var bytes = try readBytes(file)
        bytes[12] = 16
        try Data(bytes).write(to: file)
        XCTAssertThrowsError(try DatasetReader(url: file)) { error in
            XCTAssertEqual(error as? DatasetFileError, .unsupportedSide(16))
        }
    }

    func testTruncatedFileThrows() throws {
        let file = url("truncated.stgk")
        let writer = try DatasetWriter(url: file)
        var i = 0
        while i < 3 {
            try writer.append(label: i, image: try makeImage(i))
            i += 1
        }
        try writer.close()

        // 最後のサンプルの途中で切る
        let bytes = try readBytes(file)
        let cut = bytes.count - 500
        try Data(bytes[0 ..< cut]).write(to: file)

        XCTAssertThrowsError(try DatasetReader(url: file)) { error in
            XCTAssertEqual(
                error as? DatasetFileError,
                .lengthMismatch(expected: 16 + 3 * 1026, actual: cut)
            )
        }
    }

    func testTruncatedHeaderThrows() throws {
        let file = url("shorthead.stgk")
        try Data([0x53, 0x54, 0x47, 0x4B, 0x01]).write(to: file)
        XCTAssertThrowsError(try DatasetReader(url: file)) { error in
            XCTAssertEqual(error as? DatasetFileError, .truncatedHeader(actualBytes: 5))
        }
    }

    func testEmptyFileThrows() throws {
        let file = url("zero.stgk")
        try Data().write(to: file)
        XCTAssertThrowsError(try DatasetReader(url: file)) { error in
            XCTAssertEqual(error as? DatasetFileError, .truncatedHeader(actualBytes: 0))
        }
    }

    func testExtraTrailingBytesThrow() throws {
        let file = url("extra.stgk")
        let writer = try DatasetWriter(url: file)
        try writer.append(label: 0, image: CharacterImage())
        try writer.close()
        var bytes = try readBytes(file)
        bytes.append(contentsOf: [0, 0, 0, 0])
        try Data(bytes).write(to: file)
        XCTAssertThrowsError(try DatasetReader(url: file)) { error in
            XCTAssertEqual(
                error as? DatasetFileError,
                .lengthMismatch(expected: 16 + 1026, actual: 16 + 1026 + 4)
            )
        }
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try DatasetReader(url: url("does-not-exist.stgk")))
    }

    // MARK: - label の検証

    func testInvalidLabelThrows() throws {
        let file = url("badlabel.stgk")
        let writer = try DatasetWriter(url: file)
        defer { try? writer.close() }
        XCTAssertThrowsError(try writer.append(label: -1, image: CharacterImage())) { error in
            XCTAssertEqual(error as? DatasetFileError, .invalidLabel(-1))
        }
        let n = CharacterVocabulary.shared.count
        XCTAssertThrowsError(try writer.append(label: n, image: CharacterImage())) { error in
            XCTAssertEqual(error as? DatasetFileError, .invalidLabel(n))
        }
        // 上限ぎりぎりは通る
        XCTAssertNoThrow(try writer.append(label: n - 1, image: CharacterImage()))
    }

    /// 細工されたファイル (label = 65535) は読み込み時に弾く。
    /// Writer は範囲検査するので、こういうファイルはバイト列を直接作らないと作れない。
    /// (Wave 1 監査 §6-1 の指摘への対応)
    func testOutOfRangeLabelInFileThrowsOnRead() throws {
        let file = url("forged-label.stgk")
        let image = try makeImage(5)

        // ヘッダ 16 バイト + サンプル 1 件をバイト列から組み立てる
        var bytes = [UInt8]()
        bytes.append(contentsOf: DatasetFormat.magic)
        bytes.append(contentsOf: DatasetWriter.littleEndian32(DatasetFormat.version))
        bytes.append(contentsOf: DatasetWriter.littleEndian32(1))   // count = 1
        bytes.append(DatasetFormat.side)
        bytes.append(contentsOf: [0, 0, 0])                          // reserved
        bytes.append(0xFF)                                           // label 下位 = 0xFF
        bytes.append(0xFF)                                           // label 上位 = 0xFF -> 65535
        bytes.append(contentsOf: image.asUInt8())
        XCTAssertEqual(bytes.count, DatasetFormat.expectedFileSize(count: 1))
        try Data(bytes).write(to: file)

        // ヘッダは正しいので DatasetReader の初期化は通る
        let reader = try DatasetReader(url: file)
        defer { reader.close() }
        XCTAssertEqual(reader.count, 1)

        // ランダムアクセスと全読み込みの両方で投げること
        XCTAssertThrowsError(try reader.sample(at: 0)) { error in
            XCTAssertEqual(error as? DatasetFileError, .invalidLabel(65535))
        }
        XCTAssertThrowsError(try reader.readAll()) { error in
            XCTAssertEqual(error as? DatasetFileError, .invalidLabel(65535))
        }
    }

    /// 境界: クラス数ちょうどは弾き、クラス数 - 1 は通す。
    func testLabelBoundaryOnRead() throws {
        let n = CharacterVocabulary.shared.count
        let image = try makeImage(9)

        func writeForged(label: Int, to file: URL) throws {
            var bytes = [UInt8]()
            bytes.append(contentsOf: DatasetFormat.magic)
            bytes.append(contentsOf: DatasetWriter.littleEndian32(DatasetFormat.version))
            bytes.append(contentsOf: DatasetWriter.littleEndian32(1))
            bytes.append(DatasetFormat.side)
            bytes.append(contentsOf: [0, 0, 0])
            bytes.append(UInt8(label & 0xFF))
            bytes.append(UInt8((label >> 8) & 0xFF))
            bytes.append(contentsOf: image.asUInt8())
            try Data(bytes).write(to: file)
        }

        let bad = url("label-n.stgk")
        try writeForged(label: n, to: bad)
        let badReader = try DatasetReader(url: bad)
        defer { badReader.close() }
        XCTAssertThrowsError(try badReader.sample(at: 0)) { error in
            XCTAssertEqual(error as? DatasetFileError, .invalidLabel(n))
        }

        let good = url("label-n-1.stgk")
        try writeForged(label: n - 1, to: good)
        let goodReader = try DatasetReader(url: good)
        defer { goodReader.close() }
        let sample = try goodReader.sample(at: 0)
        XCTAssertEqual(sample.label, n - 1)
        XCTAssertEqual(try goodReader.readAll().count, 1)
    }

    func testIndexOutOfRangeThrows() throws {
        let file = url("range.stgk")
        let writer = try DatasetWriter(url: file)
        try writer.append(label: 0, image: CharacterImage())
        try writer.close()
        let reader = try DatasetReader(url: file)
        defer { reader.close() }
        XCTAssertThrowsError(try reader.sample(at: -1)) { error in
            XCTAssertEqual(error as? DatasetFileError, .indexOutOfRange(index: -1, count: 1))
        }
        XCTAssertThrowsError(try reader.sample(at: 1)) { error in
            XCTAssertEqual(error as? DatasetFileError, .indexOutOfRange(index: 1, count: 1))
        }
    }

    func testReadAfterCloseThrows() throws {
        let file = url("afterclose.stgk")
        let writer = try DatasetWriter(url: file)
        try writer.append(label: 0, image: CharacterImage())
        try writer.close()
        let reader = try DatasetReader(url: file)
        reader.close()
        XCTAssertThrowsError(try reader.sample(at: 0))
        XCTAssertThrowsError(try reader.readAll())
    }

    // MARK: - メタ JSON

    func testDatasetMetaRoundTrip() throws {
        let meta = DatasetMeta(
            fonts: ["font-a", "font-b"],   // テストに実在のフォント名を持ち込まない
            augmentations: 8,
            scripts: ["hiragana", "katakana", "kanji"]
        )
        let file = url("train.stgk")
        let sidecar = DatasetMeta.sidecarURL(for: file)
        XCTAssertEqual(sidecar.lastPathComponent, "train.meta.json")

        try meta.write(to: sidecar)
        let loaded = try DatasetMeta.read(from: sidecar)
        XCTAssertEqual(loaded, meta)

        // サイドカー JSON のキー名
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: sidecar)) as? [String: Any]
        XCTAssertNotNil(json?["fonts"])
        XCTAssertNotNil(json?["augmentations"])
        XCTAssertNotNil(json?["scripts"])
        XCTAssertEqual(json?.count, 3)
    }

    func testDatasetMetaReadOfMissingFileThrows() {
        XCTAssertThrowsError(try DatasetMeta.read(from: url("nope.meta.json")))
    }

    // MARK: - 大きめのファイル

    func testManySamplesStreamed() throws {
        let file = url("many.stgk")
        let writer = try DatasetWriter(url: file)
        var i = 0
        while i < 500 {
            try writer.append(label: i % CharacterVocabulary.shared.count, image: try makeImage(i))
            i += 1
        }
        try writer.close()

        let reader = try DatasetReader(url: file)
        defer { reader.close() }
        XCTAssertEqual(reader.count, 500)
        XCTAssertEqual(try reader.sample(at: 499).label, 499)
        XCTAssertEqual(try reader.sample(at: 0).image.asUInt8(), try makeImage(0).asUInt8())
        XCTAssertEqual(try reader.readAll().count, 500)
    }
}
