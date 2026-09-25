/// LIF (Leaky Integrate-and-Fire) ニューロン設定パラメータ
public struct LIFConfig: Sendable, Equatable {
    public let beta: Float      // 膜電位減衰率 (0.0 < beta < 1.0)
    public let vTh: Float       // 基本発火閾値 (通常 1.0)
    public let alpha: Float     // Surrogate Gradient 鋭さパラメータ (通常 2.0)
    public let rho: Float       // 適応閾値減衰率 (通常 0.85)
    public let gamma: Float     // 発火時閾値上昇幅 (0.0 で標準固定閾値, >0.0 で適応型 ALIF)

    public init(
        beta: Float = 0.8,
        vTh: Float = 1.0,
        alpha: Float = 2.0,
        rho: Float = 0.85,
        gamma: Float = 0.0
    ) {
        self.beta = beta
        self.vTh = vTh
        self.alpha = alpha
        self.rho = rho
        self.gamma = gamma
    }
}

/// LIF 膜電位更新。スカラーと SIMD8。学習側と同じ範囲で膜電位をクリップする。
public enum LIFNeuronEngine {
    /// 膜電位の飽和範囲。学習側 (MLX) が同じ範囲でクリップしているため、
    /// 推論側でも揃えないと発火パターンが学習時と食い違う。
    public static let vClampMin: Float = -20.0
    public static let vClampMax: Float = 20.0

    /// 読み出しのクリップ幅 (V / vTh)。
    /// 閾値下は (-1, 1) のアナログ、発火は 1.0。±20 の飽和を線形層に入れない。
    public static let readoutClipInThresholdUnits: Float = 1.0

    /// 膜電位を閾値単位にして読み出し用にクリップする。
    @inline(__always)
    public static func scaleReadout(_ v: Float, vTh: Float) -> Float {
        let k = readoutClipInThresholdUnits
        var scaled: Float = 0.0
        if vTh != 0.0 {
            scaled = v / vTh
        }
        if scaled < -k {
            return -k
        }
        if k < scaled {
            return k
        }
        return scaled
    }

    @inline(__always)
    public static func clampMembrane(_ v: Float) -> Float {
        if v < vClampMin {
            return vClampMin
        }
        if vClampMax < v {
            return vClampMax
        }
        return v
    }

    /// 1 ニューロンの適応型発火閾値 (ALIF) スカラー更新ステップ
    @inline(__always)
    public static func stepScalarAdaptive(
        config: LIFConfig,
        vPrev: Float,
        sPrev: Float,
        aPrev: Float,
        inputCurrent: Float
    ) -> (vNext: Float, sNext: Float, aNext: Float) {
        let vDecayed = config.beta * vPrev * (1.0 - sPrev)
        let vNext = clampMembrane(vDecayed + inputCurrent)
        let aNext = (config.rho * aPrev) + (config.gamma * sPrev)
        let dynVTh = config.vTh + aNext
        var sNext: Float = 0.0
        if dynVTh <= vNext {
            sNext = 1.0
        }
        return (vNext: vNext, sNext: sNext, aNext: aNext)
    }

