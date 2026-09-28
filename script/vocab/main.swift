import Foundation
import Spiketegaki

// Sources/Spiketegaki/Vocabulary/CharacterTable.swift の生成器。
//
// 漢字は JIS X 0208 第一水準 (区 16-47、JIS コード 0x3021 亜 〜 0x4F53 腕) を区・点で走査し、
// JIS -> Shift_JIS に変換してから Foundation の String(data:encoding: .shiftJIS) で復号する。
// 復号できない / 1 文字にならない / 重複する コードがあればエラー終了する (無視して進めない)。

/// 標準エラーへ出して exit 1。
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

/// JIS X 0208 の区点 (JIS バイト対 0x21..0x7E) を Shift_JIS の 2 バイトに変換する。
func jisToShiftJIS(high: Int, low: Int) -> (UInt8, UInt8) {
    var s1: Int
    var s2: Int
    if high % 2 == 1 {
        s1 = (high + 1) / 2 + 0x70
        s2 = low + 0x1F
        if s2 >= 0x7F {
            s2 += 1
        }
    } else {
        s1 = high / 2 + 0x70
        s2 = low + 0x7E
    }
    if s1 > 0x9F {
        s1 += 0x40
    }
    return (UInt8(s1), UInt8(s2))
}

/// 文字の列挙と重複検査。トップレベル変数は Swift 6 で MainActor 隔離になるので構造体に閉じる。
struct VocabularyBuilder {
    private(set) var scalars: [UInt32] = []
    private(set) var ranges: [(ScriptCategory, Range<Int>)] = []
    private var seen = Set<UInt32>()

    mutating func append(_ value: UInt32, context: String) {
        let hex = String(value, radix: 16, uppercase: true)
        if Unicode.Scalar(value) == nil {
            fail("U+\(hex) は妥当な Unicode スカラではない (\(context))")
        }
        if seen.contains(value) {
            fail("U+\(hex) が重複している (\(context))")
        }
        seen.insert(value)
        scalars.append(value)
    }

    mutating func appendRange(_ lo: UInt32, _ hi: UInt32, context: String) {
        appendRange(lo, hi, excluding: [], context: context)
    }

    /// `excluding` に含まれるコードポイントを飛ばしながら範囲を並べる。
    mutating func appendRange(
        _ lo: UInt32, _ hi: UInt32, excluding skip: Set<UInt32>, context: String
    ) {
        var v = lo
        while v <= hi {
            if !skip.contains(v) {
                append(v, context: context)
            }
            v += 1
        }
    }

    /// 直前の `startCategory` から現在までを 1 区分として閉じる。
    mutating func category(_ category: ScriptCategory, _ body: (inout VocabularyBuilder) -> Void) {
        let start = scalars.count
        body(&self)
        ranges.append((category, start ..< scalars.count))
    }

    var uniqueCount: Int {
        return seen.count
    }
}

/// 語彙から外す小書き仮名 (DESIGN.md §4、2026-09-28 決定)。
/// 手書きでは「大きさだけが手掛かり」で親字と分離できないため、認識器は親字として返す。
/// コードポイントの集合なのでソースに書いてよい (フォント名ではない)。
let smallHiragana: Set<UInt32> = [
    0x3041,  // ぁ
    0x3043,  // ぃ
    0x3045,  // ぅ
    0x3047,  // ぇ
    0x3049,  // ぉ
    0x3063,  // っ
    0x3083,  // ゃ
    0x3085,  // ゅ
    0x3087,  // ょ
    0x308E,  // ゎ
    0x3095,  // ゕ
    0x3096,  // ゖ
]

/// 語彙から外す小書き片仮名 12 字。`smallHiragana` と対になる。
let smallKatakana: Set<UInt32> = [
    0x30A1,  // ァ
    0x30A3,  // ィ
    0x30A5,  // ゥ
    0x30A7,  // ェ
    0x30A9,  // ォ
    0x30C3,  // ッ
    0x30E3,  // ャ
    0x30E5,  // ュ
    0x30E7,  // ョ
    0x30EE,  // ヮ
    0x30F5,  // ヵ
    0x30F6,  // ヶ
]

