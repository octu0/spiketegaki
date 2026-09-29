public enum CharacterClassifierError: Error, Equatable {
    /// ネットワークの出力次元が語彙数と違う。index がずれたまま推論すると
    /// 別の文字を返すので、生成時に弾く。
    case outputDimensionMismatch(networkOutputDim: Int, vocabularyCount: Int)
    /// ネットワークの入力次元が `ScanlineEncoder.frameDim` (64) と違う
    case inputDimensionMismatch(networkInputDim: Int, expected: Int)
    /// topK が 0 以下。0 件を黙って返すと呼び出し側の誤りが隠れるので投げる。
    case invalidTopK(Int)
}

/// 画像 → 正規化 → スキャンライン符号化 → SNN forward x32 → 平均ロジット → top-k。
///
/// 推論専用。Foundation 以外は import しない。
public final class CharacterClassifier: @unchecked Sendable {
    public let network: SpikingNetwork
    public let vocabulary: CharacterVocabulary

    /// 出力次元と語彙数、入力次元とフレーム次元が合わなければ投げる。
    public init(network: SpikingNetwork, vocabulary: CharacterVocabulary) throws {
        if network.outputDim != vocabulary.count {
            throw CharacterClassifierError.outputDimensionMismatch(
                networkOutputDim: network.outputDim,
                vocabularyCount: vocabulary.count
            )
        }
        if network.inputDim != ScanlineEncoder.frameDim {
            throw CharacterClassifierError.inputDimensionMismatch(
                networkInputDim: network.inputDim,
                expected: ScanlineEncoder.frameDim
            )
        }
        self.network = network
        self.vocabulary = vocabulary
    }

    /// 32 フレームの平均ロジット。
    public func logits(for image: CharacterImage) throws -> [Float] {
        return try network.classifyLogits(frames: ScanlineEncoder.encode(image))
    }

    /// softmax 後の確率。総和は 1。
    ///
    /// `categories` が空でなければ、その区分の外のロジットを `-infinity` にしてから
    /// softmax を取る。区分外の確率はちょうど 0 になり、指定区分だけで総和が 1 になる。
    public func probabilities(
        for image: CharacterImage,
        categories: Set<ScriptCategory> = []
    ) throws -> [Float] {
        return CharacterClassifier.softmax(
            maskLogits(try logits(for: image), categories: categories)
        )
    }

    /// 指定区分の外を `-infinity` に潰したロジット。空集合 (= 全部) はそのまま返す。
    public func maskLogits(_ values: [Float], categories: Set<ScriptCategory>) -> [Float] {
        if categories.isEmpty {
            return values
        }
        var out = [Float](repeating: -.infinity, count: values.count)
        for category in ScriptCategory.allCases where categories.contains(category) {
            for index in vocabulary.range(of: category) {
                out[index] = values[index]
            }
        }
        return out
    }

    /// 指定区分が占める index を語彙順に並べたもの。空集合 (= 全部) は全 index。
    private func candidateIndices(_ categories: Set<ScriptCategory>) -> [Int] {
        if categories.isEmpty {
            return Array(0 ..< vocabulary.count)
        }
        var out = [Int]()
        for category in ScriptCategory.allCases where categories.contains(category) {
            out.append(contentsOf: vocabulary.range(of: category))
        }
        return out
    }

    /// 確率の高い順に topK 件。
    ///
    /// - `topK <= 0` は `invalidTopK` を投げる (0 件を返すと呼び出し側の誤りが隠れるため)。
    /// - `topK` が候補数を超えるときは候補数に丸める (存在する以上は返しようがないため)。
    /// - `categories` が空なら全区分から選ぶ。指定したときはその区分の中だけから選び、
    ///   確率も指定区分だけで正規化される (総和 1)。
    public func classify(
        image: CharacterImage,
        topK: Int,
        categories: Set<ScriptCategory> = []
    ) throws -> [(character: Character, index: Int, probability: Float)] {
        if topK <= 0 {
            throw CharacterClassifierError.invalidTopK(topK)
        }
        let probs = try probabilities(for: image, categories: categories)

        // 候補は指定区分の index だけ。マスク後の確率は 0 に潰れるが、
        // 候補側を絞っておけば下位桁のアンダーフローで順序が揺れない
        var order = candidateIndices(categories)
        let k = min(topK, order.count)
        // 確率降順、同率は index 昇順 (決定的にするため)
        order.sort { a, b in
            if probs[a] == probs[b] {
                return a < b
            }
            return probs[a] > probs[b]
        }

        var out = [(character: Character, index: Int, probability: Float)]()
        out.reserveCapacity(k)
        var j = 0
        while j < k {
            let idx = order[j]
            out.append((character: vocabulary.character(at: idx), index: idx, probability: probs[idx]))
            j += 1
        }
        return out
    }

    /// 任意サイズのグレースケールから直接分類する便宜版。
    /// 入力全体を 1 文字分のマス目として `ImageNormalizer` に渡すので、
    /// 学習時とまったく同じ 32x32 表現になる。
    public func classify(
        width: Int,
        height: Int,
        gray: [Float],
        invert: Bool,
        topK: Int,
        categories: Set<ScriptCategory> = []
    ) throws -> [(character: Character, index: Int, probability: Float)] {
        let image = try ImageNormalizer.normalize(
            width: width, height: height, gray: gray, invert: invert
        )
        return try classify(image: image, topK: topK, categories: categories)
    }

    /// UInt8 グレースケール版。
    public func classify(
        width: Int,
        height: Int,
        gray: [UInt8],
        invert: Bool,
        topK: Int,
        categories: Set<ScriptCategory> = []
    ) throws -> [(character: Character, index: Int, probability: Float)] {
        let image = try ImageNormalizer.normalize(
            width: width, height: height, gray: gray, invert: invert
        )
        return try classify(image: image, topK: topK, categories: categories)
    }

    /// 数値的に安定な softmax (最大値を引いてから exp する)。
    public static func softmax(_ logits: [Float]) -> [Float] {
        if logits.isEmpty {
            return []
        }
        var maxValue = logits[0]
        var i = 1
        while i < logits.count {
            if logits[i] > maxValue {
                maxValue = logits[i]
            }
            i += 1
        }
        var out = [Float](repeating: 0.0, count: logits.count)
        var sum: Float = 0.0
        i = 0
        while i < logits.count {
            let e = exp(logits[i] - maxValue)
            out[i] = e
            sum += e
            i += 1
        }
        if sum <= 0.0 {
            // 全要素が -inf などの異常系。均等分布にして総和 1 を守る
            let uniform = 1.0 / Float(logits.count)
            i = 0
            while i < logits.count {
                out[i] = uniform
                i += 1
            }
            return out
        }
        i = 0
        while i < logits.count {
            out[i] /= sum
            i += 1
        }
        return out
    }
}
