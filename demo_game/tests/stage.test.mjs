// 筆記領域まわりの飾りのうち、DOM を使わない計算だけを試す。
import test from 'node:test';
import assert from 'node:assert/strict';

import { bulbPosition } from '../js/stage.js';
import { flowerPath } from '../js/fx.js';

test('bulbPosition: 16 個が四隅をまたいで枠を一周する', () => {
  assert.deepEqual(bulbPosition(0), { left: 0, top: 0 });
  assert.deepEqual(bulbPosition(4), { left: 100, top: 0 });
  assert.deepEqual(bulbPosition(8), { left: 100, top: 100 });
  assert.deepEqual(bulbPosition(12), { left: 0, top: 100 });
  // 一周して先頭に戻る
  assert.deepEqual(bulbPosition(16), bulbPosition(0));
  for (let i = 0; i < 16; i += 1) {
    const { left, top } = bulbPosition(i);
    assert.ok(left >= 0 && left <= 100 && top >= 0 && top <= 100, `${i} が枠の外`);
    assert.ok(left === 0 || left === 100 || top === 0 || top === 100, `${i} が辺の上に無い`);
  }
});

test('flowerPath: 花びらの数だけ曲線を並べた閉じたパスになる', () => {
  const d = flowerPath(8, 44, 31);
  assert.match(d, /^M/);
  assert.match(d, /Z$/);
  // 花びら 1 枚につき 2 次ベジェ 2 本
  assert.equal((d.match(/Q/g) ?? []).length, 16);
  assert.ok(!d.includes('NaN'));
});
