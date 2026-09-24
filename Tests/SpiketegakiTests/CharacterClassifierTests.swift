import XCTest
@testable import Spiketegaki

final class CharacterClassifierTests: XCTestCase {
    private let vocabulary = CharacterVocabulary.shared

    /// 乱数重みの小さめネットワーク (出力次元は語彙数に合わせる必要がある)
    private func makeClassifier(maxHiddenDim: Int = 32, numLayers: Int = 1) throws -> CharacterClassifier {
        let network = SpikingNetwork(
            numLayers: numLayers,
            inputDim: ScanlineEncoder.frameDim,
            maxHiddenDim: maxHiddenDim,
            outputDim: vocabulary.count,
            timeSteps: 2
        )
        return try CharacterClassifier(network: network, vocabulary: vocabulary)
    }

    /// 中央に十字のある試験画像
    private func sampleImage() throws -> CharacterImage {
        var p = [Float](repeating: 0.0, count: CharacterImage.pixelCount)
        var y = 8
        while y < 24 {
            var x = 8
            while x < 24 {
                if (x >= 14 && x <= 17) || (y >= 14 && y <= 17) {
                    p[y * CharacterImage.side + x] = 1.0
                }
                x += 1
            }
            y += 1
        }
        return try CharacterImage(pixels: p)
    }

    // MARK: - 生成時の検証

    func testInitRejectsOutputDimensionMismatch() {
        let network = SpikingNetwork(
            numLayers: 1,
            inputDim: ScanlineEncoder.frameDim,
            maxHiddenDim: 16,
            outputDim: 10,
            timeSteps: 2
        )
        XCTAssertThrowsError(try CharacterClassifier(network: network, vocabulary: vocabulary)) { error in
            XCTAssertEqual(
                error as? CharacterClassifierError,
                .outputDimensionMismatch(networkOutputDim: 10, vocabularyCount: vocabulary.count)
            )
        }
    }

    func testInitRejectsInputDimensionMismatch() {
        let network = SpikingNetwork(
            numLayers: 1,
            inputDim: 32,
            maxHiddenDim: 16,
            outputDim: vocabulary.count,
            timeSteps: 2
        )
        XCTAssertThrowsError(try CharacterClassifier(network: network, vocabulary: vocabulary)) { error in
            XCTAssertEqual(
                error as? CharacterClassifierError,
                .inputDimensionMismatch(networkInputDim: 32, expected: 64)
            )
        }
    }

    // MARK: - top-k の件数・確率・順序

    func testTopKCountProbabilitySumAndDescendingOrder() throws {
        let classifier = try makeClassifier()
        let image = try sampleImage()

        for k in [1, 5, 10, 100] {
            let top = try classifier.classify(image: image, topK: k)
            XCTAssertEqual(top.count, k, "topK \(k) の件数が違う")
            // 降順
            var i = 1
            while i < top.count {
                XCTAssertGreaterThanOrEqual(
                    top[i - 1].probability, top[i].probability,
                    "topK \(k): \(i - 1) 番目より \(i) 番目の確率が大きい"
                )
                i += 1
            }
            // index と文字が対応している
            for entry in top {
                XCTAssertEqual(vocabulary.character(at: entry.index), entry.character)
                XCTAssertGreaterThanOrEqual(entry.probability, 0.0)
                XCTAssertLessThanOrEqual(entry.probability, 1.0)
            }
        }

        // 確率の総和は 1 (誤差 1e-4)
        let probs = try classifier.probabilities(for: image)
        XCTAssertEqual(probs.count, vocabulary.count)
        var sum: Double = 0.0
        for p in probs {
            sum += Double(p)
        }
        XCTAssertEqual(sum, 1.0, accuracy: 1e-4, "確率の総和が 1 でない: \(sum)")
    }

    func testFullVocabularyTopKSumsToOne() throws {
        let classifier = try makeClassifier()
        let top = try classifier.classify(image: try sampleImage(), topK: vocabulary.count)
        XCTAssertEqual(top.count, vocabulary.count)
        var sum: Double = 0.0
        for e in top {
            sum += Double(e.probability)
        }
        XCTAssertEqual(sum, 1.0, accuracy: 1e-4)
        // 全クラスがちょうど 1 回ずつ現れる
        XCTAssertEqual(Set(top.map { $0.index }).count, vocabulary.count)
    }