func buildVocabulary() -> VocabularyBuilder {
    var b = VocabularyBuilder()

    // digits: U+0030-U+0039
    b.category(.digits) { $0.appendRange(0x30, 0x39, context: "digits") }

    // ascii-symbols: U+0021-U+002F, U+003A-U+0040, U+005B-U+0060, U+007B-U+007E (計 32)
    // 空白 (U+0020) は含めない
    b.category(.asciiSymbols) {
        $0.appendRange(0x21, 0x2F, context: "ascii-symbols")
        $0.appendRange(0x3A, 0x40, context: "ascii-symbols")
        $0.appendRange(0x5B, 0x60, context: "ascii-symbols")
        $0.appendRange(0x7B, 0x7E, context: "ascii-symbols")
    }

    // latin-upper: U+0041-U+005A
    b.category(.latinUpper) { $0.appendRange(0x41, 0x5A, context: "latin-upper") }

    // latin-lower: U+0061-U+007A
    b.category(.latinLower) { $0.appendRange(0x61, 0x7A, context: "latin-lower") }

    // hiragana: U+3041-U+3096 から小書き 12 字 (ぁぃぅぇぉっゃゅょゎゕゖ) を除いた 74 字
    b.category(.hiragana) {
        $0.appendRange(0x3041, 0x3096, excluding: smallHiragana, context: "hiragana")
    }

    // katakana: U+30A1-U+30FA, U+30FC (ー) から小書き 12 字 (ァィゥェォッャュョヮヵヶ) を
    // 除いた 79 字
    b.category(.katakana) {
        $0.appendRange(0x30A1, 0x30FA, excluding: smallKatakana, context: "katakana")
        $0.append(0x30FC, context: "katakana")
    }

    // kanji-level1: JIS 0x3021 (亜) 〜 0x4F53 (腕)。区 16-47 を 1 区 94 点ずつ走査する。
    let jisFirst = 0x3021
    let jisLast = 0x4F53
    b.category(.kanjiLevel1) { builder in
        var ku = 16
        while ku <= 47 {
            let high = 0x20 + ku
            var ten = 1
            while ten <= 94 {
                let low = 0x20 + ten
                let code = high << 8 | low
                if code < jisFirst || code > jisLast {
                    ten += 1
                    continue
                }
                let (s1, s2) = jisToShiftJIS(high: high, low: low)
                let codeHex = String(code, radix: 16, uppercase: true)
                let sjisHex = String(format: "%02X%02X", Int(s1), Int(s2))
                guard let decoded = String(data: Data([s1, s2]), encoding: .shiftJIS) else {
                    fail("JIS 0x\(codeHex) (区 \(ku) 点 \(ten), SJIS \(sjisHex)) を Shift_JIS から復号できない")
                }
                if decoded.unicodeScalars.count != 1 {
                    fail("JIS 0x\(codeHex) が 1 スカラにならない: \"\(decoded)\" (\(decoded.unicodeScalars.count) スカラ)")
                }
                builder.append(decoded.unicodeScalars.first!.value, context: "kanji JIS 0x\(codeHex)")
                ten += 1
            }
            ku += 1
        }
    }
    return b
}

