// DatasetFile は学習データの読み書き専用で、wasm の推論経路では使わない。
// FileHandle / NSNumber は WASI の FoundationEssentials に無いので、WASI ビルドから外す。
#if !os(WASI)

public enum DatasetFileError: Error, Equatable {
    /// 先頭 4 バイトが "STGK" でない
    case invalidMagic([UInt8])
    /// version が 1 でない
    case unsupportedVersion(UInt32)
    /// side が 32 でない
    case unsupportedSide(UInt8)
    /// ヘッダ 16 バイトに満たない
    case truncatedHeader(actualBytes: Int)
    /// ファイル長が 16 + count * 1026 と一致しない (切り詰め / 余分)
    case lengthMismatch(expected: Int, actual: Int)
    /// index がサンプル数の範囲外
    case indexOutOfRange(index: Int, count: Int)
    /// label がクラス範囲外 (書き込み時・読み込み時の両方で投げる)
    case invalidLabel(Int)
    /// ファイルを開けない / 読み書きに失敗した
    case ioFailure(String)
}

/// DatasetFile のバイナリ形式定数 (リトルエンディアン)。
///
///     magic     4 bytes  "STGK"
///     version   u32      1
///     count     u32      サンプル数
///     side      u8       32
///     reserved  3 bytes  0
///     samples   count 回: label u16 + pixels 1024 x u8
public enum DatasetFormat {
    public static let magic: [UInt8] = [0x53, 0x54, 0x47, 0x4B]  // "STGK"
    public static let version: UInt32 = 1
    public static let side: UInt8 = 32
    /// magic 4 + version 4 + count 4 + side 1 + reserved 3
    public static let headerSize = 16
    /// count フィールドのファイル先頭からのオフセット
    public static let countOffset = 8
    /// label 2 + pixels 1024
    public static let sampleSize = 2 + CharacterImage.pixelCount

    static func expectedFileSize(count: Int) -> Int {
        return headerSize + count * sampleSize
    }
}

/// 1 サンプル: クラス index と 32x32 画像。
public struct DatasetSample: Sendable, Equatable {
    public let label: Int
    public let image: CharacterImage

    public init(label: Int, image: CharacterImage) {
        self.label = label
        self.image = image
    }
}

/// 追記書き込み。ヘッダを count = 0 で先に書き、`close()` で実際の件数を書き戻す。
/// render スクリプトがストリーミングで書けるようにするため。
public final class DatasetWriter: @unchecked Sendable {
    private let handle: FileHandle
    private var sampleCount: Int
    private var closed: Bool

    /// 書き込んだサンプル数
    public var count: Int {
        return sampleCount
    }

    public init(url: URL) throws {
        let fm = FileManager.default
        if !fm.createFile(atPath: url.path, contents: nil) {
            throw DatasetFileError.ioFailure("ファイルを作成できない: \(url.path)")
        }
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw DatasetFileError.ioFailure("書き込みで開けない: \(url.path): \(error)")
        }
        sampleCount = 0
        closed = false

        var header = [UInt8]()
        header.reserveCapacity(DatasetFormat.headerSize)
        header.append(contentsOf: DatasetFormat.magic)
        header.append(contentsOf: DatasetWriter.littleEndian32(DatasetFormat.version))
        header.append(contentsOf: DatasetWriter.littleEndian32(0))  // count は close で書き戻す
        header.append(DatasetFormat.side)
        header.append(contentsOf: [0, 0, 0])  // reserved
        try write(Data(header))
    }

    /// 1 サンプル追記する。label が語彙の範囲外なら投げる (黙って壊れたデータを書かない)。
    public func append(label: Int, image: CharacterImage) throws {
        if closed {
            throw DatasetFileError.ioFailure("close 済みの DatasetWriter に append した")
        }
        if label < 0 || label >= CharacterVocabulary.shared.count || label > Int(UInt16.max) {
            throw DatasetFileError.invalidLabel(label)
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(DatasetFormat.sampleSize)
        let l = UInt16(label)
        bytes.append(UInt8(l & 0xFF))
        bytes.append(UInt8((l >> 8) & 0xFF))
        bytes.append(contentsOf: image.asUInt8())
        try write(Data(bytes))
        sampleCount += 1
    }

    public func append(_ sample: DatasetSample) throws {
        try append(label: sample.label, image: sample.image)
    }

    /// count を書き戻してファイルを閉じる。2 回呼んでも安全。
    public func close() throws {
        if closed {
            return
        }
        closed = true
        do {
            try handle.seek(toOffset: UInt64(DatasetFormat.countOffset))
            try handle.write(contentsOf: Data(DatasetWriter.littleEndian32(UInt32(sampleCount))))
            try handle.close()
        } catch {
            throw DatasetFileError.ioFailure("count の書き戻しに失敗: \(error)")
        }
    }

    private func write(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw DatasetFileError.ioFailure("書き込みに失敗: \(error)")
        }
    }

    static func littleEndian32(_ v: UInt32) -> [UInt8] {
        return [
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF)
        ]
    }
}

