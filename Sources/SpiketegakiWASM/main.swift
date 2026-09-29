// ブラウザ / node から呼ぶ wasm の窓口。C ABI (@_cdecl) だけを公開する。
//
// 入力のグレースケールは **墨の濃さ** (0 = 白 / 紙、255 = 黒 / 墨) で渡す。
// DatasetFile のサンプル画素とまったく同じ向きなので、評価データをそのまま流し込める。
// `ImageNormalizer` へは `invert: false` (値がそのまま墨の濃さ) で渡す。
// 白地黒字の普通のグレースケール (255 = 白) を持っている呼び出し側は、渡す前に 255 - v にする。
//
// macOS ビルドでは中身を空にして、パッケージ全体の build / test が通るようにしている。
#if os(WASI)

import Spiketegaki

/// 戻り値のエラーコード (負の値がエラー)。
enum StatusCode {
    static let ok: Int32 = 0
    /// 引数が不正 (null ポインタ、幅・高さ・長さが 0 以下、topK が 0 以下、区分マスクに未定義のビット)
    static let invalidArgument: Int32 = -1
    /// 重みがまだ読み込まれていない
    static let weightsNotLoaded: Int32 = -2
    /// 重みのバイト列が STGW として壊れている
    static let invalidWeights: Int32 = -3
    /// 重みの次元が語彙・フレーム次元と合わない
    static let incompatibleWeights: Int32 = -4
    /// 分類の途中で失敗した
    static let classifyFailed: Int32 = -5
    /// 直前の分類結果がまだ無い
    static let noPreviousResult: Int32 = -6
}

/// `stg_classify` の区分マスク。ビットが立った区分だけを候補にする。
/// 0 は「全部」。定義されていないビットが立っていたら不正な引数として弾く。
enum ScriptMask {
    /// bit0 digits / bit1 ascii / bit2 latinUpper / bit3 latinLower /
    /// bit4 hiragana / bit5 katakana / bit6 kanji
    static let bits: [(bit: Int32, category: ScriptCategory)] = [
        (1 << 0, .digits),
        (1 << 1, .asciiSymbols),
        (1 << 2, .latinUpper),
        (1 << 3, .latinLower),
        (1 << 4, .hiragana),
        (1 << 5, .katakana),
        (1 << 6, .kanjiLevel1)
    ]

    static let all: Int32 = (1 << 7) - 1

    /// マスクを区分の集合にする。全ビットが立っていれば 0 と同じ空集合 (= 全部)。
    /// 未定義のビットが立っている / 負のときは nil。
    static func categories(_ mask: Int32) -> Set<ScriptCategory>? {
        if mask < 0 || (mask & ~all) != 0 {
            return nil
        }
        if mask == 0 || mask == all {
            return []
        }
        var out = Set<ScriptCategory>()
        for entry in bits where (mask & entry.bit) != 0 {
            out.insert(entry.category)
        }
        return out
    }
}

/// プロセスに 1 つだけ持つ状態。
///
/// main.swift のトップレベル変数は `_start` の中で初期化されるが、
/// 型の static は初回アクセス時に初期化される。エクスポート関数がいつ呼ばれても
/// 初期化済みになるよう static で持つ。
enum Demo {
    nonisolated(unsafe) static var classifier: CharacterClassifier?
    /// 直前に分類した 32x32 の正規化結果 (0 = 紙, 255 = 墨)
    nonisolated(unsafe) static var lastNormalized: [UInt8]?
    /// 直前の分類にかかった時間 (マイクロ秒)。正規化・符号化・SNN forward を含む
    nonisolated(unsafe) static var lastMicros: Int64 = 0
}

// MARK: - メモリ

/// wasm の線形メモリを `size` バイト確保して先頭アドレスを返す。
///
/// 解放する関数は持たない。呼び出し側は用途ごとに 1 回だけ確保して使い回すこと。
@_cdecl("stg_alloc")
public func stg_alloc(_ size: Int32) -> UnsafeMutableRawPointer? {
    if size <= 0 {
        return nil
    }
    return UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
}

// MARK: - 重み

