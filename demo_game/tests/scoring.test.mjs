// 得点・ドパ・コンボの式 (DOM 無し)。
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  STAGE_QUESTIONS,
  DOPA_MAX,
  DOPA_MIN_STEP,
  advanceDopa,
  baseCurve,
  baseIncrement,
  baseIntensity,
  comboMultiplier,
  crossedMilestones,
  extraCurve,
  extraIncrement,
  extraIntensity,
  extraQuestionScore,
  extraTier,
  formatBestDopa,
  formatDopa,
  isComboCelebration,
  score
} from '../js/scoring.js';

test('得点: ステージ 1 の完走で 100 点', () => {
  assert.equal(score(0, 0), 0);
  assert.equal(score(STAGE_QUESTIONS, 0), 100);
});

test('得点: ステージ 2 以降の表の値 (旧エクストラ、SPEC §5.1)', () => {
  const table = [[5, 200], [10, 425], [15, 775], [23, 1595], [30, 2575]];
  for (const [n, expected] of table) {
    assert.equal(score(STAGE_QUESTIONS, n), expected, `ステージ 2 以降 ${n} 問`);
  }
});

test('得点: ステージ 2 以降の k 問目 (0 始まり) は 10 + 5k 点', () => {
  assert.equal(extraQuestionScore(0), 10);
  assert.equal(extraQuestionScore(1), 15);
  assert.equal(extraQuestionScore(9), 55);
  // 1 問ずつの加点を足すと合計と一致する
  let sum = 0;
  for (let k = 0; k < 15; k += 1) {
    sum += extraQuestionScore(k);
  }
  assert.equal(100 + sum, score(STAGE_QUESTIONS, 15));
});

test('ドパ: 基準曲線 B(f) と X(n)', () => {
  assert.equal(baseCurve(0), 0);
  assert.equal(baseCurve(1), 2.3);
  assert.equal(baseCurve(2), 2.3, 'f は 0..1 に丸める');
  assert.equal(baseCurve(-1), 0);
  assert.equal(extraCurve(0), 2.3);
  assert.ok(Math.abs(extraCurve(10) - (2.3 + 3 * (1 - Math.exp(-1)))) < 1e-12);
});

test('ドパ: 増分は式どおりで、合計は基準曲線の終点に一致する', () => {
  let sum = 0;
  for (let q = 0; q < 10; q += 1) {
    sum += baseIncrement(q, 10);
  }
  assert.ok(Math.abs(sum - baseCurve(1)) < 1e-12, `合計 ${sum}`);
  assert.ok(Math.abs(baseIncrement(0, 10) - baseCurve(0.1)) < 1e-12);
  assert.ok(Math.abs(extraIncrement(0) - (extraCurve(1) - extraCurve(0))) < 1e-12);
  // 後ろの問題ほど増分が大きい (B は上に凸ではない)
  assert.ok(baseIncrement(9, 10) > baseIncrement(0, 10));
});

test('ドパ: コンボ倍率 M(c) = 1 + min(1, c/20)', () => {
  assert.equal(comboMultiplier(0), 1);
  assert.equal(comboMultiplier(1), 1.05);
  assert.equal(comboMultiplier(10), 1.5);
  assert.equal(comboMultiplier(20), 2);
  assert.equal(comboMultiplier(999), 2);
  assert.equal(comboMultiplier(-5), 1);
});

test('ドパ: 最低増分 0.003 と上限 9.08', () => {
  // 基準増分が 0 でも最低増分ぶんは進む
  assert.ok(Math.abs(advanceDopa(0, 0, 1) - DOPA_MIN_STEP * 1.05) < 1e-12);
  // 倍率がかかる
  assert.ok(Math.abs(advanceDopa(1, 0.1, 20) - 1.2) < 1e-12);
  // 上限で止まる
  assert.equal(advanceDopa(9.07, 5, 20), DOPA_MAX);
  assert.equal(advanceDopa(DOPA_MAX, 1, 20), DOPA_MAX);
});

