// SNN 重みのバイナリ形式 "STGW" v1。**stdlib だけで読み書きする** (Foundation を import しない)。
//
// JSON の重みは 44 MB あり、パースも文字列経由で重い。float32 をそのまま並べた形式を
// 持たせて、ブラウザ側では fetch したバイト列をそのまま渡せるようにする。
//
// レイアウト (すべてリトルエンディアン)
//
//   off  size  field
//     0     4  magic "STGW"
//     4     4  version        u32  (= 1)
//     8     4  inputDim       u32
//    12     4  maxHiddenDim   u32
//    16     4  outputDim      u32
//    20     4  timeSteps      u32
//    24     4  readoutFrames  u32
//    28     4  numLayers      u32  (層 0 + 上位層。wLayers.count + 1)
//    32     4  labelCount     u32  (0xFFFFFFFF = classLabels が nil)
//    36     4  beta           f32
//    40     4  vTh            f32
//    44     4  alpha          f32
//    48     4  rho            f32
//    52     4  gamma          f32
//    56     8  reserved       (= 0)
//    64        ここから float32 の本体
//
//   wIn      maxHiddenDim * inputDim
//   wRec     maxHiddenDim * maxHiddenDim
//   bH       maxHiddenDim
//   層 l = 1 ..< numLayers について順に:
//     wLayers[l-1]   maxHiddenDim * maxHiddenDim
//     bHLayers[l-1]  maxHiddenDim
//     gammaRMS[l-1]  maxHiddenDim
//   wOut     outputDim * maxHiddenDim
//   bOut     outputDim
//
//   classLabels (labelCount != 0xFFFFFFFF のとき labelCount 個):
//     byteLength u32 + UTF-8 バイト列
//
// 配列長はヘッダの次元から決まるので配列ごとの長さは書かない。読み込み時に
// 「全体の長さが次元から決まる長さと完全に一致するか」を検証し、違えば投げる。

public enum SpikingNetworkWeightsBinaryError: Error, Equatable {
    /// ヘッダ 64 バイトに満たない
    case tooShort(expectedAtLeast: Int, actual: Int)
    /// magic が "STGW" でない
    case invalidMagic([UInt8])
    /// 未知のバージョン
    case unsupportedVersion(UInt32)
    /// 次元・層数・timeSteps・readoutFrames が 1 以上でない、または大きすぎる
    case invalidDimension(field: String, value: UInt32)
    /// ヘッダから決まる長さとファイル長が食い違う
    case sizeMismatch(expected: Int, actual: Int)
    /// classLabels の区間が壊れている (長さが残りを超える、UTF-8 として不正 など)
    case invalidLabelSection(reason: String)
}

extension SpikingNetworkWeights {
    /// "STGW"
    public static let binaryMagic: [UInt8] = [0x53, 0x54, 0x47, 0x57]
    public static let binaryVersion: UInt32 = 1
    public static let binaryHeaderSize = 64
    /// classLabels が nil であることを表す labelCount
    public static let binaryNoLabels: UInt32 = 0xFFFF_FFFF
    /// 次元として受け付ける上限。壊れたヘッダで巨大な確保をしないための歯止め
    public static let binaryMaxDimension: UInt32 = 1 << 24

    // MARK: - 書き出し

    /// STGW v1 のバイト列にする。
    ///
    /// 各配列は保持している要素数をそのまま書く。構造体の配列長が次元と食い違っている
    /// 場合 (通常は起きない) は、読み戻しで `sizeMismatch` になって検出される。
    public func binary() -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(SpikingNetworkWeights.binaryHeaderSize + 4 * binaryFloatCount())

        out.append(contentsOf: SpikingNetworkWeights.binaryMagic)
        binaryPutU32(&out, SpikingNetworkWeights.binaryVersion)
        binaryPutU32(&out, UInt32(truncatingIfNeeded: inputDim))
        binaryPutU32(&out, UInt32(truncatingIfNeeded: maxHiddenDim))
        binaryPutU32(&out, UInt32(truncatingIfNeeded: outputDim))
        binaryPutU32(&out, UInt32(truncatingIfNeeded: timeSteps))
        binaryPutU32(&out, UInt32(truncatingIfNeeded: readoutFrames))
        binaryPutU32(&out, UInt32(truncatingIfNeeded: numLayers))
        if let labels = classLabels {
            binaryPutU32(&out, UInt32(truncatingIfNeeded: labels.count))
        } else {
            binaryPutU32(&out, SpikingNetworkWeights.binaryNoLabels)
        }
        binaryPutF32(&out, beta)
        binaryPutF32(&out, vTh)
        binaryPutF32(&out, alpha)
        binaryPutF32(&out, rho)
        binaryPutF32(&out, gamma)
        binaryPutU32(&out, 0)   // reserved
        binaryPutU32(&out, 0)   // reserved

