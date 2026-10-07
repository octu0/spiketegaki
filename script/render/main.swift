import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Spiketegaki

// フォント → グリフ描画 → ImageNormalizer → Augmenter → DatasetFile。
// CoreText / CoreGraphics を使うのはこのターゲットだけ (推論ライブラリはフォントに依存しない)。
//
// 「豆腐」(.notdef) とフォールバック描画を学習データに入れないため、次の 3 段で弾く:
//   1. フォントの取得時に PostScript 名が要求と一致するか / ファイル URL が一致するかを見る
//   2. 文字ごとに CTFontGetGlyphsForCharacters が true かつ glyph != 0 か見る
//   3. 描いた結果に墨が 1 画素も無ければ捨てる

// MARK: - ログ

func logLine(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

// MARK: - 引数

struct Options {
    var outDir = ".tmp/datasets"
    var name = "dataset"
    var fontsDir = ".tmp/fonts"
    /// nil = 明示指定なし。その場合は <fonts-dir>/system-fonts.txt から読む。
    var systemFonts: [String]?
    var holdoutFonts: [String] = []
    var scripts: [ScriptCategory] = ScriptCategory.allCases
    var sizes: [Int] = [18, 36, 64]
    var augment = 0
    /// 漢字区分だけ別の描画サイズを使う。nil = --sizes と同じ
    var kanjiSizes: [Int]?
    /// 漢字区分だけ別の拡張枚数を使う。nil = --augment と同じ。
    /// 指定したときは --oversample の倍率を掛けない (手書き調の重み付けはかな側の判断)
    var kanjiAugment: Int?
    /// 漢字区分の対象をこのファイルに書かれた字だけに絞る。nil = 漢字区分の全字
    var kanjiListPath: String?
    /// --kanji-list で読んだ字のスカラ。nil = 絞り込みなし
    var kanjiAllowed: Set<Unicode.Scalar>?
    /// 手書き調の書体一覧 (1 行 1 PostScript 名)。nil = 無効
    var oversampleListPath: String?
    /// 一覧にある書体の拡張枚数の倍率。1 = 無効 (既定)
    var oversample = 1
    /// 漢字区分の拡張で線を太らせる確率。0 = 膨張なし (既定)。
    /// 画数が多い字は 32x32 で隣り合う画が融合して塊になるので、既定では太らせない
    var kanjiDilate: Float = 0.0
    /// 漢字区分の拡張で膨張する場合の最大 px 数。かな等の 2px より狭くする
    static let kanjiMaxDilation = 1
    /// 漢字区分に使うフォントのウェイト上限 (kCTFontWeightTrait の正規化値)。
    /// これを超える face は漢字を描かない (かな等には従来どおり使う)。
    /// 既定 0.35 は Bold 0.4 以上を外し、SemiBold 0.3 までを残す
    var kanjiMaxWeight: Double = 0.5
    var seed: UInt64 = 20260924
    var limitPerClass = 0        // 0 = 無制限
    var listFonts = false
    var listFontsTSV = ".tmp/reports/fonts_list.tsv"
    var listFacesTSV: String?    // 重複排除前の全 face (ファイル -> PostScript 名) を書き出す
    var dryRun = false           // フォントの解決と train/eval の振り分けだけ出して書き込まない
    var contactSheetDir: String? // 全書体の目視確認シートの出力先
    var probe: [Character]?      // コンタクトシートの確認文字列。nil = 既定
    var maxFonts = 0             // 0 = 無制限
    var fontFilter: String?      // PostScript 名 / ファイル名にかける正規表現
    var requireScripts: [ScriptCategory] = []   // この区分のグリフを持つフォントだけ使う
    var workers = 1

    /// 描画に使う全サイズ (--sizes と --kanji-sizes の和集合、昇順)。
    /// フォントの作り置きと本体のループはこれを回し、桝ごとに区分で振り分ける。
    var allSizes: [Int] {
        var out = sizes
        for s in kanjiSizes ?? [] where !out.contains(s) {
            out.append(s)
        }
        return out.sorted()
    }

    /// 区分ごとの描画サイズ。
    func sizes(for category: ScriptCategory) -> [Int] {
        if category == .kanjiLevel1, let k = kanjiSizes {
            return k
        }
        return sizes
    }

    /// OS 付属フォントの一覧を書いたファイルの名前。
    /// フォント名をソースに直書きしないため、実体は <fonts-dir>/ に置く。
    static let systemFontListName = "system-fonts.txt"

    /// <fonts-dir>/system-fonts.txt から PostScript 名を読む。
    /// 1 行 1 名前、'#' 以降はコメント、空行は無視。
    /// ファイルが無ければ空を返す (OS 付属フォントを使わない動作。エラーにはしない)。
    static func loadSystemFontList(fontsDir: String) -> [String] {
        let url = URL(fileURLWithPath: fontsDir).appendingPathComponent(systemFontListName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            logLine("注意: \(url.path) が無いので OS 付属フォントは使いません。"
                + " 使う場合は 1 行 1 PostScript 名で置いてください。")
            return []
        }
        var out = [String]()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") {
                line = String(line[line.startIndex ..< hash])
            }
            let name = line.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !out.contains(name) {
                out.append(name)
            }
        }
        return out
    }

    /// 手書き調の書体一覧を読む。1 行 1 PostScript 名、'#' 以降はコメント、空行は無視。
    /// --oversample-list で明示指定されたファイルなので、読めなければエラー終了する
    /// (黙って無効にすると「重み付けしたつもりのデータ」ができてしまうため)。
    static func loadOversampleList(path: String) -> Set<String> {
        guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            fail("--oversample-list のファイルを読めません: \(path)")
        }
        var out = Set<String>()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") {
                line = String(line[line.startIndex ..< hash])
            }
            let name = line.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                out.insert(name)
            }
        }
        if out.isEmpty {
            fail("--oversample-list に書体名が 1 つもありません: \(path)")
        }
        return out
    }

    /// --kanji-list の字を読む。1 行 1 字 (1 行に複数書いてもよい)、'#' 以降はコメント、空白は無視。
    /// 明示指定されたファイルなので、読めない・空・語彙に無い字が混じる場合はエラー終了する
    /// (黙って無視すると「絞ったつもりのデータ」ができてしまうため)。
    static func loadKanjiList(path: String) -> Set<Unicode.Scalar> {
        guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            fail("--kanji-list のファイルを読めません: \(path)")
        }
        let vocab = CharacterVocabulary.shared
        let kanjiRange = vocab.range(of: .kanjiLevel1)
        var kanji = Set<Character>()
        var idx = kanjiRange.lowerBound
        while idx < kanjiRange.upperBound {
            kanji.insert(vocab.character(at: idx))
            idx += 1
        }
        let all = Set(vocab.allCharacters)

        var out = Set<Unicode.Scalar>()
        var unknown = [Character]()
        var notKanji = [Character]()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") {
                line = String(line[line.startIndex ..< hash])
            }
            for c in line where !c.isWhitespace {
                if kanji.contains(c) {
                    out.insert(c.unicodeScalars.first!)
                } else if all.contains(c) {
                    if !notKanji.contains(c) { notKanji.append(c) }
                } else {
                    if !unknown.contains(c) { unknown.append(c) }
                }
            }
        }
        if !unknown.isEmpty {
            fail("--kanji-list に語彙に無い字が \(unknown.count) 件あります: \(String(unknown))  (\(path))")
        }
        if !notKanji.isEmpty {
            fail("--kanji-list に漢字区分でない字が \(notKanji.count) 件あります: \(String(notKanji))  (\(path))")
        }
        if out.isEmpty {
            fail("--kanji-list に字が 1 つもありません: \(path)")
        }
        return out
    }

    static let scriptAliases: [String: ScriptCategory] = [
        "digits": .digits,
        "ascii": .asciiSymbols,
        "asciisymbols": .asciiSymbols,
        "latin": .latinUpper,          // latin は大小両方を指す (下で展開する)
        "latinupper": .latinUpper,
        "latinlower": .latinLower,
        "hiragana": .hiragana,
        "kana": .hiragana,             // kana は平仮名 + 片仮名 (下で展開する)
        "katakana": .katakana,
        "kanji": .kanjiLevel1,
        "kanjilevel1": .kanjiLevel1
    ]

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0

        func next(_ flag: String) -> String {
            i += 1
            if i >= args.count {
                fail("\(flag) に値がありません")
            }
            return args[i]
        }

        while i < args.count {
            let a = args[i]
            switch a {
            case "--out-dir":       o.outDir = next(a)
            case "--name":          o.name = next(a)
            case "--fonts-dir":     o.fontsDir = next(a)
            case "--system-fonts":  o.systemFonts = splitList(next(a))
            case "--holdout-fonts": o.holdoutFonts = splitList(next(a))
            case "--scripts":       o.scripts = parseScripts(next(a))
            case "--sizes":         o.sizes = parseSizes(next(a))
            case "--augment":       o.augment = parseInt(next(a), a, min: 0)
            case "--kanji-sizes":   o.kanjiSizes = parseSizes(next(a))
            case "--kanji-augment": o.kanjiAugment = parseInt(next(a), a, min: 0)
            case "--kanji-list":    o.kanjiListPath = next(a)
            case "--oversample-list": o.oversampleListPath = next(a)
            case "--oversample":    o.oversample = parseInt(next(a), a, min: 1)
            case "--kanji-dilate":  o.kanjiDilate = parseProbability(next(a), a)
            case "--kanji-max-weight": o.kanjiMaxWeight = parseWeight(next(a), a)
            case "--seed":          o.seed = UInt64(parseInt(next(a), a, min: 0))
            case "--limit-per-class": o.limitPerClass = parseInt(next(a), a, min: 0)
            case "--workers":       o.workers = parseInt(next(a), a, min: 1)
            case "--max-fonts":     o.maxFonts = parseInt(next(a), a, min: 0)
            case "--font-filter":   o.fontFilter = next(a)
            case "--require-script": o.requireScripts = parseScripts(next(a))
            case "--list-fonts":    o.listFonts = true
            case "--list-fonts-tsv": o.listFontsTSV = next(a)
            case "--list-faces-tsv": o.listFacesTSV = next(a)
            case "--dry-run":       o.dryRun = true
            case "--contact-sheet": o.contactSheetDir = next(a)
            case "--probe":         o.probe = parseProbe(next(a))
            case "--help", "-h":    printUsage(); exit(0)
            default:
                fail("未知の引数: \(a)  (--help を見てください)")
            }
            i += 1
        }
        if o.sizes.isEmpty {
            fail("--sizes が空です")
        }
        if o.scripts.isEmpty {
            fail("--scripts が空です")
        }
        if let k = o.kanjiSizes, k.isEmpty {
            fail("--kanji-sizes が空です")
        }
        if let path = o.kanjiListPath {
            o.kanjiAllowed = loadKanjiList(path: path)
        }
        return o
    }

    private static func splitList(_ s: String) -> [String] {
        return s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseInt(_ s: String, _ flag: String, min lower: Int) -> Int {
        guard let v = Int(s), v >= lower else {
            fail("\(flag) には \(lower) 以上の整数を渡してください: \(s)")
        }
        return v
    }

    private static func parseProbability(_ s: String, _ flag: String) -> Float {
        guard let v = Float(s), v >= 0.0, v <= 1.0 else {
            fail("\(flag) には 0.0〜1.0 の確率を渡してください: \(s)")
        }
        return v
    }

    /// kCTFontWeightTrait の正規化値 (-1.0〜1.0)。Regular 0 / Bold 0.4 / Black 0.8
    private static func parseWeight(_ s: String, _ flag: String) -> Double {
        guard let v = Double(s), v >= -1.0, v <= 1.0 else {
            fail("\(flag) には -1.0〜1.0 の正規化ウェイトを渡してください: \(s)")
        }
        return v
    }

    private static func parseSizes(_ s: String) -> [Int] {
        var out = [Int]()
        for part in splitList(s) {
            guard let v = Int(part), v > 0 else {
                fail("--sizes には正の整数を渡してください: \(part)")
            }
            out.append(v)
        }
        return out
    }

    /// コンタクトシートの確認文字列。1 文字も無ければエラー (空のシートを黙って出さない)。
    private static func parseProbe(_ s: String) -> [Character] {
        let chars = Array(s)
        if chars.isEmpty {
            fail("--probe が空です")
        }
        return chars
    }

    private static func parseScripts(_ s: String) -> [ScriptCategory] {
        var set = [ScriptCategory]()
        for raw in splitList(s) {
            let key = raw.lowercased()
            if key == "all" {
                return ScriptCategory.allCases
            }
            guard let c = scriptAliases[key] else {
                fail("--scripts の値が不明です: \(raw)  (digits,ascii,latin,hiragana,katakana,kanji)")
            }
            var add = [c]
            if key == "latin" {
                add = [.latinUpper, .latinLower]
            }
            if key == "kana" {
                add = [.hiragana, .katakana]
            }
            for x in add where !set.contains(x) {
                set.append(x)
            }
        }
        // 語彙の並び順に揃える
        return ScriptCategory.allCases.filter { set.contains($0) }
    }
}

