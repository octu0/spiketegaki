// ラウンドの進行・判定・タイマー。DOM も canvas も触らないので node でそのまま試せる。

import { makeRound, pickExtra, PROBLEMS } from './problems.js';
import {
  BASE_QUESTIONS,
  COMBO_LIMIT_MS,
  COMBO_REPORT_MIN,
  advanceDopa,
  baseIncrement,
  baseIntensity,
  comboMultiplier,
  crossedMilestones,
  extraIncrement,
  extraIntensity,
  extraQuestionScore,
  extraTier,
  isComboCelebration,
  score
} from './scoring.js';

/** 判定の結果 */
export const CORRECT = 'correct';   // top-1 が対象字
export const CLOSE = 'close';       // top-3 に対象字 (おしい)
export const WRONG = 'wrong';       // それ以外 (もういちど)

/** 同じ問題でこの回数だけ外したら、なぞり用の薄い見本を出す */
export const HINT_AFTER_MISSES = 2;
/** エクストラの制限時間 (ms) */
export const EXTRA_MS = 90000;
/** 認識器から取る候補数。「おしい」の判定に top-3 まで見る */
export const TOP_K = 3;

/** 局面 */
const PHASE_BASE = 'base';
export const PHASE_EXTRA = 'extra';
export const PHASE_DONE = 'done';

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

export class Game {
  /**
   * @param {object} options
   * @param {() => number} options.random [0, 1) の乱数
   * @param {() => number} options.now 現在時刻 (ms)
   * @param {number} options.questionCount 基本ラウンドの問題数
   */
  constructor({ random = Math.random, now = () => Date.now(), questionCount = BASE_QUESTIONS } = {}) {
    this.random = random;
    this.now = now;
    this.questionCount = Math.min(questionCount, PROBLEMS.length);
    this.reset();
  }

  reset() {
    this.phase = PHASE_BASE;
    this.round = makeRound(this.questionCount, this.random);
    this.index = 0;              // 基本の現在位置 (0 始まり)
    this.baseSolved = 0;
    this.extraSolved = 0;
    this.extraProblem = null;
    this.recent = [];            // エクストラで直前に出した問題
    this.misses = 0;             // 今の問題で外した回数
    this.combo = 0;
    this.maxCombo = 0;
    this.dopa = 0;               // 常用対数 L
    this.correctCount = 0;
    this.closeCount = 0;
    this.firstTryCount = 0;
    this.comboDeadline = Infinity;
    this.extraDeadline = Infinity;
    this.startedAt = this.now();
    this.startTimer();
  }

  /** 今の問題 (基本 / エクストラ)。終わっていれば null */
  current() {
    if (this.phase === PHASE_BASE) {
      return this.round[this.index] ?? null;
    }
    if (this.phase === PHASE_EXTRA) {
      return this.extraProblem;
    }
    return null;
  }

  /** 今の得点 */
  score() {
    return score(this.baseSolved, this.extraSolved);
  }

  /** 今の演出強度 E */
  intensity() {
    if (this.phase === PHASE_EXTRA) {
      return extraIntensity(this.extraSolved);
    }
    return baseIntensity(Math.min(this.index, this.questionCount - 1), this.questionCount);
  }

  /** エクストラの段 (基本では 0) */
  tier() {
    return this.phase === PHASE_EXTRA ? extraTier(this.extraSolved) : 0;
  }

  /** なぞり用の薄い見本を出すか */
  showsHint() {
    return this.misses >= HINT_AFTER_MISSES;
  }

  /** コンボの残り時間 (ms)。1 コンボ以下は時間切れの対象外なので Infinity */
  comboRemainingMs() {
    if (this.combo <= 1) {
      return Infinity;
    }
    return Math.max(0, this.comboDeadline - this.now());
  }

  /** エクストラの残り時間 (ms)。基本では Infinity */
  extraRemainingMs() {
    return this.extraDeadline === Infinity ? Infinity : Math.max(0, this.extraDeadline - this.now());
  }

  /**
   * 時間の経過を反映する。画面側から毎フレーム呼ぶ。
   * @returns {{comboExpired: boolean, brokenCombo: number, extraExpired: boolean}}
   */
  tick() {
    let comboExpired = false;
    let brokenCombo = 0;
    if (this.combo > 1 && this.now() >= this.comboDeadline) {
      brokenCombo = this.combo;
      this.combo = 0;
      this.comboDeadline = Infinity;
      comboExpired = true;
    }
    let extraExpired = false;
    if (this.phase === PHASE_EXTRA && this.now() >= this.extraDeadline) {
      this.phase = PHASE_DONE;
      extraExpired = true;
    }
    return { comboExpired, brokenCombo, extraExpired };
  }

