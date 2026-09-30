// ステージ進行・判定・制限時間・ライフ・つづきから (DOM 無し)。
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  CLOSE,
  CORRECT,
  COUNTDOWN_FROM,
  Game,
  HINT_AFTER_MISSES,
  LIVES,
  PASS_LIMIT,
  PHASE_OVER,
  PHASE_PLAY,
  PHASE_REVEAL,
  TIMEOUT,
  TIME_GRACE_MS,
  TIME_LIMIT_MS,
  TIME_LOW,
  WRONG,
  AUTO_JUDGE_MS,
  DECLARE_JUDGE_MS,
  JUDGE_AUTO,
  JUDGE_DECLARE,
  JUDGE_NONE,
  acceptAuto,
  countdownNumber,
  judge,
  judgeDelay,
  nextJudge,
  parseProgress,
  timeRatio,
  timeUpVerdict
} from '../js/game.js';
import { extraIncrement, extraIntensity, advanceDopa } from '../js/scoring.js';
import { PROBLEMS } from '../js/problems.js';

/** 先頭から順に引く乱数 (ステージの出題を固定する) */
const firstPick = () => 0;

/** 手で進められる時計 */
function clock(start = 0) {
  const state = { t: start };
  return {
    now: () => state.t,
    advance: (ms) => { state.t += ms; }
  };
}

function rows(...chars) {
  return chars.map((char, i) => ({ char, probability: 1 - i * 0.1 }));
}

/** 対象字ではない字を n 個 */
function others(target, n) {
  return PROBLEMS.map((p) => p.kanji).filter((k) => k !== target).slice(0, n);
}

/** 今の問題に誤答 (もういちど) を宣言する */
function miss(game) {
  return game.answer(rows(...others(game.current().kanji, 3)));
}

/** 今の問題に正解する */
function hit(game) {
  return game.answer(rows(game.current().kanji));
}

/** ステージ 1 を全問正解で終える */
function clearStage(game) {
  let last = null;
  for (let i = 0; i < game.questionCount; i += 1) {
    last = hit(game);
  }
  return last;
}

/** 数え始め (次の問題がすべり込む間) を過ぎて、制限時間が減り始めるところまで進める */
const FULL_MS = TIME_GRACE_MS + TIME_LIMIT_MS;

// MARK: - 判定

test('判定: top-1 が対象字なら正解', () => {
  assert.equal(judge(rows('山', '出', '川'), '山'), CORRECT);
});

test('判定: top-1 でなく top-3 に入れば おしい', () => {
  assert.equal(judge(rows('出', '山', '川'), '山'), CLOSE);
  assert.equal(judge(rows('出', '川', '山'), '山'), CLOSE);
});

test('判定: top-3 の外なら もういちど', () => {
  assert.equal(judge(rows('出', '川', '土', '山'), '山'), WRONG);
  assert.equal(judge([], '山'), WRONG);
  assert.equal(judge(null, '山'), WRONG);
});

test('自動判定: 受け付けるのは top-1 が対象字のときだけ', () => {
  assert.equal(acceptAuto(rows('山', '出', '川'), '山'), true);
  assert.equal(acceptAuto(rows('出', '山', '川'), '山'), false, 'おしい は受け付けない');
  assert.equal(acceptAuto(rows('出', '川', '土'), '山'), false, 'もういちど も受け付けない');
  assert.equal(acceptAuto([], '山'), false);
  assert.equal(acceptAuto(null, '山'), false);
});

test('自動判定は正解以外を game に渡さない (書き途中でも進まない・ライフも減らない)', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  const target = game.current().kanji;
  const [a, b] = others(target, 2);

  // 1 画目だけ書いた状態のつもりの認識結果。画面側は acceptAuto で捨てる
  for (const candidates of [rows(a, b), rows(a, target, b)]) {
    if (acceptAuto(candidates, target)) {
      game.answer(candidates);
    }
  }
  assert.equal(game.current().kanji, target, '同じ問題のまま');
  assert.equal(game.misses, 0, '外した回数は増えない (見本は出ない)');
  assert.equal(game.lives, LIVES, 'ライフは減らない');
  assert.equal(game.closeCount, 0);
  assert.equal(game.score(), 0);

  // 書き上がって top-1 になったら、そこで確定する
  assert.equal(acceptAuto(rows(target, a, b), target), true);
  assert.equal(game.answer(rows(target, a, b)).verdict, CORRECT);
  assert.equal(game.score(), 10);
});