func printUsage() {
    print("""
    render — フォントから 32x32 の学習データセットを作る

      swift run -c release render [オプション]

      --out-dir <dir>         出力先 (既定 .tmp/datasets)
      --name <name>           <name>_train.stgk / <name>_eval.stgk を作る (既定 dataset)
      --fonts-dir <dir>       追加フォントの置き場。直下の *.ttf / *.otf のみ見る (既定 .tmp/fonts)
      --system-fonts <a,b>    OS 付属フォントの PostScript 名。省略時は
                              <fonts-dir>/system-fonts.txt を読む (無ければ OS 付属は使わない)
      --holdout-fonts <a,b>   eval 側に回すフォント名 (PostScript 名 / ファイル名の部分一致)
      --scripts <a,b>         digits,ascii,latin,hiragana,katakana,kanji,all (既定 all)
      --sizes <a,b>           描画サイズ px (既定 18,36,64)
      --augment <N>           1 枚につき拡張を N 枚足す (既定 0)
      --kanji-sizes <a,b>     漢字区分だけ別の描画サイズにする (既定 = --sizes と同じ)
      --kanji-augment <N>     漢字区分だけ別の拡張枚数にする (既定 = --augment と同じ)。
                              指定すると漢字には --oversample の倍率を掛けない
      --kanji-list <path>     漢字区分の対象をこのファイルに書かれた字だけに絞る
                              (1 行 1 字、'#' 以降はコメント)。語彙に無い字・漢字でない字があればエラー
      --oversample-list <path> 手書き調の書体一覧 (1 行 1 PostScript 名、'#' 以降はコメント)。
                              この一覧にある書体だけ拡張枚数を --oversample 倍にする (train 側のみ)
      --oversample <n>        --oversample-list にある書体の拡張倍率 (既定 1 = 無効)
      --kanji-dilate <p>      漢字区分の拡張で線を太らせる確率 (0.0〜1.0、既定 0 = 膨張なし)。
                              膨張量は最大 \(Options.kanjiMaxDilation)px。かな等の区分は従来どおり
                              (確率 0.3 / 最大 2px)。画数の多い字が塊になるのを防ぐ
      --kanji-max-weight <w>  漢字区分に使うフォントのウェイト上限 (kCTFontWeightTrait の正規化値。
                              既定 0.5。Thin -0.4 / Light -0.23 / Regular 0 / Medium 0.2 /
                              SemiBold 0.3 / Bold 0.4 / ExtraBold 0.6 / Black 0.8)。
                              既定では ExtraBold 以上を外し Bold までを使う
                              (Bold も外すと書体が 19 減り、精度が下がることを実測した)。
                              これを超える face は漢字を描かない (かな等には従来どおり使う)
      --seed <n>              拡張の乱数シード (既定 20260924)
      --limit-per-class <n>   1 クラスあたりの最大サンプル数 (既定 0 = 無制限)
      --workers <n>           フォント単位の並列数 (既定 1。1 なら出力順まで決定的)
      --max-fonts <n>         使うフォント数の上限。超える分は --seed でシードした乱数で抽出 (既定 0 = 無制限)
      --font-filter <regex>   PostScript 名かファイル名がこの正規表現に当たるフォントだけ使う
      --require-script <a,b>  指定した区分のグリフを 1 つ以上持つフォントだけ使う
                              (例: --require-script hiragana で日本語フォントだけに絞る)
      --list-fonts            読み込めたフォントと被覆率・マス目への配置を表示して終了
      --list-fonts-tsv <path> --list-fonts のとき TSV を書き出す先 (既定 .tmp/reports/fonts_list.tsv)
      --contact-sheet <dir>   読み込めた全書体の目視確認シート (PNG) を書き出して終了する。
                              確認文字列を 1 行に並べ、40 書体で 1 ページ。
                              描く em は --sizes と --kanji-sizes の値 (既定 18,36,64)。em ごとに別ファイル
      --probe <文字列>        コンタクトシートの確認文字列 (既定は濁点・英大小・画数の多い字を含む 15 字)
      --dry-run               フォントの解決と train / eval の振り分けだけ表示し、
                              データセットを一切書かずに終了する
      --list-faces-tsv <path> PostScript 名で重複排除する前の全 face (path と名前) を書き出して終了
                              (同じ PostScript 名を名乗るファイルの洗い出しに使う)

    対象区分のグリフを 1 つも持たないフォントは自動でスキップします
    (Latin 専用フォントに --scripts hiragana を指定した場合など)。
    """)
}

// MARK: - フォント

enum FontOrigin {
    case system
    case file(URL)

    var label: String {
        switch self {
        case .system: return "system"
        case .file(let u): return u.deletingLastPathComponent().lastPathComponent + "/" + u.lastPathComponent
        }
    }

    var shortLabel: String {
        switch self {
        case .system: return "system"
        case .file: return "fonts-dir"
        }
    }

    /// TSV 用のパス (system は空)
    var path: String {
        switch self {
        case .system: return ""
        case .file(let u): return u.path
        }
    }
}

/// 読み込みに成功したフォント 1 つ。CTFont は不変で thread-safe なのでサイズ別に作り置きする。
final class FontEntry: @unchecked Sendable {
    let postScriptName: String
    let origin: FontOrigin
    let fontsBySize: [Int: CTFont]
    /// 区分ごとの (描けるグリフ数, 語彙上の総数)
    let coverage: [ScriptCategory: (have: Int, total: Int)]
    /// 実際に描ける文字の (クラス index, スカラ, 区分)。--scripts で絞った後の集合。
    let drawable: [(index: Int, scalar: Unicode.Scalar, category: ScriptCategory)]
    /// --kanji-max-weight を超えたので漢字を描かなかったか
    let kanjiExcludedByWeight: Bool
    /// マス目への配置 (全サイズ共通)
    let layout: FontLayout

    init(
        postScriptName: String,
        origin: FontOrigin,
        fontsBySize: [Int: CTFont],
        coverage: [ScriptCategory: (have: Int, total: Int)],
        drawable: [(index: Int, scalar: Unicode.Scalar, category: ScriptCategory)],
        kanjiExcludedByWeight: Bool,
        layout: FontLayout
    ) {
        self.postScriptName = postScriptName
        self.origin = origin
        self.fontsBySize = fontsBySize
        self.coverage = coverage
        self.drawable = drawable
        self.kanjiExcludedByWeight = kanjiExcludedByWeight
        self.layout = layout
    }
}

/// フォント読み込みの結果。フォールバック・置換は「読めなかった」として理由付きで返す。
enum FontLoadOutcome {
    case loaded(FontEntry)
    case rejected(String)
}

enum FontLoader {
    /// グリフが本当にあるか。CTFontGetGlyphsForCharacters が false か glyph 0 なら無い。
    static func hasGlyph(_ font: CTFont, _ scalar: Unicode.Scalar) -> Bool {
        var utf16 = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let ok = CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
        if !ok {
            return false
        }
        for g in glyphs where g == 0 {
            return false
        }
        return !glyphs.isEmpty
    }

    /// ウェイト (kCTFontWeightTrait の正規化値)。Regular 0 / Bold 0.4 / Black 0.8。
    /// 取れないフォントは Regular 扱い (0.0) にする。可変フォントの名前付きインスタンスも
    /// 記述子ごとに別の CTFont なので、そのインスタンスの値が返る。
    static func weight(_ font: CTFont) -> Double {
        let traits = CTFontCopyTraits(font) as NSDictionary
        guard let n = traits[kCTFontWeightTrait as String] as? NSNumber else {
            return 0.0
        }
        return n.doubleValue
    }

