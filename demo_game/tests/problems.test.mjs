// 出題データとラウンド生成 (DOM 無し)。
import test from 'node:test';
import assert from 'node:assert/strict';

import { BLANK, PROBLEMS, blankedWord, makeRound, pickExtra } from '../js/problems.js';

// 小学 1 年の 80 字 (出題データと同じ集合・同じ並び)
const GRADE1 = '一右雨円王音下火花貝学気九休玉金空月犬見五口校左三山子四糸字耳七車手十出女小上森人水正生青夕石赤千川先早草足村大男竹中虫町天田土二日入年白八百文木本名目立力林六';

test('80 字が揃っていて重複が無い', () => {
  const expected = [...GRADE1];
  assert.equal(expected.length, 80);
  assert.equal(PROBLEMS.length, 80);
  const kanji = PROBLEMS.map((p) => p.kanji);
  assert.equal(new Set(kanji).size, 80, '重複がある');
  assert.deepEqual(kanji, expected, '字と並びが小学 1 年の 80 字と一致する');
});

test('各問題に読み・例語・例語の読みがある', () => {
  for (const p of PROBLEMS) {
    assert.ok(p.reading.length > 0, `${p.kanji} の読みが空`);
    assert.ok(p.word.length > 0, `${p.kanji} の例語が空`);
    assert.ok(p.wordReading.length > 0, `${p.kanji} の例語の読みが空`);
    // 読みはひらがなだけ (対象字を読みに混ぜない)
    assert.match(p.reading, /^[ぁ-ん]+$/u, `${p.kanji} の読み: ${p.reading}`);
    assert.match(p.wordReading, /^[ぁ-んー]+$/u, `${p.kanji} の例語の読み: ${p.wordReading}`);
  }
});

test('例語は対象字をちょうど 1 か所だけ含む', () => {
  for (const p of PROBLEMS) {
    const count = [...p.word].filter((ch) => ch === p.kanji).length;
    assert.equal(count, 1, `${p.kanji} が ${p.word} に ${count} 回`);
  }
});

test('例語は対象字いがいに漢字を含まない (ほかの字はひらがな)', () => {
  const han = /\p{Script=Han}/u;
  for (const p of PROBLEMS) {
    const others = [...p.word].filter((ch) => ch !== p.kanji && han.test(ch));
    assert.deepEqual(others, [], `${p.word} に ${p.kanji} いがいの漢字がある`);
  }
});

test('よみは例語の読みの中にそのまま現れる (手がかりになる)', () => {
  for (const p of PROBLEMS) {
    assert.ok(
      p.wordReading.includes(p.reading),
      `${p.kanji} の よみ ${p.reading} が ${p.word} (${p.wordReading}) に現れない`
    );
  }
});

test('空欄化は対象字の位置だけを □ にする', () => {
  for (const p of PROBLEMS) {
    const blanked = blankedWord(p);
    assert.equal(blanked.length, p.word.length, `${p.word} の長さが変わった`);
    assert.equal(blanked.indexOf(BLANK), p.word.indexOf(p.kanji), `${p.word} の空欄の位置`);
    assert.ok(!blanked.includes(p.kanji), `${p.word} に対象字が残っている`);
    // □ を対象字に戻すと元の例語になる
    assert.equal(blanked.split(BLANK).join(p.kanji), p.word);
  }
});

test('ラウンドは 10 問・重複なし', () => {
  for (let trial = 0; trial < 50; trial += 1) {
    const round = makeRound(10);
    assert.equal(round.length, 10);
    assert.equal(new Set(round.map((p) => p.kanji)).size, 10, '同じ字が 2 回出た');
    for (const p of round) {
      assert.ok(PROBLEMS.includes(p), `${p.kanji} が出題データに無い`);
    }
  }
});

test('ラウンドは乱数が決まれば決まる (テストで固定できる)', () => {
  const fixed = () => 0;
  assert.deepEqual(
    makeRound(5, fixed).map((p) => p.kanji),
    ['一', '右', '雨', '円', '王'],
    '常に先頭を引く乱数なら前から 5 字'
  );
  const last = () => 0.999999;
  assert.deepEqual(
    makeRound(3, last).map((p) => p.kanji),
    ['六', '林', '力'],
    '常に末尾を引く乱数なら後ろから 3 字'
  );
});

test('ラウンドは 80 問までしか作れない (重複なしのため)', () => {
  assert.equal(makeRound(200).length, 80);
});

test('エクストラは直前 10 問を避ける', () => {
  const recent = PROBLEMS.slice(0, 10);
  for (let trial = 0; trial < 200; trial += 1) {
    const next = pickExtra(recent);
    assert.ok(!recent.includes(next), `${next.kanji} が直前 10 問と重なった`);
  }
  // 避ける数を超えた古い問題はまた出てよい
  const many = PROBLEMS.slice(0, 20);
  const avoided = new Set(many.slice(-10).map((p) => p.kanji));
  for (let trial = 0; trial < 200; trial += 1) {
    assert.ok(!avoided.has(pickExtra(many).kanji));
  }
});

test('エクストラは避ける先が無くなっても 1 問返す', () => {
  const next = pickExtra(PROBLEMS, () => 0, 80);
  assert.ok(PROBLEMS.includes(next));
});
