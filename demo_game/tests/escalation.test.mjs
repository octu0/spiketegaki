// 演出のエスカレーション (DOM 無し): 回転速度・観客の人数・横断バナーの条件など。
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  CHEER_CONFETTI,
  CHEER_DANCE,
  CHEER_HOP,
  CHEER_NONE,
  CHEER_RING,
  CROWD_MAX,
  LEAPER_MAX,
  MARCHERS,
  FLOAT_STACK_MAX,
  FLOAT_STACK_MS,
  MAX_PARTICLES,
  MAX_PROPS,
  SPIN_BASE,
  SPIN_EASE_MS,
  SPIN_HOLD_MS,
  SPIN_SLOW,
  SPIN_STOP_MS,
  SPRITE_BUDGET,
  cheerLevel,
  correctProps,
  crowdCount,
  easeSpin,
  floatLevel,
  garlandCount,
  leaperCount,
  milestoneLabel,
  propRates,
  sashText,
  spinSpeed,
  walkerCount
} from '../js/escalation.js';

const near = (a, b, eps = 1e-12) => assert.ok(Math.abs(a - b) < eps, `${a} != ${b}`);

// MARK: - 回転

test('spinSpeed: 1 問目・0 コンボは基準速度、問題の進行で最終問は 3 倍', () => {
  near(spinSpeed({ index: 0, total: 10, combo: 0 }), SPIN_BASE);
  near(spinSpeed({ index: 9, total: 10, combo: 0 }), SPIN_BASE * 3);
  // 1 + 2 i/(N−1): 途中は線形
  near(spinSpeed({ index: 3, total: 10, combo: 0 }), SPIN_BASE * (1 + 2 * 3 / 9));
  // 進行で単調に速くなる
  for (let i = 1; i < 10; i += 1) {
    assert.ok(spinSpeed({ index: i, total: 10, combo: 0 }) > spinSpeed({ index: i - 1, total: 10, combo: 0 }));
  }
  // ステージ 2 以降はステージ 1 の最終問と同じ進行度
  near(spinSpeed({ index: 9, total: 10, later: true, combo: 0 }), SPIN_BASE * 3);
  near(spinSpeed({ index: 0, total: 10, later: true, combo: 0 }), SPIN_BASE * 3);
});

test('spinSpeed: コンボで × (1 + combo/4)、20 コンボで 6 倍に頭打ち', () => {
  const base = spinSpeed({ index: 0, total: 10, combo: 0 });
  near(spinSpeed({ index: 0, total: 10, combo: 4 }), base * 2);
  near(spinSpeed({ index: 0, total: 10, combo: 20 }), base * 6);
  near(spinSpeed({ index: 0, total: 10, combo: 60 }), base * 6);
  near(spinSpeed({ index: 0, total: 10, combo: -3 }), base);
  // 最終問 + 20 コンボ = 18 倍
  near(spinSpeed({ index: 9, total: 10, combo: 20 }), SPIN_BASE * 18);
});

test('spinSpeed: 誤答で 800 ms 止まり、そのあと 0.3 倍、次の正解 (null) で元に戻る', () => {
  const s = { index: 5, total: 10, combo: 0 };
  const full = spinSpeed(s);
  assert.equal(SPIN_STOP_MS + SPIN_HOLD_MS, 800);
  assert.equal(spinSpeed({ ...s, sinceMissMs: 0 }), 0);
  assert.equal(spinSpeed({ ...s, sinceMissMs: 299 }), 0);
  assert.equal(spinSpeed({ ...s, sinceMissMs: 799 }), 0);
  near(spinSpeed({ ...s, sinceMissMs: 800 }), full * SPIN_SLOW);
  near(spinSpeed({ ...s, sinceMissMs: 60000 }), full * 0.3);
  near(spinSpeed({ ...s, sinceMissMs: null }), full);
  // 壊れた値は「誤答なし」と同じ
  near(spinSpeed({ ...s, sinceMissMs: NaN }), full);
});

