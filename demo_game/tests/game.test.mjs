// ラウンド進行・判定・タイマー (DOM 無し)。
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  CLOSE,
  CORRECT,
  EXTRA_MS,
  Game,
  HINT_AFTER_MISSES,
  PHASE_DONE,
  PHASE_EXTRA,
  WRONG,
  AUTO_JUDGE_MS,
  DECLARE_JUDGE_MS,
  JUDGE_AUTO,
  JUDGE_DECLARE,
  JUDGE_NONE,
  acceptAuto,
  judge,
  judgeDelay,
  nextJudge
} from '../js/game.js';
import { COMBO_LIMIT_MS } from '../js/scoring.js';
import { PROBLEMS } from '../js/problems.js';

/** 先頭から順に引く乱数 (ラウンドを固定する) */
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

test('自動判定は正解以外を game に渡さない (書き途中でも進まない・減らない)', () => {
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
  assert.equal(game.showsHint(), false);
  assert.equal(game.closeCount, 0);
  assert.equal(game.combo, 0);
  assert.equal(game.score(), 0);

  // 書き上がって top-1 になったら、そこで確定する
  assert.equal(acceptAuto(rows(target, a, b), target), true);
  assert.equal(game.answer(rows(target, a, b)).verdict, CORRECT);
  assert.equal(game.score(), 10);
});

test('誤答の宣言では おしい / もういちど も受け付ける (早い方の判定との違い)', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  const target = game.current().kanji;
  const [a, b] = others(target, 2);
  // 宣言 (1800 ms) は acceptAuto を通さずそのまま answer に渡す
  assert.equal(game.answer(rows(a, target, b)).verdict, CLOSE);
  assert.equal(game.closeCount, 1);
  const second = game.answer(rows(a, b));
  assert.equal(second.verdict, WRONG);
  assert.equal(second.showsHint, true, '誤答の宣言 2 回で見本を出す');
});

test('正解で得点・コンボ・ドパが増える', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  const target = game.current().kanji;
  const out = game.answer(rows(target));
  assert.equal(out.verdict, CORRECT);
  assert.equal(out.gained, 10);
  assert.equal(out.combo, 1);
  assert.equal(game.score(), 10);
  assert.ok(game.dopa > 0);
  assert.equal(game.correctCount, 1);
});

test('誤答はコンボを 0 にするだけ (減点なし・問題は続く)', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  game.answer(rows(game.current().kanji));   // 1 問目 正解
  const second = game.current();
  const scoreBefore = game.score();
  const dopaBefore = game.dopa;
  const out = game.answer(rows(...others(second.kanji, 3)));
  assert.equal(out.verdict, WRONG);
  assert.equal(game.combo, 0);
  assert.equal(game.score(), scoreBefore, '減点しない');
  assert.equal(game.dopa, dopaBefore, 'ドパも減らない');
  assert.equal(game.current(), second, '同じ問題のまま');
});

test('おしい は closeCount に入り、コンボは切れる', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  const target = game.current().kanji;
  const [a, b] = others(target, 2);
  const out = game.answer(rows(a, target, b));
  assert.equal(out.verdict, CLOSE);
  assert.equal(game.closeCount, 1);
  assert.equal(game.combo, 0);
  assert.equal(game.score(), 0);
});

test(`同じ問題で ${HINT_AFTER_MISSES} 回外したら見本を出す`, () => {
  const game = new Game({ random: firstPick, now: clock().now });
  const target = game.current().kanji;
  const [other] = others(target, 1);
  assert.equal(game.showsHint(), false);
  const first = game.answer(rows(other));
  assert.equal(first.showsHint, false, '1 回目では出さない');
  const second = game.answer(rows(other));
  assert.equal(second.showsHint, true, '2 回目で出す');
  assert.equal(game.showsHint(), true);
  // 見本ありで正解しても得点・ドパは通常どおり
  const out = game.answer(rows(target));
  assert.equal(out.gained, 10);
  assert.ok(out.dopaAfter > out.dopaBefore);
  assert.equal(game.showsHint(), false, '次の問題では消える');
});

test('パスは得点もドパも増やさず、コンボを 0 にして次へ', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  const first = game.current();
  game.answer(rows(first.kanji));
  const dopaBefore = game.dopa;
  const scoreBefore = game.score();
  const second = game.current();
  const out = game.pass();
  assert.equal(out.passed, true);
  assert.equal(game.combo, 0);
  assert.equal(game.dopa, dopaBefore);
  assert.equal(game.score(), scoreBefore);
  assert.notEqual(game.current(), second, '次の問題へ進む');
});

test('コンボの時間切れ: 2 コンボ以上だけが対象', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });

  // 1 コンボ の状態は時間切れにならない
  game.answer(rows(game.current().kanji));
  assert.equal(game.combo, 1);
  c.advance(COMBO_LIMIT_MS * 3);
  assert.deepEqual(game.tick(), { comboExpired: false, brokenCombo: 0, extraExpired: false });
  assert.equal(game.combo, 1);

  // 2 コンボ目からは制限時間がある
  game.answer(rows(game.current().kanji));
  assert.equal(game.combo, 2);
  c.advance(COMBO_LIMIT_MS - 1);
  assert.equal(game.tick().comboExpired, false, '期限前は切れない');
  assert.equal(game.combo, 2);
  c.advance(1);
  const events = game.tick();
  assert.equal(events.comboExpired, true);
  assert.equal(events.brokenCombo, 2);
  assert.equal(game.combo, 0);
  // 問題は続く (得点は残る)
  assert.equal(game.score(), 20);
  assert.ok(game.current() !== null);
});

