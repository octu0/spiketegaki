// Web Audio の発振器とノイズだけで組み立てる BGM と効果音。外部の音源は読み込まない。
//
// 曲はゲームの進行で展開する。ステージ内の問題番号でセクション A → B → ビルド → サビを選び、
// 小節頭で切り替える。セクションごとにコード進行・楽器・打楽器の型を持ち、旋律は
// 1 小節のモチーフをステージの seed で変奏して 1 小節ずつ作る (同じ 4 小節がそのまま続かない)。
// ステージクリアでフィル + ファンファーレを鳴らし、次のステージはテンポを 5 上げて A から始める。
// コンボ (5 / 10 / 20) で打楽器のレイヤーが増え、ミスでローパスが閉じてドラムが 1 小節抜ける。
//
// 呼び出し側との契約は setProgress (問題の開始と判定のたび) と cue (出来事) の 2 つだけ。
// 効果音は曲の 16 分に量子化し、その時点のコードの構成音で鳴らす。
//
// 音の通り道:
//   和音・旋律 -> セクションのローパス ─┐
//   打楽器・ライザー ────────────────────┴-> ミスのローパス -> ダッキング -> テープ (遅延) -> 曲の音量 ─┐
//   効果音 ───────────────────────────────────────────────────────────────────────────────────────┴->
//   グルー・コンプ -> リミッター -> クリッパー -> マスター (音量スライダー) -> 出力
// テープストップは遅延時間を 2 次曲線で伸ばして再生速度を 1 -> 0 に落とす (曲全体のピッチが下がる)。
//
// AudioContext はブラウザの制約で最初のユーザー操作のときにしか始められない。
// その resume() は解決しないことがあるので、呼び出し側は待たずに投げっぱなしにする。
// 開始を待つ必要のある操作 (音量・BGM の開始) は whenStarted でこちらが待つ。

const LOOKAHEAD_MS = 25;      // スケジューラを回す間隔
const SCHEDULE_AHEAD = 0.14;  // 先読みする秒数

export const STEPS_PER_BAR = 16;   // 1 小節 = 16 分音符 16 個
export const STEPS_PER_BEAT = 4;

// MARK: - 曲の構成 (DOM・AudioContext 無しで試せる純粋関数)

export const SECTION_A = 'A';
export const SECTION_B = 'B';
export const SECTION_BUILD = 'build';
export const SECTION_CHORUS = 'chorus';
/** ステージクリアのファンファーレの 2 小節 (曲はファンファーレに場所を譲る) */
export const SECTION_FANFARE = 'fanfare';
/** ステージクリアから次のステージの 1 問目までのつなぎ */
export const SECTION_INTERLUDE = 'interlude';
const SONG_SECTIONS = [SECTION_A, SECTION_B, SECTION_BUILD];

/**
 * ステージ内の問題番号 (0 始まり) からセクションを決める。
 * 最終問がサビ、残りを 3 等分して A / B / ビルド (10 問なら 1〜3 / 4〜6 / 7〜9 問)。
 */
export function sectionFor(index, total) {
  const n = Math.max(1, Math.floor(Number.isFinite(total) ? total : 1));
  const i = Math.min(n - 1, Math.max(0, Math.floor(Number.isFinite(index) ? index : 0)));
  if (i === n - 1) {
    return SECTION_CHORUS;
  }
  return SONG_SECTIONS[Math.min(2, Math.floor((i * 3) / (n - 1)))];
}

/** ビルドの中の進み具合 0〜1 (10 問なら 7 問め 0、8 問め 1/3、9 問め 2/3)。ビルド以外は 0 */
export function buildProgress(index, total) {
  if (sectionFor(index, total) !== SECTION_BUILD) {
    return 0;
  }
  const n = Math.max(2, Math.floor(total));
  return Math.min(1, Math.max(0, (index * 3) / (n - 1) - 2));
}

/** ステージ 1 の最初のテンポと強度 E による上乗せ (112 + min(1,E) × 16) */
const STAGE1_TEMPO = 112;
const STAGE1_TEMPO_RANGE = 16;
/** ステージが 1 つ進むごとに上げるテンポ */
export const STAGE_TEMPO_STEP = 5;
export const TEMPO_MAX = 170;

/**
 * 曲のテンポ (BPM)。ステージ 1 は強度 E で 112〜128、ステージ 2 以降は
 * ステージ 1 の最後 (128) からステージごとに +5 (133, 138, ...、上限 170)。
 */
export function musicTempo(stage, intensity) {
  const s = Math.max(1, Math.floor(Number.isFinite(stage) ? stage : 1));
  if (s === 1) {
    const e = Math.min(1, Math.max(0, Number.isFinite(intensity) ? intensity : 0));
    return STAGE1_TEMPO + e * STAGE1_TEMPO_RANGE;
  }
  return Math.min(TEMPO_MAX, STAGE1_TEMPO + STAGE1_TEMPO_RANGE + (s - 1) * STAGE_TEMPO_STEP);
}

/** 長音階 (半音) */
const MAJOR = [0, 2, 4, 5, 7, 9, 11];

/** 音階の度数 (0 = 主音、7 = 1 オクターブ上) を MIDI ノート番号にする。key は移調 (半音) */
export function degreeToMidi(degree, key = 0, tonic = 60) {
  const d = Math.round(degree);
  const octave = Math.floor(d / 7);
  return tonic + key + octave * 12 + MAJOR[d - octave * 7];
}

/** 度数 root を根音とする三和音の度数 (音階の中の 3 度積み) */
export function chordTones(root) {
  return [root, root + 2, root + 4];
}

/** 度数 d が根音 root の三和音の構成音か (オクターブ違いも含む) */
export function isChordTone(d, root) {
  const r = ((d - root) % 7 + 7) % 7;
  return r === 0 || r === 2 || r === 4;
}

/**
 * セクションごとのコード進行 (根音の度数、0 = I)。
 * A = I–V–vi–IV、B = vi–IV–I–V、ビルド = IV–V–iii–vi、サビ = IV–V–I–vi
 */
export const PROGRESSIONS = {
  [SECTION_A]: [0, 4, 5, 3],
  [SECTION_B]: [5, 3, 0, 4],
  [SECTION_BUILD]: [3, 4, 2, 5],
  [SECTION_CHORUS]: [3, 4, 0, 5],
  [SECTION_FANFARE]: [0, 0],
  [SECTION_INTERLUDE]: [0, 3]
};

/** サビは 2 半音上げる (転調)。ファンファーレはサビのキーのまま */
export function sectionKey(section) {
  return section === SECTION_CHORUS || section === SECTION_FANFARE ? 2 : 0;
}

/** セクションの bar 小節め (0 始まり) のコードの根音 */
export function chordAtBar(section, bar) {
  const p = PROGRESSIONS[section] ?? PROGRESSIONS[SECTION_A];
  return p[((bar % p.length) + p.length) % p.length];
}

/** コンボで正解の音を上げる度数 (1 コンボで 0、以後 1 ずつ、最大 7 = 1 オクターブ) */
export const COMBO_SHIFT_MAX = 7;
export function comboShift(combo) {
  return Math.min(COMBO_SHIFT_MAX, Math.max(0, Math.floor(Number.isFinite(combo) ? combo : 0) - 1));
}

/**
 * 正解の効果音の 4 音 (MIDI)。今のコードの構成音を、C5 + コンボの度数から上へ並べる。
 * コンボが伸びると始まりの音が音階の度数で上がる (半音ではないのでキーから外れない)。
 */
export function correctNotes(chordRoot, combo, key = 0) {
  const from = 7 + comboShift(combo);
  const notes = [];
  for (let d = from; notes.length < 4; d += 1) {
    if (isChordTone(d, chordRoot)) {
      notes.push(degreeToMidi(d, key, 60));
    }
  }
  return notes;
}

/** カウントダウンの数字 n (5〜1) の音の度数。数字が減るほど上がる (C5, D5, E5, F5, G5) */
export function countdownDegree(n) {
  const k = Math.min(5, Math.max(1, Math.round(Number.isFinite(n) ? n : 5)));
  return 7 + (5 - k);
}

/** コンボで重ねる打楽器・旋律のレイヤー */
export function comboLayers(combo) {
  const c = Number.isFinite(combo) ? combo : 0;
  return {
    hat16: c >= 5,        // 16 分のハイハット
    openHat: c >= 10,     // 裏拍のオープンハット
    clapBeats: c >= 10,   // 毎拍のクラップ
    doubleTime: c >= 20,  // 倍テンのドラム
    leadUp: c >= 20       // 旋律を 1 オクターブ上へ
  };
}
const NO_LAYERS = comboLayers(0);

/**
 * ビルドのスネアの連打。1 拍あたりの打数 (0 = 叩かない、2 = 8 分、4 = 16 分)。
 * ビルドの何問めか (progress の 3 段) と 4 小節のまとまりの何小節めで密になる。
 */
const ROLL_TABLE = [
  [0, 0, 2, 2],
  [0, 2, 2, 4],
  [2, 2, 4, 4]
];
export function snareRoll(progress, bar) {
  const heat = Math.min(2, Math.max(0, Math.floor(progress * 3 + 1e-9)));
  return ROLL_TABLE[heat][((bar % 4) + 4) % 4];
}

/** ビルドのライザーの長さ (小節)。この小節から鳴らし始めるものだけ返す (0 = 鳴らさない) */
export function riserBars(progress, bar) {
  const heat = Math.min(2, Math.max(0, Math.floor(progress * 3 + 1e-9)));
  const pos = ((bar % 4) + 4) % 4;
  // 1 問め: 4 小節めだけ、2 問め: 3〜4 小節め、3 問め: 4 小節ずっと
  const start = [3, 2, 0][heat];
  return pos === start ? 4 - start : 0;
}

/** ビルドのローパスの周波数。小節の頭 (at = 0) から終わり (at = 1) へ開いていく */
const BUILD_CUTOFF_FROM = 5000;
const BUILD_CUTOFF_TO = 18000;
export function buildCutoff(progress, bar, at) {
  const heat = Math.min(2, Math.max(0, Math.floor(progress * 3 + 1e-9)));
  const q = Math.min(1, (heat + ((((bar % 4) + 4) % 4) + at) / 4) / 3);
  return BUILD_CUTOFF_FROM * Math.pow(BUILD_CUTOFF_TO / BUILD_CUTOFF_FROM, q);
}

/** セクションごとの和音・旋律のローパス (A はこもらせ、進むほど開ける) */
const SECTION_CUTOFF = {
  [SECTION_A]: 3200,
  [SECTION_B]: 5000,
  [SECTION_CHORUS]: 18000,
  [SECTION_FANFARE]: 18000,
  [SECTION_INTERLUDE]: 2400
};

/** 8 小節ごと (まとまりの最後の小節) にドラムフィル */
export function isFillBar(bar) {
  return bar % 8 === 7;
}

/**
 * 時刻 now 以降で最初の格子点。格子は anchor (小節頭の時刻) から step 秒おき。
 * 効果音の 16 分への量子化 (step = 16 分の長さ) や、小節頭・拍頭を探すのに使う。
 */
