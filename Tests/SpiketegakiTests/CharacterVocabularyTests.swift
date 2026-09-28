import XCTest
@testable import Spiketegaki

final class CharacterVocabularyTests: XCTestCase {
    private let vocab = CharacterVocabulary.shared

    /// 文字 → index の逆引き。推論・学習の経路は index → 文字しか使わないので、
    /// 語彙の中身を確かめるためのこの表はテスト側で組む。
    private let indexByCharacter: [Character: Int] = {
        var table = [Character: Int](minimumCapacity: CharacterVocabulary.shared.count)
        var i = 0
        let all = CharacterVocabulary.shared.allCharacters
        while i < all.count {
            table[all[i]] = i
            i += 1
        }
        return table
    }()

    /// 文字の区分。語彙に無ければ nil。
    private func category(of character: Character) -> ScriptCategory? {
        guard let i = indexByCharacter[character] else {
            return nil
        }
        return vocab.category(of: i)
    }

    // MARK: - 総数と区分ごとの件数

    func testTotalCount() {
        XCTAssertEqual(vocab.count, 3212)
        XCTAssertEqual(CharacterTable.scalars.count, 3212)
    }

    func testCategoryCountsMatchTheDesignTable() {
        let expected: [(ScriptCategory, Int)] = [
            (.digits, 10),
            (.asciiSymbols, 32),
            (.latinUpper, 26),
            (.latinLower, 26),
            (.hiragana, 74),
            (.katakana, 79),
            (.kanjiLevel1, 2965)
        ]
        var total = 0
        for (category, count) in expected {
            XCTAssertEqual(vocab.range(of: category).count, count, "\(category.rawValue) の件数が表と違う")
            total += count
        }
        XCTAssertEqual(total, 3212)
        XCTAssertEqual(total, vocab.count)
    }

    func testCategoryRangesAreContiguousAndCoverEverything() {
        // 表の順序どおりに隙間なく並ぶ
        let order: [ScriptCategory] = [
            .digits, .asciiSymbols, .latinUpper, .latinLower, .hiragana, .katakana, .kanjiLevel1
        ]
        XCTAssertEqual(CharacterTable.categoryRanges.map { $0.0 }, order)
        var cursor = 0
        for category in order {
            let r = vocab.range(of: category)
            XCTAssertEqual(r.lowerBound, cursor, "\(category.rawValue) の開始が連続していない")
            cursor = r.upperBound
        }
        XCTAssertEqual(cursor, vocab.count)
    }

    // MARK: - 個々の文字

    func testDigitsStartAtIndexZero() {
        XCTAssertEqual(indexByCharacter["0"], 0)
        XCTAssertEqual(vocab.character(at: 0), "0")
        XCTAssertEqual(indexByCharacter["9"], 9)
        XCTAssertEqual(vocab.category(of: 0), .digits)
        XCTAssertEqual(category(of: "5"), .digits)
    }

    func testTildeIsAnAsciiSymbol() {
        let i = try? XCTUnwrap(indexByCharacter["~"])
        XCTAssertNotNil(i)
        XCTAssertEqual(category(of: "~"), .asciiSymbols)
        // ascii-symbols の末尾が "~"
        let r = vocab.range(of: .asciiSymbols)
        XCTAssertEqual(vocab.character(at: r.upperBound - 1), "~")
        XCTAssertEqual(vocab.character(at: r.lowerBound), "!")
    }

    func testLatinCategories() {
        XCTAssertEqual(category(of: "A"), .latinUpper)
        XCTAssertEqual(category(of: "Z"), .latinUpper)
        XCTAssertEqual(category(of: "a"), .latinLower)
        XCTAssertEqual(category(of: "z"), .latinLower)
        XCTAssertNotEqual(indexByCharacter["A"], indexByCharacter["a"])
    }