    // MARK: - topK の境界

    func testTopKZeroOrNegativeThrows() throws {
        let classifier = try makeClassifier()
        let image = try sampleImage()
        for k in [0, -1, -100] {
            XCTAssertThrowsError(try classifier.classify(image: image, topK: k)) { error in
                XCTAssertEqual(error as? CharacterClassifierError, .invalidTopK(k))
            }
        }
    }

    func testTopKBeyondVocabularyIsClampedToVocabularyCount() throws {
        let classifier = try makeClassifier()
        let image = try sampleImage()
        let top = try classifier.classify(image: image, topK: vocabulary.count + 1000)
        XCTAssertEqual(top.count, vocabulary.count, "語彙数を超える topK が丸められていない")
    }

    // MARK: - 決定性と便宜版

    func testClassificationIsDeterministic() throws {
        let classifier = try makeClassifier()
        let image = try sampleImage()
        let a = try classifier.classify(image: image, topK: 5)
        let b = try classifier.classify(image: image, topK: 5)
        XCTAssertEqual(a.map { $0.index }, b.map { $0.index })
        XCTAssertEqual(a.map { $0.probability }, b.map { $0.probability })
    }

    func testGrayConvenienceMatchesNormalizedImage() throws {
        let classifier = try makeClassifier()
        // 64x64 の中央に 20x20 の四角
        var gray = [Float](repeating: 0.0, count: 64 * 64)
        var j = 22
        while j < 42 {
            var i = 22
            while i < 42 {
                gray[j * 64 + i] = 1.0
                i += 1
            }
            j += 1
        }
        let viaGray = try classifier.classify(width: 64, height: 64, gray: gray, invert: false, topK: 5)
        let normalized = try ImageNormalizer.normalize(width: 64, height: 64, gray: gray, invert: false)
        let viaImage = try classifier.classify(image: normalized, topK: 5)
        XCTAssertEqual(viaGray.map { $0.index }, viaImage.map { $0.index })

        // UInt8 版も同じ結果になる
        let bytes = gray.map { UInt8($0 * 255.0) }
        let viaBytes = try classifier.classify(width: 64, height: 64, gray: bytes, invert: false, topK: 5)
        XCTAssertEqual(viaBytes.map { $0.index }, viaImage.map { $0.index })
    }

    func testGrayConvenienceRejectsBadSize() throws {
        let classifier = try makeClassifier()
        XCTAssertThrowsError(
            try classifier.classify(width: 0, height: 4, gray: [Float](), invert: false, topK: 5)
        )
        XCTAssertThrowsError(
            try classifier.classify(width: 4, height: 4, gray: [Float](repeating: 0.0, count: 3), invert: false, topK: 5)
        )
    }

    func testEmptyImageStillClassifiesWithoutCrashing() throws {
        let classifier = try makeClassifier()
        // 墨の無い画像でも例外を出さず、確率の総和 1 の結果を返す
        let top = try classifier.classify(image: CharacterImage(), topK: 5)
        XCTAssertEqual(top.count, 5)
        for e in top {
            XCTAssertFalse(e.probability.isNaN)
        }
    }

    // MARK: - softmax 単体

    func testSoftmaxProperties() {
        XCTAssertEqual(CharacterClassifier.softmax([]), [])

        let p = CharacterClassifier.softmax([1.0, 2.0, 3.0])
        XCTAssertEqual(p.reduce(0, +), 1.0, accuracy: 1e-6)
        XCTAssertGreaterThan(p[2], p[1])
        XCTAssertGreaterThan(p[1], p[0])

        // 大きな値でも overflow しない (最大値を引いている)
        let big = CharacterClassifier.softmax([1000.0, 1001.0, 999.0])
        XCTAssertEqual(big.reduce(0, +), 1.0, accuracy: 1e-6)
        for v in big {
            XCTAssertFalse(v.isNaN)
        }

        // 全部同じ値なら均等
        let flat = CharacterClassifier.softmax([Float](repeating: 5.0, count: 10))
        for v in flat {
            XCTAssertEqual(v, 0.1, accuracy: 1e-6)
        }
    }
}