        binaryPutFloats(&out, wIn)
        binaryPutFloats(&out, wRec)
        binaryPutFloats(&out, bH)
        var l = 0
        while l < wLayers.count {
            binaryPutFloats(&out, wLayers[l])
            // bHLayers / gammaRMS は wLayers と同じ本数のはず。足りなければ空を書き、
            // 読み戻しの長さ検証で弾く (黙って埋めない)
            if l < bHLayers.count {
                binaryPutFloats(&out, bHLayers[l])
            }
            if l < gammaRMS.count {
                binaryPutFloats(&out, gammaRMS[l])
            }
            l += 1
        }
        binaryPutFloats(&out, wOut)
        binaryPutFloats(&out, bOut)

        if let labels = classLabels {
            var i = 0
            while i < labels.count {
                let utf8 = Array(labels[i].utf8)
                binaryPutU32(&out, UInt32(truncatingIfNeeded: utf8.count))
                out.append(contentsOf: utf8)
                i += 1
            }
        }
        return out
    }

    /// 書き出す float 総数 (reserveCapacity 用)
    private func binaryFloatCount() -> Int {
        var n = wIn.count + wRec.count + bH.count + wOut.count + bOut.count
        var l = 0
        while l < wLayers.count {
            n += wLayers[l].count
            if l < bHLayers.count { n += bHLayers[l].count }
            if l < gammaRMS.count { n += gammaRMS[l].count }
            l += 1
        }
        return n
    }

    // MARK: - 読み込み

    /// STGW v1 のバイト列から復元する。magic・バージョン・次元・長さの不整合は投げる。
    public init(binary bytes: [UInt8]) throws {
        let headerSize = SpikingNetworkWeights.binaryHeaderSize
        if bytes.count < headerSize {
            throw SpikingNetworkWeightsBinaryError.tooShort(
                expectedAtLeast: headerSize, actual: bytes.count
            )
        }
        let magic = Array(bytes[0 ..< 4])
        if magic != SpikingNetworkWeights.binaryMagic {
            throw SpikingNetworkWeightsBinaryError.invalidMagic(magic)
        }
        let version = binaryGetU32(bytes, 4)
        if version != SpikingNetworkWeights.binaryVersion {
            throw SpikingNetworkWeightsBinaryError.unsupportedVersion(version)
        }

        let rawInputDim = binaryGetU32(bytes, 8)
        let rawHidden = binaryGetU32(bytes, 12)
        let rawOutputDim = binaryGetU32(bytes, 16)
        let rawTimeSteps = binaryGetU32(bytes, 20)
        let rawReadout = binaryGetU32(bytes, 24)
        let rawNumLayers = binaryGetU32(bytes, 28)
        let rawLabelCount = binaryGetU32(bytes, 32)

        func checked(_ name: String, _ v: UInt32) throws -> Int {
            if v < 1 || v > SpikingNetworkWeights.binaryMaxDimension {
                throw SpikingNetworkWeightsBinaryError.invalidDimension(field: name, value: v)
            }
            return Int(v)
        }
        let inputDim = try checked("inputDim", rawInputDim)
        let maxHiddenDim = try checked("maxHiddenDim", rawHidden)
        let outputDim = try checked("outputDim", rawOutputDim)
        let timeSteps = try checked("timeSteps", rawTimeSteps)
        let readoutFrames = try checked("readoutFrames", rawReadout)
        let numLayers = try checked("numLayers", rawNumLayers)

        let lif = LIFConfig(
            beta: binaryGetF32(bytes, 36),
            vTh: binaryGetF32(bytes, 40),
            alpha: binaryGetF32(bytes, 44),
            rho: binaryGetF32(bytes, 48),
            gamma: binaryGetF32(bytes, 52)
        )

        // 次元から決まる float 総数とバイト長
        let upper = numLayers - 1
        let floatCount = maxHiddenDim * inputDim
            + maxHiddenDim * maxHiddenDim
            + maxHiddenDim
            + upper * (maxHiddenDim * maxHiddenDim + maxHiddenDim + maxHiddenDim)
            + outputDim * maxHiddenDim
            + outputDim
        let floatBytes = 4 * floatCount
        let bodyEnd = headerSize + floatBytes
        if rawLabelCount == SpikingNetworkWeights.binaryNoLabels {
            if bytes.count != bodyEnd {
                throw SpikingNetworkWeightsBinaryError.sizeMismatch(
                    expected: bodyEnd, actual: bytes.count
                )
            }
        } else if bytes.count < bodyEnd {
            throw SpikingNetworkWeightsBinaryError.sizeMismatch(
                expected: bodyEnd, actual: bytes.count
            )
        }

        var cursor = headerSize
        func take(_ n: Int) -> [Float] {
            let a = binaryGetFloats(bytes, cursor, n)
            cursor += 4 * n
            return a
        }
        let wIn = take(maxHiddenDim * inputDim)
        let wRec = take(maxHiddenDim * maxHiddenDim)
        let bH = take(maxHiddenDim)
        var wLayers = [[Float]]()
        var bHLayers = [[Float]]()
        var gammaRMS = [[Float]]()
        wLayers.reserveCapacity(upper)
        bHLayers.reserveCapacity(upper)
        gammaRMS.reserveCapacity(upper)
        var l = 0
        while l < upper {
            wLayers.append(take(maxHiddenDim * maxHiddenDim))
            bHLayers.append(take(maxHiddenDim))
            gammaRMS.append(take(maxHiddenDim))
            l += 1
        }
        let wOut = take(outputDim * maxHiddenDim)
        let bOut = take(outputDim)

        var classLabels: [String]?
        if rawLabelCount != SpikingNetworkWeights.binaryNoLabels {
            let count = Int(rawLabelCount)
            var labels = [String]()
            labels.reserveCapacity(count)
            var i = 0
            while i < count {
                if cursor + 4 > bytes.count {
                    throw SpikingNetworkWeightsBinaryError.invalidLabelSection(
                        reason: "ラベル \(i) の長さフィールドが範囲外"
                    )
                }
                let len = Int(binaryGetU32(bytes, cursor))
                cursor += 4
                if len < 0 || cursor + len > bytes.count {
                    throw SpikingNetworkWeightsBinaryError.invalidLabelSection(
                        reason: "ラベル \(i) の長さ \(len) が残りバイト数を超える"
                    )
                }
                labels.append(String(decoding: bytes[cursor ..< cursor + len], as: UTF8.self))
                cursor += len
                i += 1
            }
            if cursor != bytes.count {
                throw SpikingNetworkWeightsBinaryError.sizeMismatch(
                    expected: cursor, actual: bytes.count
                )
            }
            classLabels = labels
        }

        self.init(
            inputDim: inputDim,
            maxHiddenDim: maxHiddenDim,
            outputDim: outputDim,
            timeSteps: timeSteps,
            lifConfig: lif,
            wIn: wIn,
            wRec: wRec,
            bH: bH,
            wLayers: wLayers,
            bHLayers: bHLayers,
            gammaRMS: gammaRMS,
            wOut: wOut,
            bOut: bOut,
            classLabels: classLabels,
            readoutFrames: readoutFrames
        )
    }
}