// MARK: - 正解・誤答・ライフ

test('正解で得点・コンボ・ドパが増え、あつめた字に並ぶ', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  const target = game.current().kanji;
  const out = hit(game);
  assert.equal(out.verdict, CORRECT);
  assert.equal(out.safe, false);
  assert.equal(out.gained, 10);
  assert.equal(out.combo, 1);
  assert.equal(game.score(), 10);
  assert.ok(game.dopa > 0);
  assert.equal(game.correctCount, 1);
  assert.deepEqual(game.collected, [target]);
  assert.equal(game.index, 1);
});

test('誤答の宣言はミス 1: ライフが 1 減り、コンボは 0、同じ問題を続け、残り時間はそのまま', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  hit(game);
  hit(game);
  const third = game.current();
  c.advance(TIME_GRACE_MS + 4000);
  const remaining = game.remainingMs();
  const scoreBefore = game.score();
  const dopaBefore = game.dopa;
  const out = miss(game);
  assert.equal(out.verdict, WRONG);
  assert.equal(out.lives, LIVES - 1);
  assert.equal(out.gameOver, false);
  assert.equal(game.lives, LIVES - 1);
  assert.equal(game.combo, 0);
  assert.equal(game.score(), scoreBefore, '減点しない');
  assert.equal(game.dopa, dopaBefore, 'ドパも減らない');
  assert.equal(game.current(), third, '同じ問題のまま');
  assert.equal(game.remainingMs(), remaining, '残り時間はリセットしない');
  assert.equal(game.phase, PHASE_PLAY);
});

test('おしい もミス 1 (closeCount に入り、ライフが減る)', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  const target = game.current().kanji;
  const [a, b] = others(target, 2);
  const out = game.answer(rows(a, target, b));
  assert.equal(out.verdict, CLOSE);
  assert.equal(out.lives, LIVES - 1);
  assert.equal(game.closeCount, 1);
  assert.equal(game.combo, 0);
  assert.equal(game.score(), 0);
});

test(`同じ問題で ${HINT_AFTER_MISSES} 回外したら見本を出す`, () => {
  const game = new Game({ random: firstPick, now: clock().now });
  assert.equal(game.showsHint(), false);
  assert.equal(miss(game).showsHint, false, '1 回目では出さない');
  assert.equal(miss(game).showsHint, true, '2 回目で出す');
  assert.equal(game.showsHint(), true);
  // 見本ありで正解しても得点・ドパは通常どおり
  const out = hit(game);
  assert.equal(out.gained, 10);
  assert.ok(out.dopaAfter > out.dopaBefore);
  assert.equal(game.showsHint(), false, '次の問題では消える');
});

test('ライフ 3: 3 回ミスでゲームオーバー。以後の判定・パスは受け付けない', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  hit(game);
  const failed = game.current();
  assert.equal(miss(game).lives, 2);
  assert.equal(miss(game).lives, 1);
  const last = miss(game);
  assert.equal(last.lives, 0);
  assert.equal(last.gameOver, true);
  assert.equal(game.phase, PHASE_OVER);
  assert.equal(game.current(), failed, '失敗した問題を指したまま');
  assert.equal(game.remainingMs(), Infinity, '時間は止まる');
  assert.equal(hit(game).ignored, true, 'ゲームオーバー後の正解は数えない');
  assert.equal(game.score(), 10);
  assert.equal(game.pass().passed, false);
  assert.equal(game.tick().timeUp, false);
});

test('ミスで切れたコンボは 5 以上なら終了数を返す', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  for (let i = 0; i < 5; i += 1) {
    hit(game);
  }
  assert.equal(miss(game).brokenCombo, 5);
  assert.equal(miss(game).brokenCombo, 0);
});

// MARK: - パス