test('easeSpin: 300 ms の smoothstep で from から to へ', () => {
  assert.equal(SPIN_EASE_MS, 300);
  assert.equal(easeSpin(1, 3, 0), 1);
  assert.equal(easeSpin(1, 3, 150), 2);
  assert.equal(easeSpin(1, 3, 300), 3);
  assert.equal(easeSpin(1, 3, 5000), 3);
  assert.equal(easeSpin(1, 3, -10), 1);
  // 止まるときも 300 ms で 0 に着く (誤答の「300 ms かけて完全停止」)
  assert.equal(easeSpin(0.5, 0, SPIN_STOP_MS), 0);
  // 単調
  let prev = easeSpin(0, 1, 0);
  for (let t = 10; t <= 300; t += 10) {
    const v = easeSpin(0, 1, t);
    assert.ok(v >= prev);
    prev = v;
  }
});

// MARK: - 観客

test('crowdCount: 正解 0 で 1 体、1 問ごとに 2〜3 体、ステージ 1 の完走で 24 体', () => {
  assert.equal(crowdCount(0, 0.08), 1);
  const counts = [];
  for (let c = 0; c <= 10; c += 1) {
    counts.push(crowdCount(c, 0.5));
  }
  assert.deepEqual(counts, [1, 3, 6, 8, 10, 13, 15, 17, 19, 22, 24]);
  for (let c = 1; c <= 10; c += 1) {
    const step = counts[c] - counts[c - 1];
    assert.ok(step >= 2 && step <= 3, `c=${c} で +${step}`);
  }
  // ステージ 1 の E (≤ 1) は人数を変えない
  assert.equal(crowdCount(10, 1), 24);
});

test('crowdCount: ステージ 2 以降は E 倍で増えて 40 体で頭打ち', () => {
  assert.equal(crowdCount(11, 1), 26);
  assert.ok(crowdCount(14, 1.1) > crowdCount(14, 1));
  assert.equal(crowdCount(17, 1), CROWD_MAX);
  assert.equal(crowdCount(200, 1.5), CROWD_MAX);
  assert.equal(CROWD_MAX, 40);
  // 壊れた値でも 1〜40
  assert.equal(crowdCount(-5, 0), 1);
});

test('walkerCount: 4 体に 1 体が歩き回る (最大 8、1 体のときは 0)', () => {
  assert.equal(walkerCount(1), 0);
  assert.equal(walkerCount(3), 0);
  assert.equal(walkerCount(6), 1);
  assert.equal(walkerCount(24), 5);
  assert.equal(walkerCount(40), 8);
  for (let n = 1; n <= 40; n += 1) {
    assert.ok(walkerCount(n) < n, `${n} 体で全員が歩いてしまう`);
  }
});

test('cheerLevel: 1〜2 跳ねる / 3〜5 紙吹雪 / 6〜8 踊る / 9 以上 輪', () => {
  assert.equal(cheerLevel(0), CHEER_NONE);
  assert.deepEqual([1, 2].map(cheerLevel), [CHEER_HOP, CHEER_HOP]);
  assert.deepEqual([3, 4, 5].map(cheerLevel), [CHEER_CONFETTI, CHEER_CONFETTI, CHEER_CONFETTI]);
  assert.deepEqual([6, 7, 8].map(cheerLevel), [CHEER_DANCE, CHEER_DANCE, CHEER_DANCE]);
  assert.deepEqual([9, 10, 30].map(cheerLevel), [CHEER_RING, CHEER_RING, CHEER_RING]);
});

test('leaperCount: E 0.8 未満は 0、以後は E とともに増えて 5 体まで', () => {
  assert.equal(leaperCount(0.79), 0);
  assert.equal(leaperCount(0.8), 1);
  assert.equal(leaperCount(1), 2);
  assert.equal(leaperCount(1.5), 5);
  assert.equal(leaperCount(9), LEAPER_MAX);
});