// MARK: - バイト列のリトルエンディアン入出力 (stdlib のみ)

@inline(__always)
private func binaryPutU32(_ out: inout [UInt8], _ v: UInt32) {
    out.append(UInt8(truncatingIfNeeded: v))
    out.append(UInt8(truncatingIfNeeded: v >> 8))
    out.append(UInt8(truncatingIfNeeded: v >> 16))
    out.append(UInt8(truncatingIfNeeded: v >> 24))
}

@inline(__always)
private func binaryPutF32(_ out: inout [UInt8], _ v: Float) {
    binaryPutU32(&out, v.bitPattern)
}

/// float 配列をリトルエンディアンで連結する。
private func binaryPutFloats(_ out: inout [UInt8], _ values: [Float]) {
    var i = 0
    while i < values.count {
        binaryPutU32(&out, values[i].bitPattern)
        i += 1
    }
}

@inline(__always)
private func binaryGetU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    return UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

@inline(__always)
private func binaryGetF32(_ bytes: [UInt8], _ offset: Int) -> Float {
    return Float(bitPattern: binaryGetU32(bytes, offset))
}

/// offset から n 個の float32 を読む。呼び出し側が範囲を検証済みであること。
private func binaryGetFloats(_ bytes: [UInt8], _ offset: Int, _ n: Int) -> [Float] {
    var out = [Float](repeating: 0.0, count: n)
    bytes.withUnsafeBufferPointer { src in
        out.withUnsafeMutableBufferPointer { dst in
            var i = 0
            var p = offset
            while i < n {
                let bits = UInt32(src[p])
                    | (UInt32(src[p + 1]) << 8)
                    | (UInt32(src[p + 2]) << 16)
                    | (UInt32(src[p + 3]) << 24)
                dst[i] = Float(bitPattern: bits)
                p += 4
                i += 1
            }
        }
    }
    return out
}
