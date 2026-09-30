// ステージの進行・判定・制限時間・ライフ。DOM も canvas も触らないので node でそのまま試せる。

import { LAP_AVOID, pickProblem, problemOf, PROBLEMS } from './problems.js';
import {
  STAGE_QUESTIONS,
  COMBO_REPORT_MIN,
  DOPA_MAX,
  advanceDopa,
  baseIncrement,
  baseIntensity,
  comboMultiplier,
  crossedMilestones,
  extraIncrement,
  extraIntensity,
  extraQuestionScore,
  isComboCelebration,
  score
} from './scoring.js';

/** 判定の結果 */
export const CORRECT = 'correct';   // top-1 が対象字
export const CLOSE = 'close';       // top-3 に対象字 (おしい)
export const WRONG = 'wrong';       // それ以外 (もういちど)
export const TIMEOUT = 'timeout';   // 0 秒になっても正解が書けていない (時間切れ)

/** 同じ問題でこの回数だけ外したら、なぞり用の薄い見本を出す */
export const HINT_AFTER_MISSES = 2;
/** 1 問の制限時間 (ms) */
export const TIME_LIMIT_MS = 15000;
/** 問題が出てから数え始めるまで (ms)。次の問題がすべり込む間は数えない */
export const TIME_GRACE_MS = 200;
/** 残り何秒から中央に数字を出すか */
export const COUNTDOWN_FROM = 5;
/** 残り時間のバーを赤く脈動させる割合 */
export const TIME_LOW = 0.3;
/** 時間切れのとき、正解の字を見せる長さ (ms) */
export const REVEAL_MS = 800;
/** ライフ (ミス 3 回でゲームオーバー) */
export const LIVES = 3;
/** 1 ステージで使えるパスの回数 */
export const PASS_LIMIT = 3;
/** 認識器から取る候補数。「おしい」の判定に top-3 まで見る */
export const TOP_K = 3;

/** 局面 */
export const PHASE_PLAY = 'play';       // 書ける (制限時間が進む)
export const PHASE_REVEAL = 'reveal';   // 時間切れで正解の字を見せている (時間は止まる)
export const PHASE_OVER = 'over';       // ライフ 0 (ゲームオーバー)

/**
 * 認識結果 (top-k) と対象字から判定する。
 *
 * @param {{char: string}[]} rows 確率の高い順の候補
 * @param {string} target 対象字
 */
export function judge(rows, target) {
  if (!rows || rows.length === 0) {
    return WRONG;
  }
  if (rows[0].char === target) {
    return CORRECT;
  }
  return rows.slice(0, TOP_K).some((r) => r.char === target) ? CLOSE : WRONG;
}

/**
 * ペンを離してしばらく経ったときの自動判定を受け付けるか。
 *
 * 多画の字は 1 画目を書き終えた時点でも認識に掛かってしまうので、早い方の判定は
 * 「正解なら確定」だけに使い、そうでない結果は捨てる (まだ書いている途中とみなす)。
 *
 * @param {{char: string}[]} rows 確率の高い順の候補
 * @param {string} target 対象字
 */
export function acceptAuto(rows, target) {
  return judge(rows, target) === CORRECT;
}

// MARK: - 判定タイマー

/** ペンを離してから、正解だけを受け付ける認識を掛けるまで (ms) */
export const AUTO_JUDGE_MS = 600;
/** ペンを離してから、誤答も宣言するまで (ms)。画の間隔がこれより短ければ途中で判定しない */
export const DECLARE_JUDGE_MS = 1800;

/** 判定タイマーのやること */
export const JUDGE_NONE = 'none';         // まだ何もしない
export const JUDGE_AUTO = 'auto';         // 認識して、正解なら確定 (それ以外は捨てる)
export const JUDGE_DECLARE = 'declare';   // 認識して、おしい・もういちど も宣言する

/**
 * 最後のペンアップからの経過時間で、判定タイマーが次に何をするかを決める。
 *
 * ペンが降りている間は何もしない (新しいペンダウンでタイマーは解除される)。
 * 早い方 (AUTO_JUDGE_MS) は 1 回だけ掛ける。遅い方 (DECLARE_JUDGE_MS) を過ぎたら宣言する。
 *
 * @param {{penDown?: boolean, autoTried?: boolean}} state 筆記の状態
 * @param {number} elapsed 最後のペンアップからの経過 (ms)
 */