test('ドパ: 節目は越えたときだけ返る', () => {
  assert.deepEqual(crossedMilestones(1.9, 2.1), [2]);
  assert.deepEqual(crossedMilestones(2.1, 2.9), []);
  assert.deepEqual(crossedMilestones(1.5, 4.0), [2, 3, 4]);
  assert.deepEqual(crossedMilestones(8.5, 9.0), [], '節目は 1 億 (8) までで、その先は無い');
});

test('formatDopa: 1 万未満は整数、以降は 万 / 億 (上限 12 億なので 兆 は無い)', () => {
  assert.equal(formatDopa(0), '1');
  assert.equal(formatDopa(2), '100');
  assert.equal(formatDopa(3), '1000');
  assert.equal(formatDopa(Math.log10(9999)), '9999');
  assert.equal(formatDopa(4), '1.0万');
  assert.equal(formatDopa(Math.log10(12345)), '1.2万');
  assert.equal(formatDopa(5), '10万');
  assert.equal(formatDopa(Math.log10(987654)), '98万');
  assert.equal(formatDopa(Math.log10(99999999)), '9999万');
  assert.equal(formatDopa(8), '1.0億');
  assert.equal(formatDopa(DOPA_MAX), '12億');
  // 上限を越える値を渡しても「兆」の単位は持たない
  assert.equal(formatDopa(13), '100000億');
});

test('formatBestDopa: 未記録 (null) は 1 ではなく 0', () => {
  assert.equal(formatBestDopa(null), '0');
  assert.equal(formatBestDopa(0), '1');
  assert.equal(formatBestDopa(4), '1.0万');
});

test('コンボ: 祝う数は 10/20/30/50/75 と 100 以上の 50 ごと', () => {
  for (const c of [10, 20, 30, 50, 75, 100, 150, 200]) {
    assert.ok(isComboCelebration(c), `${c} は祝う`);
  }
  for (const c of [1, 9, 11, 40, 60, 90, 110, 125]) {
    assert.ok(!isComboCelebration(c), `${c} は祝わない`);
  }
});

test('演出強度', () => {
  assert.ok(Math.abs(baseIntensity(0, 10) - 0.08) < 1e-12);
  assert.ok(Math.abs(baseIntensity(9, 10) - 1) < 1e-12);
  assert.equal(baseIntensity(0, 1), 1, '1 問だけのときは 1');
  assert.ok(baseIntensity(5, 10) > baseIntensity(4, 10));

  assert.equal(extraTier(0), 0);
  assert.equal(extraTier(3), 1);
  assert.equal(extraIntensity(0), 1);
  assert.ok(Math.abs(extraIntensity(3) - 1.1) < 1e-12);
  assert.equal(extraIntensity(30), 1.5, '上限 1.5');

});

// MARK: - 演出の第 2 段階 (リーチ・観客・背景の回転・あつめた字)

test('isComboReach: 節目の 1 つ手前だけ true', async () => {
  const { isComboReach } = await import('../js/scoring.js');
  for (const c of [9, 19, 29, 49, 74, 99, 149]) {
    assert.equal(isComboReach(c), true, `${c} はリーチ`);
  }
  for (const c of [0, 1, 5, 8, 10, 11, 20, 30, 50, 75, 100]) {
    assert.equal(isComboReach(c), false, `${c} はリーチではない`);
  }
});

test('isComboReach: 0 コンボはリーチにしない (1 で祝いは無い)', async () => {
  const { isComboReach } = await import('../js/scoring.js');
  assert.equal(isComboReach(0), false);
  assert.equal(isComboReach(-3), false);
});

test('collectedSlots: ステージ 1 の 10 枠は最初から、越えたぶんだけ伸びる', async () => {
  const { collectedSlots, STAGE_QUESTIONS: base } = await import('../js/scoring.js');
  assert.equal(collectedSlots(0), base);
  assert.equal(collectedSlots(7), base);
  assert.equal(collectedSlots(base), base);
  assert.equal(collectedSlots(base + 3), base + 3);
  assert.equal(collectedSlots(-4), base);
});