test('パスはライフを減らさず、得点もドパも増やさず、コンボを 0 にして次へ', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  hit(game);
  const dopaBefore = game.dopa;
  const scoreBefore = game.score();
  const second = game.current();
  const out = game.pass();
  assert.equal(out.passed, true);
  assert.equal(game.lives, LIVES);
  assert.equal(game.combo, 0);
  assert.equal(game.dopa, dopaBefore);
  assert.equal(game.score(), scoreBefore);
  assert.notEqual(game.current(), second, '次の問題へ進む');
  assert.equal(game.collected.length, 1, 'パスした字は並ばない');
});

test(`パスは 1 ステージ ${PASS_LIMIT} 回まで。次のステージで回数が戻る`, () => {
  const game = new Game({ random: firstPick, now: clock().now });
  for (let i = 0; i < PASS_LIMIT; i += 1) {
    assert.equal(game.passesLeft(), PASS_LIMIT - i);
    assert.equal(game.pass().passed, true);
  }
  assert.equal(game.passesLeft(), 0);
  const stuck = game.current();
  assert.deepEqual(game.pass(), { passed: false });
  assert.equal(game.current(), stuck, '上限を越えたパスでは進まない');
  // 残り 7 問を正解してステージ 2 へ
  for (let i = 0; i < game.questionCount - PASS_LIMIT; i += 1) {
    hit(game);
  }
  assert.equal(game.stage, 2);
  assert.equal(game.passesLeft(), PASS_LIMIT);
  assert.equal(game.pass().passed, true);
});

// MARK: - 制限時間

test('制限時間: 1 問 15 秒。すべり込む 200 ms は数えず、その後から減る', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  assert.equal(TIME_LIMIT_MS, 15000);
  assert.equal(game.remainingMs(), TIME_LIMIT_MS);
  c.advance(TIME_GRACE_MS);
  assert.equal(game.remainingMs(), TIME_LIMIT_MS, '数え始めるまでは満タン');
  c.advance(1000);
  assert.equal(game.remainingMs(), TIME_LIMIT_MS - 1000);
  c.advance(TIME_LIMIT_MS - 1001);
  assert.equal(game.remainingMs(), 1);
  assert.equal(game.tick().timeUp, false, '0 秒になるまでは時間切れにしない');
  c.advance(1);
  assert.equal(game.remainingMs(), 0);
  assert.equal(game.tick().timeUp, true);
});

test('制限時間: 正解・パスのあとの問題は 15 秒から数え直す', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  c.advance(FULL_MS - 100);
  hit(game);
  assert.equal(game.remainingMs(), TIME_LIMIT_MS);
  c.advance(FULL_MS - 100);
  game.pass();
  assert.equal(game.remainingMs(), TIME_LIMIT_MS);
  c.advance(FULL_MS - 1);
  assert.equal(game.tick().timeUp, false);
});

test('countdownNumber: 残り 5 秒から 5, 4, 3, 2, 1 (各 1 秒)、それ以外は出さない', () => {
  assert.equal(COUNTDOWN_FROM, 5);
  assert.equal(countdownNumber(TIME_LIMIT_MS), null);
  assert.equal(countdownNumber(5001), null);
  assert.equal(countdownNumber(5000), 5);
  assert.equal(countdownNumber(4001), 5);
  assert.equal(countdownNumber(4000), 4);
  assert.equal(countdownNumber(3500), 4);
  assert.equal(countdownNumber(2001), 3);
  assert.equal(countdownNumber(1500), 2);
  assert.equal(countdownNumber(1000), 1);
  assert.equal(countdownNumber(1), 1);
  assert.equal(countdownNumber(0), null, '0 は時間切れ');
  assert.equal(countdownNumber(-5), null);
  assert.equal(countdownNumber(Infinity), null, '止まっている時間は数えない');
  assert.equal(countdownNumber(Number.NaN), null);
  // 1 ms 刻みで見ると 5 → 1 を 1 回ずつ通る
  const seen = [];
  for (let ms = TIME_LIMIT_MS; ms >= 0; ms -= 1) {
    const n = countdownNumber(ms);
    if (n !== null && n !== seen[seen.length - 1]) {
      seen.push(n);
    }
  }
  assert.deepEqual(seen, [5, 4, 3, 2, 1]);
});

