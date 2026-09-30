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

test('spiralPaths: 渦巻きを色の数だけのパスに分け、内側から外へ広がる', async () => {
  const { spiralPaths } = await import('../js/fx.js');
  const paths = spiralPaths(3, 7, 44);
  assert.equal(paths.length, 7);
  const radius = (d, which) => {
    const nums = d.match(/-?\d+(\.\d+)?/g).map(Number);
    const i = which === 'first' ? 0 : nums.length - 2;
    return Math.hypot(nums[i] - 50, nums[i + 1] - 50);
  };
  for (const d of paths) {
    assert.match(d, /^M/);
    assert.ok(!d.includes('NaN'));
  }
  assert.ok(radius(paths[0], 'first') < 5);
  assert.ok(Math.abs(radius(paths[6], 'last') - 44) < 1e-6);
  // 隣のパスとつながっている (前の終点 = 次の始点)
  for (let i = 1; i < paths.length; i += 1) {
    const end = paths[i - 1].match(/L(-?[\d.]+) (-?[\d.]+)$/);
    const start = paths[i].match(/^M(-?[\d.]+) (-?[\d.]+)/);
    assert.deepEqual([end[1], end[2]], [start[1], start[2]]);
  }
});

test('walkPath: 歩く観客の道は筆記領域の外 (左右の余白の真ん中と帯の床) だけを通る', async () => {
  const { walkPath, pathPoint } = await import('../js/crowd.js');
  const layout = {
    w: 375, h: 667,
    pad: { x: 36, y: 286, w: 303, h: 303 },
    band: { x: 16, y: 82, w: 343, h: 38 }
  };
  const path = walkPath(layout);
  assert.equal(path.left, 18);
  assert.equal(path.right, 357);
  assert.equal(path.length, path.column * 2 + path.span);
  for (let pos = 0; pos <= path.length; pos += 5) {
    const p = pathPoint(path, pos);
    const inside = p.x > layout.pad.x && p.x < layout.pad.x + layout.pad.w
      && p.y > layout.pad.y && p.y < layout.pad.y + layout.pad.h;
    assert.ok(!inside, `pos ${pos} (${p.x}, ${p.y}) が枠の中`);
  }
  // 端はつながったコの字
  assert.deepEqual(pathPoint(path, 0), { x: 18, y: 589 });
  assert.deepEqual(pathPoint(path, path.length), { x: 357, y: 589 });
  assert.equal(walkPath({ ...layout, pad: null }), null);
});