  /**
   * 認識結果を 1 回ぶん反映する。
   *
   * @param {{char: string}[]} rows 確率の高い順の候補
   * @returns {object} 判定と、そこで起きたこと
   */
  answer(rows) {
    // 判定は画面の毎フレームの tick() より先に来ることがあるので、まず期限を反映する。
    // 期限切れのコンボは 0 に戻してから数え、エクストラが終わっていれば受け付けない。
    const expired = this.tick();
    const problem = this.current();
    if (problem === null) {
      return { verdict: WRONG, ignored: true, extraExpired: expired.extraExpired };
    }
    const verdict = judge(rows, problem.kanji);
    if (verdict !== CORRECT) {
      const brokenCombo = this.combo;
      this.misses += 1;
      this.combo = 0;
      this.comboDeadline = Infinity;
      if (verdict === CLOSE) {
        this.closeCount += 1;
      }
      return {
        verdict,
        problem,
        misses: this.misses,
        showsHint: this.showsHint(),
        brokenCombo: brokenCombo >= COMBO_REPORT_MIN ? brokenCombo : 0
      };
    }

    // 正解。先にコンボを 1 増やしてから、その倍率でドパを足す (SPEC §5.2)
    this.combo += 1;
    this.maxCombo = Math.max(this.maxCombo, this.combo);
    this.correctCount += 1;
    if (this.misses === 0) {
      this.firstTryCount += 1;
    }
    const increment = this.phase === PHASE_EXTRA
      ? extraIncrement(this.extraSolved)
      : baseIncrement(this.index, this.questionCount);
    const before = this.dopa;
    this.dopa = advanceDopa(before, increment, this.combo);

    const result = {
      verdict: CORRECT,
      problem,
      combo: this.combo,
      comboCelebration: isComboCelebration(this.combo),
      multiplier: comboMultiplier(this.combo),
      dopaBefore: before,
      dopaAfter: this.dopa,
      milestones: crossedMilestones(before, this.dopa),
      intensity: this.intensity(),
      gained: 0,
      baseFinished: false
    };

    if (this.phase === PHASE_EXTRA) {
      result.gained = extraQuestionScore(this.extraSolved);
      this.extraSolved += 1;
      this.nextExtra();
    } else {
      result.gained = 10;
      this.baseSolved += 1;
      this.index += 1;
      if (this.index >= this.round.length) {
        result.baseFinished = true;
        this.phase = PHASE_DONE;
        this.comboDeadline = Infinity;
      } else {
        this.misses = 0;
        this.startTimer();
      }
    }
    result.score = this.score();
    return result;
  }

  /** パス。得点もドパも増やさず、コンボを 0 にして次の問題へ */
  pass() {
    if (this.phase === PHASE_DONE) {
      return { passed: false };
    }
    const brokenCombo = this.combo;
    this.combo = 0;
    this.comboDeadline = Infinity;
    this.misses = 0;
    if (this.phase === PHASE_EXTRA) {
      this.nextExtra();
      return { passed: true, brokenCombo: brokenCombo >= COMBO_REPORT_MIN ? brokenCombo : 0 };
    }
    this.index += 1;
    if (this.index >= this.round.length) {
      this.phase = PHASE_DONE;
      return { passed: true, baseFinished: true, brokenCombo: brokenCombo >= COMBO_REPORT_MIN ? brokenCombo : 0 };
    }
    this.startTimer();
    return { passed: true, brokenCombo: brokenCombo >= COMBO_REPORT_MIN ? brokenCombo : 0 };
  }

  /** 基本の完走後にエクストラへ進む。コンボは 0 に戻し、ドパは引き継ぐ (SPEC §5.2) */
  startExtra() {
    this.phase = PHASE_EXTRA;
    this.combo = 0;
    this.misses = 0;
    this.extraDeadline = this.now() + EXTRA_MS;
    this.nextExtra();
  }

  /** エクストラの次の 1 問を選ぶ */
  nextExtra() {
    this.extraProblem = pickExtra(this.recent, this.random);
    this.recent.push(this.extraProblem);
    if (this.recent.length > 20) {
      this.recent.shift();
    }
    this.misses = 0;
    this.startTimer();
  }

  /** 今の問題のコンボ制限時間を引き直す (入力を受け付ける時点で期限を決める) */
  startTimer() {
    this.comboDeadline = this.now() + COMBO_LIMIT_MS;
  }

  /** 結果画面に出す値 */
  summary() {
    return {
      score: this.score(),
      dopa: this.dopa,
      maxCombo: this.maxCombo,
      correctCount: this.correctCount,
      closeCount: this.closeCount,
      firstTryCount: this.firstTryCount,
      extraSolved: this.extraSolved,
      elapsedMs: this.now() - this.startedAt
    };
  }
}
