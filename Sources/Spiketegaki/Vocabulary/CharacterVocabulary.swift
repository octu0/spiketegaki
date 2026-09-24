import Foundation

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

public enum CharacterVocabularyError: Error, Equatable {
    /// index がクラス範囲外
    case indexOutOfRange(index: Int, count: Int)
}

/// 文字 ↔ クラス index の対応。
///
/// 並び順は学習済み重みと結びつくので固定。実体は `script/vocab` が生成した
/// `CharacterTable` で、このコードは検索テーブルを組むだけ。
public struct CharacterVocabulary: Sendable {
    /// 毎回 3236 要素の辞書を作らないための共有インスタンス。
    public static let shared = CharacterVocabulary()

    private let characters: [Character]
    private let indexByCharacter: [Character: Int]
    private let ranges: [(category: ScriptCategory, range: Range<Int>)]

    public init() {
        var chars = [Character]()
        chars.reserveCapacity(CharacterTable.scalars.count)
        var table = [Character: Int](minimumCapacity: CharacterTable.scalars.count)
        var i = 0
        while i < CharacterTable.scalars.count {
            // 生成器が Unicode スカラとして妥当な値だけを書き出している
            let scalar = Unicode.Scalar(CharacterTable.scalars[i])!
            let c = Character(scalar)
            chars.append(c)
            table[c] = i
            i += 1
        }
        self.characters = chars
        self.indexByCharacter = table
        self.ranges = CharacterTable.categoryRanges.map { (category: $0.0, range: $0.1) }
    }

    /// クラス数 (全区分の合計)
    public var count: Int {
        return characters.count
    }

    /// 語彙に無ければ nil。
    public func index(of character: Character) -> Int? {
        return indexByCharacter[character]
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

    /// 文字の区分。語彙に無ければ nil。
    public func category(of character: Character) -> ScriptCategory? {
        guard let i = index(of: character) else {
            return nil
        }
        return category(of: i)
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