test('timeRatio: 残り時間のバーの長さ。30% 未満で赤く脈動させる', () => {
  assert.equal(timeRatio(TIME_LIMIT_MS), 1);
  assert.equal(timeRatio(TIME_LIMIT_MS / 2), 0.5);
  assert.equal(timeRatio(0), 0);
  assert.equal(timeRatio(-10), 0);
  assert.equal(timeRatio(TIME_LIMIT_MS * 2), 1);
  assert.equal(timeRatio(Infinity), 1, '止まっているときは満タン');
  assert.equal(timeRatio(Number.NaN), 0);
  assert.equal(TIME_LOW, 0.3);
  assert.ok(timeRatio(4499) < TIME_LOW);
  assert.ok(!(timeRatio(4500) < TIME_LOW));
});

// MARK: - 0 秒の判定

test('timeUpVerdict: 墨あり正解はセーフ、墨あり不正解 (おしい を含む) と墨なしは時間切れ', () => {
  assert.equal(timeUpVerdict(rows('山', '出', '川'), '山'), CORRECT, '墨あり正解');
  assert.equal(timeUpVerdict(rows('出', '山', '川'), '山'), TIMEOUT, '墨あり おしい');
  assert.equal(timeUpVerdict(rows('出', '川', '土'), '山'), TIMEOUT, '墨あり もういちど');
  assert.equal(timeUpVerdict(null, '山'), TIMEOUT, '墨なし (薄墨で認識しなかったときも)');
  assert.equal(timeUpVerdict([], '山'), TIMEOUT);
});

test('0 秒: 墨あり正解はぎりぎりセーフ (正解として数え、次の問題へ)', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  const target = game.current().kanji;
  c.advance(FULL_MS);
  assert.equal(game.tick().timeUp, true);
  const out = game.timeUp(rows(target));
  assert.equal(out.verdict, CORRECT);
  assert.equal(out.safe, true);
  assert.equal(out.gained, 10);
  assert.equal(game.lives, LIVES);
  assert.equal(game.index, 1);
  assert.equal(game.remainingMs(), TIME_LIMIT_MS, '次の問題は 15 秒から');
});

test('0 秒: 墨あり不正解は時間切れ = ミス 1。正解の字を見せる間は時間が止まり、そのあと次の問題へ', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  hit(game);
  const second = game.current();
  c.advance(FULL_MS);
  const out = game.timeUp(rows(...others(second.kanji, 3)));
  assert.equal(out.verdict, TIMEOUT);
  assert.equal(out.problem, second, '見せる字');
  assert.equal(out.lives, LIVES - 1);
  assert.equal(out.gameOver, false);
  assert.equal(game.combo, 0, 'コンボも切れる');
  assert.equal(game.phase, PHASE_REVEAL);
  assert.equal(game.current(), second);
  assert.equal(game.remainingMs(), Infinity);
  assert.equal(game.tick().timeUp, false, '見せている間に 2 度目の時間切れは起きない');
  assert.equal(hit(game).ignored, true, '見せている間の判定は受け付けない');
  assert.equal(game.pass().passed, false);
  c.advance(800);
  const next = game.finishReveal();
  assert.deepEqual(next, { stageCleared: 0, clearedCorrect: 0 });
  assert.equal(game.phase, PHASE_PLAY);
  assert.notEqual(game.current(), second);
  assert.equal(game.index, 2);
  assert.equal(game.remainingMs(), TIME_LIMIT_MS);
  assert.equal(game.finishReveal(), null, '2 度呼んでも進まない');
});

test('0 秒: 墨なしも時間切れ = ミス 1', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  c.advance(FULL_MS);
  const out = game.timeUp(null);
  assert.equal(out.verdict, TIMEOUT);
  assert.equal(game.lives, LIVES - 1);
  assert.equal(game.phase, PHASE_REVEAL);
  assert.equal(game.collected.length, 0);
});