    /// 隠れ層の ALIF を SIMD8 で一括更新する (発火時ハードリセット)。
    /// 層ごとの状態は 1 本の配列の区間なので、呼び出し側が先頭ポインタをずらす。
    @inline(__always)
    public static func stepAdaptiveSIMD8(
        config: LIFConfig,
        vPtr: UnsafeMutablePointer<Float>,
        sPtr: UnsafeMutablePointer<Float>,
        aPtr: UnsafeMutablePointer<Float>,
        curPtr: UnsafePointer<Float>,
        count: Int
    ) {
        let limit = count - (count % 8)
        let betaVec = SIMD8<Float>(repeating: config.beta)
        let oneVec = SIMD8<Float>(repeating: 1.0)
        let rhoVec = SIMD8<Float>(repeating: config.rho)
        let gammaVec = SIMD8<Float>(repeating: config.gamma)
        let vThVec = SIMD8<Float>(repeating: config.vTh)
        let lowVec = SIMD8<Float>(repeating: vClampMin)
        let highVec = SIMD8<Float>(repeating: vClampMax)
        let zeroVec = SIMD8<Float>(repeating: 0.0)

        var i = 0
        while i < limit {
            let vPrev = SIMD8<Float>(
                vPtr[i+0], vPtr[i+1], vPtr[i+2], vPtr[i+3],
                vPtr[i+4], vPtr[i+5], vPtr[i+6], vPtr[i+7]
            )
            let sPrev = SIMD8<Float>(
                sPtr[i+0], sPtr[i+1], sPtr[i+2], sPtr[i+3],
                sPtr[i+4], sPtr[i+5], sPtr[i+6], sPtr[i+7]
            )
            let aPrev = SIMD8<Float>(
                aPtr[i+0], aPtr[i+1], aPtr[i+2], aPtr[i+3],
                aPtr[i+4], aPtr[i+5], aPtr[i+6], aPtr[i+7]
            )
            let inCur = SIMD8<Float>(
                curPtr[i+0], curPtr[i+1], curPtr[i+2], curPtr[i+3],
                curPtr[i+4], curPtr[i+5], curPtr[i+6], curPtr[i+7]
            )

            let vDecayed = betaVec * vPrev * (oneVec - sPrev)
            let vRaw = vDecayed + inCur
            var vNext = vRaw.replacing(with: lowVec, where: vRaw .< lowVec)
            vNext = vNext.replacing(with: highVec, where: highVec .< vNext)
            let aNext = (rhoVec * aPrev) + (gammaVec * sPrev)
            let dynVTh = vThVec + aNext
            let sNext = zeroVec.replacing(with: oneVec, where: dynVTh .<= vNext)

            var lane = 0
            while lane < 8 {
                vPtr[i+lane] = vNext[lane]
                sPtr[i+lane] = sNext[lane]
                aPtr[i+lane] = aNext[lane]
                lane += 1
            }
            i += 8
        }
        while i < count {
            let res = stepScalarAdaptive(
                config: config,
                vPrev: vPtr[i],
                sPrev: sPtr[i],
                aPrev: aPtr[i],
                inputCurrent: curPtr[i]
            )
            vPtr[i] = res.vNext
            sPtr[i] = res.sNext
            aPtr[i] = res.aNext
            i += 1
        }
    }

    /// 最終層の 1 ニューロン: リークのみ → 読み出し → subtractive reset。
    /// 発火の商はクリップで 1.0、余りは膜電位に残して次の内部ステップへ渡す。
    @inline(__always)
    public static func stepReadoutScalarAdaptive(
        config: LIFConfig,
        vPrev: Float,
        sPrev: Float,
        aPrev: Float,
        inputCurrent: Float
    ) -> (vNext: Float, sNext: Float, aNext: Float, readout: Float) {
        let vIntegrated = clampMembrane(config.beta * vPrev + inputCurrent)
        let aNext = (config.rho * aPrev) + (config.gamma * sPrev)
        let dynVTh = config.vTh + aNext
        var sNext: Float = 0.0
        if dynVTh <= vIntegrated {
            sNext = 1.0
        }
        let readout = scaleReadout(vIntegrated, vTh: config.vTh)
        let vNext = clampMembrane(vIntegrated - sNext * config.vTh)
        return (vNext: vNext, sNext: sNext, aNext: aNext, readout: readout)
    }

