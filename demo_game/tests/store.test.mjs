// 最高記録の更新 (localStorage が無い node でも動く。保存は try/catch で握りつぶされる)。
import test from 'node:test';
import assert from 'node:assert/strict';

import { recordBest } from '../js/store.js';

const fresh = () => ({ bestScore: 0, bestDopa: null, bestCombo: 0, sound: true, penWidth: 10 });

test('recordBest: 未記録からの初回はドパも更新する', () => {
  const state = fresh();
  const updated = recordBest(state, { score: 60, dopa: 1.8, maxCombo: 4 });
  assert.deepEqual(updated, ['score', 'dopa', 'combo']);
  assert.equal(state.bestDopa, 1.8);
});

test('recordBest: 未記録のままドパ 0 なら記録しない', () => {
  const state = fresh();
  const updated = recordBest(state, { score: 0, dopa: 0, maxCombo: 0 });
  assert.deepEqual(updated, []);
  assert.equal(state.bestDopa, null);
});

test('recordBest: 記録済みなら上回ったときだけ更新する', () => {
  const state = { ...fresh(), bestScore: 100, bestDopa: 2.3, bestCombo: 10 };
  assert.deepEqual(recordBest(state, { score: 100, dopa: 2.3, maxCombo: 10 }), []);
  assert.deepEqual(recordBest(state, { score: 105, dopa: 2.3, maxCombo: 9 }), ['score']);
  assert.equal(state.bestScore, 105);
  assert.equal(state.bestDopa, 2.3);
  assert.equal(state.bestCombo, 10);
});

test('load: 保存が無い環境では音量は既定の 50', async () => {
  const { load, VOLUME_DEFAULT } = await import('../js/store.js');
  assert.equal(load().volume, VOLUME_DEFAULT);
  assert.equal(VOLUME_DEFAULT, 50);
});

test('clampVolume: 0〜100 の整数に切り詰める', async () => {
  const { clampVolume } = await import('../js/store.js');
  assert.equal(clampVolume(50), 50);
  assert.equal(clampVolume(0), 0);
  assert.equal(clampVolume(100), 100);
  assert.equal(clampVolume(-30), 0);
  assert.equal(clampVolume(180), 100);
  assert.equal(clampVolume(42.6), 43);
});