test('0 秒を過ぎて届いた判定は 0 秒の判定として扱う (正解ならセーフ、誤答は時間切れ 1 回だけ)', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  c.advance(FULL_MS + 30);
  const safe = hit(game);
  assert.equal(safe.verdict, CORRECT);
  assert.equal(safe.safe, true);

  c.advance(FULL_MS);
  const out = miss(game);
  assert.equal(out.verdict, TIMEOUT, '誤答の宣言ではなく時間切れ');
  assert.equal(game.lives, LIVES - 1, 'ミスは 1 回ぶん');
  assert.equal(game.misses, 0, '見本の回数には数えない');
  assert.equal(game.phase, PHASE_REVEAL);
});

test('時間切れで 3 回目のミス: ゲームオーバー。失敗した問題 (時間切れの問題) を指したまま', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  miss(game);
  miss(game);
  const failed = game.current();
  c.advance(FULL_MS);
  const out = game.timeUp(null);
  assert.equal(out.verdict, TIMEOUT);
  assert.equal(out.gameOver, true);
  assert.equal(game.phase, PHASE_OVER);
  assert.equal(game.current(), failed);
  assert.equal(game.finishReveal(), null, 'ゲームオーバーでは次へ進まない');
});

// MARK: - ステージ

test('ステージ: 10 問を終えると次のステージへ。ステージ 1 は完走で 100 点', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  const last = clearStage(game);
  assert.equal(last.stageCleared, 1);
  assert.equal(last.clearedCorrect, 10);
  assert.equal(last.score, 100);
  assert.equal(game.stage, 2);
  assert.equal(game.index, 0);
  assert.equal(game.phase, PHASE_PLAY);
  assert.equal(game.maxCombo, 10);
  assert.equal(game.combo, 10, 'ステージをまたいでもコンボは続く');
  assert.ok(game.current() !== null);
  assert.deepEqual(game.round, [game.current()], '新しいステージの出題順は 1 問目から積む');
  assert.ok(!game.solved.has(game.current().kanji), '正解した字は出さない');
});

// MARK: - 出題の重複回避

test('正解した字は同じゲームで再出題しない (80 字を正解するまで重ならない)', () => {
  const game = new Game({ random: Math.random, now: clock().now });
  const seen = [];
  for (let i = 0; i < PROBLEMS.length; i += 1) {
    const k = game.current().kanji;
    assert.ok(!seen.includes(k), `${i + 1} 問目の ${k} は正解済み`);
    seen.push(k);
    hit(game);
  }
  assert.equal(new Set(seen).size, PROBLEMS.length);
  assert.equal(game.stage, 9, '80 問 = 8 ステージ');
  // 全部正解したら 2 周目。直前 10 問は避ける
  assert.equal(game.lap, 2);
  assert.equal(game.solved.size, 0, '正解済みは空になる');
  const next = [];
  for (let i = 0; i < 20; i += 1) {
    const k = game.current().kanji;
    const before = [...seen, ...next].slice(-10);
    assert.ok(!before.includes(k), `2 周目の ${i + 1} 問目 ${k} が直前 10 問に出ている`);
    next.push(k);
    hit(game);
  }
  assert.equal(new Set(next).size, 20, '2 周目の中でも正解した字は出さない');
});

test('パス・時間切れで終わった字は復習に回り、3 問以上挟んでから優先して再出題される', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  const passed = game.current().kanji;
  game.pass();
  c.advance(FULL_MS);
  const timedOut = game.current().kanji;
  game.timeUp(null);
  game.finishReveal();
  assert.deepEqual(game.review, [passed, timedOut]);
  const order = [];
  for (let i = 0; i < 6; i += 1) {
    order.push(game.current().kanji);
    hit(game);
  }
  // 出した順: passed, timedOut, a, b, passed (3 問挟んだ), timedOut (3 問挟んだ) …
  // (乱数 0 は REVIEW_CHANCE を下回るので、選べるようになった復習の字を先に選ぶ)
  assert.equal(order[2], passed, 'パスした字は 3 問挟んだところで出る');
  assert.equal(order[3], timedOut, '時間切れの字も 3 問挟んだところで出る');
  assert.ok(!order.slice(0, 2).includes(passed));
  assert.ok(!order.slice(0, 2).includes(timedOut));
  assert.deepEqual(game.review, [], '正解したら復習から外れる');
  assert.ok(!order.slice(4).includes(passed), '正解したあとは出ない');
});

