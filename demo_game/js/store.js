// localStorage への保存。最高記録と設定 (音・音量・筆幅) と、つづきから用の途中の状態を持つ。
// プライベートウィンドウなどで使えないことがあるので、読み書きは必ず try/catch。

const KEY = 'spiketegaki.game';
const PROGRESS_KEY = 'spiketegaki.game.progress';

export const PEN_MIN = 6;
export const PEN_MAX = 24;
const PEN_DEFAULT = 10;

export const VOLUME_MIN = 0;
export const VOLUME_MAX = 100;
export const VOLUME_DEFAULT = 50;

const DEFAULTS = {
  bestScore: 0,
  bestDopa: null,   // 常用対数 L。null = まだ一度も遊んでいない (10^0 = 1 を最高記録に出さないため)
  bestCombo: 0,
  bestStage: 0,     // 到達した最高のステージ (0 = まだ遊んでいない)
  sound: true,
  volume: VOLUME_DEFAULT,
  penWidth: PEN_DEFAULT
};

function clampPen(value) {
  return Math.min(PEN_MAX, Math.max(PEN_MIN, value));
}

/** 音量 (0〜100) に丸める。小数や範囲外は切り詰める */
export function clampVolume(value) {
  return Math.min(VOLUME_MAX, Math.max(VOLUME_MIN, Math.round(value)));
}

/** 保存してある値。壊れている項目は既定値に戻す */
export function load() {
  let raw = null;
  try {
    raw = window.localStorage.getItem(KEY);
  } catch (error) {
    // 使えない環境では既定値で遊べる
    raw = null;
  }
  if (raw === null) {
    return { ...DEFAULTS };
  }
  let parsed = null;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    parsed = null;
  }
  if (parsed === null || typeof parsed !== 'object') {
    return { ...DEFAULTS };
  }
  const num = (v, fallback) => (Number.isFinite(v) ? v : fallback);
  return {
    bestScore: num(parsed.bestScore, DEFAULTS.bestScore),
    bestDopa: num(parsed.bestDopa, DEFAULTS.bestDopa),
    bestCombo: num(parsed.bestCombo, DEFAULTS.bestCombo),
    bestStage: num(parsed.bestStage, DEFAULTS.bestStage),
    sound: typeof parsed.sound === 'boolean' ? parsed.sound : DEFAULTS.sound,
    volume: clampVolume(num(parsed.volume, DEFAULTS.volume)),
    penWidth: clampPen(num(parsed.penWidth, DEFAULTS.penWidth))
  };
}

/** まるごと保存する。書けなくても遊べるので失敗は無視する */
export function save(state) {
  try {
    window.localStorage.setItem(KEY, JSON.stringify(state));
  } catch (error) {
    // 保存できなくてもゲームには影響しない
  }
}

/** 記録を更新して保存する。更新された項目名の配列を返す */
export function recordBest(state, summary) {
  const updated = [];
  if (summary.score > state.bestScore) {
    state.bestScore = summary.score;
    updated.push('score');
  }
  if (summary.dopa > (state.bestDopa ?? 0)) {
    state.bestDopa = summary.dopa;
    updated.push('dopa');
  }
  if (summary.maxCombo > state.bestCombo) {
    state.bestCombo = summary.maxCombo;
    updated.push('combo');
  }
  if (summary.stage > (state.bestStage ?? 0)) {
    state.bestStage = summary.stage;
    updated.push('stage');
  }
  if (updated.length > 0) {
    save(state);
  }
  return updated;
}

// MARK: - つづきから

/** 保存してある途中の状態 (Game#snapshot() の形)。無い・読めないときは null。中身の検査は game.js の parseProgress */
export function loadProgress() {
  try {
    const raw = window.localStorage.getItem(PROGRESS_KEY);
    return raw === null ? null : JSON.parse(raw);
  } catch (error) {
    return null;
  }
}

/** 途中の状態を保存する。書けなくても遊べるので失敗は無視する */
export function saveProgress(snapshot) {
  try {
    window.localStorage.setItem(PROGRESS_KEY, JSON.stringify(snapshot));
  } catch (error) {
    // 保存できなくてもゲームには影響しない
  }
}

/** 途中の状態を消す (さいしょから) */
export function clearProgress() {
  try {
    window.localStorage.removeItem(PROGRESS_KEY);
  } catch (error) {
    // 消せなくてもゲームには影響しない
  }
}
