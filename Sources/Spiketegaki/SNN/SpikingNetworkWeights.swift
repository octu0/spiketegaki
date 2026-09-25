/// SNN 重みの JSON 表現。クラスラベルを同梱できる。
public struct SpikingNetworkWeights: Sendable, Codable, Equatable {
    public let inputDim: Int
    public let maxHiddenDim: Int
    public let outputDim: Int
    public let timeSteps: Int
    public let beta: Float
    public let vTh: Float
    public let alpha: Float
    public let rho: Float      // 適応閾値減衰率
    public let gamma: Float    // 発火時閾値上昇幅 (0.0 で固定閾値)

    /// 層 0 (再帰 LIF 層)
    public let wIn: [Float]    // [maxHiddenDim * inputDim]
    public let wRec: [Float]   // [maxHiddenDim * maxHiddenDim]
    public let bH: [Float]     // [maxHiddenDim]

    /// 層 1 以降 (前層スパイクを受けるフィードフォワード LIF 層)。
    /// 各層は結合重み・バイアス・電流 RMSNorm ゲインを持つ。1 層構成では空
    public let wLayers: [[Float]]    // [numLayers - 1][maxHiddenDim * maxHiddenDim]
    public let bHLayers: [[Float]]   // [numLayers - 1][maxHiddenDim]
    public let gammaRMS: [[Float]]   // [numLayers - 1][maxHiddenDim]

    public let wOut: [Float]   // [outputDim * maxHiddenDim]
    public let bOut: [Float]   // [outputDim]

    /// 出力層の ID 割当に対応するクラスラベル (index 順)。
    /// ラベルを同梱しないネットワークでは nil になる
    public let classLabels: [String]?

    /// 分類ロジットに使う末尾フレーム数 (既定 32 = 全フレーム平均)。
    /// CPU と MLX が必ず同じ値を使うよう重みと一緒に運ぶ。
    /// このキーを持たない古い JSON は `legacyReadoutFrames` (32 = 全フレーム平均) とみなす。
    public let readoutFrames: Int

    /// `readoutFrames` を持たない古い重み JSON のデコード既定値 (従来の全 32 フレーム平均)
    public static let legacyReadoutFrames = 32

    public init(
        inputDim: Int,
        maxHiddenDim: Int,
        outputDim: Int,
        timeSteps: Int,
        lifConfig: LIFConfig,
        wIn: [Float],
        wRec: [Float],
        bH: [Float],
        wLayers: [[Float]] = [],
        bHLayers: [[Float]] = [],
        gammaRMS: [[Float]] = [],
        wOut: [Float],
        bOut: [Float],
        classLabels: [String]? = nil,
        readoutFrames: Int = 32
    ) {
        self.inputDim = inputDim
        self.maxHiddenDim = maxHiddenDim
        self.outputDim = outputDim
        self.timeSteps = timeSteps
        self.beta = lifConfig.beta
        self.vTh = lifConfig.vTh
        self.alpha = lifConfig.alpha
        self.rho = lifConfig.rho
        self.gamma = lifConfig.gamma
        self.wIn = wIn
        self.wRec = wRec
        self.bH = bH
        self.wLayers = wLayers
        self.bHLayers = bHLayers
        self.gammaRMS = gammaRMS
        self.wOut = wOut
        self.bOut = bOut
        self.classLabels = classLabels
        // 0 以下は分類できないので 1 に丸める (SpikingNetwork.init と同じ扱い)
        self.readoutFrames = max(1, readoutFrames)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case inputDim, maxHiddenDim, outputDim, timeSteps
        case beta, vTh, alpha, rho, gamma
        case wIn, wRec, bH
        case wLayers, bHLayers, gammaRMS
        case wOut, bOut
        case classLabels
        case readoutFrames
    }

    /// `readoutFrames` だけは省略可能。無い JSON は `legacyReadoutFrames` (32) とみなす。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.inputDim = try c.decode(Int.self, forKey: .inputDim)
        self.maxHiddenDim = try c.decode(Int.self, forKey: .maxHiddenDim)
        self.outputDim = try c.decode(Int.self, forKey: .outputDim)
        self.timeSteps = try c.decode(Int.self, forKey: .timeSteps)
        self.beta = try c.decode(Float.self, forKey: .beta)
        self.vTh = try c.decode(Float.self, forKey: .vTh)
        self.alpha = try c.decode(Float.self, forKey: .alpha)
        self.rho = try c.decode(Float.self, forKey: .rho)
        self.gamma = try c.decode(Float.self, forKey: .gamma)
        self.wIn = try c.decode([Float].self, forKey: .wIn)
        self.wRec = try c.decode([Float].self, forKey: .wRec)
        self.bH = try c.decode([Float].self, forKey: .bH)
        self.wLayers = try c.decode([[Float]].self, forKey: .wLayers)
        self.bHLayers = try c.decode([[Float]].self, forKey: .bHLayers)
        self.gammaRMS = try c.decode([[Float]].self, forKey: .gammaRMS)
        self.wOut = try c.decode([Float].self, forKey: .wOut)
        self.bOut = try c.decode([Float].self, forKey: .bOut)
        self.classLabels = try c.decodeIfPresent([String].self, forKey: .classLabels)
        let decodedReadout = try c.decodeIfPresent(Int.self, forKey: .readoutFrames)
            ?? SpikingNetworkWeights.legacyReadoutFrames
        self.readoutFrames = max(1, decodedReadout)
    }

    /// 層数 (層 0 + 上位層)
    public var numLayers: Int {
        return 1 + wLayers.count
    }

    /// 保持している LIF / ALIF パラメータを LIFConfig として復元
    public var lifConfig: LIFConfig {
        return LIFConfig(
            beta: beta,
            vTh: vTh,
            alpha: alpha,
            rho: rho,
            gamma: gamma
        )
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        try data.write(to: url, options: [])
    }

    public static func load(from url: URL) throws -> SpikingNetworkWeights {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(SpikingNetworkWeights.self, from: data)
    }
}