export function nextJudge({ penDown = false, autoTried = false } = {}, elapsed) {
  if (penDown || !Number.isFinite(elapsed) || elapsed < 0) {
    return JUDGE_NONE;
  }
  if (elapsed >= DECLARE_JUDGE_MS) {
    return JUDGE_DECLARE;
  }
  if (elapsed >= AUTO_JUDGE_MS && !autoTried) {
    return JUDGE_AUTO;
  }
  return JUDGE_NONE;
}

/**
 * 次に nextJudge が none 以外を返すまでの待ち時間 (ms)。もう無ければ Infinity。
 * 画面側はこれを setTimeout の遅延に使う。
 *
 * @param {{penDown?: boolean, autoTried?: boolean}} state 筆記の状態
 * @param {number} elapsed 最後のペンアップからの経過 (ms)
 */
export function judgeDelay({ penDown = false, autoTried = false } = {}, elapsed) {
  if (penDown || !Number.isFinite(elapsed) || elapsed < 0) {
    return Infinity;
  }
  if (!autoTried && elapsed < AUTO_JUDGE_MS) {
    return AUTO_JUDGE_MS - elapsed;
  }
  if (elapsed < DECLARE_JUDGE_MS) {
    return DECLARE_JUDGE_MS - elapsed;
  }
  return 0;
}

// MARK: - 制限時間

/**
 * 中央に出すカウントダウンの数字。残り 5 秒から 5, 4, 3, 2, 1 (各 1 秒)、それ以外は null。
 * 残り 4001〜5000 ms が 5、1〜1000 ms が 1。0 は時間切れなので出さない。
 *
 * @param {number} remainingMs 残り時間 (ms)
 */
export function countdownNumber(remainingMs) {
  if (!(remainingMs > 0) || remainingMs > COUNTDOWN_FROM * 1000) {
    return null;
  }
  return Math.ceil(remainingMs / 1000);
}

/** 残り時間のバーの長さ (0〜1)。時間が止まっている (Infinity) ときは満タン */
export function timeRatio(remainingMs) {
  if (remainingMs === Infinity) {
    return 1;
  }
  if (!Number.isFinite(remainingMs)) {
    return 0;
  }
  return Math.min(1, Math.max(0, remainingMs / TIME_LIMIT_MS));
}

/**
 * 0 秒の瞬間の判定。墨があれば認識した結果 (rows) を渡し、墨が無い・薄墨で認識しなかったときは null。
 * top-1 が対象字なら正解 (ぎりぎりセーフ)、それ以外 (おしい を含む) は時間切れ。
 *
 * @param {{char: string}[]|null} rows 確率の高い順の候補
 * @param {string} target 対象字
 */
export function timeUpVerdict(rows, target) {
  return rows && judge(rows, target) === CORRECT ? CORRECT : TIMEOUT;
}

// MARK: - つづきから

const isCount = (v, max = Infinity) => Number.isInteger(v) && v >= 0 && v <= max;

/** 字の配列 (出題データにある字だけ) か。そうでなければ null */
function kanjiList(value, max = Infinity) {
  if (!Array.isArray(value) || value.length > max) {
    return null;
  }
  return value.every((k) => typeof k === 'string' && problemOf(k) !== null) ? value.slice() : null;
}

/**
 * 保存しておいた途中の状態を読み、そのまま使える形にする。壊れていれば null。
 * 出題順 (このステージで出した問題、末尾が今の問題)・あつめた字・正解済み・復習・最近出した字は字で持つ
 * (出題データに無い字が混ざっていたら壊れているとみなす)。
 *
 * @param {object|null} saved Game#snapshot() を保存したもの
 * @param {number} questionCount 1 ステージの問題数
 */
export function parseProgress(saved, questionCount = STAGE_QUESTIONS) {
  if (saved === null || typeof saved !== 'object') {
    return null;
  }
  const order = kanjiList(saved.order, questionCount);
  const collected = kanjiList(saved.collected);
  const solved = kanjiList(saved.solved);
  const review = kanjiList(saved.review);
  const recent = kanjiList(saved.recent, LAP_AVOID);
  if ([order, collected, solved, review, recent].includes(null)) {
    return null;
  }
  const ok = Number.isInteger(saved.stage) && saved.stage >= 1
    && isCount(saved.index, questionCount - 1)
    && order.length === saved.index + 1
    && isCount(saved.lap) && saved.lap >= 1
    && Number.isInteger(saved.lives) && saved.lives >= 1 && saved.lives <= LIVES
    && isCount(saved.passes, PASS_LIMIT)
    && isCount(saved.firstStageSolved, questionCount)
    && isCount(saved.laterSolved)
    && isCount(saved.stageCorrect, questionCount)
    && Number.isFinite(saved.dopa) && saved.dopa >= 0 && saved.dopa <= DOPA_MAX;
  if (!ok) {
    return null;
  }
  const count = (v) => (isCount(v) ? v : 0);
  return {
    stage: saved.stage,
    index: saved.index,
    order: order.map((k) => problemOf(k)),
    solved,
    review,
    recent,
    lap: saved.lap,
    lives: saved.lives,
    passes: saved.passes,
    firstStageSolved: saved.firstStageSolved,
    laterSolved: saved.laterSolved,
    stageCorrect: saved.stageCorrect,
    dopa: saved.dopa,
    collected,
    maxCombo: count(saved.maxCombo),
    correctCount: count(saved.correctCount),
    closeCount: count(saved.closeCount),
    firstTryCount: count(saved.firstTryCount)
  };
}

