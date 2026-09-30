// 演出のエスカレーション (「どんどんアガる」) の計算。すべて純粋関数 (DOM も乱数も使わない)。
//
// 1 問目は控えめに始め、正解が増えるほど・問題が進むほど、背景の回転・観客の人数・
// 飾りの量を毎問 1 段ずつ上げる。画面側 (fx.js / crowd.js / props.js / main.js) は
// ここが返す数をそのまま使う。

function clamp(v, lo, hi) {
  return Math.min(hi, Math.max(lo, v));
}

// MARK: - 背景 (サンバースト) の回転

/** 1 問目・0 コンボの回転速度 (rad/s)。第 2 段階の最低速度の約 3 倍 */
export const SPIN_BASE = 0.08;
/** コンボによる加速がここで頭打ちになる (20 コンボで 6 倍 =「ぐるんぐるん」) */
export const SPIN_FULL_COMBO = 20;
/** 速度が変わるときのイージングの長さ (ms) */
export const SPIN_EASE_MS = 300;
/** 誤答から完全に止まるまで (ms)。イージングの長さと同じ */
export const SPIN_STOP_MS = 300;
/** 止まったまま待つ時間 (ms) */
export const SPIN_HOLD_MS = 500;
/** 誤答のあと、次の正解までのゆっくり回転 (通常の何倍か) */
export const SPIN_SLOW = 0.3;

/**
 * 背景の回転速度 (rad/s) の目標値。
 *
 *   base × (1 + 2 i/(N−1)) × (1 + min(combo, 20)/4)
 *
 * ステージ 2 以降はステージ 1 の最終問と同じ進行度 (i = N−1) として扱う。
 * 誤答のあと (sinceMissMs が数のとき) は 800 ms 止め、以後は 0.3 倍。
 * 次の正解で呼び出し側が sinceMissMs を null に戻すと元の速度に戻る。
 *
 * @param {object} state
 * @param {number} state.index ステージ内の問題番号 (0 始まり)
 * @param {number} state.total 1 ステージの問題数 N
 * @param {boolean} [state.later] ステージ 2 以降か
 * @param {number} state.combo 今のコンボ数
 * @param {number|null} [state.sinceMissMs] 最後の誤答からの経過 (ms)。誤答のあと正解していなければ数
 */
export function spinSpeed({ index, total, later = false, combo, sinceMissMs = null }) {
  const progress = later || total <= 1 ? 1 : clamp(index / (total - 1), 0, 1);
  const boost = 1 + clamp(combo, 0, SPIN_FULL_COMBO) / 4;
  const full = SPIN_BASE * (1 + 2 * progress) * boost;
  if (sinceMissMs === null || !Number.isFinite(sinceMissMs)) {
    return full;
  }
  if (sinceMissMs < SPIN_STOP_MS + SPIN_HOLD_MS) {
    return 0;
  }
  return full * SPIN_SLOW;
}

/**
 * from から to へ SPIN_EASE_MS かけて移る途中の速度 (smoothstep)。
 * @param {number} elapsedMs 目標が変わってからの経過 (ms)
 */
export function easeSpin(from, to, elapsedMs) {
  const t = clamp(elapsedMs / SPIN_EASE_MS, 0, 1);
  return from + (to - from) * t * t * (3 - 2 * t);
}

// MARK: - 観客

/** 観客の最大人数 */
export const CROWD_MAX = 40;
/** 1 回の正解で増える観客の数 (平均。1 問ごとに 2〜3 体) */
const CROWD_PER_CORRECT = 2.3;

/**
 * 観客の人数。正解数 c が 0 のとき 1 体、1 問ごとに 2〜3 体増えて
 * ステージ 1 の完走で 24 体。ステージ 2 以降 (E > 1) はさらに E 倍で増え、40 体で頭打ち。
 *
 * @param {number} correct 正解数 (ステージをまたいで数える)
 * @param {number} intensity 演出強度 E
 */
export function crowdCount(correct, intensity) {
  const c = Math.max(0, Math.floor(correct));
  const e = Math.max(1, intensity);
  return clamp(1 + Math.round(CROWD_PER_CORRECT * c * e), 1, CROWD_MAX);
}

/** 帯を離れて画面内を歩き回る観客の数 (4 体に 1 体、最大 8 体)。先頭の 1 体は必ず帯に残る */
export function walkerCount(count) {
  return clamp(Math.floor((count - 1) / 4), 0, 8);
}

/** 喜び方の段階 */
export const CHEER_NONE = 0;
export const CHEER_HOP = 1;        // 跳ねる
export const CHEER_CONFETTI = 2;   // 各自が紙吹雪を撒く
export const CHEER_DANCE = 3;      // 踊る (回転 + 腕上げ)
export const CHEER_RING = 4;       // 筆記領域のまわりに輪になって踊る + 花火

/**
 * 正解数 c (ラウンド内) に応じた喜び方。
 * 1〜2 = 跳ねる、3〜5 = 紙吹雪、6〜8 = 踊る、9 以上 = 輪になる。
 */
