// 最高記録の更新 (localStorage が無い node でも動く。保存は try/catch で握りつぶされる)。
import test from 'node:test';
import assert from 'node:assert/strict';

import { recordBest } from '../js/store.js';

const fresh = () => ({ bestScore: 0, bestDopa: null, bestCombo: 0, bestStage: 0, sound: true, penWidth: 10 });

test('recordBest: 未記録からの初回はドパも更新する', () => {
  const state = fresh();
  const updated = recordBest(state, { score: 60, dopa: 1.8, maxCombo: 4, stage: 1 });
  assert.deepEqual(updated, ['score', 'dopa', 'combo', 'stage']);
  assert.equal(state.bestDopa, 1.8);
});

test('recordBest: 未記録のままドパ 0 なら記録しない', () => {
  const state = fresh();
  const updated = recordBest(state, { score: 0, dopa: 0, maxCombo: 0, stage: 0 });
  assert.deepEqual(updated, []);
  assert.equal(state.bestDopa, null);
});

test('recordBest: 記録済みなら上回ったときだけ更新する', () => {
  const state = { ...fresh(), bestScore: 100, bestDopa: 2.3, bestCombo: 10, bestStage: 2 };
  assert.deepEqual(recordBest(state, { score: 100, dopa: 2.3, maxCombo: 10, stage: 2 }), []);
  assert.deepEqual(recordBest(state, { score: 105, dopa: 2.3, maxCombo: 9, stage: 1 }), ['score']);
  assert.deepEqual(recordBest(state, { score: 105, dopa: 2.3, maxCombo: 9, stage: 3 }), ['stage']);
  assert.equal(state.bestStage, 3);
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

// MARK: - つづきから (localStorage の代わりに Map で試す)

function withStorage(run) {
  const data = new Map();
  const saved = globalThis.window;
  globalThis.window = {
    localStorage: {
      getItem: (k) => (data.has(k) ? data.get(k) : null),
      setItem: (k, v) => { data.set(k, String(v)); },
      removeItem: (k) => { data.delete(k); }
    }
  };
  try {
    return run(data);
  } finally {
    globalThis.window = saved;
  }
}

test('saveProgress / loadProgress: 途中の状態を保存して読み戻し、Game に渡すと同じ位置から続く', async () => {
  const { saveProgress, loadProgress, clearProgress } = await import('../js/store.js');
  const { Game, parseProgress, LIVES } = await import('../js/game.js');
  withStorage(() => {
    assert.equal(loadProgress(), null, '保存が無ければ null');
    const game = new Game({ random: () => 0, now: () => 0 });
    for (let i = 0; i < 12; i += 1) {
      game.answer([{ char: game.current().kanji, probability: 1 }]);
    }
    game.answer([{ char: '?', probability: 1 }]);
    saveProgress(game.snapshot());
    const parsed = parseProgress(loadProgress());
    assert.ok(parsed !== null);
    const resumed = new Game({ random: () => 0, now: () => 0, saved: parsed });
    assert.equal(resumed.stage, 2);
    assert.equal(resumed.index, 2);
    assert.equal(resumed.current(), game.current());
    assert.equal(resumed.score(), 100 + 10 + 15);
    assert.equal(resumed.dopa, game.dopa);
    assert.equal(resumed.lives, LIVES - 1);
    assert.deepEqual(resumed.collected, game.collected, 'あつめた字は字だけで戻る');
    assert.ok(resumed.collected.every((k) => typeof k === 'string'));
    clearProgress();
    assert.equal(loadProgress(), null, 'さいしょから で消える');
  });
});

test('saveProgress: 最高記録・設定とは別のキーに置く (消しても記録は残る)', async () => {
  const { save, load, saveProgress, clearProgress } = await import('../js/store.js');
  withStorage((data) => {
    save({ ...load(), bestScore: 321, bestStage: 4 });
    saveProgress({ stage: 4 });
    assert.equal(data.size, 2);
    clearProgress();
    assert.equal(data.size, 1);
    assert.equal(load().bestScore, 321);
    assert.equal(load().bestStage, 4);
  });
});

test('loadProgress: 壊れた JSON や localStorage が使えない環境では null', async () => {
  const { loadProgress, saveProgress, clearProgress } = await import('../js/store.js');
  withStorage((data) => {
    data.set('spiketegaki.game.progress', '{broken');
    assert.equal(loadProgress(), null);
  });
  // node には window が無い (プライベートウィンドウで使えない場合と同じ) が、例外を出さない
  assert.equal(loadProgress(), null);
  saveProgress({ stage: 1 });
  clearProgress();
});
