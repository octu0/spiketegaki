// 出題データとラウンド生成 (DOM 無し)。
import test from 'node:test';
import assert from 'node:assert/strict';

import { BLANK, LAP_AVOID, PROBLEMS, REPEAT_GAP, REVIEW_CHANCE, blankedWord, pickProblem, problemOf } from '../js/problems.js';

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

const ALL = PROBLEMS.map((p) => p.kanji);
const none = { solved: new Set(), review: [], recent: [] };

test('pickProblem: 正解済みの字は出さない', () => {
  const solved = new Set(ALL.slice(0, 79));
  for (let trial = 0; trial < 50; trial += 1) {
    assert.equal(pickProblem({ ...none, solved }).kanji, ALL[79]);
  }
  for (let trial = 0; trial < 200; trial += 1) {
    const solvedHalf = new Set(ALL.slice(0, 40));
    assert.ok(!solvedHalf.has(pickProblem({ ...none, solved: solvedHalf }).kanji));
  }
});

test('pickProblem: 乱数が決まれば決まる (テストで固定できる)', () => {
  assert.equal(pickProblem(none, () => 0).kanji, '一', '常に先頭を引く乱数なら先頭');
  assert.equal(pickProblem(none, () => 0.999999).kanji, '六', '常に末尾を引く乱数なら末尾');
});

test(`pickProblem: 復習の字は ${REPEAT_GAP} 問挟むまで出さず、挟んだら REVIEW_CHANCE で優先する`, () => {
  assert.equal(REPEAT_GAP, 3);
  const review = ['山'];
  // 直前 3 問に出ていると選べない
  for (const recent of [['山'], ['山', '一'], ['山', '一', '右']]) {
    for (let trial = 0; trial < 50; trial += 1) {
      assert.notEqual(pickProblem({ ...none, review, recent }).kanji, '山', JSON.stringify(recent));
    }
  }
  const recent = ['山', '一', '右', '雨'];
  assert.equal(pickProblem({ ...none, review, recent }, () => 0).kanji, '山', '乱数 < REVIEW_CHANCE なら復習');
  assert.notEqual(pickProblem({ ...none, review, recent }, () => REVIEW_CHANCE).kanji, '山', 'それ以外はまだ出していない字');
  // まだ出していない字が無ければ必ず復習
  const solved = new Set(ALL.filter((k) => k !== '山'));
  assert.equal(pickProblem({ solved, review, recent }, () => 0.99).kanji, '山');
});

test(`pickProblem: 復習でない字は直前 ${LAP_AVOID} 問に出ていれば避ける (2 周目の始まり)`, () => {
  assert.equal(LAP_AVOID, 10);
  const recent = ALL.slice(0, 10);
  for (let trial = 0; trial < 200; trial += 1) {
    assert.ok(!recent.includes(pickProblem({ ...none, recent }).kanji));
  }
});

test('pickProblem: 残りがみな最近出たばかりなら、いちばん前に出した字を選ぶ', () => {
  const solved = new Set(ALL.filter((k) => k !== '山' && k !== '川'));
  const recent = ['川', '一', '山'];
  assert.equal(pickProblem({ solved, review: ['山', '川'], recent }, () => 0).kanji, '川');
  assert.equal(pickProblem({ solved, review: [], recent: ['一', '川'] }, () => 0).kanji, '山', '出していない字を先に');
});

test('problemOf: 字から問題を引く。無ければ null', () => {
  assert.equal(problemOf('山'), PROBLEMS.find((p) => p.kanji === '山'));
  assert.equal(problemOf('鬱'), null);
  assert.equal(problemOf(''), null);
});