test('誤答の宣言だけでは復習に回らない (同じ問題を続け、正解すれば正解済み)', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  const k = game.current().kanji;
  miss(game);
  hit(game);
  assert.deepEqual(game.review, []);
  assert.ok(game.solved.has(k));
});

test('リトライ・つづきからでも正解済みと復習は保持、さいしょから (新しい Game) で消える', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  hit(game);
  hit(game);
  game.pass();
  miss(game);
  miss(game);
  miss(game);
  game.retry();
  assert.equal(game.solved.size, 2);
  assert.equal(game.review.length, 1);
  const parsed = parseProgress(JSON.parse(JSON.stringify(game.snapshot())));
  const resumed = new Game({ random: firstPick, now: c.now, saved: parsed });
  assert.deepEqual([...resumed.solved], [...game.solved]);
  assert.deepEqual(resumed.review, game.review);
  assert.deepEqual(resumed.recent, game.recent);
  assert.equal(resumed.lap, 1);
  const fresh = new Game({ random: firstPick, now: c.now });
  assert.equal(fresh.solved.size, 0);
  assert.deepEqual(fresh.review, []);
});

test('ステージ 2 の得点: 1 問目 10 点、2 問目 15 点、3 問目 20 点 (10 + 5k)', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  clearStage(game);
  assert.equal(hit(game).gained, 10);
  assert.equal(hit(game).gained, 15);
  assert.equal(hit(game).gained, 20);
  assert.equal(game.score(), 145);
});

test('ステージ 2 の k はパスした問題を数えない (旧エクストラと同じく正解した数)', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  clearStage(game);
  game.pass();
  assert.equal(hit(game).gained, 10);
  game.pass();
  assert.equal(hit(game).gained, 15);
});

test('ステージ 2 のドパは X(n)、強度 E は旧エクストラの式', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  clearStage(game);
  assert.equal(game.intensity(), extraIntensity(0));
  const before = game.dopa;
  const combo = game.combo + 1;
  const out = hit(game);
  assert.equal(out.dopaAfter, advanceDopa(before, extraIncrement(0), combo));
  for (let i = 0; i < 2; i += 1) {
    hit(game);
  }
  assert.ok(Math.abs(game.intensity() - 1.1) < 1e-12);
});

test('ステージ 3 へも続く。10 + 5k の k はステージ 2 から通しで数える', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  clearStage(game);
  const out = clearStage(game);
  assert.equal(out.stageCleared, 2);
  assert.equal(game.stage, 3);
  assert.equal(hit(game).gained, 10 + 5 * 10);
});

test('最終問が時間切れでも、見せ終えたらステージクリア (そのステージの正解数を返す)', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  for (let i = 0; i < PASS_LIMIT; i += 1) {
    game.pass();
  }
  while (game.index < game.questionCount - 1) {
    hit(game);
  }
  c.advance(FULL_MS);
  assert.equal(game.timeUp(null).verdict, TIMEOUT);
  assert.equal(game.stage, 1, '見せている間はまだステージ 1');
  const next = game.finishReveal();
  assert.equal(next.stageCleared, 1);
  assert.equal(next.clearedCorrect, 10 - PASS_LIMIT - 1);
  assert.equal(game.stage, 2);
  assert.equal(game.passesLeft(), PASS_LIMIT);
});

test('最終問のパスでもステージクリア。正解 0 なら clearedCorrect 0 (画面側は祝わない)', () => {
  const game = new Game({ random: firstPick, now: clock().now, questionCount: 3 });
  game.pass();
  game.pass();
  const out = game.pass();
  assert.equal(out.passed, true);
  assert.equal(out.stageCleared, 1);
  assert.equal(out.clearedCorrect, 0);
  assert.equal(game.stage, 2);
});

// MARK: - リトライ