export function cheerLevel(correct) {
  if (correct >= 9) {
    return CHEER_RING;
  }
  if (correct >= 6) {
    return CHEER_DANCE;
  }
  if (correct >= 3) {
    return CHEER_CONFETTI;
  }
  return correct >= 1 ? CHEER_HOP : CHEER_NONE;
}

/** 正解のとき画面を放物線で飛び越える観客の数。E 0.8 から出て、E 1.5 で 5 体 */
export function leaperCount(intensity) {
  if (intensity < 0.8) {
    return 0;
  }
  return clamp(1 + Math.floor((intensity - 0.8) / 0.15), 1, LEAPER_MAX);
}

// MARK: - 飾り

/** 三角旗のガーランドの本数。正解 3 問目から 1 本ずつ増え、3 本で頭打ち */
export function garlandCount(correct) {
  return clamp(Math.floor(correct) - 2, 0, 3);
}

/**
 * 飾りが常時わき出る頻度 (1 秒あたりの個数)。しきい値より下は 0 で、E に比例して増える。
 *   ストリーマー E ≥ 0.4 / 包みキャンディ E ≥ 0.5 / 風船 E ≥ 0.7 / 硬貨 E ≥ 0.85
 */
export function propRates(intensity) {
  const e = clamp(intensity, 0, 1.5);
  return {
    streamer: e >= 0.4 ? 0.9 * e : 0,
    candy: e >= 0.5 ? 0.8 * e : 0,
    balloon: e >= 0.7 ? 1.6 * e : 0,
    coin: e >= 0.85 ? 10 * (e - 0.6) : 0
  };
}

/**
 * 正解の一撃で出す飾りの数。常時の頻度と同じしきい値で、E が高いほど多い。
 * 硬貨の雨はドパの節目か、E ≥ 0.85 の正解で降らせる。
 */
export function correctProps(intensity, milestone = false) {
  const e = clamp(intensity, 0, 1.5);
  return {
    streamer: e >= 0.4 ? Math.round(1 + 3 * e) : 0,
    candy: e >= 0.5 ? Math.round(1 + 4 * (e - 0.5)) : 0,
    balloon: e >= 0.7 ? Math.round(2 + 5 * (e - 0.7)) : 0,
    coin: milestone ? 40 : (e >= 0.85 ? Math.round(12 + 30 * (e - 0.85)) : 0)
  };
}

/** 粒子 (fx.js) とスプライト (観客 + 飾り) を合わせた上限 */
export const SPRITE_BUDGET = 900;
/** fx.js の粒子の上限 */
export const MAX_PARTICLES = 600;
/** 飛び越える観客の同時の上限 */
export const LEAPER_MAX = 5;
/** パレードの行進の人数 */
export const MARCHERS = 8;
/** 飾り (props.js) の上限。粒子と観客 (帯 + 飛び越え + パレード) のぶんを引いた残り */
export const MAX_PROPS = SPRITE_BUDGET - MAX_PARTICLES - CROWD_MAX - LEAPER_MAX - MARCHERS;

// MARK: - 横断バナーと節目

/**
 * 横断バナーの文言。次の問題を出したときに呼び、出さないときは null。
 *   ステージ 2 以降の 1 問目 → 「ステージ n」、ステージ内の最終問 → 「ラスト1もん」。
 *
 * @param {object} state
 * @param {number} [state.stage] ステージ (1 始まり)
 * @param {number} [state.index] ステージ内の問題番号 (0 始まり)
 * @param {number} [state.total] 1 ステージの問題数
 */
export function sashText({ stage = 1, index = 0, total = 0 }) {
  if (stage >= 2 && index === 0) {
    return `ステージ ${stage}`;
  }
  return total > 1 && index === total - 1 ? 'ラスト1もん' : null;
}

/** ドパの節目 (常用対数 2〜8) を巨大ステッカーの数字にする。100 / 1000 / 1万 / 10万 / … / 1億 */
export function milestoneLabel(level) {
  const m = Math.round(level);
  if (m >= 8) {
    return `${10 ** (m - 8)}億`;
  }
  if (m >= 4) {
    return `${10 ** (m - 4)}万`;
  }
  return String(10 ** Math.max(0, m));
}

// MARK: - 加点の浮遊

/** 続けて正解したとき、前の浮遊がまだ見えている間 (ms) は 1 段上に積む */
export const FLOAT_STACK_MS = 1400;
/** 積む段数の上限 */
export const FLOAT_STACK_MAX = 4;

/**
 * 次の浮遊を何段目に置くか。前の浮遊から FLOAT_STACK_MS 以内なら 1 段上、それ以外は 0 段目。
 * @param {number} prevLevel 前の浮遊の段
 * @param {number} sinceMs 前の浮遊からの経過 (ms)
 */
export function floatLevel(prevLevel, sinceMs) {
  if (!Number.isFinite(sinceMs) || sinceMs < 0 || sinceMs >= FLOAT_STACK_MS) {
    return 0;
  }
  return Math.min(FLOAT_STACK_MAX, prevLevel + 1);
}