/// 読み込み。初期化時に magic / version / side / ファイル長を検証する。
/// サンプルを復号するときは label がクラス範囲に収まることも検査する。
/// index 指定のランダムアクセスと全読み込みの両方を持つ。
public final class DatasetReader: @unchecked Sendable {
    private let handle: FileHandle
    private let sampleCount: Int
    private var closed: Bool

    /// サンプル数 (ヘッダの count とファイル長が一致していることは検証済み)
    public var count: Int {
        return sampleCount
    }

    public init(url: URL) throws {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let sizeValue = attrs[.size] as? NSNumber else {
            throw DatasetFileError.ioFailure("ファイルの大きさを取得できない: \(url.path)")
        }
        let fileSize = sizeValue.intValue

        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw DatasetFileError.ioFailure("読み込みで開けない: \(url.path): \(error)")
        }
        closed = false

        let headerData: Data
        do {
            headerData = try handle.read(upToCount: DatasetFormat.headerSize) ?? Data()
        } catch {
            try? handle.close()
            throw DatasetFileError.ioFailure("ヘッダを読めない: \(error)")
        }
        if headerData.count < DatasetFormat.headerSize {
            try? handle.close()
            throw DatasetFileError.truncatedHeader(actualBytes: headerData.count)
        }
        let header = [UInt8](headerData)

        let magic = Array(header[0 ..< 4])
        if magic != DatasetFormat.magic {
            try? handle.close()
            throw DatasetFileError.invalidMagic(magic)
        }
        let version = DatasetReader.readLittleEndian32(header, at: 4)
        if version != DatasetFormat.version {
            try? handle.close()
            throw DatasetFileError.unsupportedVersion(version)
        }
        let declaredCount = DatasetReader.readLittleEndian32(header, at: 8)
        let side = header[12]
        if side != DatasetFormat.side {
            try? handle.close()
            throw DatasetFileError.unsupportedSide(side)
        }

        let expected = DatasetFormat.expectedFileSize(count: Int(declaredCount))
        if expected != fileSize {
            try? handle.close()
            throw DatasetFileError.lengthMismatch(expected: expected, actual: fileSize)
        }
        sampleCount = Int(declaredCount)
    }

    /// index 指定のランダムアクセス。
    public func sample(at index: Int) throws -> DatasetSample {
        if closed {
            throw DatasetFileError.ioFailure("close 済みの DatasetReader から読んだ")
        }
        if index < 0 || index >= sampleCount {
            throw DatasetFileError.indexOutOfRange(index: index, count: sampleCount)
        }
        let offset = DatasetFormat.headerSize + index * DatasetFormat.sampleSize
        let data: Data
        do {
            try handle.seek(toOffset: UInt64(offset))
            data = try handle.read(upToCount: DatasetFormat.sampleSize) ?? Data()
        } catch {
            throw DatasetFileError.ioFailure("サンプル \(index) を読めない: \(error)")
        }
        if data.count != DatasetFormat.sampleSize {
            throw DatasetFileError.lengthMismatch(
                expected: offset + DatasetFormat.sampleSize,
                actual: offset + data.count
            )
        }
        return try DatasetReader.decodeSample([UInt8](data))
    }

    public func close() {
        if closed {
            return
        }
        closed = true
        try? handle.close()
    }

    deinit {
        if !closed {
            try? handle.close()
        }
    }

    /// `sample(at:)` の復号経路。label の範囲検査もここで行う。
    private static func decodeSample(_ bytes: [UInt8]) throws -> DatasetSample {
        let label = Int(bytes[0]) | (Int(bytes[1]) << 8)
        // u16 なので負にはならないが、細工されたファイルはクラス数以上の label を持てる。
        // 黙って通すと呼び出し側が範囲外 index で語彙を引く (DatasetWriter.append と同じ検査)
        if label >= CharacterVocabulary.shared.count {
            throw DatasetFileError.invalidLabel(label)
        }
        let pixels = Array(bytes[2 ..< DatasetFormat.sampleSize])
        let image: CharacterImage
        do {
            image = try CharacterImage(uint8: pixels)
        } catch {
            throw DatasetFileError.lengthMismatch(
                expected: CharacterImage.pixelCount,
                actual: pixels.count
            )
        }
        return DatasetSample(label: label, image: image)
    }

    static func readLittleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

/// サイドカー `<name>.meta.json` の中身。
public struct DatasetMeta: Codable, Sendable, Equatable {
    public var fonts: [String]
    public var augmentations: Int
    public var scripts: [String]

    public init(fonts: [String], augmentations: Int, scripts: [String]) {
        self.fonts = fonts
        self.augmentations = augmentations
        self.scripts = scripts
    }

    /// データセット本体のパスから `<name>.meta.json` のパスを作る。
    public static func sidecarURL(for datasetURL: URL) -> URL {
        return datasetURL.deletingPathExtension().appendingPathExtension("meta.json")
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        do {
            try data.write(to: url, options: [])
        } catch {
            throw DatasetFileError.ioFailure("メタ JSON を書けない: \(url.path): \(error)")
        }
    }

    public static func read(from url: URL) throws -> DatasetMeta {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DatasetFileError.ioFailure("メタ JSON を読めない: \(url.path): \(error)")
        }
        return try JSONDecoder().decode(DatasetMeta.self, from: data)
    }
}

#endif