/// CharacterTable.swift のソースを組み立てる。
func renderSource(_ b: VocabularyBuilder) -> String {
    var source = ""
    source += "// script/vocab が生成。手編集禁止。\n"
    source += "// 変更が必要なら script/vocab/main.swift を直して `swift run -c release vocab` で作り直す。\n"
    source += "// index はここでの並びと 1 対 1 に対応し、学習済み重みと結びつく。\n"
    source += "\n"
    source += "public enum CharacterTable {\n"
    source += "    /// 全 \(b.scalars.count) 文字の Unicode スカラ値 (クラス index 順)\n"
    source += "    public static let scalars: [UInt32] = [\n"

    // 1 行 8 要素。型注釈が明示されているので単一のリテラルでも型検査は線形。
    var line = ""
    var column = 0
    var i = 0
    while i < b.scalars.count {
        if column == 0 {
            line = "        "
        } else {
            line += " "
        }
        line += "0x" + String(b.scalars[i], radix: 16, uppercase: true)
        if i != b.scalars.count - 1 {
            line += ","
        }
        column += 1
        if column == 8 {
            source += line + "\n"
            column = 0
        }
        i += 1
    }
    if column != 0 {
        source += line + "\n"
    }
    source += "    ]\n"
    source += "\n"
    source += "    /// 区分とその index 範囲 (scalars と同じ並び順)\n"
    source += "    public static let categoryRanges: [(ScriptCategory, Range<Int>)] = [\n"
    for (category, r) in b.ranges {
        source += "        (.\(category.rawValue), \(r.lowerBound) ..< \(r.upperBound)),\n"
    }
    source += "    ]\n"
    source += "}\n"
    return source
}

func run() {
    let b = buildVocabulary()

    // 検証 (テストが確認する事実を生成器自身でも確かめる)
    if b.scalars.count != b.uniqueCount {
        fail("重複検出: \(b.scalars.count) 文字中ユニークは \(b.uniqueCount)")
    }
    guard let kanji = b.ranges.first(where: { $0.0 == .kanjiLevel1 })?.1 else {
        fail("kanjiLevel1 の区分が無い")
    }
    let firstKanji = Character(Unicode.Scalar(b.scalars[kanji.lowerBound])!)
    let lastKanji = Character(Unicode.Scalar(b.scalars[kanji.upperBound - 1])!)
    if firstKanji != "亜" {
        fail("漢字の先頭が \"亜\" でなく \"\(firstKanji)\"")
    }
    if lastKanji != "腕" {
        fail("漢字の末尾が \"腕\" でなく \"\(lastKanji)\"")
    }
    var covered = 0
    for (_, r) in b.ranges {
        covered += r.count
    }
    if covered != b.scalars.count {
        fail("区分の合計 \(covered) が総数 \(b.scalars.count) と一致しない")
    }
    // 小書き仮名 24 字が 1 つも残っていないこと (DESIGN.md §4)
    let small = smallHiragana.union(smallKatakana)
    for v in b.scalars where small.contains(v) {
        fail("小書き仮名 U+\(String(v, radix: 16, uppercase: true)) が語彙に残っている")
    }

    // 出力先: 引数があればそれ、無ければパッケージ内の所定位置
    let outputPath: String
    if CommandLine.arguments.count > 1 {
        outputPath = CommandLine.arguments[1]
    } else {
        // script/vocab/main.swift からパッケージルートへ 3 つ上がる
        let here = URL(fileURLWithPath: #filePath)
        let root = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        outputPath = root
            .appendingPathComponent("Sources/Spiketegaki/Vocabulary/CharacterTable.swift")
            .path
    }

    do {
        try renderSource(b).write(toFile: outputPath, atomically: true, encoding: .utf8)
    } catch {
        fail("\(outputPath) に書けない: \(error)")
    }

    print("vocab (spiketegaki \(Spiketegaki.version))")
    for (category, r) in b.ranges {
        let first = Character(Unicode.Scalar(b.scalars[r.lowerBound])!)
        let last = Character(Unicode.Scalar(b.scalars[r.upperBound - 1])!)
        let name = category.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
        let countText = String(format: "%5d", r.count)
        print("  \(name) \(countText) 文字  index \(r.lowerBound)..<\(r.upperBound)  \"\(first)\" 〜 \"\(last)\"")
    }
    print("  合計         \(String(format: "%5d", b.scalars.count)) 文字 (重複なし)")
    print("  出力: \(outputPath)")
}

run()
exit(0)