export function nextGridTime(now, anchor, step) {
  if (!(step > 0) || !Number.isFinite(anchor)) {
    return now;
  }
  const k = Math.ceil((now - anchor) / step - 1e-6);
  return anchor + k * step;
}

/** テープストップの遅延時間の曲線。d(t) = t² / 2D なので再生速度 1 − d'(t) が 1 から 0 へ落ちる */
export function tapeStopCurve(duration, points = 64) {
  const curve = new Float32Array(points);
  for (let i = 0; i < points; i += 1) {
    const x = i / (points - 1);
    curve[i] = (x * x * duration) / 2;
  }
  return curve;
}

// MARK: - 旋律 (モチーフ + 変奏)

/** 文字列でない整数の組から 32bit の種を作る */
function hash(...values) {
  let h = 2166136261;
  for (const v of values) {
    h ^= v | 0;
    h = Math.imul(h, 16777619);
    h ^= h >>> 13;
  }
  return h >>> 0;
}

/** 種から [0, 1) の乱数列 (mulberry32) */
function random(...values) {
  let a = hash(...values);
  return () => {
    a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function pick(rng, list) {
  return list[Math.floor(rng() * list.length)];
}

/** ステージの seed (旋律の変奏を決める) */
export function stageSeed(stage) {
  return hash(0x7e9a, Math.max(1, Math.floor(stage)));
}

/** セクションごとのモチーフのリズム (1 小節の中の発音位置、16 分) */
const RHYTHMS = {
  [SECTION_A]: [[0, 3, 6, 8, 12], [0, 4, 6, 10, 12], [2, 4, 8, 11, 14], [0, 2, 6, 8, 12]],
  [SECTION_B]: [[0, 3, 6, 8, 10, 12], [0, 2, 4, 7, 10, 12], [2, 4, 6, 8, 11, 14], [0, 3, 4, 8, 11, 12]],
  [SECTION_BUILD]: [[0, 2, 4, 6, 8, 10, 12, 14], [0, 3, 4, 6, 8, 11, 12, 14], [0, 2, 4, 7, 8, 10, 12, 15]],
  [SECTION_CHORUS]: [[0, 3, 6, 8, 10, 12, 14], [0, 2, 3, 6, 8, 11, 12, 14], [0, 3, 6, 7, 10, 12, 13, 14],
    [0, 2, 4, 6, 8, 11, 14]]
};
/** 強拍に置く構成音 (根音からの度数) */
const STRONG_TONES = [0, 2, 4, 7];
/** 旋律の音域 (根音からの度数を足したあと、この範囲にオクターブで折り返す) */
const MELODY_LOW = -3;
const MELODY_HIGH = 10;

/** 強拍 (拍頭) の音を最寄りの構成音 (根音からの度数 0, 2, 4, 7, ...) にそろえる */
function snapStrong(events) {
  for (const e of events) {
    if (e.step % STEPS_PER_BEAT === 0 && !isChordTone(e.rel, 0)) {
      e.rel += isChordTone(e.rel - 1, 0) ? -1 : 1;
    }
  }
  return events;
}

/** 発音位置の順に並べ、次の音までを長さにする (最長 4 = 1 拍) */
function withLengths(events) {
  events.sort((a, b) => a.step - b.step);
  for (let i = 0; i < events.length; i += 1) {
    const next = i + 1 < events.length ? events[i + 1].step : STEPS_PER_BAR;
    events[i].len = Math.max(1, Math.min(4, next - events[i].step));
  }
  return events;
}

/** ステージの seed とセクションで決まる 1 小節のモチーフ。rel は根音からの度数 */
function motif(seed, section) {
  const rng = random(seed, SONG_SECTIONS.indexOf(section) + 11, 0x51);
  const onsets = pick(rng, RHYTHMS[section]);
  let prev = pick(rng, STRONG_TONES);
  const events = onsets.map((step) => {
    let rel;
    if (step % STEPS_PER_BEAT === 0) {
      // 強拍は構成音。直前から近いものを選ぶと跳躍が大きくなりすぎない
      const near = STRONG_TONES.filter((t) => Math.abs(t - prev) <= 4);
      rel = pick(rng, near.length > 0 ? near : STRONG_TONES);
    } else {
      rel = prev + pick(rng, [-2, -1, 1, 1, 2]);
    }
    rel = Math.min(9, Math.max(-2, rel));
    prev = rel;
    return { step, rel, len: 1 };
  });
  return withLengths(snapStrong(events));
}

/** 変奏の操作。どれもモチーフの形 (リズムか輪郭のどちらか) を残す */
const VARIATIONS = [
  // リズムのずらし: 拍頭でない 1 音を 16 分後ろへ
  (events, rng) => {
    const candidates = events.filter((e, i) => i > 0 && e.step < 15 && !events.some((o) => o.step === e.step + 1));
    if (candidates.length > 0) {
      pick(rng, candidates).step += 1;
    }
  },
  // 音程の置換: 1 音を隣の音へ
  (events, rng) => {
    const e = pick(rng, events);
    e.rel += pick(rng, [-1, 1]);
  },
  // オクターブ: 最後の音を 1 オクターブ上 (上がりすぎなら下) へ
  (events) => {
    const e = events[events.length - 1];
    e.rel += e.rel >= 5 ? -7 : 7;
  },
  // 輪郭の反転: 最初の音を軸に上下を入れ替える
  (events) => {
    const axis = events[0].rel;
    for (const e of events) {
      e.rel = axis - (e.rel - axis);
    }
  },
  // 分割: 長い音を 16 分 2 つ (2 つめは隣の音) に割る
  (events, rng) => {
    const long = events.filter((e) => e.len >= 2);
    if (long.length > 0) {
      const e = pick(rng, long);
      events.push({ step: e.step + 1, rel: e.rel + pick(rng, [-1, 1, 2]), len: 1 });
    }
  },
  // 反復進行: 全体を 1〜2 度ずらす
  (events, rng) => {
    const by = pick(rng, [-2, -1, 1, 2]);
    for (const e of events) {
      e.rel += by;
    }
  }
];

function vary(events, rng, count) {
  const out = events.map((e) => ({ ...e }));
  for (let i = 0; i < count; i += 1) {
    pick(rng, VARIATIONS)(out, rng);
    withLengths(out);
  }
  return withLengths(snapStrong(out));
}

/** まとまりの終わりの小節: 前半を残し、後半を構成音の長い音で終える (最後の小節はフィルの場所を空ける) */
function cadence(events, rng, last) {
  const head = events.filter((e) => e.step < 8).map((e) => ({ ...e }));
  const end = { step: 8, rel: pick(rng, last ? [0, 0, 2] : [0, 2, 4]), len: last ? 4 : 8 };
  return [...head, end];
}

/** 度数を音域の中へ、直前の音 (prev) にいちばん近いオクターブで置く (オクターブ違いなので構成音は保つ) */
function fold(degree, prev) {
  let best = null;
  for (let d = degree - 21; d <= degree + 21; d += 7) {
    if (d < MELODY_LOW || d > MELODY_HIGH) {
      continue;
    }
    if (best === null || Math.abs(d - prev) < Math.abs(best - prev)) {
      best = d;
    }
  }
  return best;
}

/**
 * セクションの bar 小節め (0 始まり) の旋律。{ step, len (16 分), degree (主音からの度数) } の列。
 * 8 小節を 1 まとまりとし、1 小節めでモチーフ (2 まとまりめ以降はその変奏) を示し、
 * 4・8 小節めは長い音で区切る。残りの小節は小節ごとの乱数で 1〜2 個の変奏を重ねる。
 */
export function melodyBar(seed, section, bar) {
  if (!(section in RHYTHMS)) {
    return [];
  }
  const root = chordAtBar(section, bar);
  const index = SONG_SECTIONS.indexOf(section) + 11;
  const phrase = Math.floor(bar / 8);
  const pos = bar % 8;
  let events = motif(seed, section);
  if (phrase > 0) {
    events = vary(events, random(seed, index, 0x1000 + phrase), 1);
  }
  const rng = random(seed, index, 0x2000 + bar);
  if (pos === 3 || pos === 7) {
    events = cadence(vary(events, rng, 1), rng, pos === 7);
  } else if (pos !== 0) {
    events = vary(events, rng, rng() < 0.5 ? 1 : 2);
  }
  // 小節の頭は音域の中ほど (主音の 5 度上) に近いオクターブから
  let prev = 4;
  return events.map((e) => {
    prev = fold(root + e.rel, prev);
    return { step: e.step, len: e.len, degree: prev };
  });
}

// MARK: - 打楽器・伴奏の型 (1 小節 16 分)

const DRUMS = {
  [SECTION_A]: { kick: [0, 6, 8], clap: [], hat: [], open: [] },
  [SECTION_B]: { kick: [0, 6, 8, 11], clap: [4, 12], hat: [0, 2, 4, 6, 8, 10, 12, 14], open: [] },
  [SECTION_BUILD]: { kick: [0, 4, 8, 12], clap: [4, 12], hat: Array.from({ length: STEPS_PER_BAR }, (_, i) => i), open: [14] },
  [SECTION_CHORUS]: { kick: [0, 4, 8, 12], clap: [4, 12], hat: [0, 4, 8, 12], open: [2, 6, 10, 14] },
  [SECTION_FANFARE]: { kick: [], clap: [], hat: [], open: [] },
  [SECTION_INTERLUDE]: { kick: [0, 8], clap: [], hat: [], open: [] }
};
/** 倍テンのキックとスネア */
const DOUBLE_KICK = [0, 3, 4, 8, 11, 12];
const DOUBLE_SNARE = [2, 6, 10, 14];
const OFFBEATS = [2, 6, 10, 14];
const BEATS = [0, 4, 8, 12];

/** セクションごとの曲全体の音量 (A は控えめに始め、サビで最大) */
const SECTION_LEVEL = {
  [SECTION_A]: 0.72,
  [SECTION_B]: 0.84,
  [SECTION_BUILD]: 0.92,
  [SECTION_CHORUS]: 1,
  [SECTION_FANFARE]: 1,
  [SECTION_INTERLUDE]: 0.7
};

/** キックでパッド・低音・和音を押し下げる深さ (サイドチェイン) */
const PUMP_DEPTH = {
  [SECTION_A]: 0.25,
  [SECTION_B]: 0.35,
  [SECTION_BUILD]: 0.45,
  [SECTION_CHORUS]: 0.5,
  [SECTION_FANFARE]: 0,
  [SECTION_INTERLUDE]: 0.2
};

/** 低音: [16 分の位置, 構成音 (0 根音 / 1 3 度 / 2 5 度), オクターブ, 長さ] */
const BASS = {
  [SECTION_A]: [[0, 0, 0, 5], [6, 0, 0, 2], [8, 0, 0, 5], [14, 2, 0, 2]],
  [SECTION_B]: [[0, 0, 0, 2], [2, 0, 1, 2], [4, 0, 0, 2], [6, 0, 1, 2], [8, 0, 0, 2], [10, 0, 1, 2],
    [12, 2, 0, 2], [14, 0, 1, 2]],
  [SECTION_BUILD]: [0, 2, 4, 6, 8, 10, 12, 14].map((s) => [s, 0, 0, 2]),
  [SECTION_CHORUS]: [[0, 0, 0, 2], [2, 0, 1, 2], [4, 0, 0, 1], [6, 0, 1, 2], [8, 0, 0, 2], [10, 0, 1, 2],
    [12, 2, 0, 1], [14, 0, 1, 2]],
  [SECTION_FANFARE]: [],
  [SECTION_INTERLUDE]: [[0, 0, 0, 16]]
};

/** 鍵盤の和音の刻み: [16 分の位置, 長さ] */
const COMP = {
  [SECTION_A]: [[0, 4], [6, 3], [10, 4]],
  [SECTION_B]: [[0, 2], [3, 2], [8, 2], [11, 2]],
  [SECTION_BUILD]: [0, 2, 4, 6, 8, 10, 12, 14].map((s) => [s, 1]),
  [SECTION_CHORUS]: [],
  [SECTION_FANFARE]: [],
  [SECTION_INTERLUDE]: []
};

/** サビのブラス風スタブ: [16 分の位置, 長さ] */
const STABS = [[0, 3], [3, 2], [6, 2], [10, 2]];

/** アルペジオ (構成音 0, 1, 2 と 3 = オクターブ上の根音) */
const ARP_ORDER = [0, 1, 2, 3, 2, 1, 0, 2];

function midiToFreq(note) {
  return 440 * Math.pow(2, (note - 69) / 12);
}

/** 構成音 i (0 根音 / 1 3 度 / 2 5 度 / 3 オクターブ) の度数 */
function chordDegree(root, i) {
  return i >= 3 ? root + 7 : root + i * 2;
}

/** 音量を最大にしたときのマスターの利得 */
export const MASTER_GAIN = 0.85;

/**
 * マスターの利得。音量スライダー (0〜100) に比例させ、「おと」を切ったら 0 にする。
 * 既定の 50 では 0.85 * 0.5 = 0.425。
 *
 * @param {number} volume 0〜100
 * @param {boolean} enabled 「おと」が入っているか
 */
export function masterGain(volume, enabled = true) {
  if (!enabled) {
    return 0;
  }
  const v = Number.isFinite(volume) ? Math.min(100, Math.max(0, volume)) : 100;
  return MASTER_GAIN * (v / 100);
}

/** cue で受け付ける名前 */
export const CUE_NAMES = [
  'correct', 'close', 'wrong', 'lifeLost', 'timeout', 'safe', 'countdown', 'lastProblem',
  'stageClear', 'comboMilestone', 'dopaMilestone', 'gameOver', 'retry', 'whoosh', 'blip'
];

/** ミスでローパスを閉じる先 (Hz) と、開いているときの値 */
const MISS_CUTOFF = 800;
const OPEN_CUTOFF = 20000;
/** カウントダウン中の曲の音量 (−8 dB) */
const DUCK_LEVEL = Math.pow(10, -8 / 20);
/** カウントダウンの 1 つの数字でダッキングを続ける長さ (次の数字が来なければ戻す) */
const DUCK_HOLD = 1.15;
/** ゲームオーバーのテープストップの長さ (秒) */
const TAPE_STOP = 1.0;

export class Sound {
  /**
   * @param {object} options
   * @param {BaseAudioContext} options.context 使う AudioContext。省略すると最初の操作で作る
   *   (検証では OfflineAudioContext を渡して同じ生成コードを描画する)
   */
  constructor({ context = null } = {}) {
    this.given = context;
    this.ctx = null;
    this.master = null;
    this.musicGain = null;
    this.sfxGain = null;
    this.noiseBuffer = null;
    this.verbs = new Map();   // 出力先 -> そこへ混ぜるリバーブの send
    this.enabled = true;
    this.volume = 100;      // 0〜100。呼び出し側が setVolume で保存値に合わせる
    this.starting = null;   // ensureStarted の Promise (1 回だけ作る)
    this.wantsMusic = false;
    this.playing = false;
    this.timer = 0;
    this.progress = { stage: 1, index: 0, total: 10, combo: 0, lives: 3, intensity: 0 };
    this.resetSong();
  }

  /** 曲の進行を最初 (ステージの A の 1 小節め) に戻す */
  resetSong() {
    this.step = 0;              // 小節の中の 16 分の位置
    this.nextTime = 0;
    this.stepDur = 60 / STAGE1_TEMPO / STEPS_PER_BEAT;
    this.stage = 0;             // 0 = まだ小節を始めていない
    this.seed = stageSeed(1);
    this.cur = null;            // 今の小節 { time, stepDur, section, bar, root, key, build, melody }
    this.bars = [];             // 予約した小節の記録 (効果音の量子化とコード合わせに使う)
    this.drumMuteFrom = 0;
    this.drumMuteTo = 0;
    this.missEnd = 0;
    this.missShape = null;      // ミスのローパスの形 { start, closed, back, end }
    this.fillFrom = 0;
    this.fillTo = 0;
    this.fanfareFrom = Infinity;
    this.fanfareTo = Infinity;
    this.fanfareStep = this.stepDur;
    this.clearedFrom = null;    // ステージクリアしたときのステージ (次のステージが始まるまでつなぎを鳴らす)
    this.retryHold = null;      // リトライした問題 (その問題のあいだは A)
    this.holdUntil = 0;         // この時刻までは今のセクションを続ける (ラスト 1 問のライザーの頂点でサビへ)
    this.lastImpact = -1;       // ラスト 1 問の効果音がインパクトを置いた時刻
    this.stopAt = Infinity;     // テープストップのあとで曲を止める時刻
    this.tapeEnd = 0;
  }

  /**
   * 最初のユーザー操作から呼ぶ。待たなくてよい (2 回目以降は同じ Promise を返す)。
   * 音を始められなくても呼び出し側が止まらないよう、失敗は false に畳む。
   */
  ensureStarted() {
    if (this.starting === null) {
      this.starting = this.open().catch(() => false);
    }
    return this.starting;
  }

  async open() {
    if (this.ctx === null) {
      if (this.given !== null) {
        this.ctx = this.given;
      } else {
        const Ctor = window.AudioContext || window.webkitAudioContext;
        if (Ctor === undefined) {
          return false;
        }
        this.ctx = new Ctor();
      }
      this.build();
    }
    // オフライン描画の context は startRendering まで suspended のままなので resume しない
    if (this.ctx.state === 'suspended' && typeof this.ctx.startRendering !== 'function') {
      await this.ctx.resume();
    }
    return true;
  }

  /** 音の通り道を組み立てる。context ごとに 1 回だけ */
  build() {
    const ctx = this.ctx;

    // 出力段: グルー・コンプ -> リミッター -> クリッパー -> マスター (音量) -> 出力
    this.master = ctx.createGain();
    this.master.gain.value = masterGain(this.volume, this.enabled);
    this.master.connect(ctx.destination);

    const clipper = ctx.createWaveShaper();
    clipper.curve = this.softClipCurve();
    clipper.connect(this.master);

    const limiter = ctx.createDynamicsCompressor();
    limiter.threshold.value = -4;
    limiter.knee.value = 0;
    limiter.ratio.value = 20;
    limiter.attack.value = 0.001;
    limiter.release.value = 0.08;
    limiter.connect(clipper);

    const glue = ctx.createDynamicsCompressor();
    glue.threshold.value = -16;
    glue.knee.value = 12;
    glue.ratio.value = 3;
    glue.attack.value = 0.01;
    glue.release.value = 0.2;
    glue.connect(limiter);

    this.mix = ctx.createGain();
    this.mix.gain.value = 1;
    this.mix.connect(glue);

    // 効果音 (曲のテープ・ダッキングを通らない)
    this.sfxGain = ctx.createGain();
    this.sfxGain.gain.value = 0.5;
    this.sfxGain.connect(this.mix);
    this.verbs.set(this.sfxGain, this.reverb(this.mix, 0.24));

    // 曲: song -> ミスのローパス -> ダッキング -> テープ -> 曲の音量
    this.musicGain = ctx.createGain();
    this.musicGain.gain.value = 0.34;
    this.musicGain.connect(this.mix);

    this.tapeGain = ctx.createGain();
    this.tapeGain.gain.value = 1;
    this.tapeGain.connect(this.musicGain);
    this.tape = ctx.createDelay(2);
    this.tape.delayTime.value = 0;
    this.tape.connect(this.tapeGain);

    this.duck = ctx.createGain();
    this.duck.gain.value = 1;
    this.duck.connect(this.tape);

    this.missFilter = ctx.createBiquadFilter();
    this.missFilter.type = 'lowpass';
    this.missFilter.Q.value = 0.9;
    this.missFilter.frequency.value = OPEN_CUTOFF;
    this.missFilter.connect(this.duck);

    this.song = ctx.createGain();
    this.song.gain.value = 1;
    this.song.connect(this.missFilter);
    const songVerb = this.reverb(this.song, 0.22);

    // 和音・旋律はセクションのローパスを通す
    this.sectionFilter = ctx.createBiquadFilter();
    this.sectionFilter.type = 'lowpass';
    this.sectionFilter.Q.value = 1.1;
    this.sectionFilter.frequency.value = SECTION_CUTOFF[SECTION_A];
    this.sectionFilter.connect(this.song);

    this.tonal = ctx.createGain();
    this.tonal.gain.value = 1;
    this.tonal.connect(this.sectionFilter);

    // サイドチェイン: パッド・低音・和音はキックのたびに押し下げる
    this.pumpGain = ctx.createGain();
    this.pumpGain.gain.value = 1;
    this.pumpGain.connect(this.tonal);

    // 旋律には 8 分付点ぶんのディレイ (テンポが変わっても違和感が出ない程度に固定)
    this.melodyBus = ctx.createGain();
    this.melodyBus.gain.value = 1;
    this.melodyBus.connect(this.tonal);
    const delay = ctx.createDelay(1);
    delay.delayTime.value = 0.26;
    const feedback = ctx.createGain();
    feedback.gain.value = 0.25;
    const delayOut = ctx.createGain();
    delayOut.gain.value = 0.3;
    this.melodyBus.connect(delay);
    delay.connect(feedback);
    feedback.connect(delay);
    delay.connect(delayOut);
    delayOut.connect(this.tonal);

    // ステレオ配置: アルペジオは右、対旋律は左、ハイハットはやや右、クラップはやや左
    this.arpBus = this.panned(0.45, this.tonal);
    this.counterBus = this.panned(-0.45, this.tonal);
    this.drumBus = ctx.createGain();
    this.drumBus.gain.value = 1;
    this.drumBus.connect(this.song);
    this.hatBus = this.panned(0.25, this.drumBus);
    this.clapBus = this.panned(-0.15, this.drumBus);
    this.crashBus = this.panned(0.3, this.drumBus);
    for (const bus of [this.tonal, this.pumpGain, this.melodyBus, this.arpBus, this.counterBus,
      this.drumBus, this.hatBus, this.clapBus, this.crashBus, this.song]) {
      this.verbs.set(bus, songVerb);
    }

    // 打楽器のノイズは 1 回だけ作って使い回す
    const frames = Math.floor(ctx.sampleRate * 1.0);
    this.noiseBuffer = ctx.createBuffer(1, frames, ctx.sampleRate);
    const data = this.noiseBuffer.getChannelData(0);
    for (let i = 0; i < frames; i += 1) {
      data[i] = Math.random() * 2 - 1;
    }
  }

  /** 生成したインパルス応答のリバーブを destination へ返す。戻り値は send の入口 */
  reverb(destination, wetGain) {
    const ctx = this.ctx;
    const convolver = ctx.createConvolver();
    convolver.buffer = this.impulse(1.8);
    const send = ctx.createGain();
    send.gain.value = 1;
    send.connect(convolver);
    const wet = ctx.createGain();
    wet.gain.value = wetGain;
    convolver.connect(wet);
    wet.connect(destination);
    return send;
  }

  /** 減衰ノイズのインパルス応答 (ステレオ) */
  impulse(seconds) {
    const frames = Math.floor(this.ctx.sampleRate * seconds);
    const buffer = this.ctx.createBuffer(2, frames, this.ctx.sampleRate);
    for (let c = 0; c < 2; c += 1) {
      const data = buffer.getChannelData(c);
      for (let i = 0; i < frames; i += 1) {
        data[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / frames, 2.6);
      }
    }
    return buffer;
  }

  /** 0.8 までは素通しし、その先を 0.95 手前へ丸めるクリッパーの曲線 (ピーク < 0.99 の保険) */
  softClipCurve() {
    const n = 2049;
    const curve = new Float32Array(n);
    for (let i = 0; i < n; i += 1) {
      const x = (i / (n - 1)) * 2 - 1;
      const a = Math.abs(x);
      const y = a <= 0.8 ? a : 0.8 + 0.18 * Math.tanh((a - 0.8) / 0.18);
      curve[i] = Math.sign(x) * y;
    }
    return curve;
  }

  /** 左右に振る枝。StereoPanner が無い環境ではそのまま通す */
  panned(pan, destination) {
    const ctx = this.ctx;
    if (typeof ctx.createStereoPanner !== 'function') {
      const g = ctx.createGain();
      g.connect(destination);
      return g;
    }
    const p = ctx.createStereoPanner();
    p.pan.value = pan;
    p.connect(destination);
    return p;
  }

  /** 音を始めたあとに action を動かす。まだ始めていなければ何もしない */
  whenStarted(action) {
    if (this.starting === null) {
      return;
    }
    this.starting.then(() => {
      if (this.ctx !== null) {
        action();
      }
    });
  }

  setEnabled(on) {
    this.enabled = on;
    this.applyGain();
  }

  /** 音量 (0〜100)。「おと」を切っているあいだは反映しても 0 のまま */
  setVolume(volume) {
    this.volume = Number.isFinite(volume) ? Math.min(100, Math.max(0, volume)) : this.volume;
    this.applyGain();
  }

  /** 今の音量と「おと」をマスターに反映する。開始前でも build() が同じ式で読む */
  applyGain() {
    this.whenStarted(() => {
      this.master.gain.setTargetAtTime(masterGain(this.volume, this.enabled), this.ctx.currentTime, 0.02);
    });
  }

  /**
   * 問題の開始と判定のたびに呼ぶ。セクション・テンポ・ステージは次の小節頭で、
   * コンボのレイヤーは次の 16 分から反映する。
   */
  setProgress({ stage, index, total, combo, lives, intensity } = {}) {
    const p = this.progress;
    const next = {
      stage: Number.isFinite(stage) ? Math.max(1, Math.floor(stage)) : p.stage,
      index: Number.isFinite(index) ? Math.max(0, Math.floor(index)) : p.index,
      total: Number.isFinite(total) ? Math.max(1, Math.floor(total)) : p.total,
      combo: Number.isFinite(combo) ? Math.max(0, Math.floor(combo)) : p.combo,
      lives: Number.isFinite(lives) ? lives : p.lives,
      intensity: Number.isFinite(intensity) ? intensity : p.intensity
    };
    if (this.clearedFrom !== null && next.stage !== this.clearedFrom) {
      this.clearedFrom = null;
    }
    if (this.retryHold !== null && (next.stage !== this.retryHold.stage || next.index !== this.retryHold.index)) {
      this.retryHold = null;
    }
    this.progress = next;
  }

  startMusic() {
    this.wantsMusic = true;
    this.whenStarted(() => this.runScheduler(this.ctx.currentTime + 0.08));
  }

  stopMusic() {
    this.wantsMusic = false;
    this.halt();
  }

  /** スケジューラを止める (予約済みの音はそのまま鳴り終わる) */
  halt() {
    this.playing = false;
    window.clearInterval(this.timer);
    this.timer = 0;
  }

  /** 音が始まってから呼ばれる。待っている間に stopMusic されていたら鳴らさない */
  runScheduler(startTime) {
    if (!this.wantsMusic || this.playing) {
      return;
    }
    this.playing = true;
    this.beginMusic(startTime);
    this.timer = window.setInterval(() => {
      if (this.playing) {
        this.pump(this.ctx.currentTime + SCHEDULE_AHEAD);
      }
    }, LOOKAHEAD_MS);
  }

  /** 曲を startTime (テープストップの途中ならその後) から A の頭で鳴らし始める */
  beginMusic(startTime) {
    const at = Math.max(startTime, this.tapeEnd);
    this.restoreChain(at);
    this.resetSong();
    this.nextTime = at;
  }

  /** until 秒までの音を先に予約する */
  pump(until) {
    while (this.playing && this.nextTime < until) {
      if (this.nextTime >= this.stopAt) {
        this.halt();
        return;
      }
      if (this.step === 0) {
        this.startBar(this.nextTime);
      }
      this.playStep(this.step, this.nextTime, this.stepDur);
      this.nextTime += this.stepDur;
      this.step = (this.step + 1) % STEPS_PER_BAR;
    }
  }

  /** time の時点で鳴らすセクション (ファンファーレ・つなぎ・リトライ直後の A を含む) */
  sectionAt(time) {
    if (time >= this.fanfareFrom - 1e-4 && time < this.fanfareTo - 1e-4) {
      return SECTION_FANFARE;
    }
    if (this.cur !== null && time < this.holdUntil - 1e-4) {
      return this.cur.section;
    }
    if (this.clearedFrom !== null) {
      return SECTION_INTERLUDE;
    }
    if (this.retryHold !== null) {
      return SECTION_A;
    }
    return sectionFor(this.progress.index, this.progress.total);
  }

  /** 小節頭: 保留していたセクション・ステージ・テンポを反映し、この小節のコードと旋律を決める */
  startBar(time) {
    const p = this.progress;
    const section = this.sectionAt(time);
    let bar = this.cur === null ? 0 : this.cur.bar + 1;
    // ファンファーレの 2 小節は予約した時点のテンポのまま。ステージの切り替えはその後の小節頭で
    const fanfare = section === SECTION_FANFARE;
    const stageChanged = !fanfare && p.stage !== this.stage;
    if (stageChanged) {
      this.stage = p.stage;
      this.seed = stageSeed(p.stage);
    }
    if (stageChanged || this.cur === null || section !== this.cur.section) {
      bar = 0;
    }
    this.stepDur = fanfare ? this.fanfareStep : 60 / musicTempo(p.stage, p.intensity) / STEPS_PER_BEAT;
    const build = buildProgress(p.index, p.total);
    this.cur = {
      time,
      stepDur: this.stepDur,
      section,
      bar,
      root: chordAtBar(section, bar),
      key: sectionKey(section),
      build,
      melody: melodyBar(this.seed, section, bar)
    };
    this.bars.push(this.cur);
    if (this.bars.length > 8) {
      this.bars.shift();
    }

    const barDur = this.stepDur * STEPS_PER_BAR;
    this.song.gain.setTargetAtTime(SECTION_LEVEL[section], time, 0.03);
    const f = this.sectionFilter.frequency;
    if (section === SECTION_BUILD) {
      f.setValueAtTime(buildCutoff(build, bar, 0), time);
      f.exponentialRampToValueAtTime(buildCutoff(build, bar, 1), time + barDur);
    } else {
      f.setTargetAtTime(SECTION_CUTOFF[section], time, 0.05);
    }
    // サビに入った小節はインパクトで区切る (ラスト 1 問の効果音が同じ小節頭に置いていれば重ねない)
    if (section === SECTION_CHORUS && bar === 0 && this.drumsOn(time) && Math.abs(time - this.lastImpact) > 0.01) {
      this.impact(time, 0.5, this.drumBus);
    }
  }

  drumsOn(time) {
    return !(time >= this.drumMuteFrom && time < this.drumMuteTo);
  }

  /** 小節の step 番目 (16 分) を time に鳴らす */
  playStep(step, time, s) {
    if (this.ctx === null) {
      return;
    }
    const c = this.cur;
    const special = c.section === SECTION_FANFARE || c.section === SECTION_INTERLUDE;
    const layers = special ? NO_LAYERS : comboLayers(this.progress.combo);
    if (this.drumsOn(time)) {
      this.playDrums(step, time, s, layers);
    }
    this.playTonal(step, time, s, layers);
  }

  /** この 16 分がフィルか (8 小節ごとの後半 2 拍、セクションが変わる直前の 1 拍、ステージクリア) */
  isFill(step, time, s) {
    const c = this.cur;
    if (c.section === SECTION_FANFARE || c.section === SECTION_INTERLUDE) {
      return false;
    }
    if (time >= this.fillFrom - 1e-4 && time < this.fillTo - 1e-4) {
      return true;
    }
    if (isFillBar(c.bar) && step >= 8) {
      return true;
    }
    const barEnd = time + (STEPS_PER_BAR - step) * s;
    return step >= 12 && this.sectionAt(barEnd) !== c.section;
  }

  playDrums(step, time, s, layers) {
    const c = this.cur;
    const pattern = DRUMS[c.section];
    const fill = this.isFill(step, time, s);
    const kick = layers.doubleTime ? DOUBLE_KICK.includes(step) : pattern.kick.includes(step);
    const soft = c.section === SECTION_INTERLUDE;
    if (kick && (!fill || step === 8)) {
      this.kick(time, soft ? 0.35 : 0.62);
      this.sidechain(time, PUMP_DEPTH[c.section]);
    }
    if (fill) {
      this.fillHit(step, time);
      return;
    }
    if (c.section === SECTION_CHORUS && step === 0) {
      this.crash(time, 0.2);
    }
    if (pattern.clap.includes(step) || (layers.clapBeats && BEATS.includes(step))) {
      this.clap(time, pattern.clap.includes(step) ? 0.34 : 0.22);
    }
    if (layers.doubleTime && DOUBLE_SNARE.includes(step)) {
      this.snare(time, 0.2);
    }
    if (c.section === SECTION_BUILD) {
      const perBeat = snareRoll(c.build, c.bar);
      if (perBeat > 0 && step % (STEPS_PER_BEAT / perBeat) === 0) {
        this.snare(time, 0.08 + 0.16 * (step / (STEPS_PER_BAR - 1)));
      }
    }
    // ハイハット: 16 分 (コンボ 5) > 型 (ビルドは 16 分、ほかは 8 分)。裏拍のオープン (サビ・コンボ 10)
    const open = pattern.open.includes(step) || (layers.openHat && OFFBEATS.includes(step));
    if (open) {
      this.hat(time, 0.12, 0.08);
    } else if (layers.hat16) {
      this.hat(time, 0.03, step % 2 === 0 ? 0.075 : 0.045);
    } else if (pattern.hat.includes(step)) {
      this.hat(time, 0.03, step % 4 === 2 ? 0.075 : step % 2 === 0 ? 0.05 : 0.04);
    }
  }

  /** フィルの 1 打。後半 2 拍をタムで降りてスネアで締める */
  fillHit(step, time) {
    if (step >= 14 || step < 8) {
      this.snare(time, 0.14 + 0.03 * (step % 4));
      return;
    }
    const tom = [220, 220, 175, 175, 131, 131][step - 8];
    this.tom(time, tom, 0.34);
  }

  playTonal(step, time, s, layers) {
    const c = this.cur;
    const sec = c.section;
    const key = c.key;

    // 低音
    for (const [at, tone, oct, len] of BASS[sec]) {
      if (at === step) {
        const note = degreeToMidi(chordDegree(c.root, tone), key, 36) + oct * 12;
        this.bassVoice(time, midiToFreq(note), s * len, sec === SECTION_INTERLUDE ? 0.2 : 0.3, this.pumpGain);
      }
    }

    // 鍵盤の和音
    for (const [at, len] of COMP[sec]) {
      if (at === step) {
        const gain = sec === SECTION_BUILD ? 0.035 + 0.035 * c.build : 0.06;
        for (const d of chordTones(c.root)) {
          this.keyVoice(time, midiToFreq(degreeToMidi(d, key, 60)), s * len * 1.4, gain, this.pumpGain, 0.15);
        }
      }
    }

    // パッド (B から)
    if (step === 0 && sec !== SECTION_A && sec !== SECTION_FANFARE) {
      for (const d of chordTones(c.root)) {
        this.padVoice(time, midiToFreq(degreeToMidi(d, key, 48)), s * STEPS_PER_BAR, 0.05);
      }
    }

    // アルペジオ (右): B は 8 分、ビルドの後半とサビは 16 分、つなぎは 4 分。
    // ビルドは鋸歯のプラックに替えて、ローパスが開くほど明るくなるようにする
    const arpEvery = { [SECTION_B]: 2, [SECTION_BUILD]: c.build >= 1 / 3 ? 1 : 2, [SECTION_CHORUS]: 1,
      [SECTION_INTERLUDE]: 4 }[sec];
    if (arpEvery !== undefined && step % arpEvery === 0) {
      const tone = ARP_ORDER[(step / arpEvery) % ARP_ORDER.length];
      const freq = midiToFreq(degreeToMidi(chordDegree(c.root, tone), key, 72));
      if (sec === SECTION_BUILD) {
        this.supersaw(time, freq, s * arpEvery * 0.6, 0.07 + 0.02 * c.build, this.arpBus);
      } else {
        this.keyVoice(time, freq, s * arpEvery * 0.9, sec === SECTION_CHORUS ? 0.07 : 0.08, this.arpBus, 0.25);
      }
    }

    // 対旋律 (左): 3 度 -> 5 度を 2 分音符で
    if ((sec === SECTION_B || sec === SECTION_BUILD || sec === SECTION_CHORUS) && (step === 0 || step === 8)) {
      const d = chordDegree(c.root, step === 0 ? 1 : 2);
      this.keyVoice(time + s, midiToFreq(degreeToMidi(d, key, 60)), s * 7, 0.11, this.counterBus, 0.2);
    }

    // ブラス風スタブ (サビ)
    if (sec === SECTION_CHORUS) {
      for (const [at, len] of STABS) {
        if (at === step) {
          this.brassChord(time, c.root, key, s * len, 0.065, this.pumpGain);
        }
      }
    }

    // 旋律。サビはスーパーソーのリード (鍵盤を 1 オクターブ下に薄く重ねる)
    const up = layers.leadUp ? 12 : 0;
    for (const e of c.melody) {
      if (e.step !== step) {
        continue;
      }
      const note = degreeToMidi(e.degree, key, 72) + up;
      if (sec === SECTION_CHORUS) {
        this.supersaw(time, midiToFreq(note), s * e.len * 0.95, 0.085, this.melodyBus);
        this.keyVoice(time, midiToFreq(note - 12), s * e.len * 1.6, 0.09, this.melodyBus, 0.15);
      } else {
        this.keyVoice(time, midiToFreq(note), s * e.len * 1.8, sec === SECTION_A ? 0.24 : 0.22, this.melodyBus, 0.18);
      }
    }

    // ライザー: ビルドの 4 小節ごと、サビの 8 小節めの頭から次のまとまりへ
    if (step === 0 && this.drumsOn(time)) {
      const bars = sec === SECTION_BUILD ? riserBars(c.build, c.bar) : (sec === SECTION_CHORUS && isFillBar(c.bar) ? 1 : 0);
      if (bars > 0) {
        this.riser(time, time + bars * STEPS_PER_BAR * s, sec === SECTION_BUILD ? 0.14 + 0.1 * c.build : 0.12, this.song);
      }
    }
  }

  // MARK: - 曲の状態を変える出来事

  /** 量子化の基準にする小節 (time 以前に始まった最後の小節) */
  barAt(time) {
    let found = null;
    for (const b of this.bars) {
      if (b.time <= time + 1e-6) {
        found = b;
      }
    }
    return found ?? this.bars[0] ?? null;
  }

  /** time 以降で最初の division (16 分の数) の格子点。曲が止まっていれば time のまま */
  gridAfter(time, division = 1) {
    const b = this.playing ? this.barAt(time) : null;
    if (b === null) {
      return time;
    }
    return nextGridTime(time, b.time, b.stepDur * division);
  }

  /** 今の 16 分の長さ (曲が止まっていればステージのテンポから) */
  currentStep() {
    const p = this.progress;
    return this.playing && this.cur !== null ? this.cur.stepDur : 60 / musicTempo(p.stage, p.intensity) / STEPS_PER_BEAT;
  }

  /** time に鳴っているコードの根音とキー */
  harmonyAt(time) {
    const b = this.playing ? this.barAt(time) : null;
    if (b === null) {
      const section = this.sectionAt(time);
      return { root: chordAtBar(section, 0), key: sectionKey(section) };
    }
    return { root: b.root, key: b.key };
  }

  /** ミス: ローパスを 1 小節かけて閉じ、次の小節頭からドラムを 1 小節抜いて戻す */
  miss(now) {
    if (!this.playing || now < this.missEnd) {
      return;
    }
    const s = this.currentStep();
    const barDur = s * STEPS_PER_BAR;
    const from = this.gridAfter(now + 0.005, STEPS_PER_BAR);
    const back = from + barDur;
    const f = this.missFilter.frequency;
    f.cancelScheduledValues(now);
    f.setValueAtTime(OPEN_CUTOFF, now);
    f.exponentialRampToValueAtTime(MISS_CUTOFF, now + barDur);
    f.setValueAtTime(MISS_CUTOFF, back);
    f.exponentialRampToValueAtTime(OPEN_CUTOFF, back + s * STEPS_PER_BEAT);
    this.drumMuteFrom = from;
    this.drumMuteTo = back;
    this.missEnd = back + s * STEPS_PER_BEAT;
    this.missShape = { start: now, closed: now + barDur, back, end: this.missEnd };
  }

  /** ミスのローパスの time での周波数 (miss で予約した曲線を計算で追う) */
  missCutoffAt(time) {
    const m = this.missShape;
    if (m === null || time >= m.end || time < m.start) {
      return OPEN_CUTOFF;
    }
    const ratio = MISS_CUTOFF / OPEN_CUTOFF;
    if (time < m.closed) {
      return OPEN_CUTOFF * Math.pow(ratio, (time - m.start) / (m.closed - m.start));
    }
    if (time < m.back) {
      return MISS_CUTOFF;
    }
    return MISS_CUTOFF * Math.pow(1 / ratio, (time - m.back) / (m.end - m.back));
  }

  /** ミスの途中で正解したら、ローパスを 1 拍で開けてドラムは次の小節頭から戻す */
  recover(at) {
    if (at >= this.missEnd) {
      return;
    }
    const s = this.currentStep();
    const now = this.ctx.currentTime;
    const f = this.missFilter.frequency;
    f.cancelScheduledValues(now);
    f.setValueAtTime(this.missCutoffAt(now), now);
    f.setValueAtTime(this.missCutoffAt(at), at);
    f.exponentialRampToValueAtTime(OPEN_CUTOFF, at + s * STEPS_PER_BEAT);
    this.drumMuteTo = Math.min(this.drumMuteTo, this.gridAfter(at, STEPS_PER_BAR));
    this.missEnd = at + s * STEPS_PER_BEAT;
    this.missShape = null;
  }

  /** カウントダウンのダッキング (−8 dB)。次の数字が来なければ DUCK_HOLD 後に戻す */
  duckFor(now) {
    const g = this.duck.gain;
    g.cancelScheduledValues(now);
    g.setTargetAtTime(DUCK_LEVEL, now, 0.04);
    g.setTargetAtTime(1, now + DUCK_HOLD, 0.12);
  }

  unduck(now) {
    const g = this.duck.gain;
    g.cancelScheduledValues(now);
    g.setTargetAtTime(1, now, 0.08);
  }

  /** 曲の通り道を元に戻す (テープ・ダッキング・ミスのローパス) */
  restoreChain(at) {
    this.tape.delayTime.cancelScheduledValues(at);
    this.tape.delayTime.setValueAtTime(0, at);
    this.tapeGain.gain.cancelScheduledValues(at);
    this.tapeGain.gain.setValueAtTime(1, at);
    this.duck.gain.cancelScheduledValues(at);
    this.duck.gain.setValueAtTime(1, at);
    this.missFilter.frequency.cancelScheduledValues(at);
    this.missFilter.frequency.setValueAtTime(OPEN_CUTOFF, at);
  }

  /**
   * 出来事を鳴らす。名前は CUE_NAMES のどれか。知らない名前は警告して無視する。
   *   correct {combo} / close / wrong / lifeLost {lives} / timeout / safe / countdown {n} / lastProblem /
   *   stageClear {stage} / comboMilestone {combo} / dopaMilestone {level} / gameOver / retry /
   *   whoosh {delay} / blip
   */
  cue(name, opts = {}) {
    if (!CUE_NAMES.includes(name)) {
      console.warn(`sound.cue: 知らない名前 "${name}" を無視しました`);
      return;
    }
    if (this.ctx === null) {
      return;
    }
    const o = opts ?? {};
    const now = this.ctx.currentTime;
    switch (name) {
      case 'correct': this.cueCorrect(now, o.combo); break;
      case 'close': this.cueClose(now); break;
      case 'wrong': this.cueWrong(now); break;
      case 'lifeLost': this.cueLifeLost(now, o.lives); break;
      case 'timeout': this.cueTimeout(now); break;
      case 'safe': this.cueSafe(now); break;
      case 'countdown': this.cueCountdown(now, o.n); break;
      case 'lastProblem': this.cueLastProblem(now); break;
      case 'stageClear': this.cueStageClear(now, o.stage); break;
      case 'comboMilestone': this.cueMilestone(now, false); break;
      case 'dopaMilestone': this.cueMilestone(now, true); break;
      case 'gameOver': this.cueGameOver(now); break;
      case 'retry': this.cueRetry(now); break;
      case 'whoosh': this.whoosh(now + Math.max(0, Number.isFinite(o.delay) ? o.delay : 0)); break;
      case 'blip': this.cueBlip(now); break;
    }
  }

  /** 正解: 次の 16 分に、今のコードの構成音を上へ 4 つ。コンボで始まりの度数が上がる */
  cueCorrect(now, combo) {
    const c = Number.isFinite(combo) ? combo : this.progress.combo;
    this.progress = { ...this.progress, combo: Math.max(0, Math.floor(c)) };
    const t = this.gridAfter(now + 0.01);
    this.unduck(now);
    this.recover(t);
    const { root, key } = this.harmonyAt(t);
    const gap = Math.min(0.07, this.currentStep() / 2);
    correctNotes(root, c, key).forEach((note, i) => {
      this.keyVoice(t + i * gap, midiToFreq(note), 0.34, 0.26, this.sfxGain, 0.25);
    });
  }

  /** おしい: 柔らかい二音 (3 度 -> 根音)。ミスなので曲も沈める */
  cueClose(now) {
    const t = this.gridAfter(now + 0.01);
    const { root, key } = this.harmonyAt(t);
    this.keyVoice(t, midiToFreq(degreeToMidi(root + 2 + 7, key, 60)), 0.34, 0.32, this.sfxGain, 0.22);
    this.keyVoice(t + this.currentStep() * 2, midiToFreq(degreeToMidi(root + 7, key, 60)), 0.52, 0.32, this.sfxGain, 0.22);
    this.miss(now);
  }

  /** もういちど: 今のコードの根音を低く一音 (とがらせず、短い減衰で) */
  cueWrong(now) {
    const t = this.gridAfter(now + 0.01);
    const { root, key } = this.harmonyAt(t);
    const note = degreeToMidi(root, key, 48);
    this.keyVoice(t, midiToFreq(note), 0.7, 0.32, this.sfxGain, 0.2);
    this.keyVoice(t, midiToFreq(note - 12), 0.7, 0.18, this.sfxGain, 0.1);
    this.miss(now);
  }

  /** ハートが割れる: 割れる音 + 高い二音が下がる。残りが少ないほど低い */
  cueLifeLost(now, lives) {
    const left = Number.isFinite(lives) ? Math.max(0, Math.min(3, lives)) : 2;
    const { key } = this.harmonyAt(now);
    this.noise(now, 0.05, 0.3, 'bandpass', 3200, 1.4, this.sfxGain);
    this.noise(now + 0.03, 0.12, 0.14, 'highpass', 6000, 0.8, this.sfxGain);
    const top = 11 + left;
    this.keyVoice(now + 0.02, midiToFreq(degreeToMidi(top, key, 60)), 0.25, 0.18, this.sfxGain, 0.3);
    this.keyVoice(now + 0.12, midiToFreq(degreeToMidi(top - 3, key, 60)), 0.45, 0.18, this.sfxGain, 0.3);
  }

  /** 時間切れ: テープストップの効果音 (今の和音のピッチが落ちる) + 曲を沈める */
  cueTimeout(now) {
    this.unduck(now);
    const { root, key } = this.harmonyAt(now);
    const ctx = this.ctx;
    const duration = 0.7;
    const filter = ctx.createBiquadFilter();
    filter.type = 'lowpass';
    filter.frequency.setValueAtTime(4000, now);
    filter.frequency.exponentialRampToValueAtTime(300, now + duration);
    const env = ctx.createGain();
    env.gain.setValueAtTime(0.16, now);
    env.gain.setValueAtTime(0.16, now + duration * 0.5);
    env.gain.linearRampToValueAtTime(0, now + duration);
    for (const d of chordTones(root)) {
      const osc = ctx.createOscillator();
      osc.type = 'sawtooth';
      const freq = midiToFreq(degreeToMidi(d, key, 60));
      osc.frequency.setValueAtTime(freq, now);
      osc.frequency.exponentialRampToValueAtTime(freq * 0.2, now + duration);
      osc.connect(filter);
      osc.start(now);
      osc.stop(now + duration + 0.02);
    }
    filter.connect(env);
    env.connect(this.sfxGain);
    this.miss(now);
  }

  /** セーフ: ブラスの和音 + 上がる二音 */
  cueSafe(now) {
    const t = this.gridAfter(now + 0.01);
    this.unduck(now);
    this.recover(t);
    const { root, key } = this.harmonyAt(t);
    this.brassChord(t, root, key, 0.3, 0.09, this.sfxGain);
    const s = Math.min(0.09, this.currentStep());
    this.keyVoice(t, midiToFreq(degreeToMidi(root + 7 + 2, key, 60)), 0.2, 0.22, this.sfxGain, 0.25);
    this.keyVoice(t + s, midiToFreq(degreeToMidi(root + 7 + 4, key, 60)), 0.2, 0.22, this.sfxGain, 0.25);
    this.keyVoice(t + s * 2, midiToFreq(degreeToMidi(root + 14, key, 60)), 0.4, 0.22, this.sfxGain, 0.3);
  }

  /** カウントダウン n: 曲をダッキングし、この 1 秒の拍に時計の音、心音のキック、数字ごとに上がる音 */
  cueCountdown(now, n) {
    this.duckFor(now);
    const { key } = this.harmonyAt(now);
    this.heart(now, 0.5);
    this.keyVoice(now, midiToFreq(degreeToMidi(countdownDegree(n), key, 60)), 0.45, 0.24, this.sfxGain, 0.3);
    const beat = this.currentStep() * STEPS_PER_BEAT;
    let t = this.playing ? this.gridAfter(now, STEPS_PER_BEAT) : now;
    for (let i = 0; t < now + 0.98; i += 1, t += beat) {
      this.tick(t, i % 2 === 0);
    }
  }

  /**
   * ラスト 1 問: 次の小節頭へライザーを上げてインパクト + クラッシュ。
   * 小節頭まで 1 拍もなければ次の次の小節頭にし、サビへの切り替えもそこまで待たせる
   */
  cueLastProblem(now) {
    const barDur = this.currentStep() * STEPS_PER_BAR;
    let at = this.playing ? this.gridAfter(now, STEPS_PER_BAR) : now + 0.8;
    if (at - now < barDur / 4) {
      at += barDur;
      this.holdUntil = at;
    }
    this.riser(now, at, 0.16, this.sfxGain);
    this.impact(at, 0.6, this.sfxGain);
    this.crash(at, 0.26, this.sfxGain);
    this.lastImpact = at;
  }

  /** 節目 (コンボ / ドパ): 次の拍へライザー + インパクト + クラッシュ。ドパは高いきらめきを足す */
  cueMilestone(now, dopa) {
    const beat = this.currentStep() * STEPS_PER_BEAT;
    let at = this.playing ? this.gridAfter(now, STEPS_PER_BEAT) : now + 0.3;
    if (at - now < 0.25) {
      at += beat;
    }
    const { root, key } = this.harmonyAt(at);
    this.riser(now, at, 0.12, this.sfxGain);
    this.impact(at, 0.45, this.sfxGain);
    this.crash(at, 0.22, this.sfxGain);
    if (dopa) {
      // 構成音を 2 オクターブ駆け上がる
      [0, 2, 4, 7, 9, 11].forEach((rel, i) => {
        this.keyVoice(at + i * 0.055, midiToFreq(degreeToMidi(root + rel + 7, key, 60)), 0.6, 0.14, this.sfxGain, 0.6);
      });
    } else {
      this.brassChord(at, root, key, beat * 0.9, 0.08, this.sfxGain);
      this.brassChord(at + beat, root, key, beat * 1.8, 0.08, this.sfxGain);
    }
  }

  /**
   * ステージクリア: 残りの拍をフィルにし、次の小節頭から 2 小節のファンファーレ。
   * そのあとは setProgress で別のステージが来るまでつなぎを鳴らす。
   * stage はクリアしたステージ (2 つめのステージから、リードにオクターブ上を重ねる)
   */
  cueStageClear(now, stage) {
    const cleared = Number.isFinite(stage) ? Math.floor(stage) : this.progress.stage;
    this.unduck(now);
    const s = this.currentStep();
    let at = now + 0.05;
    if (this.playing) {
      at = this.gridAfter(now, STEPS_PER_BAR);
      if (at - now < s * 2) {
        at += s * STEPS_PER_BAR;
      }
      this.fillFrom = this.gridAfter(now + 0.005);
      this.fillTo = at;
      this.fanfareFrom = at;
      this.fanfareTo = at + s * STEPS_PER_BAR * 2;
      this.fanfareStep = s;
      // 次のステージの setProgress が先に来ていたら、つなぎは要らない
      if (this.progress.stage <= cleared) {
        this.clearedFrom = this.progress.stage;
      }
    }
    this.fanfare(at, s, sectionKey(SECTION_FANFARE), cleared >= 2);
  }

  /** ゲームオーバー: 曲をテープストップで止め、短いジングル */
  cueGameOver(now) {
    if (now < this.tapeEnd) {
      return;   // すでに止めている途中
    }
    this.unduck(now);
    let jingleAt = now + 0.05;
    if (this.playing) {
      const g = this.tape.delayTime;
      g.cancelScheduledValues(now);
      g.setValueCurveAtTime(tapeStopCurve(TAPE_STOP), now, TAPE_STOP);
      this.tapeGain.gain.cancelScheduledValues(now);
      this.tapeGain.gain.setValueAtTime(1, now);
      this.tapeGain.gain.setValueAtTime(1, now + TAPE_STOP * 0.6);
      this.tapeGain.gain.linearRampToValueAtTime(0, now + TAPE_STOP);
      // 遅延が読み出すのは now + TAPE_STOP / 2 までに作った音なので、そこまでは曲を作り続ける
      this.stopAt = now + TAPE_STOP / 2;
      this.tapeEnd = now + TAPE_STOP;
      jingleAt = now + TAPE_STOP + 0.05;
    }
    this.jingle(jingleAt);
  }

  /** リトライ: 曲の通り道を戻して A から鳴らし直す (リトライした問題のあいだは A) */
  cueRetry(now) {
    this.halt();
    this.wantsMusic = true;
    this.runScheduler(now + 0.08);
    const p = this.progress;
    this.retryHold = { stage: p.stage, index: p.index };
  }

  /** 音量スライダーを動かしたときの確認音 (今のキーの主音) */
  cueBlip(now) {
    const { key } = this.harmonyAt(now);
    this.keyVoice(now, midiToFreq(degreeToMidi(7, key, 60)), 0.34, 0.26, this.sfxGain, 0.25);
  }

  // MARK: - 決まった節 (ファンファーレ・ジングル)

  /** 2 小節のファンファーレ: タタタ・ターン (I) -> IV・V・I。ブラス + リード + 打楽器 */
  fanfare(at, s, key, octave) {
    const out = this.sfxGain;
    const bar = s * STEPS_PER_BAR;
    const hits = [[0, 0, 1], [2, 0, 1], [4, 0, 1], [6, 0, 10], [16, 3, 4], [20, 4, 4], [24, 0, 8]];
    const lead = [[0, 4, 1], [2, 4, 1], [4, 4, 1], [6, 7, 9], [16, 5, 4], [20, 6, 4], [24, 7, 8]];
    for (const [step, root, len] of hits) {
      this.brassChord(at + step * s, root, key, s * len, 0.1, out);
      this.kick(at + step * s, 0.5, out);
    }
    for (const [step, degree, len] of lead) {
      this.supersaw(at + step * s, midiToFreq(degreeToMidi(degree, key, 72)), s * len, 0.07, out);
      if (octave) {
        this.supersaw(at + step * s, midiToFreq(degreeToMidi(degree + 7, key, 72)), s * len, 0.035, out);
      }
    }
    for (let i = 0; i < 4; i += 1) {
      this.snare(at + (20 + i) * s, 0.12 + 0.04 * i, out);
    }
    this.crash(at, 0.26, out);
    this.impact(at, 0.5, out);
    this.crash(at + bar * 1.5, 0.3, out);
    this.impact(at + bar * 1.5, 0.45, out);
  }

  /** 「残念だけどかわいい」ジングル: はずむ下降 -> 下へ曲がる音 -> 高い鈴の和音 */
  jingle(at) {
    const out = this.sfxGain;
    [[0, 11], [0.14, 9], [0.28, 10], [0.42, 8]].forEach(([dt, d]) => {
      this.keyVoice(at + dt, midiToFreq(degreeToMidi(d, 0, 60)), 0.18, 0.18, out, 0.25);
    });
    // 下へ曲がる「ぷわーん」(三角波 + ビブラート)
    const ctx = this.ctx;
    const t = at + 0.6;
    const osc = ctx.createOscillator();
    osc.type = 'triangle';
    const freq = midiToFreq(degreeToMidi(7, 0, 60));
    osc.frequency.setValueAtTime(freq, t);
    osc.frequency.setValueAtTime(freq, t + 0.15);
    osc.frequency.exponentialRampToValueAtTime(freq * 0.84, t + 0.55);
    const lfo = ctx.createOscillator();
    lfo.frequency.value = 6;
    const lfoGain = ctx.createGain();
    lfoGain.gain.value = freq * 0.012;
    lfo.connect(lfoGain);
    lfoGain.connect(osc.frequency);
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, t);
    env.gain.linearRampToValueAtTime(0.2, t + 0.02);
    env.gain.setValueAtTime(0.2, t + 0.4);
    env.gain.exponentialRampToValueAtTime(0.0001, t + 0.62);
    osc.connect(env);
    this.route(env, out, 0.25);
    osc.start(t);
    lfo.start(t);
    osc.stop(t + 0.65);
    lfo.stop(t + 0.65);
    // 最後に高い鈴の和音 (ちょこんと)
    for (const d of [14, 16, 18]) {
      this.keyVoice(at + 1.3, midiToFreq(degreeToMidi(d, 0, 60)), 0.9, 0.1, out, 0.5);
    }
  }

  // MARK: - 音源

  /** リバーブへ送る枝を足す。送り先は出力先のバス (曲か効果音か) で決まる */
  send(node, amount, destination = null) {
    if (amount <= 0) {
      return;
    }
    const verb = this.verbs.get(destination) ?? this.verbs.get(this.song);
    const g = this.ctx.createGain();
    g.gain.value = amount;
    node.connect(g);
    g.connect(verb);
  }

  /** 出力先へつなぎ、同じバスのリバーブへ送る */
  route(node, destination, reverb) {
    node.connect(destination);
    this.send(node, reverb, destination);
  }

  /** キックでサイドチェインのポンプを掛ける (depth だけ下げて 0.07 秒で戻す) */
  sidechain(time, depth) {
    if (depth <= 0) {
      return;
    }
    const g = this.pumpGain.gain;
    g.setValueAtTime(1 - depth, time);
    g.setTargetAtTime(1, time + 0.01, 0.07);
  }

  /**
   * FM の鍵盤 (マリンバ / エレピ風)。キャリア sine をモジュレーター sine で揺らし、
   * 変調量を速く減衰させて硬い立ち上がりを作る。キャリアは 2 本を微デチューンする。
   */
  keyVoice(time, freq, duration, gain, destination, reverb = 0.15) {
    if (this.ctx === null || !Number.isFinite(freq)) {
      return;
    }
    const ctx = this.ctx;
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, time);
    env.gain.linearRampToValueAtTime(gain, time + 0.006);
    env.gain.exponentialRampToValueAtTime(Math.max(0.0001, gain * 0.25), time + duration * 0.35);
    env.gain.exponentialRampToValueAtTime(0.0001, time + duration);

    const mod = ctx.createOscillator();
    mod.type = 'sine';
    mod.frequency.setValueAtTime(freq * 2, time);
    const modGain = ctx.createGain();
    modGain.gain.setValueAtTime(freq * 2.2, time);
    modGain.gain.exponentialRampToValueAtTime(freq * 0.02, time + Math.min(0.22, duration));
    mod.connect(modGain);

    for (const cents of [-6, 6]) {
      const carrier = ctx.createOscillator();
      carrier.type = 'sine';
      carrier.frequency.setValueAtTime(freq, time);
      carrier.detune.setValueAtTime(cents, time);
      modGain.connect(carrier.frequency);
      carrier.connect(env);
      carrier.start(time);
      carrier.stop(time + duration + 0.05);
    }
    mod.start(time);
    mod.stop(time + duration + 0.05);

    this.route(env, destination ?? this.tonal, reverb);
  }

  /** パッド。鋸歯 2 本を微デチューンしてローパス (周波数エンベロープ付き) に通す。キックで押される */
  padVoice(time, freq, duration, gain) {
    if (this.ctx === null || !Number.isFinite(freq)) {
      return;
    }
    const ctx = this.ctx;
    const filter = ctx.createBiquadFilter();
    filter.type = 'lowpass';
    filter.Q.value = 0.8;
    filter.frequency.setValueAtTime(Math.max(200, freq * 1.5), time);
    filter.frequency.linearRampToValueAtTime(Math.max(600, freq * 6), time + duration * 0.3);
    filter.frequency.linearRampToValueAtTime(Math.max(300, freq * 2), time + duration);

    const env = ctx.createGain();
    env.gain.setValueAtTime(0, time);
    env.gain.linearRampToValueAtTime(gain, time + duration * 0.18);
    env.gain.setTargetAtTime(gain * 0.7, time + duration * 0.2, duration * 0.3);
    env.gain.linearRampToValueAtTime(0, time + duration);

    for (const cents of [-8, 8]) {
      const osc = ctx.createOscillator();
      osc.type = 'sawtooth';
      osc.frequency.setValueAtTime(freq, time);
      osc.detune.setValueAtTime(cents, time);
      osc.connect(filter);
      osc.start(time);
      osc.stop(time + duration + 0.05);
    }
    filter.connect(env);
    this.route(env, this.pumpGain, 0.35);
  }

  /** 低音。三角波にサブの sine (1 オクターブ下) を重ねる */
  bassVoice(time, freq, duration, gain, destination) {
    if (this.ctx === null || !Number.isFinite(freq)) {
      return;
    }
    const ctx = this.ctx;
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, time);
    env.gain.linearRampToValueAtTime(gain, time + 0.014);
    env.gain.setTargetAtTime(gain * 0.55, time + 0.02, duration * 0.25);
    env.gain.exponentialRampToValueAtTime(0.0001, time + duration);

    const tri = ctx.createOscillator();
    tri.type = 'triangle';
    tri.frequency.setValueAtTime(freq, time);
    tri.connect(env);
    tri.start(time);
    tri.stop(time + duration + 0.05);

    const sub = ctx.createOscillator();
    const subGain = ctx.createGain();
    subGain.gain.value = 0.6;
    sub.type = 'sine';
    sub.frequency.setValueAtTime(freq / 2, time);
    sub.connect(subGain);
    subGain.connect(env);
    sub.start(time);
    sub.stop(time + duration + 0.05);

    env.connect(destination);
  }

  /** スーパーソーのリード: 鋸歯 5 本をデチューンして左右に広げ、ローパスのエンベロープで立ち上げる */
  supersaw(time, freq, duration, gain, destination) {
    if (this.ctx === null || !Number.isFinite(freq)) {
      return;
    }
    const ctx = this.ctx;
    const filter = ctx.createBiquadFilter();
    filter.type = 'lowpass';
    filter.Q.value = 0.7;
    filter.frequency.setValueAtTime(freq * 2, time);
    filter.frequency.exponentialRampToValueAtTime(Math.min(16000, freq * 9), time + 0.02);
    filter.frequency.exponentialRampToValueAtTime(Math.min(12000, freq * 4), time + Math.max(0.05, duration));

    const env = ctx.createGain();
    env.gain.setValueAtTime(0, time);
    env.gain.linearRampToValueAtTime(gain, time + 0.01);
    env.gain.setTargetAtTime(gain * 0.75, time + 0.03, 0.08);
    env.gain.setValueAtTime(gain * 0.75, time + duration);
    env.gain.exponentialRampToValueAtTime(0.0001, time + duration + 0.12);

    [-24, -11, 0, 11, 24].forEach((cents, i) => {
      const osc = ctx.createOscillator();
      osc.type = 'sawtooth';
      osc.frequency.setValueAtTime(freq, time);
      osc.detune.setValueAtTime(cents, time);
      const lane = this.panned((i - 2) * 0.3, filter);
      osc.connect(lane);
      osc.start(time);
      osc.stop(time + duration + 0.15);
    });
    filter.connect(env);
    this.route(env, destination, 0.2);
  }

  /** ブラス風スタブ 1 音: 鋸歯 2 本 + 1 オクターブ下の矩形波、ピッチのしゃくりとローパスの速い開き */
  brass(time, freq, duration, gain, destination) {
    if (this.ctx === null || !Number.isFinite(freq)) {
      return;
    }
    const ctx = this.ctx;
    const filter = ctx.createBiquadFilter();
    filter.type = 'lowpass';
    filter.Q.value = 1.2;
    filter.frequency.setValueAtTime(350, time);
    filter.frequency.exponentialRampToValueAtTime(Math.min(9000, freq * 7), time + 0.035);
    filter.frequency.exponentialRampToValueAtTime(Math.min(6000, freq * 3), time + 0.035 + Math.max(0.05, duration));

    const env = ctx.createGain();
    env.gain.setValueAtTime(0, time);
    env.gain.linearRampToValueAtTime(gain, time + 0.012);
    env.gain.setTargetAtTime(gain * 0.7, time + 0.04, 0.1);
    env.gain.setValueAtTime(gain * 0.7, time + duration);
    env.gain.exponentialRampToValueAtTime(0.0001, time + duration + 0.08);

    const voices = [['sawtooth', 1, -7, 1], ['sawtooth', 1, 7, 1], ['square', 0.5, 0, 0.5]];
    for (const [type, ratio, cents, level] of voices) {
      const osc = ctx.createOscillator();
      osc.type = type;
      osc.frequency.setValueAtTime(freq * ratio, time);
      osc.detune.setValueAtTime(cents - 40, time);
      osc.detune.linearRampToValueAtTime(cents, time + 0.04);
      const g = ctx.createGain();
      g.gain.value = level;
      osc.connect(g);
      g.connect(filter);
      osc.start(time);
      osc.stop(time + duration + 0.1);
    }
    filter.connect(env);
    this.route(env, destination, 0.2);
  }

  /** ブラスの三和音 (根音・3 度・5 度 + オクターブ上の根音) */
  brassChord(time, root, key, duration, gain, destination) {
    for (const d of [...chordTones(root), root + 7]) {
      this.brass(time, midiToFreq(degreeToMidi(d, key, 60)), duration, gain, destination);
    }
  }

  /** 使い回しのノイズをフィルターに通して鳴らす */
  noise(time, duration, gain, type, frequency, q, destination) {
    if (this.ctx === null || this.noiseBuffer === null) {
      return;
    }
    const ctx = this.ctx;
    const src = ctx.createBufferSource();
    src.buffer = this.noiseBuffer;
    src.loop = true;
    const filter = ctx.createBiquadFilter();
    filter.type = type;
    filter.frequency.value = frequency;
    filter.Q.value = q;
    const env = ctx.createGain();
    env.gain.setValueAtTime(gain, time);
    env.gain.exponentialRampToValueAtTime(0.0001, time + duration);
    src.connect(filter);
    filter.connect(env);
    env.connect(destination ?? this.drumBus);
    src.start(time, Math.random() * 0.5);
    src.stop(time + duration + 0.02);
    return env;
  }

  /** キック: sine のピッチスイープ (150 -> 50 Hz、100 ms) にクリックを足す */
  kick(time, gain = 0.62, destination = this.drumBus) {
    if (this.ctx === null) {
      return;
    }
    const ctx = this.ctx;
    const osc = ctx.createOscillator();
    const env = ctx.createGain();
    osc.type = 'sine';
    osc.frequency.setValueAtTime(150, time);
    osc.frequency.exponentialRampToValueAtTime(50, time + 0.10);
    env.gain.setValueAtTime(0, time);
    env.gain.linearRampToValueAtTime(gain, time + 0.004);
    env.gain.exponentialRampToValueAtTime(0.0001, time + 0.24);
    osc.connect(env);
    env.connect(destination);
    osc.start(time);
    osc.stop(time + 0.26);
    this.noise(time, 0.012, gain * 0.26, 'highpass', 2200, 0.7, destination);
  }

  /** スネア: ノイズ (バンドパス 1.8 kHz) に 200 Hz の短い音を足す */
  snare(time, gain = 0.24, destination = this.drumBus) {
    if (this.ctx === null) {
      return;
    }
    const tail = this.noise(time, 0.14, gain, 'bandpass', 1800, 0.7, destination);
    const ctx = this.ctx;
    const osc = ctx.createOscillator();
    const env = ctx.createGain();
    osc.type = 'triangle';
    osc.frequency.setValueAtTime(200, time);
    env.gain.setValueAtTime(gain * 0.66, time);
    env.gain.exponentialRampToValueAtTime(0.0001, time + 0.07);
    osc.connect(env);
    env.connect(destination);
    osc.start(time);
    osc.stop(time + 0.09);
    this.send(tail, 0.18, destination);
  }

  /** クラップ: バンドパスのノイズを 11 ms おきに 3 回はじいてから短い残響 */
  clap(time, gain = 0.3, destination = this.clapBus) {
    if (this.ctx === null) {
      return;
    }
    for (let i = 0; i < 3; i += 1) {
      this.noise(time + i * 0.011, 0.012, gain, 'bandpass', 1150, 1.1, destination);
    }
    const tail = this.noise(time + 0.033, 0.16, gain * 0.8, 'bandpass', 1150, 0.9, destination);
    this.send(tail, 0.3, destination);
  }

  /** ハイハット: ノイズ (ハイパス 8 kHz)。閉じ 30 ms / 開き 120 ms */
  hat(time, duration, gain) {
    this.noise(time, duration, gain, 'highpass', 8000, 0.6, this.hatBus);
  }

  /** タム: sine のピッチを 150 ms で 0.6 倍へ落とす */
  tom(time, freq, gain) {
    if (this.ctx === null) {
      return;
    }
    const ctx = this.ctx;
    const osc = ctx.createOscillator();
    const env = ctx.createGain();
    osc.type = 'sine';
    osc.frequency.setValueAtTime(freq, time);
    osc.frequency.exponentialRampToValueAtTime(freq * 0.6, time + 0.15);
    env.gain.setValueAtTime(0, time);
    env.gain.linearRampToValueAtTime(gain, time + 0.003);
    env.gain.exponentialRampToValueAtTime(0.0001, time + 0.26);
    osc.connect(env);
    env.connect(this.drumBus);
    osc.start(time);
    osc.stop(time + 0.28);
    this.noise(time, 0.02, gain * 0.3, 'bandpass', 2500, 0.8);
    this.send(env, 0.15, this.drumBus);
  }

  /** クラッシュ: ハイパスのノイズの長い減衰に、非整数倍の矩形波の金属音を重ねる */
  crash(time, gain, destination = this.crashBus) {
    if (this.ctx === null) {
      return;
    }
    const ring = this.noise(time, 1.7, gain, 'highpass', 4500, 0.5, destination);
    this.noise(time, 0.9, gain * 0.6, 'bandpass', 9000, 0.8, destination);
    this.send(ring, 0.3, destination);
    const ctx = this.ctx;
    const hp = ctx.createBiquadFilter();
    hp.type = 'highpass';
    hp.frequency.value = 3000;
    const env = ctx.createGain();
    env.gain.setValueAtTime(gain * 0.18, time);
    env.gain.exponentialRampToValueAtTime(0.0001, time + 1.0);
    for (const f of [540, 803, 1172, 1631]) {
      const osc = ctx.createOscillator();
      osc.type = 'square';
      osc.frequency.value = f;
      osc.connect(hp);
      osc.start(time);
      osc.stop(time + 1.02);
    }
    hp.connect(env);
    env.connect(destination);
  }

  /** ライザー: ノイズのバンドパスを start から end へ掃き上げ、音量も上げる。sine の上昇を重ねる */
  riser(start, end, gain, destination) {
    if (this.ctx === null || this.noiseBuffer === null || !(end > start)) {
      return;
    }
    const ctx = this.ctx;
    const src = ctx.createBufferSource();
    src.buffer = this.noiseBuffer;
    src.loop = true;
    const filter = ctx.createBiquadFilter();
    filter.type = 'bandpass';
    filter.Q.value = 0.9;
    filter.frequency.setValueAtTime(600, start);
    filter.frequency.exponentialRampToValueAtTime(12000, end);
    const env = ctx.createGain();
    env.gain.setValueAtTime(0.0001, start);
    env.gain.exponentialRampToValueAtTime(gain, end - 0.01);
    env.gain.linearRampToValueAtTime(0, end + 0.02);
    src.connect(filter);
    filter.connect(env);
    this.route(env, destination, 0.3);
    src.start(start, Math.random() * 0.5);
    src.stop(end + 0.05);

    const osc = ctx.createOscillator();
    osc.type = 'sine';
    osc.frequency.setValueAtTime(220, start);
    osc.frequency.exponentialRampToValueAtTime(1760, end);
    const oscGain = ctx.createGain();
    oscGain.gain.setValueAtTime(0.0001, start);
    oscGain.gain.exponentialRampToValueAtTime(gain * 0.25, end - 0.01);
    oscGain.gain.linearRampToValueAtTime(0, end + 0.02);
    osc.connect(oscGain);
    oscGain.connect(destination);
    osc.start(start);
    osc.stop(end + 0.05);
  }

  /** インパクト: 低い sine の長い落下 (90 -> 28 Hz) に、こもったノイズの破裂とリバーブ */
  impact(time, gain, destination) {
    if (this.ctx === null) {
      return;
    }
    const ctx = this.ctx;
    const osc = ctx.createOscillator();
    osc.type = 'sine';
    osc.frequency.setValueAtTime(90, time);
    osc.frequency.exponentialRampToValueAtTime(28, time + 0.6);
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, time);
    env.gain.linearRampToValueAtTime(gain, time + 0.005);
    env.gain.exponentialRampToValueAtTime(0.0001, time + 1.1);
    osc.connect(env);
    env.connect(destination);
    osc.start(time);
    osc.stop(time + 1.15);
    const burst = this.noise(time, 0.4, gain * 0.5, 'lowpass', 900, 0.7, destination);
    this.send(burst, 0.5, destination);
  }

  /** 時計の音: 短い sine (チッ = 2.2 kHz / タッ = 1.5 kHz) + 高いノイズのかちっ */
  tick(time, high) {
    if (this.ctx === null) {
      return;
    }
    const ctx = this.ctx;
    const osc = ctx.createOscillator();
    osc.type = 'sine';
    osc.frequency.value = high ? 2200 : 1500;
    const env = ctx.createGain();
    env.gain.setValueAtTime(0.16, time);
    env.gain.exponentialRampToValueAtTime(0.0001, time + 0.03);
    osc.connect(env);
    env.connect(this.sfxGain);
    osc.start(time);
    osc.stop(time + 0.04);
    this.noise(time, 0.008, 0.12, 'highpass', 6000, 0.7, this.sfxGain);
  }

  /** 心音のキック: どくん (低い sine を 2 回、2 回めは弱く) */
  heart(time, gain) {
    if (this.ctx === null) {
      return;
    }
    const ctx = this.ctx;
    [[0, 1], [0.17, 0.7]].forEach(([dt, level]) => {
      const t = time + dt;
      const osc = ctx.createOscillator();
      osc.type = 'sine';
      osc.frequency.setValueAtTime(75, t);
      osc.frequency.exponentialRampToValueAtTime(42, t + 0.12);
      const env = ctx.createGain();
      env.gain.setValueAtTime(0, t);
      env.gain.linearRampToValueAtTime(gain * level, t + 0.008);
      env.gain.exponentialRampToValueAtTime(0.0001, t + 0.2);
      osc.connect(env);
      env.connect(this.sfxGain);
      osc.start(t);
      osc.stop(t + 0.22);
    });
  }

  /** 次の問題の到着を鳴らす「シュッ」。ノイズをバンドパスで 80 ms のあいだ上へ掃く */
  whoosh(t) {
    if (this.ctx === null || this.noiseBuffer === null) {
      return;
    }
    const ctx = this.ctx;
    const duration = 0.08;
    const src = ctx.createBufferSource();
    src.buffer = this.noiseBuffer;
    src.loop = true;
    const filter = ctx.createBiquadFilter();
    filter.type = 'bandpass';
    filter.Q.value = 1.1;
    filter.frequency.setValueAtTime(600, t);
    filter.frequency.exponentialRampToValueAtTime(5200, t + duration);
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, t);
    env.gain.linearRampToValueAtTime(0.22, t + 0.012);
    env.gain.exponentialRampToValueAtTime(0.0001, t + duration);
    src.connect(filter);
    filter.connect(env);
    this.route(env, this.sfxGain, 0.12);
    src.start(t, Math.random() * 0.5);
    src.stop(t + duration + 0.02);
  }
}