export class Game {
  /**
   * @param {object} options
   * @param {() => number} options.random [0, 1) の乱数
   * @param {() => number} options.now 現在時刻 (ms)
   * @param {number} options.questionCount 1 ステージの問題数
   * @param {object|null} options.saved つづきから (parseProgress に通したもの)。null なら最初から
   */
  constructor({ random = Math.random, now = () => Date.now(), questionCount = STAGE_QUESTIONS, saved = null } = {}) {
    this.random = random;
    this.now = now;
    this.questionCount = Math.min(questionCount, PROBLEMS.length);
    this.reset();
    if (saved !== null) {
      this.resume(saved);
    }
  }

  reset() {
    this.phase = PHASE_PLAY;
    this.stage = 1;              // 1 始まり
    this.round = [];             // このステージで出した問題 (末尾が今の問題)
    this.index = 0;              // ステージ内の位置 (0 始まり)
    this.solved = new Set();     // このゲームで正解した字 (再出題しない。全部正解したら空にして次の周へ)
    this.review = [];            // ミス・パスで終わってまだ正解していない字 (復習として優先して出す)
    this.recent = [];            // 最近出した字 (古い順、LAP_AVOID 問まで)
    this.lap = 1;                // 何周目か
    this.firstStageSolved = 0;   // ステージ 1 で正解した数
    this.laterSolved = 0;        // ステージ 2 以降で正解した数 (得点・ドパ・強度の k)
    this.stageCorrect = 0;       // 今のステージで正解した数 (0 ならクリアを祝わない)
    this.lives = LIVES;
    this.passes = 0;             // 今のステージで使ったパス
    this.misses = 0;             // 今の問題で外した回数
    this.combo = 0;
    this.maxCombo = 0;
    this.dopa = 0;               // 常用対数 L
    this.correctCount = 0;
    this.closeCount = 0;
    this.firstTryCount = 0;
    this.collected = [];         // 正解した字 (ステージをまたいで並ぶ)
    this.startedAt = this.now();
    this.present(this.pick());
    this.startTimer();
  }

  /** つづきから: 保存した位置・得点・ドパ・あつめた字・ライフに戻す (コンボは 0) */
  resume(saved) {
    this.stage = saved.stage;
    this.round = saved.order.slice();
    this.index = saved.index;
    this.solved = new Set(saved.solved);
    this.review = saved.review.slice();
    this.recent = saved.recent.slice();
    this.lap = saved.lap;
    this.lives = saved.lives;
    this.passes = saved.passes;
    this.firstStageSolved = saved.firstStageSolved;
    this.laterSolved = saved.laterSolved;
    this.stageCorrect = saved.stageCorrect;
    this.dopa = saved.dopa;
    this.collected = saved.collected.slice();
    this.maxCombo = saved.maxCombo;
    this.correctCount = saved.correctCount;
    this.closeCount = saved.closeCount;
    this.firstTryCount = saved.firstTryCount;
    this.startTimer();
  }

  /**
   * 保存する状態。ゲームオーバーではリトライと同じ位置 (失敗した問題、ライフ満タン) を残す。
   * 出題順・あつめた字・正解済み・復習・最近出した字は字だけを持つ。
   */
  snapshot() {
    return {
      stage: this.stage,
      index: this.index,
      order: this.round.map((p) => p.kanji),
      solved: [...this.solved],
      review: this.review.slice(),
      recent: this.recent.slice(),
      lap: this.lap,
      lives: this.phase === PHASE_OVER ? LIVES : this.lives,
      passes: this.passes,
      firstStageSolved: this.firstStageSolved,
      laterSolved: this.laterSolved,
      stageCorrect: this.stageCorrect,
      dopa: this.dopa,
      score: this.score(),
      collected: this.collected.slice(),
      maxCombo: this.maxCombo,
      correctCount: this.correctCount,
      closeCount: this.closeCount,
      firstTryCount: this.firstTryCount
    };
  }