    /// 最終層の SIMD8 更新。隠れ層のハードリセット LIF とは別に、余りを残す。
    @inline(__always)
    public static func stepReadoutAdaptiveSIMD8(
        config: LIFConfig,
        vPtr: UnsafeMutablePointer<Float>,
        sPtr: UnsafeMutablePointer<Float>,
        aPtr: UnsafeMutablePointer<Float>,
        curPtr: UnsafePointer<Float>,
        readoutSumPtr: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        let limit = count - (count % 8)
        let betaVec = SIMD8<Float>(repeating: config.beta)
        let oneVec = SIMD8<Float>(repeating: 1.0)
        let rhoVec = SIMD8<Float>(repeating: config.rho)
        let gammaVec = SIMD8<Float>(repeating: config.gamma)
        let vThVec = SIMD8<Float>(repeating: config.vTh)
        let lowVec = SIMD8<Float>(repeating: vClampMin)
        let highVec = SIMD8<Float>(repeating: vClampMax)
        let zeroVec = SIMD8<Float>(repeating: 0.0)
        let k = readoutClipInThresholdUnits
        let negKVec = SIMD8<Float>(repeating: -k)
        let posKVec = SIMD8<Float>(repeating: k)
        var invThVec = SIMD8<Float>(repeating: 0.0)
        if config.vTh != 0.0 {
            invThVec = SIMD8<Float>(repeating: 1.0 / config.vTh)
        }

        var i = 0
        while i < limit {
            let vPrev = SIMD8<Float>(
                vPtr[i+0], vPtr[i+1], vPtr[i+2], vPtr[i+3],
                vPtr[i+4], vPtr[i+5], vPtr[i+6], vPtr[i+7]
            )
            let sPrev = SIMD8<Float>(
                sPtr[i+0], sPtr[i+1], sPtr[i+2], sPtr[i+3],
                sPtr[i+4], sPtr[i+5], sPtr[i+6], sPtr[i+7]
            )
            let aPrev = SIMD8<Float>(
                aPtr[i+0], aPtr[i+1], aPtr[i+2], aPtr[i+3],
                aPtr[i+4], aPtr[i+5], aPtr[i+6], aPtr[i+7]
            )
            let inCur = SIMD8<Float>(
                curPtr[i+0], curPtr[i+1], curPtr[i+2], curPtr[i+3],
                curPtr[i+4], curPtr[i+5], curPtr[i+6], curPtr[i+7]
            )

            let vRaw = (betaVec * vPrev) + inCur
            var vIntegrated = vRaw.replacing(with: lowVec, where: vRaw .< lowVec)
            vIntegrated = vIntegrated.replacing(with: highVec, where: highVec .< vIntegrated)
            let aNext = (rhoVec * aPrev) + (gammaVec * sPrev)
            let dynVTh = vThVec + aNext
            let sNext = zeroVec.replacing(with: oneVec, where: dynVTh .<= vIntegrated)

            var scaled = vIntegrated * invThVec
            scaled = scaled.replacing(with: negKVec, where: scaled .< negKVec)
            scaled = scaled.replacing(with: posKVec, where: posKVec .< scaled)
            let sumPrev = SIMD8<Float>(
                readoutSumPtr[i+0], readoutSumPtr[i+1], readoutSumPtr[i+2], readoutSumPtr[i+3],
                readoutSumPtr[i+4], readoutSumPtr[i+5], readoutSumPtr[i+6], readoutSumPtr[i+7]
            )
            let sumNext = sumPrev + scaled

            let vSub = vIntegrated - (sNext * vThVec)
            var vNext = vSub.replacing(with: lowVec, where: vSub .< lowVec)
            vNext = vNext.replacing(with: highVec, where: highVec .< vNext)

            var lane = 0
            while lane < 8 {
                vPtr[i+lane] = vNext[lane]
                sPtr[i+lane] = sNext[lane]
                aPtr[i+lane] = aNext[lane]
                readoutSumPtr[i+lane] = sumNext[lane]
                lane += 1
            }
            i += 8
        }
        while i < count {
            let res = stepReadoutScalarAdaptive(
                config: config,
                vPrev: vPtr[i],
                sPrev: sPtr[i],
                aPrev: aPtr[i],
                inputCurrent: curPtr[i]
            )
            vPtr[i] = res.vNext
            sPtr[i] = res.sNext
            aPtr[i] = res.aNext
            readoutSumPtr[i] += res.readout
            i += 1
        }
    }

}
