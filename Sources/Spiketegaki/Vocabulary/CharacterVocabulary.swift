/// 文字集合の区分。index の並び順もこの順序。
public enum ScriptCategory: String, Sendable, Equatable, CaseIterable {
    case digits
    case asciiSymbols
    case latinUpper
    case latinLower
    case hiragana
    case katakana
    case kanjiLevel1
}

/// 文字 ↔ クラス index の対応。
///
/// 並び順は学習済み重みと結びつくので固定。実体は `script/vocab` が生成した
/// `CharacterTable` で、このコードは検索テーブルを組むだけ。
public struct CharacterVocabulary: Sendable {
    /// 毎回数千要素の配列を作らないための共有インスタンス。
    public static let shared = CharacterVocabulary()

    private let characters: [Character]
    private let ranges: [(category: ScriptCategory, range: Range<Int>)]

    public init() {
        var chars = [Character]()
        chars.reserveCapacity(CharacterTable.scalars.count)
        var i = 0
        while i < CharacterTable.scalars.count {
            // 生成器が Unicode スカラとして妥当な値だけを書き出している
            let scalar = Unicode.Scalar(CharacterTable.scalars[i])!
            chars.append(Character(scalar))
            i += 1
        }
        self.characters = chars
        self.ranges = CharacterTable.categoryRanges.map { (category: $0.0, range: $0.1) }
    }

    /// クラス数 (全区分の合計)
    public var count: Int {
        return characters.count
    }

    /// index の文字。範囲外はプログラミング誤りとして停止する (`characters` は固定長)。
    public func character(at index: Int) -> Character {
        precondition(index >= 0 && index < characters.count, "index \(index) が語彙 \(characters.count) の範囲外")
        return characters[index]
    }

    /// index の区分。範囲外は停止する。
    public func category(of index: Int) -> ScriptCategory {
        precondition(index >= 0 && index < characters.count, "index \(index) が語彙 \(characters.count) の範囲外")
        var i = 0
        while i < ranges.count {
            if ranges[i].range.contains(index) {
                return ranges[i].category
            }
            i += 1
        }
        // categoryRanges は語彙全体を隙間なく覆う (生成器が保証する)
        preconditionFailure("index \(index) を覆う区分が CharacterTable.categoryRanges に無い")
    }

    /// 区分が占める index 範囲。
    public func range(of category: ScriptCategory) -> Range<Int> {
        var i = 0
        while i < ranges.count {
            if ranges[i].category == category {
                return ranges[i].range
            }
            i += 1
        }
        return 0 ..< 0
    }

    /// 全文字 (index 順)。
    public var allCharacters: [Character] {
        return characters
    }
}