test('リトライ: 同じステージの失敗した問題から。得点・ドパ・あつめた字・パス回数は保持、ライフ 3、コンボ 0', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  clearStage(game);
  hit(game);
  game.pass();
  hit(game);
  const failed = game.current();
  const score = game.score();
  const dopa = game.dopa;
  const collected = game.collected.slice();
  const maxCombo = game.maxCombo;
  miss(game);
  miss(game);
  c.advance(3000);
  assert.equal(miss(game).gameOver, true);
  assert.equal(game.retry(), true);
  assert.equal(game.phase, PHASE_PLAY);
  assert.equal(game.stage, 2);
  assert.equal(game.index, 3);
  assert.equal(game.current(), failed);
  assert.equal(game.lives, LIVES);
  assert.equal(game.combo, 0);
  assert.equal(game.misses, 0, '見本は消える');
  assert.equal(game.score(), score);
  assert.equal(game.dopa, dopa);
  assert.deepEqual(game.collected, collected);
  assert.equal(game.maxCombo, maxCombo);
  assert.equal(game.passesLeft(), PASS_LIMIT - 1, 'パス回数はステージのまま');
  assert.equal(game.remainingMs(), TIME_LIMIT_MS, '制限時間は引き直す');
  // 続きの得点も通しで数える (ステージ 2 で 3 問目の正解 = 10 + 5 × 2)
  assert.equal(hit(game).gained, 20);
  assert.equal(game.retry(), false, 'ゲームオーバーでなければ何もしない');
});

test('リトライ: 時間切れで終わったときは、その時間切れの問題から', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  miss(game);
  hit(game);
  miss(game);
  const failed = game.current();
  c.advance(FULL_MS);
  assert.equal(game.timeUp(null).gameOver, true);
  game.retry();
  assert.equal(game.current(), failed);
  assert.equal(game.index, 1);
});

// MARK: - つづきから

test('つづきから: snapshot を JSON にして戻すと、位置・得点・ドパ・あつめた字・ライフ・出題順・パスが戻る', () => {
  const c = clock();
  const game = new Game({ random: Math.random, now: c.now });
  clearStage(game);
  hit(game);
  game.pass();
  hit(game);
  miss(game);
  const saved = JSON.parse(JSON.stringify(game.snapshot()));
  assert.equal(saved.score, game.score());
  const parsed = parseProgress(saved);
  assert.ok(parsed !== null);
  const resumed = new Game({ random: Math.random, now: c.now, saved: parsed });
  assert.equal(resumed.stage, 2);
  assert.equal(resumed.index, game.index);
  assert.deepEqual(resumed.round, game.round, '出題順 (このステージで出した問題、問題データそのもの)');
  assert.equal(resumed.current(), game.current());
  assert.equal(resumed.score(), game.score());
  assert.equal(resumed.dopa, game.dopa);
  assert.deepEqual(resumed.collected, game.collected);
  assert.equal(resumed.lives, LIVES - 1);
  assert.equal(resumed.passesLeft(), game.passesLeft());
  assert.equal(resumed.maxCombo, game.maxCombo);
  assert.equal(resumed.correctCount, game.correctCount);
  assert.equal(resumed.combo, 0, 'コンボは戻さない');
  assert.equal(resumed.phase, PHASE_PLAY);
  assert.equal(resumed.remainingMs(), TIME_LIMIT_MS);
  // 続きの得点も通しで数える
  assert.equal(hit(resumed).gained, 20);
});

test('つづきから: ゲームオーバーの状態はリトライと同じ位置 (失敗した問題、ライフ 3) で残す', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  hit(game);
  const failed = game.current();
  miss(game);
  miss(game);
  miss(game);
  assert.equal(game.phase, PHASE_OVER);
  const parsed = parseProgress(JSON.parse(JSON.stringify(game.snapshot())));
  assert.equal(parsed.lives, LIVES);
  const resumed = new Game({ random: firstPick, now: clock().now, saved: parsed });
  assert.equal(resumed.current(), failed);
  assert.equal(resumed.lives, LIVES);
  assert.equal(resumed.score(), 10);
});