/// STGW v1 のバイト列を読み込んで分類器を作る。成功で 0、失敗で負の値。
@_cdecl("stg_load_weights")
public func stg_load_weights(_ ptr: UnsafeRawPointer?, _ len: Int32) -> Int32 {
    guard let ptr = ptr, len > 0 else {
        return StatusCode.invalidArgument
    }
    let bytes = [UInt8](UnsafeRawBufferPointer(start: ptr, count: Int(len)))
    let weights: SpikingNetworkWeights
    do {
        weights = try SpikingNetworkWeights(binary: bytes)
    } catch {
        return StatusCode.invalidWeights
    }
    let vocabulary = CharacterVocabulary.shared
    if weights.outputDim != vocabulary.count || weights.inputDim != ScanlineEncoder.frameDim {
        return StatusCode.incompatibleWeights
    }
    do {
        Demo.classifier = try CharacterClassifier(
            network: SpikingNetwork(weights: weights),
            vocabulary: vocabulary
        )
    } catch {
        return StatusCode.incompatibleWeights
    }
    Demo.lastNormalized = nil
    Demo.lastMicros = 0
    return StatusCode.ok
}

// MARK: - 分類

/// マス目 1 つ分のグレースケール (width x height、0 = 紙、255 = 墨) を分類する。
///
/// `scriptMask` は候補にする区分のビットマスク (`ScriptMask`)。0 なら全区分。
/// 指定した区分の外は softmax の前に除かれるので、候補も確率もその区分の中だけになる。
///
/// `outIndex` に topK 個の Int32 クラス index、`outProb` に topK 個の Float 確率を書く。
/// 戻り値は実際に書いた件数。負の値はエラー。
@_cdecl("stg_classify")
public func stg_classify(
    _ gray: UnsafeRawPointer?,
    _ width: Int32,
    _ height: Int32,
    _ topK: Int32,
    _ scriptMask: Int32,
    _ outIndex: UnsafeMutableRawPointer?,
    _ outProb: UnsafeMutableRawPointer?
) -> Int32 {
    guard let gray = gray, let outIndex = outIndex, let outProb = outProb else {
        return StatusCode.invalidArgument
    }
    if width <= 0 || height <= 0 || topK <= 0 {
        return StatusCode.invalidArgument
    }
    guard let categories = ScriptMask.categories(scriptMask) else {
        return StatusCode.invalidArgument
    }
    guard let classifier = Demo.classifier else {
        return StatusCode.weightsNotLoaded
    }

    let count = Int(width) * Int(height)
    let pixels = [UInt8](UnsafeRawBufferPointer(start: gray, count: count))

    let clock = ContinuousClock()
    let started = clock.now

    let image: CharacterImage
    let top: [(character: Character, index: Int, probability: Float)]
    do {
        // 入力の値がそのまま墨の濃さ (255 = 墨) なので反転しない
        image = try ImageNormalizer.normalize(
            width: Int(width), height: Int(height), gray: pixels, invert: false
        )
        top = try classifier.classify(image: image, topK: Int(topK), categories: categories)
    } catch {
        return StatusCode.classifyFailed
    }

    let elapsed = clock.now - started
    let components = elapsed.components
    Demo.lastMicros = components.seconds &* 1_000_000
        &+ Int64(components.attoseconds / 1_000_000_000_000)
    Demo.lastNormalized = image.asUInt8()

    let indexPtr = outIndex.assumingMemoryBound(to: Int32.self)
    let probPtr = outProb.assumingMemoryBound(to: Float.self)
    var i = 0
    while i < top.count {
        indexPtr[i] = Int32(top[i].index)
        probPtr[i] = top[i].probability
        i += 1
    }
    return Int32(top.count)
}

// MARK: - 結果の取り出し

/// クラス index の Unicode スカラ値。範囲外は 0 を返す。
@_cdecl("stg_char")
public func stg_char(_ index: Int32) -> UInt32 {
    let vocabulary = CharacterVocabulary.shared
    if index < 0 || Int(index) >= vocabulary.count {
        return 0
    }
    let character = vocabulary.character(at: Int(index))
    guard let scalar = character.unicodeScalars.first else {
        return 0
    }
    return scalar.value
}

/// 直前の分類で使った 32x32 の正規化結果を UInt8 (0 = 紙, 255 = 墨) で書き出す。
/// 書いたバイト数 (1024) を返す。分類がまだなら負の値。
@_cdecl("stg_last_normalized")
public func stg_last_normalized(_ ptr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = ptr else {
        return StatusCode.invalidArgument
    }
    guard let normalized = Demo.lastNormalized else {
        return StatusCode.noPreviousResult
    }
    let dst = ptr.assumingMemoryBound(to: UInt8.self)
    var i = 0
    while i < normalized.count {
        dst[i] = normalized[i]
        i += 1
    }
    return Int32(normalized.count)
}

/// 直前の分類にかかった時間 (マイクロ秒)。分類がまだなら 0。
@_cdecl("stg_last_micros")
public func stg_last_micros() -> Int64 {
    return Demo.lastMicros
}

#endif
