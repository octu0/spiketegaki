import XCTest
@testable import Spiketegaki

/// 重みのバイナリ形式 ("STGW" v1) の単体テスト。
/// JSON 経由の重みと完全一致すること、壊れた入力を投げることを確かめる。
final class SpikingNetworkWeightsBinaryTests: XCTestCase {

    /// 線形合同法の疑似乱数 (`SpikingNetwork.init` の Float.random は実行ごとに変わるため)
    private struct SeededRandom {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next(in range: Float) -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float((state >> 33) % 1_000_003) / 1_000_003.0
            return (unit * 2.0 - 1.0) * range
        }
    }

    private func seedWeights(_ net: SpikingNetwork, seed: UInt64) {
        var rng = SeededRandom(seed: seed)
        func fill(_ param: Parameter, _ range: Float) {
            var i = 0
            while i < param.count {
                param.data[i] = rng.next(in: range)
                i += 1
            }
        }
        fill(net.pWIn, 0.5)
        fill(net.pWRec, 0.2)
        fill(net.pBH, 0.35)
        var l = 0
        while l < net.pWLayers.count {
            fill(net.pWLayers[l], 0.4)
            fill(net.pBHLayers[l], 0.1)
            fill(net.pGammaRMS[l], 0.9)
            l += 1
        }
        fill(net.pWOut, 0.3)
        fill(net.pBOut, 0.05)
        net.rebuildInferenceLayout()
    }

    private func makeNetwork(
        numLayers: Int = 3,
        readoutFrames: Int = 32,
        seed: UInt64 = 20260925
    ) -> SpikingNetwork {
        let net = SpikingNetwork(
            numLayers: numLayers,
            inputDim: 8,
            maxHiddenDim: 16,
            outputDim: 5,
            timeSteps: 3,
            lifConfig: LIFConfig(beta: 0.75, vTh: 1.1, vReset: 0.25, alpha: 2.5, rho: 0.8, gamma: 0.2),
            readoutFrames: readoutFrames
        )
        seedWeights(net, seed: seed)
        return net
    }

    private func makeFrames(count: Int, dim: Int, seed: UInt64) -> [[Float]] {
        var rng = SeededRandom(seed: seed)
        var frames = [[Float]]()
        var t = 0
        while t < count {
            var f = [Float](repeating: 0.0, count: dim)
            var i = 0
            while i < dim {
                f[i] = rng.next(in: 1.0) + 1.0
                i += 1
            }
            frames.append(f)
            t += 1
        }
        return frames
    }

    // MARK: - 往復

    /// JSON 経由で得た重みをバイナリに往復させても全配列が完全一致する
    func testBinaryRoundTripMatchesJSONDecodedWeightsExactly() throws {
        let net = makeNetwork()
        let exported = net.exportWeights(classLabels: ["あ", "い", "う", "え", "お"])

        // JSON 経路 (既存の保存形式) を通した重みを基準にする
        let jsonData = try JSONEncoder().encode(exported)
        let fromJSON = try JSONDecoder().decode(SpikingNetworkWeights.self, from: jsonData)

        let bytes = fromJSON.binary()
        let fromBinary = try SpikingNetworkWeights(binary: bytes)

        // Equatable による全体一致 (全配列・全スカラ・classLabels を含む)
        XCTAssertEqual(fromBinary, fromJSON, "バイナリ往復で重みが変わってはいけない")

        // 配列ごとにも要素単位で突き合わせる (Equatable の実装に依存しない一次確認)
        XCTAssertEqual(fromBinary.wIn, fromJSON.wIn)
        XCTAssertEqual(fromBinary.wRec, fromJSON.wRec)
        XCTAssertEqual(fromBinary.bH, fromJSON.bH)
        XCTAssertEqual(fromBinary.wLayers, fromJSON.wLayers)
        XCTAssertEqual(fromBinary.bHLayers, fromJSON.bHLayers)
        XCTAssertEqual(fromBinary.gammaRMS, fromJSON.gammaRMS)
        XCTAssertEqual(fromBinary.wOut, fromJSON.wOut)
        XCTAssertEqual(fromBinary.bOut, fromJSON.bOut)
        XCTAssertEqual(fromBinary.classLabels, ["あ", "い", "う", "え", "お"])
        XCTAssertEqual(fromBinary.lifConfig, fromJSON.lifConfig)
        XCTAssertEqual(fromBinary.readoutFrames, fromJSON.readoutFrames)
        XCTAssertEqual(fromBinary.numLayers, 3)

        // ロジットも一致する
        let frames = makeFrames(count: 32, dim: 8, seed: 7)
        let expected = try SpikingNetwork(weights: fromJSON).classifyLogits(frames: frames)
        let actual = try SpikingNetwork(weights: fromBinary).classifyLogits(frames: frames)
        XCTAssertEqual(actual, expected, "バイナリ往復でロジットが変わってはいけない")
    }

    /// バイト列も決定的 (同じ重みからは同じバイト列)
    func testBinaryIsDeterministic() {
        let net = makeNetwork()
        let w = net.exportWeights(classLabels: ["a", "b", "c", "d", "e"])
        XCTAssertEqual(w.binary(), w.binary())
    }

    /// 1 層構成 (上位層なし) と classLabels なしも往復する
    func testBinaryRoundTripSingleLayerWithoutLabels() throws {
        let net = makeNetwork(numLayers: 1)
        let w = net.exportWeights()
        XCTAssertNil(w.classLabels)
        XCTAssertTrue(w.wLayers.isEmpty)

        let decoded = try SpikingNetworkWeights(binary: w.binary())
        XCTAssertEqual(decoded, w)
        XCTAssertNil(decoded.classLabels)
        XCTAssertEqual(decoded.numLayers, 1)
    }

    /// readoutFrames がバイナリを往復する
    func testBinaryRoundTripPreservesReadoutFrames() throws {
        for readoutFrames in [1, 8, 32] {
            let net = makeNetwork(readoutFrames: readoutFrames)
            let decoded = try SpikingNetworkWeights(binary: net.exportWeights().binary())
            XCTAssertEqual(decoded.readoutFrames, readoutFrames)
            XCTAssertEqual(SpikingNetwork(weights: decoded).readoutFrames, readoutFrames)
        }
    }

    /// ヘッダの定数とサイズ (float 本体の長さが次元から決まること)
    func testBinaryHeaderLayout() {
        let net = makeNetwork(numLayers: 3)
        let bytes = net.exportWeights().binary()
        XCTAssertEqual(Array(bytes[0 ..< 4]), Array("STGW".utf8))
        XCTAssertEqual(SpikingNetworkWeights.binaryHeaderSize, 64)

        let hidden = 16, input = 8, output = 5, upper = 2
        let floatCount = hidden * input + hidden * hidden + hidden
            + upper * (hidden * hidden + hidden + hidden)
            + output * hidden + output
        // classLabels は無いので本体で終わる
        XCTAssertEqual(bytes.count, 64 + 4 * floatCount)
    }

    // MARK: - 壊れた入力

    func testBinaryThrowsOnShortInput() {
        XCTAssertThrowsError(try SpikingNetworkWeights(binary: [UInt8](repeating: 0, count: 63))) { e in
            XCTAssertEqual(
                e as? SpikingNetworkWeightsBinaryError,
                .tooShort(expectedAtLeast: 64, actual: 63)
            )
        }
    }

    func testBinaryThrowsOnInvalidMagic() {
        var bytes = makeNetwork().exportWeights().binary()
        bytes[0] = 0x58   // "X"
        XCTAssertThrowsError(try SpikingNetworkWeights(binary: bytes)) { e in
            XCTAssertEqual(
                e as? SpikingNetworkWeightsBinaryError,
                .invalidMagic([0x58, 0x54, 0x47, 0x57])
            )
        }
    }

    func testBinaryThrowsOnUnsupportedVersion() {
        var bytes = makeNetwork().exportWeights().binary()
        bytes[4] = 9
        XCTAssertThrowsError(try SpikingNetworkWeights(binary: bytes)) { e in
            XCTAssertEqual(e as? SpikingNetworkWeightsBinaryError, .unsupportedVersion(9))
        }
    }

    func testBinaryThrowsOnZeroDimension() {
        // maxHiddenDim (offset 12) を 0 にする
        var bytes = makeNetwork().exportWeights().binary()
        bytes[12] = 0
        bytes[13] = 0
        bytes[14] = 0
        bytes[15] = 0
        XCTAssertThrowsError(try SpikingNetworkWeights(binary: bytes)) { e in
            XCTAssertEqual(
                e as? SpikingNetworkWeightsBinaryError,
                .invalidDimension(field: "maxHiddenDim", value: 0)
            )
        }
    }

    func testBinaryThrowsOnAbsurdDimension() {
        // outputDim (offset 16) を上限超えにする (巨大確保を防ぐ歯止め)
        var bytes = makeNetwork().exportWeights().binary()
        let huge = SpikingNetworkWeights.binaryMaxDimension + 1
        bytes[16] = UInt8(truncatingIfNeeded: huge)
        bytes[17] = UInt8(truncatingIfNeeded: huge >> 8)
        bytes[18] = UInt8(truncatingIfNeeded: huge >> 16)
        bytes[19] = UInt8(truncatingIfNeeded: huge >> 24)
        XCTAssertThrowsError(try SpikingNetworkWeights(binary: bytes)) { e in
            XCTAssertEqual(
                e as? SpikingNetworkWeightsBinaryError,
                .invalidDimension(field: "outputDim", value: huge)
            )
        }
    }

    /// 末尾が欠けたファイル (次元から決まる長さと合わない)
    func testBinaryThrowsOnTruncatedBody() {
        let bytes = makeNetwork().exportWeights().binary()
        let truncated = Array(bytes[0 ..< (bytes.count - 4)])
        XCTAssertThrowsError(try SpikingNetworkWeights(binary: truncated)) { e in
            XCTAssertEqual(
                e as? SpikingNetworkWeightsBinaryError,
                .sizeMismatch(expected: bytes.count, actual: bytes.count - 4)
            )
        }
    }

    /// 余分なバイトが付いたファイルも弾く (黙って無視しない)
    func testBinaryThrowsOnTrailingGarbage() {
        var bytes = makeNetwork().exportWeights().binary()
        let expected = bytes.count
        bytes.append(contentsOf: [0, 0, 0, 0])
        XCTAssertThrowsError(try SpikingNetworkWeights(binary: bytes)) { e in
            XCTAssertEqual(
                e as? SpikingNetworkWeightsBinaryError,
                .sizeMismatch(expected: expected, actual: expected + 4)
            )
        }
    }

    /// ラベル区間が壊れている (長さが残りを超える)
    func testBinaryThrowsOnBrokenLabelSection() {
        let w = makeNetwork().exportWeights(classLabels: ["あ", "い", "う", "え", "お"])
        var bytes = w.binary()
        // 本体の終わり = ヘッダ + float 本体。その直後がラベル 0 の長さフィールド
        let hidden = 16, input = 8, output = 5, upper = 2
        let floatCount = hidden * input + hidden * hidden + hidden
            + upper * (hidden * hidden + hidden + hidden)
            + output * hidden + output
        let labelStart = 64 + 4 * floatCount
        bytes[labelStart] = 0xFF
        bytes[labelStart + 1] = 0xFF
        XCTAssertThrowsError(try SpikingNetworkWeights(binary: bytes)) { e in
            guard case .invalidLabelSection = (e as? SpikingNetworkWeightsBinaryError) else {
                XCTFail("invalidLabelSection を期待したが \(e)")
                return
            }
        }
    }
}