test('コンボの期限は問題ごとに引き直す', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  game.answer(rows(game.current().kanji));
  c.advance(COMBO_LIMIT_MS - 500);
  game.answer(rows(game.current().kanji));    // ここで期限が引き直される
  c.advance(COMBO_LIMIT_MS - 1);
  assert.equal(game.tick().comboExpired, false);
  assert.equal(game.combo, 2);
});

test('10 問完走で 100 点になり、局面が終わる', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  let last = null;
  for (let i = 0; i < 10; i += 1) {
    last = game.answer(rows(game.current().kanji));
  }
  assert.equal(last.baseFinished, true);
  assert.equal(game.phase, PHASE_DONE);
  assert.equal(game.score(), 100);
  assert.equal(game.maxCombo, 10);
  assert.equal(game.current(), null);
});

test('10 問すべてパスすると、正解 0 のまま完走する', () => {
  const game = new Game({ random: firstPick, now: clock().now });
  let last = null;
  for (let i = 0; i < 10; i += 1) {
    last = game.pass();
  }
  assert.equal(last.baseFinished, true);
  assert.equal(game.phase, PHASE_DONE);
  assert.equal(game.score(), 0);
  assert.equal(game.summary().correctCount, 0, '祝う理由が無い (画面側はここを見て演出を出さない)');
  assert.equal(game.pass().passed, false, '完走したあとのパスは効かない');
  // エクストラへは正解数に関係なく進める
  game.startExtra();
  assert.equal(game.phase, PHASE_EXTRA);
  assert.ok(game.current() !== null);
});

test('コンボの期限ちょうどに来た正解は、コンボを 0 に戻してから数える', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  game.answer(rows(game.current().kanji));
  game.answer(rows(game.current().kanji));
  assert.equal(game.combo, 2);
  c.advance(COMBO_LIMIT_MS);                       // 期限ちょうど
  const out = game.answer(rows(game.current().kanji));
  assert.equal(out.verdict, CORRECT);
  assert.equal(out.combo, 1, '切れたコンボから数え直す');
  assert.equal(out.multiplier, 1.05);
  assert.equal(game.tick().comboExpired, false, 'tick にはもう切るものが無い');
});

test('コンボの期限 1 ms 前に来た正解はつながる', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  game.answer(rows(game.current().kanji));
  game.answer(rows(game.current().kanji));
  c.advance(COMBO_LIMIT_MS - 1);
  assert.equal(game.answer(rows(game.current().kanji)).combo, 3);
});

test('エクストラの期限後に来た正解は受け付けず、終了を知らせる', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  for (let i = 0; i < 10; i += 1) {
    game.answer(rows(game.current().kanji));
  }
  game.startExtra();
  c.advance(EXTRA_MS - 1);
  assert.equal(game.answer(rows(game.current().kanji)).gained, 10, '期限 1 ms 前はまだ数える');
  assert.equal(game.score(), 110);

  c.advance(1);                                    // 期限ちょうど
  const out = game.answer(rows(game.current().kanji));
  assert.equal(out.ignored, true);
  assert.equal(out.extraExpired, true, '画面側はこれを見て結果へ進む');
  assert.equal(game.phase, PHASE_DONE);
  assert.equal(game.score(), 110, '期限後の正解では増えない');
});

test('エクストラはコンボを 0 に戻し、ドパを引き継ぐ', () => {
  const c = clock();
  const game = new Game({ random: firstPick, now: c.now });
  for (let i = 0; i < 10; i += 1) {
    game.answer(rows(game.current().kanji));
  }
  const dopa = game.dopa;
  game.startExtra();
  assert.equal(game.phase, PHASE_EXTRA);
  assert.equal(game.combo, 0);
  assert.equal(game.dopa, dopa);
  assert.ok(game.current() !== null);

  // k 問目 (0 始まり) は 10 + 5k 点
  assert.equal(game.answer(rows(game.current().kanji)).gained, 10);
  assert.equal(game.answer(rows(game.current().kanji)).gained, 15);
  assert.equal(game.score(), 125);

  // 90 秒で終わる
  c.advance(EXTRA_MS);
  assert.equal(game.tick().extraExpired, true);
  assert.equal(game.phase, PHASE_DONE);
});

test('エクストラは直前の問題を繰り返さない', () => {
  const game = new Game({ random: Math.random, now: clock().now });
  for (let i = 0; i < 10; i += 1) {
    game.answer(rows(game.current().kanji));
  }
  game.startExtra();
  const seen = [];
  for (let i = 0; i < 30; i += 1) {
    const problem = game.current();
    assert.ok(!seen.slice(-9).includes(problem.kanji), `${problem.kanji} が直前 10 問で重複`);
    seen.push(problem.kanji);
    game.answer(rows(problem.kanji));
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
