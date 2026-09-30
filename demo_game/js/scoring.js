// 得点・ドパ・コンボ・演出強度の計算。すべて純粋関数 (DOM も乱数も使わない)。
//
// 式は参考仕様のものを、1 問 1 マス (m = 1) の書き取りに当てはめたもの。

/** 1 ステージの問題数 */
export const STAGE_QUESTIONS = 10;
/** ドパ (常用対数) の上限 */
export const DOPA_MAX = 9.08;
/** 1 回の正解で必ず加わる最低のドパ増分 */
export const DOPA_MIN_STEP = 0.003;
/** ドパの節目 (常用対数)。100 / 1000 / 1万 / 10万 / 100万 / 1000万 / 1億 */
const DOPA_MILESTONES = [2, 3, 4, 5, 6, 7, 8];
/** この数以上のコンボが途切れたら終了数を表示する */
export const COMBO_REPORT_MIN = 5;
/** 電飾を点ける強度 E */
export const LIGHTS_FROM = 0.6;
/** 短く祝うコンボ数 (これ以降は 100 以上で 50 ごと) */
const COMBO_CELEBRATIONS = [10, 20, 30, 50, 75];

function clamp(v, lo, hi) {
  return Math.min(hi, Math.max(lo, v));
}

// MARK: - 得点 (SPEC §5.1)

/**
 * 得点。ステージ 1 は 1 問 10 点 (10 問完走で 100 点)、ステージ 2 以降で k 問目 (0 始まり、
 * ステージ 2 以降で正解した数) に正解すると 10 + 5k 点 (旧エクストラの式)。
 * ステージ 2 以降で n 問正解した合計は 10 × (ステージ 1 の正解数) + 10n + 5n(n−1)/2。
 */
export function score(firstStageSolved, laterSolved) {
  const later = 10 * laterSolved + 5 * laterSolved * (laterSolved - 1) / 2;
  return 10 * firstStageSolved + later;
}

/** ステージ 2 以降の k 問目 (0 始まり、ステージ 2 以降で正解した数) の加点 */
export function extraQuestionScore(k) {
  return 10 + 5 * k;
}

// MARK: - ドパ (SPEC §5.2)

/** ステージ 1 の基準曲線 B(f) = 2.3 * clamp(f, 0, 1)^1.15 */
export function baseCurve(f) {
  return 2.3 * Math.pow(clamp(f, 0, 1), 1.15);
}

/** ステージ 2 以降の基準曲線 X(n) = 2.3 + 3.0 * (1 − exp(−n / 10)) */
export function extraCurve(n) {
  return 2.3 + 3.0 * (1 - Math.exp(-n / 10));
}

/** ステージ 1 の q 問目 (0 始まり、問題の位置) を解いたときの基準増分。1 問 1 マスなので m = 1 */
export function baseIncrement(q, total) {
  return baseCurve((q + 1) / total) - baseCurve(q / total);
}

/** ステージ 2 以降の k 問目 (0 始まり、ステージ 2 以降で正解した数) を解いたときの基準増分 */
export function extraIncrement(k) {
  return extraCurve(k + 1) - extraCurve(k);
}

/** コンボ倍率 M(c) = 1 + min(1, max(0, c) / 20)。10 コンボで 1.5 倍、20 以上で 2 倍 */
export function comboMultiplier(c) {
  return 1 + Math.min(1, Math.max(0, c) / 20);
}

/**
 * ドパを進める。combo は「この正解を数えたあと」のコンボ数。
 * 新しい L = min(上限, L + max(最低増分, 基準増分) * M(c))
 */
export function advanceDopa(level, increment, combo) {
  return Math.min(DOPA_MAX, level + Math.max(DOPA_MIN_STEP, increment) * comboMultiplier(combo));
}

/** prev から next の間に越えた節目 (常用対数) の一覧 */
export function crossedMilestones(prev, next) {
  return DOPA_MILESTONES.filter((m) => prev < m && next >= m);
}

/**
 * ドパの表示。1 万未満は整数、以降は「万」「億」を付け、
 * 単位内の値が 10 未満なら小数第 1 位まで、10 以上なら切り捨てた整数にする。
 * 端数はすべて切り捨てる (9999.7 が「10000」になってから「1.0万」に戻るのを避けるため)。
 * 上限 10^9.08 = 12 億なので「兆」には届かない。
 */
export function formatDopa(level) {
  const value = Math.pow(10, level);
  const units = [[1e8, '億'], [1e4, '万']];
  for (const [base, name] of units) {
    if (value >= base) {
      const x = value / base;
      return (x < 10 ? truncate(x, 1).toFixed(1) : String(truncate(x, 0))) + name;
    }
  }
  return String(truncate(value, 0));
}

/** 最高記録の表示。未記録 (null) は 10^0 = 1 ではなく 0 と出す */
export function formatBestDopa(level) {
  return level === null ? '0' : formatDopa(level);
}

/** 切り捨て。10^L は浮動小数点なので、10^4 が 9999.999… になるぶんだけ余裕を持たせる */
function truncate(x, digits) {
  const f = Math.pow(10, digits);
  return Math.floor(x * f + 1e-9) / f;
}

// MARK: - コンボ (SPEC §5.3)

/** 大きく祝うコンボ数か。10・20・30・50・75 と、100 以上の 50 ごと */
export function isComboCelebration(combo) {
  if (COMBO_CELEBRATIONS.includes(combo)) {
    return true;
  }
  return combo >= 100 && combo % 50 === 0;
}

/**
 * 節目の 1 つ手前 (リーチ) か。次の 1 問が当たれば祝いになる状態を指す。
 * 9 → 10、19 → 20、29 → 30、49 → 50、74 → 75、99 → 100 …
 */
export function isComboReach(combo) {
  return combo >= 1 && isComboCelebration(combo + 1);
}

// MARK: - 演出強度 (SPEC §8)

/** ステージ 1 の i 問目 (0 始まり) の演出強度 E = 0.08 + 0.92 * (i/(N−1))^1.3 */
export function baseIntensity(index, total) {
  if (total <= 1) {
    return 1;
  }
  return 0.08 + 0.92 * Math.pow(clamp(index / (total - 1), 0, 1), 1.3);
}

/** ステージ 2 以降の段 tier = floor(k/3) (k = ステージ 2 以降で正解した数) */
export function extraTier(k) {
  return Math.floor(k / 3);
}

/** ステージ 2 以降の演出強度 E = 1 + min(0.5, tier * 0.1) */
export function extraIntensity(k) {
  return 1 + Math.min(0.5, extraTier(k) * 0.1);
}

/**
 * 「あつめた字」の帯に並べる枠の数。ステージ 1 の 10 問ぶんを最初から空で見せ、
 * ステージをまたいで 10 を越えたらその数だけ伸ばす。
 */
export function collectedSlots(collected) {
  return Math.max(STAGE_QUESTIONS, Math.max(0, Math.floor(collected)));
}