    static func glyph(_ font: CTFont, _ scalar: Unicode.Scalar) -> CGGlyph? {
        var utf16 = Array(String(Character(scalar)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        let ok = CTFontGetGlyphsForCharacters(font, &utf16, &glyphs, utf16.count)
        if !ok || glyphs.count != 1 || glyphs[0] == 0 {
            return nil
        }
        return glyphs[0]
    }

    /// OS 付属フォントを PostScript 名で取る。
    /// CTFontCreateWithName は名前が見つからないと別のフォントを返すので、
    /// 戻り値の PostScript 名が要求と一致しなければ「読めなかった」として弾く。
    static func loadSystem(
        _ psName: String,
        sizes: [Int],
        scripts: [ScriptCategory],
        kanjiAllowed: Set<Unicode.Scalar>?,
        kanjiMaxWeight: Double
    ) -> FontLoadOutcome {
        let probe = CTFontCreateWithName(psName as CFString, CGFloat(sizes[0]), nil)
        let actual = CTFontCopyPostScriptName(probe) as String
        if actual != psName {
            return .rejected("フォールバック: \"\(psName)\" を要求したが \"\(actual)\" が返った")
        }
        var fonts = [Int: CTFont]()
        for s in sizes {
            fonts[s] = CTFontCreateWithName(psName as CFString, CGFloat(s), nil)
        }
        return .loaded(makeEntry(psName: psName, origin: .system, fonts: fonts, scripts: scripts,
                                 kanjiAllowed: kanjiAllowed, kanjiMaxWeight: kanjiMaxWeight))
    }

    /// ファイルから読む。記述子から作ったフォントの URL が元ファイルと一致することを確かめ、
    /// 置換が起きていないことを保証する。
    static func loadFile(
        _ url: URL,
        sizes: [Int],
        scripts: [ScriptCategory],
        kanjiAllowed: Set<Unicode.Scalar>?,
        kanjiMaxWeight: Double
    ) -> [FontLoadOutcome] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else {
            return [.rejected("記述子を作れない: \(url.lastPathComponent)")]
        }
        var out = [FontLoadOutcome]()
        for desc in descriptors {
            let probe = CTFontCreateWithFontDescriptor(desc, CGFloat(sizes[0]), nil)
            let psName = CTFontCopyPostScriptName(probe) as String
            // 作られたフォントが本当にこのファイル由来か確認する
            let attr = CTFontCopyAttribute(probe, kCTFontURLAttribute)
            guard let fontURL = attr as? URL else {
                out.append(.rejected("URL 属性を取れない: \(url.lastPathComponent) (\(psName))"))
                continue
            }
            if fontURL.standardizedFileURL.path != url.standardizedFileURL.path {
                out.append(.rejected("置換が起きた: \(url.lastPathComponent) -> \(fontURL.lastPathComponent)"))
                continue
            }
            var fonts = [Int: CTFont]()
            for s in sizes {
                fonts[s] = CTFontCreateWithFontDescriptor(desc, CGFloat(s), nil)
            }
            out.append(.loaded(makeEntry(psName: psName, origin: .file(url), fonts: fonts, scripts: scripts,
                                         kanjiAllowed: kanjiAllowed, kanjiMaxWeight: kanjiMaxWeight)))
        }
        return out
    }

    private static func makeEntry(
        psName: String,
        origin: FontOrigin,
        fonts: [Int: CTFont],
        scripts: [ScriptCategory],
        kanjiAllowed: Set<Unicode.Scalar>?,
        kanjiMaxWeight: Double
    ) -> FontEntry {
        let vocab = CharacterVocabulary.shared
        let probeFont = fonts.values.first!
        var coverage = [ScriptCategory: (have: Int, total: Int)]()
        var drawable = [(index: Int, scalar: Unicode.Scalar, category: ScriptCategory)]()
        // 太いウェイトは em 64 で描いても隣り合う画が融合して塊になるので、漢字だけ対象から外す。
        // 判定は数値トレイトだけで行う (書体名では判定しない)
        let heavyForKanji = weight(probeFont) > kanjiMaxWeight

        for category in ScriptCategory.allCases {
            let range = vocab.range(of: category)
            var have = 0
            var idx = range.lowerBound
            while idx < range.upperBound {
                let c = vocab.character(at: idx)
                let scalar = c.unicodeScalars.first!
                if hasGlyph(probeFont, scalar) {
                    have += 1
                    // --kanji-list を指定したときは漢字区分だけ一覧の字に絞る。
                    // coverage は絞らない (--require-script と被覆表はフォント自体の被覆を見るため)
                    let inScope = category != .kanjiLevel1
                        || (!heavyForKanji && kanjiAllowed?.contains(scalar) ?? true)
                    if scripts.contains(category) && inScope {
                        drawable.append((index: idx, scalar: scalar, category: category))
                    }
                }
                idx += 1
            }
            coverage[category] = (have: have, total: range.count)
        }
        let hasKanji = (coverage[.kanjiLevel1]?.have ?? 0) > 0
        return FontEntry(
            postScriptName: psName,
            origin: origin,
            fontsBySize: fonts,
            coverage: coverage,
            drawable: drawable,
            kanjiExcludedByWeight: heavyForKanji && hasKanji,
            // 配置は最大の描画サイズで測る (辞書の並びは実行ごとに変わるので first は使わない。
            // 外接矩形はサイズでわずかに変わるため、測るサイズを固定して決定的にする)
            layout: FontLayout.measure(font: fonts[fonts.keys.max()!]!, scalars: drawable.map { $0.scalar })
        )
    }
}

/// 並列読み込みの結果を集める。
final class LoadCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var loaded: [FontEntry] = []
    private(set) var rejected: [(name: String, reason: String)] = []

    func addLoaded(_ e: FontEntry) {
        lock.lock()
        loaded.append(e)
        lock.unlock()
    }

    func addRejected(_ name: String, _ reason: String) {
        lock.lock()
        rejected.append((name, reason))
        lock.unlock()
    }
}

/// --max-fonts の抽出に使う決定的な乱数 (SplitMix64)。
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) {
        state = seed &+ 0x9E3779B97F4A7C15
    }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - 描画

/// 書体ごとのマス目への配置。長さはすべて em を 1 とした比率なので、どの描画サイズでも同じ配置になる。
///
/// 字ごとには中央寄せしない (句読点・小さい記号・小書きの位置と大きさを残すため)。
/// ベースラインは書体で 1 つ、縮尺と縦の最小限のずらしは書体の区分 (`ScaleGroup`) ごとに決め、
/// それでもマス目に収まらない字だけを個別に直す (`GlyphRenderer`)。
struct FontLayout: Sendable {
    /// 縮尺を別々に決める区分。英字のディセンダや括弧が em の下へ出る分で、
    /// かなや漢字まで縮めないために分ける
    enum ScaleGroup: String, Sendable, CaseIterable {
        case kana
        case alnumSymbols
        case kanji

        init(_ category: ScriptCategory) {
            switch category {
            case .hiragana, .katakana: self = .kana
            case .digits, .asciiSymbols, .latinUpper, .latinLower: self = .alnumSymbols
            case .kanjiLevel1: self = .kanji
            }
        }

        /// 語彙の外の字 (コンタクトシートの句読点など) も含めた区分。
        /// 語彙にあればその区分、無ければ Unicode のブロックで決める
        init(_ scalar: Unicode.Scalar) {
            if let index = FontLayout.vocabularyIndex[scalar] {
                self.init(CharacterVocabulary.shared.category(of: index))
            } else if (0x3000 ... 0x30FF).contains(scalar.value) {
                self = .kana
            } else if (0x3400 ... 0x9FFF).contains(scalar.value) {
                self = .kanji
            } else {
                self = .alnumSymbols
            }
        }

        var label: String {
            switch self {
            case .kana: return "かな"
            case .alnumSymbols: return "英数"
            case .kanji: return "漢字"
            }
        }
    }

    /// 語彙の字 → クラス index
    static let vocabularyIndex: [Unicode.Scalar: Int] = {
        var out = [Unicode.Scalar: Int]()
        for (i, c) in CharacterVocabulary.shared.allCharacters.enumerated() {
            out[c.unicodeScalars.first!] = i
        }
        return out
    }()

    /// ベースラインの決め方
    enum Basis: String, Sendable {
        /// OS/2 の sTypoAscender - sTypoDescender が unitsPerEm に一致する書体。
        /// ベースラインはマス目の底から |sTypoDescender| 上げた位置
        case typo
        /// 一致しない書体。代表字の外接矩形の和をマス目の縦中央に置く
        case representative
        /// 代表字も欧文の代表字も持たない書体。対象グリフ全体の外接矩形の和を縦中央に置く
        case allGlyphs

        var label: String {
            switch self {
            case .typo: return "typo"
            case .representative: return "代表字"
            case .allGlyphs: return "全字"
            }
        }
    }

    let basis: Basis
    /// 縮尺 1 のときのベースラインの高さ (マス目の底から、em 比)
    let baseline: CGFloat
    /// 区分ごとの縮尺 (マス目の中心が基準、1 以下)。対象グリフが無い区分は持たない
    let scales: [ScaleGroup: CGFloat]
    /// 区分ごとの縦のずらし (em 比、上向き正)。縮尺だけでは上下へ出る区分だけ 0 でない
    let offsets: [ScaleGroup: CGFloat]

    /// 区分の縮尺。対象グリフが無かった区分 (コンタクトシートで --scripts の外の字を描くとき) は 1
    func scale(for group: ScaleGroup) -> CGFloat {
        return scales[group] ?? 1.0
    }

    /// 区分の縦のずらし。対象グリフが無かった区分は 0
    func offset(for group: ScaleGroup) -> CGFloat {
        return offsets[group] ?? 0.0
    }

    /// typo 値が em に一致するとみなす許容幅 (unitsPerEm 比)
    static let typoTolerance = 0.02
    /// 代表字。無い字は飛ばす
    static let representativeChars: [Character] = ["国", "あ", "口", "永"]
    /// 代表字が 1 つも無い (欧文専用) 書体の代表字
    static let latinRepresentativeChars: [Character] = ["A", "H", "x"]
    /// 区分ごとの縮尺で収める対象グリフの割合。残りの外れ値 (| や g など) はグリフ単位で直す。
    /// 余白は取らずマス目そのものに収める (拡張の余白は Augmenter が取る)。
    /// 98% や余白 1px では字が小さくなりすぎた (2026-10-01 実測: 英数の高さの中央値 0.750 → 0.688)
    static let fitQuantile = 0.95

    /// グリフの外接矩形 (グリフ原点基準、em 比)。空なら nil
    static func bounds(_ font: CTFont, _ glyph: CGGlyph) -> CGRect? {
        var g = glyph
        var r = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &g, &r, 1)
        if r.isNull || r.isInfinite || r.width <= 0 || r.height <= 0 {
            return nil
        }
        let size = CTFontGetSize(font)
        return CGRect(x: r.minX / size, y: r.minY / size, width: r.width / size, height: r.height / size)
    }

    /// 字送り幅 (em 比)
    static func advance(_ font: CTFont, _ glyph: CGGlyph) -> CGFloat {
        var g = glyph
        var a = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .default, &g, &a, 1)
        return a.width / CTFontGetSize(font)
    }

    /// 統計行・--list-fonts 用の 1 行表示
    var summary: String {
        return "配置 \(basis.label) ベースライン \(String(format: "%.3f", baseline)) 縮尺 \(scaleSummary)"
    }

    /// コンタクトシートの書体名の下に添える短い表示 (例 "typo 0.141 か0.95 英0.80 漢0.96")
    var compactSummary: String {
        var out = "\(basis.label) \(String(format: "%.3f", baseline))"
        for g in ScaleGroup.allCases {
            if let v = scales[g] {
                out += " \(g.label.prefix(1))\(String(format: "%.2f", v))"
                let o = offset(for: g)
                if o != 0.0 {
                    out += String(format: "%+.2f", o)
                }
            }
        }
        return out
    }

    /// 対象グリフのある区分の縮尺と縦のずらし (例 "かな 0.952 英数 0.801+0.031")
    var scaleSummary: String {
        let parts = ScaleGroup.allCases.compactMap { g in
            scales[g].map { v -> String in
                let o = offset(for: g)
                return "\(g.label) \(String(format: "%.3f", v))" + (o != 0.0 ? String(format: "%+.3f", o) : "")
            }
        }
        return parts.isEmpty ? "-" : parts.joined(separator: " ")
    }

    /// 縮尺 1 でのマス目上の外接矩形 (マス目の左下 = 原点、em 比)
    func cellRect(bounds: CGRect, advance: CGFloat) -> CGRect {
        return bounds.offsetBy(dx: (1.0 - advance) * 0.5, dy: baseline)
    }

    /// OS/2 の (sTypoAscender, sTypoDescender, unitsPerEm)。テーブルが無ければ nil
    static func typoMetrics(_ font: CTFont) -> (ascender: Int, descender: Int, unitsPerEm: Int)? {
        guard let data = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), []) as Data?,
              data.count >= 72 else {
            return nil
        }
        func int16(_ offset: Int) -> Int {
            let hi = UInt16(data[data.startIndex + offset])
            let lo = UInt16(data[data.startIndex + offset + 1])
            return Int(Int16(bitPattern: (hi << 8) | lo))
        }
        return (int16(68), int16(70), Int(CTFontGetUnitsPerEm(font)))
    }

    /// 書体の配置を決める。`scalars` はその実行で描く対象グリフ (--scripts の範囲)。
    static func measure(font: CTFont, scalars: [Unicode.Scalar]) -> FontLayout {
        let basis: Basis
        let baseline: CGFloat
        if let typo = typoMetrics(font), typo.unitsPerEm > 0,
           abs(Double(typo.ascender - typo.descender - typo.unitsPerEm))
               <= typoTolerance * Double(typo.unitsPerEm) {
            basis = .typo
            baseline = CGFloat(-typo.descender) / CGFloat(typo.unitsPerEm)
        } else {
            // 代表字の外接矩形の和の縦中央をマス目の縦中央に合わせる
            func union(_ chars: [Unicode.Scalar]) -> CGRect? {
                var out: CGRect?
                for s in chars {
                    guard let g = FontLoader.glyph(font, s), let b = bounds(font, g) else {
                        continue
                    }
                    out = out.map { $0.union(b) } ?? b
                }
                return out
            }
            let japanese = union(representativeChars.map { $0.unicodeScalars.first! })
            let latin = japanese == nil ? union(latinRepresentativeChars.map { $0.unicodeScalars.first! }) : nil
            if let r = japanese ?? latin {
                basis = .representative
                baseline = 0.5 - r.midY
            } else if let r = union(scalars) {
                basis = .allGlyphs
                baseline = 0.5 - r.midY
            } else {
                basis = .allGlyphs
                baseline = 0.5
            }
        }

        // 区分ごとの縮尺とずらし。マス目に、その区分の対象グリフの 95% が収まるようにする。
        // 横: 字送り幅の中央に置くので、マス目中心基準の縮尺だけで収める。
        // 縦: 下端の 5 パーセンタイルから上端の 95 パーセンタイルまでの高さが収まる縮尺
        //     (マス目中心基準) にし、それでも上下どちらかへ出るなら最小限だけ縦にずらす。
        // 拡大はしない
        let unscaled = FontLayout(basis: basis, baseline: baseline, scales: [:], offsets: [:])
        var rects = [ScaleGroup: [CGRect]]()
        for s in scalars {
            guard let g = FontLoader.glyph(font, s), let b = bounds(font, g) else {
                continue
            }
            rects[ScaleGroup(s), default: []].append(unscaled.cellRect(bounds: b, advance: advance(font, g)))
        }
        var scales = [ScaleGroup: CGFloat]()
        var offsets = [ScaleGroup: CGFloat]()
        for (group, list) in rects {
            let outliers = min(list.count - 1, Int((1.0 - fitQuantile) * Double(list.count)))
            let needX = list.map { r -> CGFloat in
                let reach = max(0.5 - r.minX, r.maxX - 0.5)
                return reach > 0.5 ? 0.5 / reach : 1.0
            }.sorted()
            let bottom = list.map { $0.minY }.sorted()[outliers]
            let top = list.map { $0.maxY }.sorted(by: >)[outliers]
            let scale = min(1.0, needX[outliers], 1.0 / max(top - bottom, 1e-6))
            let lo = 0.5 + scale * (bottom - 0.5)
            let hi = 0.5 + scale * (top - 0.5)
            var offset: CGFloat = 0.0
            if lo < 0.0 {
                offset = -lo
            } else if hi > 1.0 {
                offset = 1.0 - hi
            }
            scales[group] = scale
            offsets[group] = offset
        }
        return FontLayout(basis: basis, baseline: baseline, scales: scales, offsets: offsets)
    }
}