  /** 今の問題。ゲームオーバーでは失敗した問題、時間切れの表示中はその問題 */
  current() {
    return this.round[this.index] ?? null;
  }

  /** 書いて判定を受け付けるか */
  playing() {
    return this.phase === PHASE_PLAY;
  }

  /** 今の得点 */
  score() {
    return score(this.firstStageSolved, this.laterSolved);
  }

  /** 今の演出強度 E */
  intensity() {
    if (this.stage > 1) {
      return extraIntensity(this.laterSolved);
    }
    return baseIntensity(Math.min(this.index, this.questionCount - 1), this.questionCount);
  }

  /** このステージで残っているパスの回数 */
  passesLeft() {
    return PASS_LIMIT - this.passes;
  }

  /** なぞり用の薄い見本を出すか */
  showsHint() {
    return this.misses >= HINT_AFTER_MISSES;
  }

  /** 今の問題の残り時間 (ms)。数え始めるまでは満タン、止まっているときは Infinity */
  remainingMs() {
    if (this.deadline === Infinity) {
      return Infinity;
    }
    return Math.max(0, Math.min(TIME_LIMIT_MS, this.deadline - this.now()));
  }

  /** 今の問題の制限時間を引き直す (次の問題が書けるようになった時点から数える) */
  startTimer() {
    this.deadline = this.now() + TIME_GRACE_MS + TIME_LIMIT_MS;
  }

  /**
   * 時間の経過を見る。画面側から毎フレーム呼ぶ。
   * timeUp が true なら、画面側は筆記領域の墨を認識して timeUp(rows) を呼ぶ。
   * @returns {{timeUp: boolean}}
   */
  tick() {
    return { timeUp: this.phase === PHASE_PLAY && this.now() >= this.deadline };
  }

  /**
   * 認識結果を 1 回ぶん反映する (誤答の宣言か、正解の確定)。
   *
   * @param {{char: string}[]} rows 確率の高い順の候補
   * @returns {object} 判定と、そこで起きたこと
   */
  answer(rows) {
    if (this.phase !== PHASE_PLAY) {
      return { verdict: WRONG, ignored: true };
    }
    // 判定は画面の毎フレームの tick() より先に来ることがある。0 秒を過ぎて届いた判定は 0 秒の判定として扱う
    if (this.now() >= this.deadline) {
      return this.timeUp(rows);
    }
    const problem = this.current();
    const verdict = judge(rows, problem.kanji);
    if (verdict === CORRECT) {
      return this.solve(problem, false);
    }
    this.misses += 1;
    if (verdict === CLOSE) {
      this.closeCount += 1;
    }
    return {
      verdict,
      problem,
      misses: this.misses,
      showsHint: this.showsHint(),
      ...this.loseLife()
    };
  }

  /**
   * 0 秒の判定。墨があれば認識結果 (rows)、無ければ null を渡す。
   * 正解ならぎりぎりセーフ (safe: true)、それ以外は時間切れでミス 1。
   * 時間切れでライフが残っていれば、正解の字を見せる局面 (PHASE_REVEAL) に入る。画面側は
   * REVEAL_MS のあと finishReveal() で次の問題へ進める。
   *
   * @param {{char: string}[]|null} rows 確率の高い順の候補
   */
  timeUp(rows) {
    if (this.phase !== PHASE_PLAY) {
      return { verdict: TIMEOUT, ignored: true };
    }
    const problem = this.current();
    if (timeUpVerdict(rows, problem.kanji) === CORRECT) {
      return this.solve(problem, true);
    }
    this.deadline = Infinity;
    this.remember(problem);
    const lost = this.loseLife();
    if (!lost.gameOver) {
      this.phase = PHASE_REVEAL;
    }
    return { verdict: TIMEOUT, problem, ...lost };
  }

  /** 時間切れの字を見せ終えた。次の問題へ (ステージの最終問ならステージクリア) */
  finishReveal() {
    if (this.phase !== PHASE_REVEAL) {
      return null;
    }
    this.phase = PHASE_PLAY;
    return this.advance();
  }

  /** ミス 1: コンボを切り、ライフを 1 減らす。0 になればゲームオーバー (時間は止まる) */
  loseLife() {
    const brokenCombo = this.combo;
    this.combo = 0;
    this.lives = Math.max(0, this.lives - 1);
    const gameOver = this.lives === 0;
    if (gameOver) {
      this.phase = PHASE_OVER;
      this.deadline = Infinity;
    }
    return {
      lives: this.lives,
      gameOver,
      brokenCombo: brokenCombo >= COMBO_REPORT_MIN ? brokenCombo : 0
    };
  }

