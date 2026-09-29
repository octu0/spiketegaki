// 出題データ (小学 1 年の 80 字) と、ラウンドの組み立て。
//
// 1 件 = { kanji, reading, word, wordReading }
//   kanji       書いてもらう 1 字
//   reading     その字の代表的な読み (手がかり)。例語の読みの中に必ずそのまま現れる
//   word        その字を 1 か所だけ含む例語。ほかの字はひらがなで書く
//   wordReading word 全体の読み (ひらがな)
//
// 対象字は表示のときに空欄 (□) にする。字は小学 1 年で習う 80 字。

export const BLANK = '□';

export const PROBLEMS = [
  { kanji: '一', reading: 'いち',   word: '一ばん',     wordReading: 'いちばん' },
  { kanji: '右', reading: 'みぎ',   word: '右て',       wordReading: 'みぎて' },
  { kanji: '雨', reading: 'あめ',   word: '雨ふり',     wordReading: 'あめふり' },
  { kanji: '円', reading: 'えん',   word: 'ひゃく円',   wordReading: 'ひゃくえん' },
  { kanji: '王', reading: 'おう',   word: '王さま',     wordReading: 'おうさま' },
  { kanji: '音', reading: 'おと',   word: 'あし音',     wordReading: 'あしおと' },
  { kanji: '下', reading: 'した',   word: '下じき',     wordReading: 'したじき' },
  { kanji: '火', reading: 'ひ',     word: '火ばな',     wordReading: 'ひばな' },
  { kanji: '花', reading: 'はな',   word: '花たば',     wordReading: 'はなたば' },
  { kanji: '貝', reading: 'かい',   word: '貝がら',     wordReading: 'かいがら' },
  { kanji: '学', reading: 'がく',   word: '学ねん',     wordReading: 'がくねん' },
  { kanji: '気', reading: 'き',     word: '気もち',     wordReading: 'きもち' },
  { kanji: '九', reading: 'きゅう', word: '九ひき',     wordReading: 'きゅうひき' },
  { kanji: '休', reading: 'やす',   word: '休み',       wordReading: 'やすみ' },
  { kanji: '玉', reading: 'たま',   word: '玉ねぎ',     wordReading: 'たまねぎ' },
  { kanji: '金', reading: 'かね',   word: 'お金',       wordReading: 'おかね' },
  { kanji: '空', reading: 'そら',   word: '空いろ',     wordReading: 'そらいろ' },
  { kanji: '月', reading: 'つき',   word: '月あかり',   wordReading: 'つきあかり' },
  { kanji: '犬', reading: 'いぬ',   word: '犬ごや',     wordReading: 'いぬごや' },
  { kanji: '見', reading: 'み',     word: '見る',       wordReading: 'みる' },
  { kanji: '五', reading: 'ご',     word: '五かい',     wordReading: 'ごかい' },
  { kanji: '口', reading: 'くち',   word: '口ぶえ',     wordReading: 'くちぶえ' },
  { kanji: '校', reading: 'こう',   word: 'がっ校',     wordReading: 'がっこう' },
  { kanji: '左', reading: 'ひだり', word: '左がわ',     wordReading: 'ひだりがわ' },
  { kanji: '三', reading: 'さん',   word: '三かく',     wordReading: 'さんかく' },
  { kanji: '山', reading: 'やま',   word: '山のぼり',   wordReading: 'やまのぼり' },
  { kanji: '子', reading: 'こ',     word: '子ども',     wordReading: 'こども' },
  { kanji: '四', reading: 'し',     word: '四かく',     wordReading: 'しかく' },
  { kanji: '糸', reading: 'いと',   word: '糸でんわ',   wordReading: 'いとでんわ' },
  { kanji: '字', reading: 'じ',     word: 'かん字',     wordReading: 'かんじ' },
  { kanji: '耳', reading: 'みみ',   word: '耳たぶ',     wordReading: 'みみたぶ' },
  { kanji: '七', reading: 'なな',   word: '七いろ',     wordReading: 'なないろ' },
  { kanji: '車', reading: 'くるま', word: '車いす',     wordReading: 'くるまいす' },
  { kanji: '手', reading: 'て',     word: '手がみ',     wordReading: 'てがみ' },
  { kanji: '十', reading: 'じゅう', word: '十まい',     wordReading: 'じゅうまい' },
  { kanji: '出', reading: 'で',     word: '出ぐち',     wordReading: 'でぐち' },
  { kanji: '女', reading: 'おんな', word: '女のこ',     wordReading: 'おんなのこ' },
  { kanji: '小', reading: 'ちい',   word: '小さい',     wordReading: 'ちいさい' },
  { kanji: '上', reading: 'うえ',   word: '上むき',     wordReading: 'うえむき' },
  { kanji: '森', reading: 'もり',   word: '森のなか',   wordReading: 'もりのなか' },
  { kanji: '人', reading: 'ひと',   word: '人びと',     wordReading: 'ひとびと' },
  { kanji: '水', reading: 'みず',   word: '水たまり',   wordReading: 'みずたまり' },
  { kanji: '正', reading: 'ただ',   word: '正しい',     wordReading: 'ただしい' },
  { kanji: '生', reading: 'い',     word: '生きもの',   wordReading: 'いきもの' },
  { kanji: '青', reading: 'あお',   word: '青ぞら',     wordReading: 'あおぞら' },
  { kanji: '夕', reading: 'ゆう',   word: '夕やけ',     wordReading: 'ゆうやけ' },
  { kanji: '石', reading: 'いし',   word: '石ころ',     wordReading: 'いしころ' },
  { kanji: '赤', reading: 'あか',   word: '赤ちゃん',   wordReading: 'あかちゃん' },
  { kanji: '千', reading: 'せん',   word: '千ばづる',   wordReading: 'せんばづる' },
  { kanji: '川', reading: 'かわ',   word: '川ぎし',     wordReading: 'かわぎし' },
  { kanji: '先', reading: 'せん',   word: '先せい',     wordReading: 'せんせい' },
  { kanji: '早', reading: 'はや',   word: '早おき',     wordReading: 'はやおき' },
  { kanji: '草', reading: 'くさ',   word: '草はら',     wordReading: 'くさはら' },
  { kanji: '足', reading: 'あし',   word: '足あと',     wordReading: 'あしあと' },
  { kanji: '村', reading: 'むら',   word: '村まつり',   wordReading: 'むらまつり' },
  { kanji: '大', reading: 'おお',   word: '大きい',     wordReading: 'おおきい' },
  { kanji: '男', reading: 'おとこ', word: '男のこ',     wordReading: 'おとこのこ' },
  { kanji: '竹', reading: 'たけ',   word: '竹とんぼ',   wordReading: 'たけとんぼ' },
  { kanji: '中', reading: 'なか',   word: 'まん中',     wordReading: 'まんなか' },
  { kanji: '虫', reading: 'むし',   word: '虫めがね',   wordReading: 'むしめがね' },
  { kanji: '町', reading: 'まち',   word: '町なみ',     wordReading: 'まちなみ' },
  { kanji: '天', reading: 'てん',   word: '天き',       wordReading: 'てんき' },
  { kanji: '田', reading: 'た',     word: '田うえ',     wordReading: 'たうえ' },
  { kanji: '土', reading: 'つち',   word: '土あそび',   wordReading: 'つちあそび' },
  { kanji: '二', reading: 'に',     word: '二かい',     wordReading: 'にかい' },
  { kanji: '日', reading: 'ひ',     word: '日ので',     wordReading: 'ひので' },
  { kanji: '入', reading: 'はい',   word: '入る',       wordReading: 'はいる' },
  { kanji: '年', reading: 'とし',   word: 'お年だま',   wordReading: 'おとしだま' },
  { kanji: '白', reading: 'しろ',   word: '白くま',     wordReading: 'しろくま' },
  { kanji: '八', reading: 'はち',   word: '八じ',       wordReading: 'はちじ' },
  { kanji: '百', reading: 'ひゃく', word: '百てん',     wordReading: 'ひゃくてん' },
  { kanji: '文', reading: 'ぶん',   word: '文しょう',   wordReading: 'ぶんしょう' },
  { kanji: '木', reading: 'き',     word: '木のえだ',   wordReading: 'きのえだ' },
  { kanji: '本', reading: 'ほん',   word: '本だな',     wordReading: 'ほんだな' },
  { kanji: '名', reading: 'な',     word: '名まえ',     wordReading: 'なまえ' },
  { kanji: '目', reading: 'め',     word: '目ざまし',   wordReading: 'めざまし' },
  { kanji: '立', reading: 'た',     word: '立つ',       wordReading: 'たつ' },
  { kanji: '力', reading: 'ちから', word: '力もち',     wordReading: 'ちからもち' },
  { kanji: '林', reading: 'はやし', word: '林のなか',   wordReading: 'はやしのなか' },
  { kanji: '六', reading: 'ろく',   word: '六ねん',     wordReading: 'ろくねん' }
];