/// 1 文字分のマス目に描いた結果。
struct CellRender {
    /// マス目 (em x em) の 8bit グレー。row-major、上の行が先。
    let gray: [UInt8]
    /// マス目の外へ出た墨の割合 (0.0 = 収まっている, 1.0 = 全部はみ出した)。
    /// 配置で収めているので 0 になるはずの値。描画の自己検査として測り続ける
    let overflowRatio: Float
    /// マス目の中に残った墨の量 (画素値の総和。0 なら空画像)
    let insideInk: Float
    /// 書体の配置のままではマス目からはみ出すので、このグリフだけ平行移動した
    let moved: Bool
    /// マス目より大きいので、このグリフだけ縮小した
    let shrunk: Bool
}

enum GlyphRenderer {
    /// マス目の外側に取る余白 (em 単位)。はみ出した墨を測るためだけに使い、最後に切り落とす。
    static let overflowPadEm = 1
    /// 描いた墨がマス目からはみ出したときに描き直す回数の上限
    static let maxRedraws = 8

    /// 1 em 四方のマス目にグリフを描く。
    ///
    /// - 書体の配置 (`FontLayout`): 水平は字送り幅の中央、垂直は書体ごとのベースライン、
    ///   全体を書体の区分 (`group`) ごとの縮尺でマス目の中心を基準に縮める。
    /// - それでもマス目からはみ出すグリフは、マス目より大きければマス目の中心を基準に縮小し、
    ///   マス目の内側へ平行移動する (墨を捨てない)。判定はアウトラインの外接矩形で見積もってから、
    ///   描いた墨の外接矩形で確かめる (小さい em ではアンチエイリアスの墨がアウトラインの
    ///   外接矩形より 1px ほど外へ出るため)。墨がはみ出していれば整数 px の平行移動
    ///   (マス目より大きければ縮小) をして描き直す。
    /// - 外へ出た墨の割合を `overflowRatio` に記録する (配置が正しければ 0)。
    ///
    /// 返す配列は row-major で行 0 が上端 (`GrayBitmap` が揃える)。
    /// グリフの外接矩形が空なら nil (空白文字など)。
    static func renderCell(
        font: CTFont, glyph: CGGlyph, em: Int, layout: FontLayout, group: FontLayout.ScaleGroup
    ) -> CellRender? {
        guard let bounds = FontLayout.bounds(font, glyph) else {
            return nil
        }
        let advance = FontLayout.advance(font, glyph)

        // マス目の左下を原点とする em 比の座標で、書体の縮尺を掛けた外接矩形
        let unscaled = layout.cellRect(bounds: bounds, advance: advance)
        var placement = Placement(scale: layout.scale(for: group), tx: 0.0, ty: layout.offset(for: group))
        var shrunk = false
        var moved = false
        // アウトラインで見積もる: マス目より大きければ縮小し、はみ出す辺を内側へ寄せる
        var rect = placement.apply(unscaled)
        if rect.width > 1.0 || rect.height > 1.0 {
            placement.scale *= 1.0 / max(rect.width, rect.height)
            rect = placement.apply(unscaled)
            shrunk = true
        }
        func shift(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            if lo < 0.0 { return -lo }
            if hi > 1.0 { return 1.0 - hi }
            return 0.0
        }
        let sx = shift(rect.minX, rect.maxX)
        let sy = shift(rect.minY, rect.maxY)
        placement.tx += sx
        placement.ty += sy
        if sx != 0.0 || sy != 0.0 {
            moved = true
        }

        // はみ出しを測るため、マス目の周囲に overflowPadEm 分の余白を取って描く
        let pad = em * overflowPadEm
        let canvas = em + 2 * pad
        var canvasGray = [UInt8]()
        var redraws = 0
        while true {
            guard let drawn = draw(font: font, glyph: glyph, em: em, canvas: canvas,
                                   advance: advance, layout: layout, placement: placement) else {
                return nil
            }
            canvasGray = drawn
            // 描いた墨の外接矩形 (マス目の左上 = 原点の画素座標、行は下向き)
            guard let ink = inkBounds(canvasGray, canvas: canvas), redraws < maxRedraws else {
                break
            }
            let x0 = ink.minX - pad, x1 = ink.maxX - pad
            let y0 = ink.minY - pad, y1 = ink.maxY - pad
            if x0 >= 0 && y0 >= 0 && x1 < em && y1 < em {
                break
            }
            let w = x1 - x0 + 1
            let h = y1 - y0 + 1
            if w > em || h > em {
                placement.scale *= CGFloat(em) / CGFloat(max(w, h) + 1)
                shrunk = true
            } else {
                // 整数 px の平行移動なら描き直しても墨の形は変わらない
                let dx = x0 < 0 ? -x0 : (x1 >= em ? em - 1 - x1 : 0)
                let dy = y0 < 0 ? -y0 : (y1 >= em ? em - 1 - y1 : 0)
                placement.tx += CGFloat(dx) / CGFloat(em)
                placement.ty -= CGFloat(dy) / CGFloat(em)   // 行は下向き、描画の y は上向き
                moved = true
            }
            redraws += 1
        }

        // マス目の中と外の墨を数えつつ、マス目の分だけ取り出す
        var cell = [UInt8](repeating: 255, count: em * em)
        var insideInk: Float = 0.0
        var totalInk: Float = 0.0
        var cy = 0
        while cy < canvas {
            let srcRow = cy * canvas
            let insideRow = (cy >= pad && cy < pad + em)
            var cx = 0
            while cx < canvas {
                let ink = Float(255 - Int(canvasGray[srcRow + cx])) * (1.0 / 255.0)
                totalInk += ink
                if insideRow && cx >= pad && cx < pad + em {
                    insideInk += ink
                    cell[(cy - pad) * em + (cx - pad)] = canvasGray[srcRow + cx]
                }
                cx += 1
            }
            cy += 1
        }

        let overflow: Float = totalInk > 0.0 ? (totalInk - insideInk) / totalInk : 0.0
        return CellRender(gray: cell, overflowRatio: overflow, insideInk: insideInk,
                          moved: moved, shrunk: shrunk)
    }

    /// グリフ 1 つ分の縮尺と平行移動 (em 比)。縮尺はマス目の中心が基準
    private struct Placement {
        var scale: CGFloat
        var tx: CGFloat
        var ty: CGFloat

        func scaled(_ v: CGFloat) -> CGFloat {
            return 0.5 + scale * (v - 0.5)
        }

        /// 縮尺 1 のマス目上の矩形をこの配置で写した矩形
        func apply(_ r: CGRect) -> CGRect {
            return CGRect(x: scaled(r.minX) + tx, y: scaled(r.minY) + ty,
                          width: scale * r.width, height: scale * r.height)
        }
    }

    /// 周囲に余白を取ったキャンバス (canvas x canvas) の中央のマス目にグリフを描く
    private static func draw(
        font: CTFont,
        glyph: CGGlyph,
        em: Int,
        canvas: Int,
        advance: CGFloat,
        layout: FontLayout,
        placement: Placement
    ) -> [UInt8]? {
        guard let ctx = GrayBitmap.makeContext(width: canvas, height: canvas) else {
            return nil
        }
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSmoothFonts(false)
        ctx.setFillColor(gray: 0.0, alpha: 1.0)

        // グリフ原点 (縮尺 1 では ((1 - advance) / 2, baseline)) を写した位置に、縮尺つきで描く
        let emF = CGFloat(em)
        let pad = CGFloat((canvas - em) / 2)
        let originX = placement.scaled((1.0 - advance) * 0.5) + placement.tx
        let originY = placement.scaled(layout.baseline) + placement.ty
        ctx.translateBy(x: pad + emF * originX, y: pad + emF * originY)
        let drawScale = placement.scale * emF / CTFontGetSize(font)
        ctx.scaleBy(x: drawScale, y: drawScale)
        var g = glyph
        var pos = CGPoint.zero
        CTFontDrawGlyphs(font, &g, &pos, 1, ctx)

        // 行の向きは GrayBitmap が揃える (行 0 = 上)
        return GrayBitmap.read(ctx)
    }