    func testHiraganaAndKatakana() {
        XCTAssertEqual(category(of: "あ"), .hiragana)
        XCTAssertEqual(category(of: "ゔ"), .hiragana)
        XCTAssertEqual(category(of: "ア"), .katakana)
        // 長音符 (U+30FC) は katakana に入れる
        XCTAssertEqual(category(of: "ー"), .katakana)
        let k = vocab.range(of: .katakana)
        XCTAssertEqual(vocab.character(at: k.lowerBound), "ア")
        XCTAssertEqual(vocab.character(at: k.upperBound - 1), "ー")
        let h = vocab.range(of: .hiragana)
        XCTAssertEqual(vocab.character(at: h.lowerBound), "あ")
        XCTAssertEqual(vocab.character(at: h.upperBound - 1), "ゔ")
    }

    /// 小書き仮名 24 字は語彙に無い (DESIGN.md §4、2026-09-28 決定)。
    /// 手書きでは大きさだけが手掛かりで親字と分離できないため、認識器は親字として返す。
    func testSmallKanaAreNotInTheVocabulary() {
        let small: [Character] = Array("ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶ")
        XCTAssertEqual(small.count, 24)
        for c in small {
            XCTAssertNil(indexByCharacter[c], "小書き \(c) が語彙に残っている")
        }
        // 対応する親字はすべて残っている
        for c in Array("あいうえおつやゆよわかけアイウエオツヤユヨワカケ") {
            XCTAssertNotNil(indexByCharacter[c], "親字 \(c) が語彙から消えている")
        }
        // ひらがな・カタカナの区分は小書きを抜いた 74 / 79 字
        XCTAssertEqual(vocab.range(of: .hiragana).count, 86 - 12)
        XCTAssertEqual(vocab.range(of: .katakana).count, 91 - 12)
    }

    func testKanjiFirstAndLast() {
        let r = vocab.range(of: .kanjiLevel1)
        XCTAssertEqual(r.count, 2965)
        XCTAssertEqual(vocab.character(at: r.lowerBound), "亜")
        XCTAssertEqual(vocab.character(at: r.upperBound - 1), "腕")
        XCTAssertEqual(vocab.character(at: vocab.count - 1), "腕")
        XCTAssertEqual(category(of: "亜"), .kanjiLevel1)
        XCTAssertEqual(category(of: "腕"), .kanjiLevel1)
    }

    func testSomeWellKnownKanjiArePresent() {
        for c: Character in ["日", "本", "語", "一", "人", "手", "書", "認", "識", "文", "字"] {
            XCTAssertNotNil(indexByCharacter[c], "\(c) が語彙に無い")
            XCTAssertEqual(category(of: c), .kanjiLevel1, "\(c) が kanjiLevel1 でない")
        }
    }

    // MARK: - 重複と往復

    func testNoDuplicates() {
        XCTAssertEqual(Set(vocab.allCharacters).count, vocab.count, "重複した文字がある")
        XCTAssertEqual(Set(CharacterTable.scalars).count, CharacterTable.scalars.count)
    }

    func testIndexAndCharacterRoundTripForEveryClass() {
        var i = 0
        while i < vocab.count {
            let c = vocab.character(at: i)
            XCTAssertEqual(indexByCharacter[c], i, "index \(i) (\(c)) の往復が壊れている")
            i += 1
        }
    }

    func testEveryIndexHasACategory() {
        var counts = [ScriptCategory: Int]()
        var i = 0
        while i < vocab.count {
            counts[vocab.category(of: i), default: 0] += 1
            i += 1
        }
        XCTAssertEqual(counts[.digits], 10)
        XCTAssertEqual(counts[.asciiSymbols], 32)
        XCTAssertEqual(counts[.latinUpper], 26)
        XCTAssertEqual(counts[.latinLower], 26)
        XCTAssertEqual(counts[.hiragana], 74)
        XCTAssertEqual(counts[.katakana], 79)
        XCTAssertEqual(counts[.kanjiLevel1], 2965)
    }

    // MARK: - 含まれないもの