/** 例語の対象字を空欄にした表示用の文字列 (例: 山のぼり -> □のぼり) */
export function blankedWord(problem) {
  return problem.word.split(problem.kanji).join(BLANK);
}

/** 0 以上 max 未満の整数。random は [0, 1) を返す関数 */
function pick(max, random) {
  return Math.min(max - 1, Math.floor(random() * max));
}

/**
 * 基本ラウンドの出題を作る。重複なしでランダムに count 問。
 *
 * @param {number} count 問題数
 * @param {() => number} random [0, 1) の乱数
 * @returns {object[]} PROBLEMS の要素
 */
export function makeRound(count, random = Math.random) {
  const pool = PROBLEMS.slice();
  const out = [];
  const n = Math.min(count, pool.length);
  for (let i = 0; i < n; i += 1) {
    out.push(pool.splice(pick(pool.length, random), 1)[0]);
  }
  return out;
}

/**
 * エクストラの 1 問を選ぶ。重複はしてよいが、直前 `avoidCount` 問と同じ字は避ける。
 *
 * @param {object[]} recent 直近に出した問題 (新しいものが末尾)
 * @param {() => number} random [0, 1) の乱数
 * @param {number} avoidCount 避ける直前の問題数
 */
export function pickExtra(recent, random = Math.random, avoidCount = 10) {
  const avoid = new Set(recent.slice(-avoidCount).map((p) => p.kanji));
  const pool = PROBLEMS.filter((p) => !avoid.has(p.kanji));
  const from = pool.length === 0 ? PROBLEMS : pool;
  return from[pick(from.length, random)];
}