    /// 墨 (紙 255 より濃い画素) の外接矩形。画素座標、行 0 = 上。墨が無ければ nil
    private static func inkBounds(_ gray: [UInt8], canvas: Int) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        var minX = canvas, maxX = -1, minY = canvas, maxY = -1
        var y = 0
        while y < canvas {
            let row = y * canvas
            var x = 0
            while x < canvas {
                if gray[row + x] < 255 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
                x += 1
            }
            y += 1
        }
        return maxX < 0 ? nil : (minX, maxX, minY, maxY)
    }
}

// MARK: - ビットマップと配列の相互変換

/// CGBitmapContext (8bit グレー) と「行 0 = 上」の row-major 配列との相互変換。
///
/// CGBitmapContext のデータバッファは **先頭行が画像の上端** に対応する。
/// 描画の座標系は左下原点なので `y = 0` に描いた内容はバッファの最終行に入るが、
/// バッファの並び自体は上から下なので、バッファ行 r をそのまま配列行 r に写せば
/// 「行 0 = 上」になる。
///
/// **行の向きを扱うのはこの 2 つの関数だけ。** 他の場所で行を入れ替えないこと。
enum GrayBitmap {
    /// 8bit グレーの描画先を作る。`bytesPerRow` の詰め物は呼び出し側から見えない。
    static func makeContext(width: Int, height: Int) -> CGContext? {
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
    }

    /// ビットマップ → row-major の 8bit グレー配列 (行 0 = 上)。
    static func read(_ ctx: CGContext) -> [UInt8]? {
        guard let base = ctx.data else {
            return nil
        }
        let width = ctx.width
        let height = ctx.height
        let bytesPerRow = ctx.bytesPerRow
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: width * height)
        var y = 0
        while y < height {
            let src = ptr + y * bytesPerRow
            let dst = y * width
            var x = 0
            while x < width {
                out[dst + x] = src[x]
                x += 1
            }
            y += 1
        }
        return out
    }

    /// row-major の 8bit グレー配列 (行 0 = 上) → ビットマップ。
    /// `pixel(x, y)` の y = 0 が上端。
    static func makeContext(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> UInt8
    ) -> CGContext? {
        guard let ctx = makeContext(width: width, height: height),
              let base = ctx.data else {
            return nil
        }
        let bytesPerRow = ctx.bytesPerRow
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var y = 0
        while y < height {
            let dst = ptr + y * bytesPerRow
            var x = 0
            while x < width {
                dst[x] = pixel(x, y)
                x += 1
            }
            y += 1
        }
        return ctx
    }
}

// MARK: - コンタクトシート

/// 全書体を人間が目視確認するための一覧 PNG。
/// データを増やす前に、豆腐・欠落・フォールバック・位置ずれをここで潰す。
enum ContactSheet {
    /// 確認用の既定の文字列 (15 文字)。--probe で差し替えられる。
    /// 濁点と半濁点 (ビ/ピ)、英大小文字 (c/C)、画数の多い字 (永/鬱) を必ず含める。
    /// マス目基準の正規化がこれらを区別できているかを 1 行で見るため。
    /// 小書き仮名 (ょ) は語彙から外したので親字 (よ) に置き換えてある。
    static let defaultProbe: [Character] = Array("あいうえお永鬱Aa0よビピcC")
    /// 32x32 を何倍に拡大して並べるか
    static let scale = 4
    /// 1 ページあたりの書体数
    static let rowsPerPage = 40

    static let cellPx = CharacterImage.side * scale       // 128
    static let labelWidth = 470
    static let headerHeight = 160

    /// 1 桝の状態
    private enum CellState {
        case drawn(CharacterImage)
        case noGlyph
        case blank
    }

    /// 書体一覧を em ごとに複数ページの PNG に書き出し、書いたページ数を返す。
    static func write(
        entries: [FontEntry],
        directory: String,
        labelFont: CTFont,
        probe: [Character],
        ems: [Int]
    ) throws -> Int {
        let dir = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sorted = entries.sorted { $0.postScriptName < $1.postScriptName }
        let pagesPerEm = max(1, (sorted.count + rowsPerPage - 1) / rowsPerPage)
        var written = 0
        for em in ems {
            var page = 0
            while page < pagesPerEm {
                let slice = Array(sorted.dropFirst(page * rowsPerPage).prefix(rowsPerPage))
                let url = dir.appendingPathComponent(
                    String(format: "sheet_em%02d_%02d.png", em, page + 1)
                )
                try writePage(slice, to: url, labelFont: labelFont, probe: probe, em: em,
                              page: page + 1, of: pagesPerEm)
                written += 1
                page += 1
            }
        }
        return written
    }

    private static func writePage(
        _ fonts: [FontEntry],
        to url: URL,
        labelFont: CTFont,
        probe: [Character],
        em: Int,
        page: Int,
        of pageCount: Int
    ) throws {
        let width = labelWidth + probe.count * cellPx
        let height = headerHeight + fonts.count * cellPx
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ContactSheetError.contextFailed
        }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        // 用紙は白
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // --- 凡例 (ページ上部) ---
        let legend = "\(page) / \(pageCount) ページ  —  em \(em)px でマス目に描き マス目基準で 32x32 にした画像 を \(scale) 倍表示"
        let legend2 = "灰色の桝 = グリフ無し (skip)   赤枠の桝 = 描いたが墨なし (skip)   細い枠 = マス目の境界"
        let legend3 = String(probe)
        drawText(legend, in: ctx, at: CGPoint(x: 16, y: CGFloat(height) - 44), font: labelFont, gray: 0.0)
        drawText(legend2, in: ctx, at: CGPoint(x: 16, y: CGFloat(height) - 80), font: labelFont, gray: 0.25)
        drawText("確認文字: " + legend3, in: ctx, at: CGPoint(x: 16, y: CGFloat(height) - 116), font: labelFont, gray: 0.25)

        // --- 各行 ---
        // 書体名の下に配置 (ベースラインの決め方・区分ごとの縮尺) を小さく添える
        let layoutFont = CTFontCreateCopyWithAttributes(labelFont, 19.0, nil, nil)
        for (row, entry) in fonts.enumerated() {
            // CG は下が原点。行はページ上から並べる
            let top = CGFloat(height - headerHeight - row * cellPx)
            let bottom = top - CGFloat(cellPx)

            drawText(
                entry.postScriptName,
                in: ctx,
                at: CGPoint(x: 12, y: bottom + CGFloat(cellPx) * 0.5 + 4),
                font: labelFont,
                gray: 0.0
            )
            drawText(
                entry.layout.compactSummary,
                in: ctx,
                at: CGPoint(x: 12, y: bottom + CGFloat(cellPx) * 0.5 - 28),
                font: layoutFont,
                gray: 0.4
            )

            guard let font = entry.fontsBySize[em] ?? entry.fontsBySize.values.first else {
                continue
            }
            for (col, ch) in probe.enumerated() {
                let x = CGFloat(labelWidth + col * cellPx)
                let rect = CGRect(x: x, y: bottom, width: CGFloat(cellPx), height: CGFloat(cellPx))
                switch state(of: ch, font: font, em: em, layout: entry.layout) {
                case .noGlyph:
                    ctx.setFillColor(red: 0.78, green: 0.78, blue: 0.78, alpha: 1)
                    ctx.fill(rect)
                case .blank:
                    ctx.setStrokeColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)
                    ctx.setLineWidth(4)
                    ctx.stroke(rect.insetBy(dx: 2, dy: 2))
                case .drawn(let image):
                    if let cg = makeGrayImage(image) {
                        ctx.interpolationQuality = .none
                        ctx.draw(cg, in: rect)
                    }
                }
                // マス目の境界
                ctx.setStrokeColor(red: 0.8, green: 0.8, blue: 0.85, alpha: 1)
                ctx.setLineWidth(1)
                ctx.stroke(rect)
            }
        }

        guard let image = ctx.makeImage() else {
            throw ContactSheetError.imageFailed
        }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw ContactSheetError.writeFailed(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) {
            throw ContactSheetError.writeFailed(url.path)
        }
    }

    private static func state(of ch: Character, font: CTFont, em: Int, layout: FontLayout) -> CellState {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
            return .noGlyph
        }
        guard let glyph = FontLoader.glyph(font, scalar) else {
            return .noGlyph
        }
        guard let cell = GlyphRenderer.renderCell(
            font: font, glyph: glyph, em: em, layout: layout, group: FontLayout.ScaleGroup(scalar)
        ) else {
            return .blank
        }
        guard let image = try? ImageNormalizer.normalize(
            width: em, height: em, gray: cell.gray, invert: true
        ) else {
            return .blank
        }
        if image.inkSum <= 0.0 {
            return .blank
        }
        return .drawn(image)
    }

    /// 32x32 の墨画像を白地黒字の CGImage にする (拡大は呼び出し側で nearest)
    private static func makeGrayImage(_ image: CharacterImage) -> CGImage? {
        let side = CharacterImage.side
        let ctx = GrayBitmap.makeContext(width: side, height: side) { x, y in
            // 墨 1.0 -> 黒 0、紙 0.0 -> 白 255。y = 0 が上端 (画像と同じ向き)
            let v = 255.0 - image[x, y] * 255.0
            return UInt8(max(0.0, min(255.0, v.rounded())))
        }
        return ctx?.makeImage()
    }

    private static func drawText(
        _ text: String,
        in ctx: CGContext,
        at point: CGPoint,
        font: CTFont,
        gray: CGFloat
    ) {
        let color = CGColor(red: gray, green: gray, blue: gray, alpha: 1)
        // AppKit を入れないので CoreText の属性キーを直接使う
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }
}

enum ContactSheetError: Error, CustomStringConvertible {
    case contextFailed
    case imageFailed
    case writeFailed(String)

    var description: String {
        switch self {
        case .contextFailed: return "描画コンテキストを作れません"
        case .imageFailed:   return "画像を取り出せません"
        case .writeFailed(let p): return "PNG を書けません: \(p)"
        }
    }
}

// MARK: - 出力先

/// DatasetWriter への書き込みを直列化し、クラスごとの上限も見る。
final class SampleSink: @unchecked Sendable {
    private let writer: DatasetWriter
    private let lock = NSLock()
    private var perClass: [Int: Int] = [:]
    private let limitPerClass: Int
    private(set) var written = 0
    private(set) var droppedByLimit = 0
    private(set) var fontNames: [String] = []

    init(writer: DatasetWriter, limitPerClass: Int) {
        self.writer = writer
        self.limitPerClass = limitPerClass
    }

    func write(fontName: String, samples: [(label: Int, image: CharacterImage)]) throws {
        lock.lock()
        defer { lock.unlock() }
        if !fontNames.contains(fontName) {
            fontNames.append(fontName)
        }
        for s in samples {
            if limitPerClass > 0 && perClass[s.label, default: 0] >= limitPerClass {
                droppedByLimit += 1
                continue
            }
            try writer.append(label: s.label, image: s.image)
            perClass[s.label, default: 0] += 1
            written += 1
        }
    }

    /// 1 件以上書けたクラスの数
    var coveredClasses: Int {
        lock.lock()
        defer { lock.unlock() }
        return perClass.count
    }

    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        try writer.close()
    }
}

/// 1 フォント分の集計
struct FontStats: Sendable {
    var font = ""
    var origin = ""
    var drawn = 0
    var skippedNoGlyph = 0
    var skippedBlank = 0
    var samples = 0
    /// マス目から少しでもはみ出した文字の数 (配置で収めているので 0 のはず)
    var overflowAny = 0
    /// マス目から 5% 以上はみ出した文字の数
    var overflowOver5 = 0
    /// はみ出し割合の合計 (平均を出すのに使う)
    var overflowSum = 0.0
    /// はみ出し割合の最大
    var overflowMax = 0.0
    /// 書体の配置のままでははみ出すので平行移動したグリフの数
    var moved = 0
    /// マス目より大きいので縮小したグリフの数
    var shrunk = 0
    var seconds = 0.0
}