    func testExcludedCharacters() {
        // 空白は含めない
        XCTAssertNil(indexByCharacter[" "])
        XCTAssertNil(indexByCharacter["　"])  // 全角空白
        XCTAssertNil(indexByCharacter["\n"])
        // 第二水準の漢字 (JIS 区 48 以降) は含めない
        XCTAssertNil(indexByCharacter["弌"], "第二水準の \"弌\" が入っている")
        XCTAssertNil(indexByCharacter["鎔"], "第二水準の \"鎔\" が入っている")
        // JIS 記号 (区 1-2) も含めない
        XCTAssertNil(indexByCharacter["、"])
        XCTAssertNil(indexByCharacter["○"])
        // 濁点付き平仮名は U+3041-U+3096 の範囲内なので含まれる
        XCTAssertNotNil(indexByCharacter["が"])
    }

    // MARK: - 生成済みテーブルの妥当性

    func testAllScalarsAreValidSingleScalarCharacters() {
        for value in CharacterTable.scalars {
            XCTAssertNotNil(Unicode.Scalar(value), "U+\(String(value, radix: 16, uppercase: true)) が不正")
        }
        for c in vocab.allCharacters {
            XCTAssertEqual(c.unicodeScalars.count, 1, "\(c) が単一スカラでない")
        }
    }

    /// 生成器を使わずに Shift_JIS 変換を再現し、漢字部分が一致することを確かめる。
    func testKanjiMatchAnIndependentShiftJISScan() {
        var expected = [Character]()
        var ku = 16
        while ku <= 47 {
            let high = 0x20 + ku
            var ten = 1
            while ten <= 94 {
                let low = 0x20 + ten
                let code = high << 8 | low
                if code < 0x3021 || code > 0x4F53 {
                    ten += 1
                    continue
                }
                var s1: Int
                var s2: Int
                if high % 2 == 1 {
                    s1 = (high + 1) / 2 + 0x70
                    s2 = low + 0x1F
                    if s2 >= 0x7F { s2 += 1 }
                } else {
                    s1 = high / 2 + 0x70
                    s2 = low + 0x7E
                }
                if s1 > 0x9F { s1 += 0x40 }
                let data = Data([UInt8(s1), UInt8(s2)])
                guard let decoded = String(data: data, encoding: .shiftJIS), decoded.count == 1 else {
                    XCTFail("JIS 0x\(String(code, radix: 16)) を復号できない")
                    ten += 1
                    continue
                }
                expected.append(decoded.first!)
                ten += 1
            }
            ku += 1
        }
        XCTAssertEqual(expected.count, 2965)
        let r = vocab.range(of: .kanjiLevel1)
        XCTAssertEqual(Array(vocab.allCharacters[r]), expected)
    }

    // MARK: - 生成式を使わない固定の照合表