  /** 正解。先にコンボを 1 増やしてから、その倍率でドパを足す (SPEC §5.2) */
  solve(problem, safe) {
    this.combo += 1;
    this.maxCombo = Math.max(this.maxCombo, this.combo);
    this.correctCount += 1;
    this.stageCorrect += 1;
    if (this.misses === 0) {
      this.firstTryCount += 1;
    }
    const later = this.stage > 1;
    const increment = later
      ? extraIncrement(this.laterSolved)
      : baseIncrement(this.index, this.questionCount);
    const before = this.dopa;
    this.dopa = advanceDopa(before, increment, this.combo);

    const result = {
      verdict: CORRECT,
      safe,
      problem,
      combo: this.combo,
      comboCelebration: isComboCelebration(this.combo),
      multiplier: comboMultiplier(this.combo),
      dopaBefore: before,
      dopaAfter: this.dopa,
      milestones: crossedMilestones(before, this.dopa),
      intensity: this.intensity(),
      gained: later ? extraQuestionScore(this.laterSolved) : 10
    };
    if (later) {
      this.laterSolved += 1;
    } else {
      this.firstStageSolved += 1;
    }
    this.collected.push(problem.kanji);
    this.solved.add(problem.kanji);
    this.review = this.review.filter((k) => k !== problem.kanji);
    Object.assign(result, this.advance());
    result.score = this.score();
    return result;
  }

  /**
   * 次の問題へ。ステージの最終問を終えたら次のステージへ進む (パスの回数はステージごと)。
   * 次の 1 問は pickProblem で選ぶ (正解した字は出さない、復習の字は 3 問挟んでから)。
   * @returns {{stageCleared: number, clearedCorrect: number}} クリアしたステージ (0 = まだ途中) とその正解数
   */
  advance() {
    this.misses = 0;
    this.index += 1;
    let stageCleared = 0;
    let clearedCorrect = 0;
    if (this.index >= this.questionCount) {
      stageCleared = this.stage;
      clearedCorrect = this.stageCorrect;
      this.stage += 1;
      this.round = [];
      this.index = 0;
      this.passes = 0;
      this.stageCorrect = 0;
    }
    this.present(this.pick());
    this.startTimer();
    return { stageCleared, clearedCorrect };
  }

  /** 次の 1 問を選ぶ。全部の字を正解していたら、正解済みを空にして次の周へ */
  pick() {
    if (PROBLEMS.every((p) => this.solved.has(p.kanji))) {
      this.solved.clear();
      this.lap += 1;
    }
    return pickProblem({ solved: this.solved, review: this.review, recent: this.recent }, this.random);
  }

  /** 問題を出す (このステージの出題順と、最近出した字に積む) */
  present(problem) {
    this.round.push(problem);
    this.recent.push(problem.kanji);
    if (this.recent.length > LAP_AVOID) {
      this.recent.shift();
    }
  }

  /** 正解できずに終わった字 (パス・時間切れ) を復習に回す */
  remember(problem) {
    if (!this.solved.has(problem.kanji) && !this.review.includes(problem.kanji)) {
      this.review.push(problem.kanji);
    }
  }

  /** パス。ライフは減らさず、得点もドパも増やさず、コンボを 0 にして次の問題へ。1 ステージ 3 回まで */
  pass() {
    if (this.phase !== PHASE_PLAY || this.passes >= PASS_LIMIT) {
      return { passed: false };
    }
    this.passes += 1;
    this.remember(this.current());
    const brokenCombo = this.combo;
    this.combo = 0;
    return {
      passed: true,
      brokenCombo: brokenCombo >= COMBO_REPORT_MIN ? brokenCombo : 0,
      ...this.advance()
    };
  }

  /**
   * リトライ: ライフを満タンに戻して、失敗した問題から続ける。
   * 得点・ドパ・あつめた字・パスの回数はそのまま、コンボは 0、制限時間は引き直す。
   */
  retry() {
    if (this.phase !== PHASE_OVER) {
      return false;
    }
    this.phase = PHASE_PLAY;
    this.lives = LIVES;
    this.combo = 0;
    this.misses = 0;
    this.startTimer();
    return true;
  }

  /** 終了画面に出す値 */
  summary() {
    return {
      score: this.score(),
      dopa: this.dopa,
      maxCombo: this.maxCombo,
      correctCount: this.correctCount,
      closeCount: this.closeCount,
      firstTryCount: this.firstTryCount,
      stage: this.stage,
      collected: this.collected.slice(),
      elapsedMs: this.now() - this.startedAt
    };
  }
}