test('parseProgress: 壊れた保存は null (最初から遊ぶ)', () => {
  const good = new Game({ random: firstPick, now: clock().now }).snapshot();
  assert.ok(parseProgress(good) !== null);
  const broken = [
    null,
    'text',
    {},
    { ...good, order: [] },
    { ...good, order: ['鬱'] },
    { ...good, order: [good.order[0], good.order[0]] },
    { ...good, solved: ['鬱'] },
    { ...good, solved: undefined },
    { ...good, review: 'a' },
    { ...good, recent: new Array(11).fill(good.order[0]) },
    { ...good, lap: 0 },
    { ...good, index: 10 },
    { ...good, index: 1 },
    { ...good, index: -1 },
    { ...good, stage: 0 },
    { ...good, stage: 1.5 },
    { ...good, lives: 0 },
    { ...good, lives: 4 },
    { ...good, passes: PASS_LIMIT + 1 },
    { ...good, dopa: Number.NaN },
    { ...good, dopa: 99 },
    { ...good, collected: ['鬱'] },
    { ...good, collected: 'ab' },
    { ...good, firstStageSolved: 11 },
    { ...good, laterSolved: -1 }
  ];
  for (const b of broken) {
    assert.equal(parseProgress(b), null, JSON.stringify(b));
  }
});

// MARK: - 判定タイマー

test('判定タイマー: 600 ms で正解だけを受け付ける認識に入る', () => {
  const state = { penDown: false, autoTried: false };
  assert.equal(nextJudge(state, 0), JUDGE_NONE);
  assert.equal(nextJudge(state, AUTO_JUDGE_MS - 1), JUDGE_NONE);
  assert.equal(nextJudge(state, AUTO_JUDGE_MS), JUDGE_AUTO);
  assert.equal(nextJudge(state, 1200), JUDGE_AUTO);
});

test('判定タイマー: 早い方の認識は 1 回だけ', () => {
  const tried = { penDown: false, autoTried: true };
  assert.equal(nextJudge(tried, AUTO_JUDGE_MS), JUDGE_NONE);
  assert.equal(nextJudge(tried, 1799), JUDGE_NONE);
});

test('判定タイマー: 1800 ms で誤答を宣言する', () => {
  assert.equal(nextJudge({ autoTried: false }, DECLARE_JUDGE_MS - 1), JUDGE_AUTO);
  assert.equal(nextJudge({ autoTried: true }, DECLARE_JUDGE_MS - 1), JUDGE_NONE);
  assert.equal(nextJudge({ autoTried: true }, DECLARE_JUDGE_MS), JUDGE_DECLARE);
  assert.equal(nextJudge({ autoTried: false }, DECLARE_JUDGE_MS), JUDGE_DECLARE);
  assert.equal(nextJudge({ autoTried: true }, 5000), JUDGE_DECLARE);
});

test('判定タイマー: ペンが降りている間は何もしない (ペンダウンで解除)', () => {
  assert.equal(nextJudge({ penDown: true, autoTried: false }, AUTO_JUDGE_MS), JUDGE_NONE);
  assert.equal(nextJudge({ penDown: true, autoTried: true }, 9999), JUDGE_NONE);
  assert.equal(judgeDelay({ penDown: true }, 9999), Infinity);
});

test('判定タイマー: 画の間隔が 1.8 秒未満なら宣言に届かない', () => {
  // 1 秒おきに 4 画。どの画のあとも経過は 1000 ms なので宣言は起きない
  for (let stroke = 0; stroke < 4; stroke += 1) {
    assert.equal(nextJudge({ penDown: false, autoTried: false }, 600), JUDGE_AUTO);
    assert.equal(nextJudge({ penDown: false, autoTried: true }, 1000), JUDGE_NONE);
  }
  // 最後のペンアップから 1800 ms 書き足しが無ければ宣言する
  assert.equal(nextJudge({ penDown: false, autoTried: true }, 1800), JUDGE_DECLARE);
});

test('判定タイマー: 次の予定までの待ち時間', () => {
  assert.equal(judgeDelay({ autoTried: false }, 0), AUTO_JUDGE_MS);
  assert.equal(judgeDelay({ autoTried: false }, 200), 400);
  assert.equal(judgeDelay({ autoTried: true }, 600), DECLARE_JUDGE_MS - 600);
  assert.equal(judgeDelay({ autoTried: true }, DECLARE_JUDGE_MS), 0);
  assert.equal(judgeDelay({ autoTried: true }, 5000), 0);
});