    /// 区分ごとの件数から手で引いた index を、文字リテラルと整数リテラルで直に書いた照合表。
    ///
    /// `testKanjiMatchAnIndependentShiftJISScan` は `script/vocab` と同じ JIS→Shift_JIS 変換式を
    /// 書き写しているため、変換式そのものが間違っていれば両方が同じように間違える。
    /// この表は式を一切使わず、区分順と件数だけから決まる値を固定値で持つ。
    /// (Wave 1 監査 §6-4 の指摘への対応)
    ///
    /// 区分の開始 index は §4 の件数の累積:
    ///   digits 0 / ascii-symbols 10 / latin-upper 42 / latin-lower 68 /
    ///   hiragana 94 / katakana 168 / kanji-level1 247 (= 10+32+26+26+74+79)、末尾 3211。
    ///   (2026-09-28 に小書き仮名 24 字を語彙から外したので hiragana 86→74、katakana 91→79。)
    ///
    /// 漢字の 4 点 (唖 / 蔭 / 院 / 翠) は Python の `euc_jp` コーデックで JIS 0x3021–0x4F53 を
    /// 独立に列挙して求めた値で、リポジトリのコードは一切使っていない。
    func testFixedLookupTable() {
        let table: [(Character, Int)] = [
            // digits (0–9): 先頭と末尾
            ("0", 0),
            ("9", 9),
            // ascii-symbols (10–41): U+0021–U+002F, U+003A–U+0040, U+005B–U+0060, U+007B–U+007E
            ("!", 10),      // U+0021 区分の先頭
            ("/", 24),      // U+002F 1 つ目の連続範囲の末尾 (10 + 14)
            (":", 25),      // U+003A 2 つ目の連続範囲の先頭
            ("@", 31),      // U+0040 2 つ目の末尾 (25 + 6)
            ("[", 32),      // U+005B 3 つ目の先頭
            ("`", 37),      // U+0060 3 つ目の末尾 (32 + 5)
            ("{", 38),      // U+007B 4 つ目の先頭
            ("~", 41),      // U+007E 区分の末尾 (38 + 3)
            // latin-upper (42–67)
            ("A", 42),
            ("Z", 67),
            // latin-lower (68–93)
            ("a", 68),
            ("z", 93),
            // hiragana (94–167): U+3041–U+3096 から小書き 12 字を除いた 74 字
            ("あ", 94),      // U+3042 区分の先頭 (ぁ U+3041 は外した)
            ("い", 95),      // U+3044 (ぃ U+3043 は外した)
            ("ん", 166),     // U+3093
            ("ゔ", 167),     // U+3094 区分の末尾 (ゕ U+3095 / ゖ U+3096 は外した)
            // katakana (168–246): U+30A1–U+30FA と U+30FC から小書き 12 字を除いた 79 字
            ("ア", 168),     // U+30A2 区分の先頭 (ァ U+30A1 は外した)
            ("イ", 169),     // U+30A4
            ("ヺ", 245),     // U+30FA
            ("ー", 246),     // U+30FC 区分の末尾 (長音符は最後に足す)
            // kanji-level1 (247–3211)
            ("亜", 247),     // JIS 0x3021 区分の先頭
            ("唖", 248),     // JIS 0x3022
            ("蔭", 340),     // JIS 0x307E 区 16 の末尾 (247 + 93)
            ("院", 341),     // JIS 0x3121 区 17 の先頭
            ("翠", 1729),    // JIS 0x3F69
            ("碗", 3210),    // JIS 0x4F52
            ("腕", 3211)     // JIS 0x4F53 区分の末尾 = 語彙の末尾
        ]
        XCTAssertGreaterThanOrEqual(table.count, 12)

        for (character, expectedIndex) in table {
            XCTAssertEqual(indexByCharacter[character], expectedIndex, "\(character) の index が違う")
            XCTAssertEqual(vocab.character(at: expectedIndex), character, "character(at: \(expectedIndex)) が違う")
        }
    }

    /// 固定値で区分の境界を押さえる (件数の累積が §4 の表と合っていること)。
    func testFixedCategoryBoundaries() {
        let expected: [(ScriptCategory, Int, Int)] = [
            (.digits, 0, 10),
            (.asciiSymbols, 10, 42),
            (.latinUpper, 42, 68),
            (.latinLower, 68, 94),
            (.hiragana, 94, 168),
            (.katakana, 168, 247),
            (.kanjiLevel1, 247, 3212)
        ]
        for (category, lower, upper) in expected {
            XCTAssertEqual(vocab.range(of: category), lower ..< upper, "\(category.rawValue) の範囲が違う")
        }
        // 固定 index からの区分の引き当て
        XCTAssertEqual(vocab.category(of: 0), .digits)
        XCTAssertEqual(vocab.category(of: 41), .asciiSymbols)
        XCTAssertEqual(vocab.category(of: 42), .latinUpper)
        XCTAssertEqual(vocab.category(of: 93), .latinLower)
        XCTAssertEqual(vocab.category(of: 94), .hiragana)
        XCTAssertEqual(vocab.category(of: 246), .katakana)
        XCTAssertEqual(vocab.category(of: 247), .kanjiLevel1)
        XCTAssertEqual(vocab.category(of: 3211), .kanjiLevel1)
    }

    func testFreshInstanceMatchesShared() {
        let fresh = CharacterVocabulary()
        XCTAssertEqual(fresh.count, vocab.count)
        XCTAssertEqual(fresh.allCharacters, vocab.allCharacters)
    }
}