// MARK: - 飾り

test('garlandCount: 正解 3 問目から 1 本ずつ、3 本まで', () => {
  assert.deepEqual([0, 1, 2, 3, 4, 5, 6, 20].map(garlandCount), [0, 0, 0, 1, 2, 3, 3, 3]);
});

test('propRates: しきい値より下は 0、E とともに増える', () => {
  assert.deepEqual(propRates(0.08), { streamer: 0, candy: 0, balloon: 0, coin: 0 });
  assert.ok(propRates(0.4).streamer > 0 && propRates(0.39).streamer === 0);
  assert.ok(propRates(0.5).candy > 0 && propRates(0.49).candy === 0);
  assert.ok(propRates(0.7).balloon > 0 && propRates(0.69).balloon === 0);
  assert.ok(propRates(0.85).coin > 0 && propRates(0.84).coin === 0);
  const keys = ['streamer', 'candy', 'balloon', 'coin'];
  for (const k of keys) {
    assert.ok(propRates(1.5)[k] >= propRates(1)[k], k);
    assert.ok(propRates(1)[k] > 0, k);
  }
});

test('correctProps: 正解の一撃も E で増え、ドパの節目は硬貨の雨', () => {
  assert.deepEqual(correctProps(0.08), { streamer: 0, candy: 0, balloon: 0, coin: 0 });
  assert.ok(correctProps(1).streamer > correctProps(0.5).streamer);
  assert.equal(correctProps(0.3, true).coin, 40);
  assert.ok(correctProps(1).coin > 0);
});

test('粒子 + スプライトの上限は合計 900', () => {
  assert.equal(SPRITE_BUDGET, 900);
  assert.equal(MAX_PARTICLES + CROWD_MAX + LEAPER_MAX + MARCHERS + MAX_PROPS, SPRITE_BUDGET);
  assert.ok(MAX_PROPS > 0);
});

// MARK: - 横断バナー

test('sashText: ステージ内の最終問で「ラスト1もん」、それ以外の問題では出さない', () => {
  for (let i = 1; i < 9; i += 1) {
    assert.equal(sashText({ stage: 1, index: i, total: 10 }), null, `i=${i}`);
    assert.equal(sashText({ stage: 3, index: i, total: 10 }), null, `stage 3, i=${i}`);
  }
  assert.equal(sashText({ stage: 1, index: 0, total: 10 }), null, 'ステージ 1 の 1 問目は出さない');
  assert.equal(sashText({ stage: 1, index: 9, total: 10 }), 'ラスト1もん');
  assert.equal(sashText({ stage: 4, index: 9, total: 10 }), 'ラスト1もん');
  // 1 問だけのステージは「ラスト」と言わない
  assert.equal(sashText({ stage: 1, index: 0, total: 1 }), null);
});

test('sashText: ステージ 2 以降の 1 問目で「ステージ n」', () => {
  assert.equal(sashText({ stage: 2, index: 0, total: 10 }), 'ステージ 2');
  assert.equal(sashText({ stage: 12, index: 0, total: 10 }), 'ステージ 12');
});

test('milestoneLabel: ドパの節目を 100 / 1000 / 1万 … 1億 にする', () => {
  assert.deepEqual([2, 3, 4, 5, 6, 7, 8].map(milestoneLabel),
    ['100', '1000', '1万', '10万', '100万', '1000万', '1億']);
});

// MARK: - 加点の浮遊

test('floatLevel: 続けて正解すると 1 段ずつ積み、間が空くと 0 段目に戻る', () => {
  assert.equal(floatLevel(0, Infinity), 0);
  assert.equal(floatLevel(0, 700), 1);
  assert.equal(floatLevel(1, 700), 2);
  assert.equal(floatLevel(FLOAT_STACK_MAX, 700), FLOAT_STACK_MAX);
  assert.equal(floatLevel(3, FLOAT_STACK_MS), 0);
  assert.equal(floatLevel(2, -1), 0);
});