final class StatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stats: [FontStats] = []
    func add(_ s: FontStats) {
        lock.lock()
        stats.append(s)
        lock.unlock()
    }
}

// MARK: - 本体

func run() {
    let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
    let vocab = CharacterVocabulary.shared
    let started = Date()

    // --- フォントの読み込み ---
    // 数百〜数千ファイルになるので、被覆率の走査 (1 フォントあたり語彙数ぶんのグリフ検索) を
    // 並列化する。CTFont は不変で thread-safe。結果は後で名前順に並べ直すので決定的。
    var entries = [FontEntry]()
    var rejected = [(name: String, reason: String)]()
    var seenPSNames = Set<String>()

    // 正規表現フィルタ (PostScript 名かファイル名に当てる)
    var filterRegex: NSRegularExpression?
    if let pattern = options.fontFilter {
        do {
            filterRegex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            fail("--font-filter の正規表現が不正です: \(pattern): \(error)")
        }
    }
    func passesFilter(name: String, fileName: String) -> Bool {
        guard let re = filterRegex else {
            return true
        }
        for s in [name, fileName] where !s.isEmpty {
            let r = NSRange(s.startIndex ..< s.endIndex, in: s)
            if re.firstMatch(in: s, options: [], range: r) != nil {
                return true
            }
        }
        return false
    }

    let fontsDirURL = URL(fileURLWithPath: options.fontsDir)
    var fileURLs = [URL]()
    if let items = try? FileManager.default.contentsOfDirectory(
        at: fontsDirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) {
        // 直下のみ。dedupe.sh が重複排除してフラットに置いた前提
        fileURLs = items
            .filter { ["ttf", "otf", "ttc"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } else {
        logLine("警告: フォントディレクトリを読めません: \(options.fontsDir)")
    }

    // ファイル名の時点でフィルタを掛け、読み込む本数自体を減らす
    let targetFileURLs = fileURLs.filter { passesFilter(name: "", fileName: $0.lastPathComponent) }
    // 明示指定が無ければ <fonts-dir>/system-fonts.txt から読む (ソースに名前を持たない)
    let systemFontNames = options.systemFonts ?? Options.loadSystemFontList(fontsDir: options.fontsDir)
    let targetSystemNames = systemFontNames.filter { passesFilter(name: $0, fileName: "") }
    let skippedByFilter = (fileURLs.count - targetFileURLs.count)
        + (systemFontNames.count - targetSystemNames.count)

    let collector = LoadCollector()
    let loadWidth = max(1, min(options.workers, max(1, targetSystemNames.count + targetFileURLs.count)))
    let totalToLoad = targetSystemNames.count + targetFileURLs.count
    logLine("== フォント読み込み: system \(targetSystemNames.count) + ファイル \(targetFileURLs.count) 件 (並列 \(loadWidth))")

    DispatchQueue.concurrentPerform(iterations: loadWidth) { chunk in
        var i = chunk
        while i < totalToLoad {
            if i < targetSystemNames.count {
                let psName = targetSystemNames[i]
                switch FontLoader.loadSystem(psName, sizes: options.allSizes, scripts: options.scripts,
                                             kanjiAllowed: options.kanjiAllowed,
                                             kanjiMaxWeight: options.kanjiMaxWeight) {
                case .loaded(let e):  collector.addLoaded(e)
                case .rejected(let w): collector.addRejected(psName, w)
                }
            } else {
                let url = targetFileURLs[i - targetSystemNames.count]
                for r in FontLoader.loadFile(url, sizes: options.allSizes, scripts: options.scripts,
                                             kanjiAllowed: options.kanjiAllowed,
                                             kanjiMaxWeight: options.kanjiMaxWeight) {
                    switch r {
                    case .loaded(let e):  collector.addLoaded(e)
                    case .rejected(let w): collector.addRejected(url.lastPathComponent, w)
                    }
                }
            }
            i += loadWidth
        }
    }

    // PostScript 名で重複排除。並列で集めたので名前順に並べてから決定的に選ぶ。
    // system を優先し、その後はファイル名順。
    let loadedSorted = collector.loaded.sorted { a, b in
        if a.postScriptName != b.postScriptName {
            return a.postScriptName < b.postScriptName
        }
        let aSystem = a.origin.shortLabel == "system"
        let bSystem = b.origin.shortLabel == "system"
        if aSystem != bSystem {
            return aSystem
        }
        return a.origin.path < b.origin.path
    }
    // --list-faces-tsv: 重複排除する前の全 face を書き出して終了する。
    // 可変フォントは名前付きインスタンスごとに 1 行になる。
    if let facesPath = options.listFacesTSV {
        var t = "postscript_name\torigin\tpath\n"
        for e in loadedSorted {
            t += e.postScriptName + "\t" + e.origin.shortLabel + "\t" + e.origin.path + "\n"
        }
        let u = URL(fileURLWithPath: facesPath)
        do {
            try FileManager.default.createDirectory(
                at: u.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try t.write(to: u, atomically: true, encoding: .utf8)
        } catch {
            fail("face TSV を書けません: \(facesPath): \(error)")
        }
        let names = loadedSorted.map { $0.postScriptName }
        let dupes = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }
        print("face 総数: \(loadedSorted.count)")
        print("ユニークな PostScript 名: \(Set(names).count)")
        print("2 つ以上のファイルが名乗る PostScript 名: \(dupes.count)")
        print("出力: \(facesPath)")
        return
    }

    rejected = collector.rejected
    for e in loadedSorted {
        if seenPSNames.contains(e.postScriptName) {
            let who = e.origin.path.isEmpty ? e.postScriptName : (e.origin.path as NSString).lastPathComponent
            rejected.append((who, "PostScript 名 \(e.postScriptName) が重複 (先に読んだものを使う)"))
            continue
        }
        seenPSNames.insert(e.postScriptName)
        entries.append(e)
    }

    // --kanji-max-weight でウェイト超過のため漢字を描かない face の数。
    // 漢字だけが対象のときはこの後の「グリフ 0」フィルタで消えるので、落とす前に数える
    let kanjiExcludedByWeight = entries.filter { $0.kanjiExcludedByWeight }.count

    // 対象区分のグリフを 1 つも持たないフォントは自動でスキップする
    // (Latin 専用フォントに --scripts hiragana を指定した場合など)。
    // --list-fonts のときは被覆率を見せたいので落とさない。
    var skippedNoCoverage = 0
    if !options.listFonts {
        let before = entries.count
        entries = entries.filter { !$0.drawable.isEmpty }
        skippedNoCoverage = before - entries.count
    }

    // --require-script: 指定区分のグリフを持たないフォントを落とす
    var skippedByRequire = 0
    if !options.requireScripts.isEmpty && !options.listFonts {
        let before = entries.count
        entries = entries.filter { e in
            for c in options.requireScripts where (e.coverage[c]?.have ?? 0) > 0 {
                return true
            }
            return false
        }
        skippedByRequire = before - entries.count
    }
    if skippedByRequire > 0 {
        logLine("   --require-script \(options.requireScripts.map { $0.rawValue }.joined(separator: ",")) により \(skippedByRequire) 件を除外")
    }

    // held-out の照合はファミリー単位で行う。
    // ファミリー名 = PostScript 名の最初の '-' より前 (例 "Foo-SemiBold" -> "Foo")。
    // 指定側も同じ規則で切り出すので、"Foo" でも "Foo-Regular.ttf" でも同じ結果になる。
    // 前方一致なので、そのファミリーの全ウェイト・全バージョンがまとめて eval 側へ回る
    // (同じ書体の別ウェイトが train と eval に割れると held-out の意味が無くなるため)。
    func familyName(_ raw: String) -> String {
        var name = raw
        for ext in [".ttf", ".otf", ".ttc"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        if let i = name.firstIndex(of: "-") {
            name = String(name[name.startIndex ..< i])
        }
        return name.lowercased()
    }

    func matches(_ e: FontEntry, _ needle: String) -> Bool {
        return familyName(e.postScriptName).hasPrefix(familyName(needle))
    }

    func isHoldout(_ e: FontEntry) -> Bool {
        for needle in options.holdoutFonts where matches(e, needle) {
            return true
        }
        return false
    }

    // --max-fonts: シード付きの決定的な抽出 (並び順に依存しないよう名前順に並べてから引く)。
    // held-out に指定されたフォントは必ず残し、残り枠を train 候補から引く
    // (抽出で holdout が落ちると eval が空になってしまうため)。
    var sampledOut = 0
    if options.maxFonts > 0 && entries.count > options.maxFonts && !options.listFonts {
        let keep = entries.filter { isHoldout($0) }.sorted { $0.postScriptName < $1.postScriptName }
        var pool = entries.filter { !isHoldout($0) }.sorted { $0.postScriptName < $1.postScriptName }
        let slots = max(0, options.maxFonts - keep.count)
        if slots < pool.count {
            var rng = SplitMix64(seed: options.seed)
            var i = 0
            while i < slots {
                let j = i + Int(rng.next() % UInt64(pool.count - i))
                pool.swapAt(i, j)
                i += 1
            }
            pool = Array(pool.prefix(slots))
        }
        sampledOut = entries.count - (keep.count + pool.count)
        entries = (keep + pool).sorted { $0.postScriptName < $1.postScriptName }
        if keep.count > 0 {
            logLine("   --max-fonts: held-out \(keep.count) 件は抽出対象から外して必ず残す")
        }
    }

    if skippedByFilter > 0 {
        logLine("   --font-filter で除外 \(skippedByFilter) 件")
    }
    if skippedNoCoverage > 0 {
        logLine("   対象区分のグリフが 0 のため自動スキップ \(skippedNoCoverage) 件")
    }
    if sampledOut > 0 {
        logLine("   --max-fonts \(options.maxFonts) により \(sampledOut) 件を抽出で除外 (seed \(options.seed))")
    }

    if entries.isEmpty {
        fail("読み込めたフォントが 1 つもありません (--list-fonts で確認してください)")
    }

    // --- --list-fonts ---
    if options.listFonts {
        printFontTable(entries: entries, rejected: rejected, scripts: options.scripts, tsvPath: options.listFontsTSV)
        return
    }

    // --- train / eval の振り分け ---
    let evalEntries = entries.filter { isHoldout($0) }
    let trainEntries = entries.filter { !isHoldout($0) }

    for needle in options.holdoutFonts {
        var hit = false
        for e in evalEntries where matches(e, needle) {
            hit = true
        }
        if !hit {
            logLine("警告: --holdout-fonts \"\(needle)\" に一致するフォントがありません")
        }
    }

    if trainEntries.isEmpty {
        fail("train 側のフォントが 0 です (--holdout-fonts が全フォントに一致しています)")
    }
    if !options.holdoutFonts.isEmpty && evalEntries.isEmpty {
        fail("eval 側のフォントが 0 です (--holdout-fonts が 1 つも一致しません)")
    }

    // 漢字の描き方の 1 行要約 (ログと --dry-run で共用)。対象区分に漢字が無ければ出さない
    func kanjiOverrideLine() -> String? {
        if !options.scripts.contains(.kanjiLevel1) {
            return nil
        }
        let sz = options.sizes(for: .kanjiLevel1).map(String.init).joined(separator: ",")
        let ag = options.kanjiAugment ?? options.augment
        let note = options.kanjiAugment == nil ? "" : " (--oversample の倍率は掛けない)"
        var line = "   漢字: サイズ \(sz) / 拡張 \(ag)\(note)"
            + " / 膨張 確率 \(options.kanjiDilate) 最大 \(Options.kanjiMaxDilation)px (--kanji-dilate)"
        line += "\n   --kanji-max-weight \(options.kanjiMaxWeight):"
            + " ウェイト超過で漢字を描かない face \(kanjiExcludedByWeight) 件 (かな等には使う)"
        if let allowed = options.kanjiAllowed, let path = options.kanjiListPath {
            line += "\n   --kanji-list \(path): 対象 \(allowed.count) 字"
        }
        return line
    }

    // --- 手書き調の書体一覧 (--oversample-list) ---
    // 一覧の名前は PostScript 名の完全一致で引く。ソースには書体名を持たない (DESIGN §1)。
    let oversampleNames: Set<String> = options.oversampleListPath
        .map { Options.loadOversampleList(path: $0) } ?? []
    if let listPath = options.oversampleListPath {
        let hitTrain = trainEntries.filter { oversampleNames.contains($0.postScriptName) }
        let hitEval = evalEntries.filter { oversampleNames.contains($0.postScriptName) }
        let matched = Set(hitTrain.map { $0.postScriptName }).union(hitEval.map { $0.postScriptName })
        let missing = oversampleNames.subtracting(matched).sorted()
        logLine("   --oversample-list \(listPath): 一覧 \(oversampleNames.count) 件 /"
            + " train で一致 \(hitTrain.count) 件 (拡張 \(options.augment) -> \(options.augment * options.oversample))"
            + " / eval で一致 \(hitEval.count) 件 (倍率は掛けない)")
        if !missing.isEmpty {
            logLine("   注意: 一覧にあるが読み込めたフォントに無い名前 \(missing.count) 件: \(missing.joined(separator: ", "))")
        }
    }

    // --- --contact-sheet: 目視確認シートを書いて終了する ---
    if let sheetDir = options.contactSheetDir {
        // ラベルの描画に使うフォントは system-fonts.txt の先頭。
        // 読めなければ CoreText の既定 UI フォント (どちらもソースに名前を持たない)。
        var labelFont = CTFontCreateUIFontForLanguage(.system, 26.0, nil)
            ?? CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes([:] as CFDictionary), 26.0, nil)
        if let first = Options.loadSystemFontList(fontsDir: options.fontsDir).first {
            let candidate = CTFontCreateWithName(first as CFString, 26.0, nil)
            if (CTFontCopyPostScriptName(candidate) as String) == first {
                labelFont = candidate
            }
        }
        let probe = options.probe ?? ContactSheet.defaultProbe
        do {
            let pages = try ContactSheet.write(
                entries: entries, directory: sheetDir, labelFont: labelFont,
                probe: probe, ems: options.allSizes
            )
            print("コンタクトシート: \(entries.count) 書体 / \(pages) ページ -> \(sheetDir)")
            print("  確認文字列: \(String(probe)) (\(probe.count) 文字)")
            print("  桝: em \(options.allSizes.map(String.init).joined(separator: ","))px で描き"
                + " マス目基準で 32x32 にした画像 を \(ContactSheet.scale) 倍 (em ごとに別ファイル)")
        } catch {
            fail("コンタクトシートを書けません: \(error)")
        }
        return
    }

    // --- --dry-run: ここまでの解決結果だけ出して終了する (ファイルを一切作らない) ---
    if options.dryRun {
        print("dry-run: 何も書き込みません")
        print("対象フォント \(entries.count) 件 (train \(trainEntries.count) / eval \(evalEntries.count))")
        print("区分 \(options.scripts.map { $0.rawValue }.joined(separator: ",")) / サイズ \(options.sizes.map(String.init).joined(separator: ",")) / 拡張 \(options.augment)")
        if let line = kanjiOverrideLine() {
            print(line.trimmingCharacters(in: .whitespaces))
        }
        if options.oversampleListPath != nil {
            let hit = trainEntries.filter { oversampleNames.contains($0.postScriptName) }
            print("--oversample \(options.oversample) 倍の書体 (train) \(hit.count) 件: 拡張 \(options.augment) -> \(options.augment * options.oversample)")
        }
        if options.holdoutFonts.isEmpty {
            print("--holdout-fonts の指定なし")
        } else {
            print("")
            print("--holdout-fonts \(options.holdoutFonts.joined(separator: ",")) で eval に回るフォント (\(evalEntries.count) 件):")
            for e in evalEntries.sorted(by: { $0.postScriptName < $1.postScriptName }) {
                let file = e.origin.path.isEmpty ? "(system)" : (e.origin.path as NSString).lastPathComponent
                print("  \(e.postScriptName.padding(toLength: 34, withPad: " ", startingAt: 0)) ファミリー=\(familyName(e.postScriptName).padding(toLength: 18, withPad: " ", startingAt: 0)) \(file)")
            }
        }
        print("")
        print("train に残るフォント \(trainEntries.count) 件 (先頭 10)")
        for e in trainEntries.sorted(by: { $0.postScriptName < $1.postScriptName }).prefix(10) {
            print("  \(e.postScriptName)")
        }
        return
    }

    // --- 出力先 ---
    let outDir = URL(fileURLWithPath: options.outDir)
    do {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    } catch {
        fail("出力先を作れません: \(options.outDir): \(error)")
    }
    let trainURL = outDir.appendingPathComponent("\(options.name)_train.stgk")
    let evalURL = outDir.appendingPathComponent("\(options.name)_eval.stgk")

    let trainSink: SampleSink
    let evalSink: SampleSink?
    do {
        trainSink = SampleSink(writer: try DatasetWriter(url: trainURL), limitPerClass: options.limitPerClass)
        evalSink = evalEntries.isEmpty
            ? nil
            : SampleSink(writer: try DatasetWriter(url: evalURL), limitPerClass: options.limitPerClass)
    } catch {
        fail("データセットを開けません: \(error)")
    }

    logLine("== render: フォント \(entries.count) 件 (train \(trainEntries.count) / eval \(evalEntries.count))")
    logLine("   区分 \(options.scripts.map { $0.rawValue }.joined(separator: ",")) / サイズ \(options.sizes.map(String.init).joined(separator: ",")) / 拡張 \(options.augment) / workers \(options.workers)")
    if let line = kanjiOverrideLine() {
        logLine(line)
    }
    if options.oversampleListPath != nil {
        let hit = trainEntries.filter { oversampleNames.contains($0.postScriptName) }.count
        logLine("   手書き調 \(hit) 書体 (train) は拡張 \(options.augment * options.oversample) 枚 (--oversample \(options.oversample))")
    }

    let statsBox = StatsBox()

    // 1 フォント分の生成。拡張の乱数シードはフォント固定なのでスレッドの割り当てに依存しない。
    // oversampled = train 側 (手書き調の倍率を掛けてよい側) かどうか。
    @Sendable func process(entry: FontEntry, fontIndex: Int, oversampled: Bool, sink: SampleSink) {
        let t0 = Date()
        var stats = FontStats()
        stats.font = entry.postScriptName
        stats.origin = entry.origin.shortLabel

        let augmenter = Augmenter(seed: options.seed &+ UInt64(fontIndex) &* 0x9E3779B97F4A7C15)
        // 漢字は画数が多く、32x32 に縮めた後で膨張させると隣り合う画が融合して塊になる。
        // 膨張の確率 (既定 0) と最大 px を漢字だけ別のパラメータにする。乱数も別系列
        let kanjiAugmenter = Augmenter(
            seed: options.seed &+ 0xA5A5_5A5A &+ UInt64(fontIndex) &* 0x2545F4914F6CDD1D,
            parameters: Augmenter.Parameters(
                thicknessProbability: options.kanjiDilate,
                maxDilationPixels: Options.kanjiMaxDilation
            )
        )
        let vocabCount = vocab.count

        // 区分ごとの拡張枚数。--kanji-augment を指定した漢字には --oversample の倍率を掛けない
        // (手書き調の重み付けはかな側の判断なので漢字に持ち込まない)。
        let handwriting = oversampled && oversampleNames.contains(entry.postScriptName)
        func augmentCount(_ category: ScriptCategory) -> Int {
            if category == .kanjiLevel1, let n = options.kanjiAugment {
                return n
            }
            return handwriting ? options.augment * options.oversample : options.augment
        }
        let maxAugment = ScriptCategory.allCases.map { augmentCount($0) }.max() ?? 0

        for size in options.allSizes {
            guard let font = entry.fontsBySize[size] else {
                continue
            }
            // 1 em 四方がマス目。em = 描画サイズ (--sizes / --kanji-sizes で指定した px)
            let em = max(8, size)
            var batch = [(label: Int, image: CharacterImage)]()
            batch.reserveCapacity(entry.drawable.count * (1 + maxAugment))

            for item in entry.drawable {
                if item.index < 0 || item.index >= vocabCount {
                    continue
                }
                // この桝を使わない区分の文字は飛ばす (--kanji-sizes で漢字だけ別サイズにする)
                if !options.sizes(for: item.category).contains(size) {
                    continue
                }
                guard let glyph = FontLoader.glyph(font, item.scalar) else {
                    stats.skippedNoGlyph += 1
                    continue
                }
                guard let cell = GlyphRenderer.renderCell(
                    font: font, glyph: glyph, em: em, layout: entry.layout,
                    group: FontLayout.ScaleGroup(item.category)
                ) else {
                    stats.skippedBlank += 1
                    continue
                }
                if cell.moved { stats.moved += 1 }
                if cell.shrunk { stats.shrunk += 1 }
                if cell.overflowRatio > 0.0 {
                    stats.overflowAny += 1
                }
                stats.overflowSum += Double(cell.overflowRatio)
                if Double(cell.overflowRatio) > stats.overflowMax {
                    stats.overflowMax = Double(cell.overflowRatio)
                }
                if cell.overflowRatio >= 0.05 {
                    stats.overflowOver5 += 1
                }
                guard let base = try? ImageNormalizer.normalize(
                    width: em, height: em, gray: cell.gray, invert: true
                ) else {
                    stats.skippedBlank += 1
                    continue
                }
                if base.inkSum <= 0.0 {
                    // 描いたが墨が 1 画素も無い (空白グリフ・小さすぎて潰れた)
                    stats.skippedBlank += 1
                    continue
                }
                stats.drawn += 1

                batch.append((label: item.index, image: base))
                let aug = item.category == .kanjiLevel1 ? kanjiAugmenter : augmenter
                let augment = augmentCount(item.category)
                var a = 0
                while a < augment {
                    batch.append((label: item.index, image: aug.augment(base)))
                    a += 1
                }
            }

            do {
                try sink.write(fontName: entry.postScriptName, samples: batch)
            } catch {
                fail("書き込みに失敗: \(entry.postScriptName) size \(size): \(error)")
            }
            stats.samples += batch.count
        }

        stats.seconds = Date().timeIntervalSince(t0)
        statsBox.add(stats)
        let namePad = entry.postScriptName.padding(toLength: 34, withPad: " ", startingAt: 0)
        let originPad = stats.origin.padding(toLength: 9, withPad: " ", startingAt: 0)
        let overflowAvg = stats.drawn > 0 ? stats.overflowSum / Double(stats.drawn) : 0.0
        logLine("   [\(namePad)] \(originPad) 描画 \(stats.drawn) / グリフ無し \(stats.skippedNoGlyph)"
            + " / 空画像 \(stats.skippedBlank) / サンプル \(stats.samples)"
            + " / \(entry.layout.summary) / 移動 \(stats.moved) / 縮小 \(stats.shrunk)"
            + " / はみ出し あり \(stats.overflowAny) 5%以上 \(stats.overflowOver5)"
            + " (平均 \(String(format: "%.3f", overflowAvg)) 最大 \(String(format: "%.3f", stats.overflowMax)))"
            + " / \(String(format: "%.1f", stats.seconds)) 秒")
    }

    // --- 並列実行 (フォント単位。--workers で束ねる数を決める) ---
    // oversampled = true の側 (train) だけ手書き調の書体の拡張枚数を --oversample 倍にする。
    // eval は held-out フォントの素の分布を測るので倍率を掛けない (実際の枚数は process 内で決める)
    func runGroup(_ list: [FontEntry], offset: Int, oversampled: Bool, sink: SampleSink) {
        if list.isEmpty {
            return
        }
        let width = max(1, min(options.workers, list.count))
        if width == 1 {
            for (i, e) in list.enumerated() {
                process(entry: e, fontIndex: offset + i,
                        oversampled: oversampled, sink: sink)
            }
            return
        }
        DispatchQueue.concurrentPerform(iterations: width) { chunk in
            var i = chunk
            while i < list.count {
                let e = list[i]
                process(entry: e, fontIndex: offset + i,
                        oversampled: oversampled, sink: sink)
                i += width
            }
        }
    }

    runGroup(trainEntries, offset: 0, oversampled: true, sink: trainSink)
    if let evalSink {
        runGroup(evalEntries, offset: trainEntries.count, oversampled: false, sink: evalSink)
    }

    // --- 後始末とメタ ---
    do {
        try trainSink.close()
        try evalSink?.close()
    } catch {
        fail("データセットを閉じられません: \(error)")
    }

    let scriptNames = options.scripts.map { $0.rawValue }
    do {
        try DatasetMeta(
            fonts: trainEntries.map { $0.postScriptName }.sorted(),
            augmentations: options.augment,
            scripts: scriptNames
        ).write(to: DatasetMeta.sidecarURL(for: trainURL))
        if evalSink != nil {
            try DatasetMeta(
                fonts: evalEntries.map { $0.postScriptName }.sorted(),
                augmentations: options.augment,
                scripts: scriptNames
            ).write(to: DatasetMeta.sidecarURL(for: evalURL))
        }
    } catch {
        fail("メタ JSON を書けません: \(error)")
    }

    // --- まとめ ---
    let elapsed = Date().timeIntervalSince(started)
    var totalDrawn = 0
    var totalNoGlyph = 0
    var totalBlank = 0
    var totalOverflowAny = 0
    var totalOverflow5 = 0
    var totalOverflowSum = 0.0
    var totalMoved = 0
    var totalShrunk = 0
    var globalOverflowMax = 0.0
    for s in statsBox.stats {
        totalDrawn += s.drawn
        totalNoGlyph += s.skippedNoGlyph
        totalBlank += s.skippedBlank
        totalOverflowAny += s.overflowAny
        totalOverflow5 += s.overflowOver5
        totalOverflowSum += s.overflowSum
        totalMoved += s.moved
        totalShrunk += s.shrunk
        if s.overflowMax > globalOverflowMax {
            globalOverflowMax = s.overflowMax
        }
    }

    logLine("")
    logLine("== 完了 (\(String(format: "%.1f", elapsed)) 秒)")
    logLine("   train: \(trainSink.written) サンプル / \(trainSink.coveredClasses) クラス -> \(trainURL.path)")
    if let evalSink {
        logLine("   eval : \(evalSink.written) サンプル / \(evalSink.coveredClasses) クラス -> \(evalURL.path)")
    }
    logLine("   描画成功 \(totalDrawn) / グリフ無しスキップ \(totalNoGlyph) / 空画像スキップ \(totalBlank)")
    let avgOverflow = totalDrawn > 0 ? totalOverflowSum / Double(totalDrawn) : 0.0
    let pct = totalDrawn > 0 ? 100.0 * Double(totalOverflow5) / Double(totalDrawn) : 0.0
    let fontsScaled = entries.filter { e in e.layout.scales.values.contains { $0 < 1.0 } }.count
    let typoFonts = entries.filter { $0.layout.basis == .typo }.count
    logLine("   配置: typo \(typoFonts) 書体 / それ以外 \(entries.count - typoFonts) 書体"
        + " / 区分の縮尺が 1 未満 \(fontsScaled) 書体 / グリフ単位の調整 移動 \(totalMoved) / 縮小 \(totalShrunk)")
    logLine("   マス目からのはみ出し: あり \(totalOverflowAny) 件 / 5%以上 \(totalOverflow5) 件 (\(String(format: "%.2f", pct))%)"
        + " / 平均 \(String(format: "%.4f", avgOverflow)) / 最大 \(String(format: "%.3f", globalOverflowMax))")
    // 見切れた字で学習しない。配置で必ず収めているので、1 件でも残っていれば配置の不具合として止める
    // (書き出し済みのデータセットは使わないこと)
    if totalOverflowAny > 0 {
        fail("マス目からはみ出したサンプルが \(totalOverflowAny) 件あります。書き出したデータセットは使わず、"
            + "上の書体ごとの統計で「はみ出し」が 0 でない書体を確認してください")
    }
    if options.limitPerClass > 0 {
        let dropped = trainSink.droppedByLimit + (evalSink?.droppedByLimit ?? 0)
        logLine("   --limit-per-class \(options.limitPerClass) による除外 \(dropped)")
    }
    if !rejected.isEmpty {
        logLine("   読み込めなかったフォント \(rejected.count) 件:")
        for r in rejected {
            logLine("     \(r.name): \(r.reason)")
        }
    }

    // 標準出力には機械可読な 1 行だけ出す
    print("train=\(trainSink.written) eval=\(evalSink?.written ?? 0) fonts=\(entries.count) seconds=\(String(format: "%.1f", elapsed))")
}

func printFontTable(
    entries: [FontEntry],
    rejected: [(name: String, reason: String)],
    scripts: [ScriptCategory],
    tsvPath: String
) {
    let order: [ScriptCategory] = ScriptCategory.allCases
    let sorted = entries.sorted { $0.postScriptName < $1.postScriptName }

    // --- TSV (全件。数千行になるのでファイルへ) ---
    var tsv = "postscript_name\torigin\tpath"
    for c in order {
        tsv += "\t" + c.rawValue
    }
    tsv += "\tdrawable_in_scope\tlayout_basis\tbaseline"
    for g in FontLayout.ScaleGroup.allCases {
        tsv += "\tscale_" + g.rawValue + "\toffset_" + g.rawValue
    }
    tsv += "\n"
    for e in sorted {
        tsv += e.postScriptName + "\t" + e.origin.shortLabel + "\t" + e.origin.path
        for c in order {
            let cov = e.coverage[c] ?? (have: 0, total: 0)
            tsv += "\t\(cov.have)/\(cov.total)"
        }
        tsv += "\t\(e.drawable.count)\t\(e.layout.basis.rawValue)\t\(String(format: "%.4f", e.layout.baseline))"
        for g in FontLayout.ScaleGroup.allCases {
            tsv += "\t" + (e.layout.scales[g].map { String(format: "%.4f", $0) } ?? "")
            tsv += "\t" + (e.layout.offsets[g].map { String(format: "%.4f", $0) } ?? "")
        }
        tsv += "\n"
    }
    let tsvURL = URL(fileURLWithPath: tsvPath)
    do {
        try FileManager.default.createDirectory(
            at: tsvURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try tsv.write(to: tsvURL, atomically: true, encoding: .utf8)
    } catch {
        logLine("警告: TSV を書けません: \(tsvPath): \(error)")
    }

    // --- 標準出力には要約だけ ---
    let jp = sorted.filter { ($0.coverage[.hiragana]?.have ?? 0) >= 80 }
    let kanjiFull = sorted.filter { ($0.coverage[.kanjiLevel1]?.have ?? 0) >= 2965 }
    let kanjiSome = sorted.filter { ($0.coverage[.kanjiLevel1]?.have ?? 0) > 0 }
    let latinOnly = sorted.filter {
        ($0.coverage[.hiragana]?.have ?? 0) == 0
            && ($0.coverage[.kanjiLevel1]?.have ?? 0) == 0
            && ($0.coverage[.latinUpper]?.have ?? 0) > 0
    }

    print("読み込めたフォント: \(sorted.count) 件")
    print("  日本語被覆あり (hiragana >= 80) : \(jp.count) 件")
    print("  第一水準漢字を全部持つ (2965)   : \(kanjiFull.count) 件")
    print("  漢字を 1 字でも持つ             : \(kanjiSome.count) 件")
    print("  Latin 専用 (かな 0 / 漢字 0)    : \(latinOnly.count) 件")
    print("  対象区分: \(scripts.map { $0.rawValue }.joined(separator: ","))")
    print("  描ける文字数 (対象区分のみ) の合計: \(sorted.reduce(0) { $0 + $1.drawable.count })")
    print("  全件の被覆率 TSV: \(tsvPath)")

    func sample(_ list: [FontEntry], _ label: String, _ n: Int) {
        if list.isEmpty {
            return
        }
        print("")
        print("  -- \(label) の例 (先頭 \(min(n, list.count)) 件) --")
        var header = "     " + "PostScript 名".padding(toLength: 34, withPad: " ", startingAt: 0)
        header += " " + "出自".padding(toLength: 10, withPad: " ", startingAt: 0)
        for h in ["digit", "ascii", "upper", "lower", "hira", "kata", "kanji"] {
            header += " " + h.padding(toLength: 11, withPad: " ", startingAt: 0)
        }
        header += " 配置 (対象区分の縮尺)"
        print(header)
        for e in list.prefix(n) {
            var line = "     " + e.postScriptName.padding(toLength: 34, withPad: " ", startingAt: 0)
            line += " " + e.origin.shortLabel.padding(toLength: 10, withPad: " ", startingAt: 0)
            for c in order {
                let cov = e.coverage[c] ?? (have: 0, total: 0)
                line += " " + "\(cov.have)/\(cov.total)".padding(toLength: 11, withPad: " ", startingAt: 0)
            }
            line += " " + e.layout.summary
            print(line)
        }
    }

    sample(jp, "日本語被覆あり", 20)
    sample(latinOnly, "Latin 専用", 10)

    if !rejected.isEmpty {
        // 全件はファイルへ (PostScript 名の重複 = 同名だが内容の違うファイルの一覧になる)
        let rejURL = URL(fileURLWithPath: tsvPath + ".rejected.tsv")
        var rt = "source\treason\n"
        for r in rejected.sorted(by: { $0.name < $1.name }) {
            rt += r.name + "\t" + r.reason + "\n"
        }
        try? rt.write(to: rejURL, atomically: true, encoding: .utf8)

        print("")
        print("読み込めなかった / 除外したフォント: \(rejected.count) 件 (フォールバックしたものはこの表に載せない)")
        print("  全件: \(rejURL.path)")
        for r in rejected.prefix(15) {
            print("  \(r.name): \(r.reason)")
        }
        if rejected.count > 15 {
            print("  ... 残り \(rejected.count - 15) 件は上のファイルを参照")
        }
    }
}

run()
exit(0)
