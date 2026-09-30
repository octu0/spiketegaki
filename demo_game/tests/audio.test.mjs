// 曲の構成と効果音の音程 (DOM・AudioContext 無し)。
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  COMBO_SHIFT_MAX,
  CUE_NAMES,
  PROGRESSIONS,
  SECTION_A,
  SECTION_B,
  SECTION_BUILD,
  SECTION_CHORUS,
  STEPS_PER_BAR,
  Sound,
  buildCutoff,
  buildProgress,
  chordAtBar,
  chordTones,
  comboLayers,
  comboShift,
  correctNotes,
  countdownDegree,
  degreeToMidi,
  isChordTone,
  isFillBar,
  masterGain,
  melodyBar,
  musicTempo,
  nextGridTime,
  riserBars,
  sectionFor,
  sectionKey,
  snareRoll,
  stageSeed,
  tapeStopCurve
} from '../js/audio.js';

const SONG = [SECTION_A, SECTION_B, SECTION_BUILD, SECTION_CHORUS];

/** MIDI ノートが key (半音) の長音階に入っているか */
function inKey(note, key = 0) {
  const pc = (((Math.round(note) - key) % 12) + 12) % 12;
  return [0, 2, 4, 5, 7, 9, 11].includes(pc);
}

test('10 問のステージは 1〜3 問が A、4〜6 問が B、7〜9 問がビルド、10 問めがサビ', () => {
  const got = Array.from({ length: 10 }, (_, i) => sectionFor(i, 10));
  assert.deepEqual(got, ['A', 'A', 'A', 'B', 'B', 'B', 'build', 'build', 'build', 'chorus']);
});

test('セクションは問題数が違っても最終問がサビで、範囲の外は端に丸める', () => {
  assert.equal(sectionFor(0, 1), SECTION_CHORUS);
  assert.equal(sectionFor(0, 2), SECTION_A);
  assert.equal(sectionFor(1, 2), SECTION_CHORUS);
  assert.equal(sectionFor(-3, 10), SECTION_A);
  assert.equal(sectionFor(42, 10), SECTION_CHORUS);
  assert.equal(sectionFor(Number.NaN, 10), SECTION_A);
});

test('ビルドの進み具合は 7・8・9 問めで 0・1/3・2/3、ビルド以外は 0', () => {
  assert.equal(buildProgress(6, 10), 0);
  assert.ok(Math.abs(buildProgress(7, 10) - 1 / 3) < 1e-9);
  assert.ok(Math.abs(buildProgress(8, 10) - 2 / 3) < 1e-9);
  assert.equal(buildProgress(2, 10), 0);
  assert.equal(buildProgress(9, 10), 0);
});

test('テンポ: ステージ 1 は 112 + min(1,E)×16、以後はステージごとに +5 (上限 170)', () => {
  assert.equal(musicTempo(1, 0), 112);
  assert.equal(musicTempo(1, 0.5), 120);
  assert.equal(musicTempo(1, 1), 128);
  assert.equal(musicTempo(1, 1.5), 128);
  assert.equal(musicTempo(2, 1), 133);
  assert.equal(musicTempo(3, 1.2), 138);
  assert.equal(musicTempo(4, 1.5), 143);
  assert.equal(musicTempo(99, 1), 170);
  for (let s = 2; s < 9; s += 1) {
    assert.equal(musicTempo(s + 1, 1) - musicTempo(s, 1), 5);
  }
});

test('コード進行はセクションで変わる (A = I–V–vi–IV、B = vi–IV–I–V、ビルド = IV–V–iii–vi、サビ = IV–V–I–vi)', () => {
  assert.deepEqual(PROGRESSIONS[SECTION_A], [0, 4, 5, 3]);
  assert.deepEqual(PROGRESSIONS[SECTION_B], [5, 3, 0, 4]);
  assert.deepEqual(PROGRESSIONS[SECTION_BUILD], [3, 4, 2, 5]);
  assert.deepEqual(PROGRESSIONS[SECTION_CHORUS], [3, 4, 0, 5]);
  assert.equal(chordAtBar(SECTION_CHORUS, 6), 0);
  assert.equal(sectionKey(SECTION_CHORUS), 2);
  assert.equal(sectionKey(SECTION_A), 0);
});

test('どのセクションのコードの構成音もキーから外れない', () => {
  for (const section of SONG) {
    const key = sectionKey(section);
    for (let bar = 0; bar < 8; bar += 1) {
      for (const d of chordTones(chordAtBar(section, bar))) {
        for (const tonic of [36, 48, 60, 72]) {
          const note = degreeToMidi(d, key, tonic);
          assert.ok(inKey(note, key), `${section} ${bar} 小節め ${note}`);
        }
      }
    }
  }
});

test('度数から MIDI: ハ長調の C4 = 60 から 1 オクターブ、負の度数も音階の中', () => {
  assert.deepEqual([0, 1, 2, 3, 4, 5, 6, 7].map((d) => degreeToMidi(d)), [60, 62, 64, 65, 67, 69, 71, 72]);
  assert.equal(degreeToMidi(-1), 59);
  assert.equal(degreeToMidi(0, 2), 62);
  assert.ok(!inKey(61, 0));
  assert.ok(inKey(61, 2));   // D 長調の C#
});

test('正解の音は今のコードの構成音で、キーから外れない (全セクション × コンボ 0〜30)', () => {
  for (const section of SONG) {
    const key = sectionKey(section);
    for (const root of new Set(PROGRESSIONS[section])) {
      for (let combo = 0; combo <= 30; combo += 1) {
        const notes = correctNotes(root, combo, key);
        assert.equal(notes.length, 4);
        for (const n of notes) {
          assert.ok(inKey(n, key), `${section} root=${root} combo=${combo} note=${n}`);
          const pc = ((n - 60 - key) % 12 + 12) % 12;
          const degree = [0, 2, 4, 5, 7, 9, 11].indexOf(pc);
          assert.ok(isChordTone(degree, root), `構成音でない: ${n}`);
        }
        for (let i = 1; i < notes.length; i += 1) {
          assert.ok(notes[i] > notes[i - 1]);
        }
      }
    }
  }
});

test('コンボで正解の音は音階の度数で上がり (半音では上げない)、1 オクターブで頭打ち', () => {
  assert.equal(comboShift(0), 0);
  assert.equal(comboShift(1), 0);
  assert.equal(comboShift(2), 1);
  assert.equal(comboShift(8), COMBO_SHIFT_MAX);
  assert.equal(comboShift(50), COMBO_SHIFT_MAX);
  // I の和音 (C): 1 コンボは C5 から、コンボが伸びると E5, G5, C6 と構成音を上がる
  const first = [1, 2, 3, 4, 5, 6, 7, 8].map((c) => correctNotes(0, c, 0)[0]);
  assert.deepEqual(first, [72, 76, 76, 79, 79, 84, 84, 84]);
  for (let c = 2; c <= 30; c += 1) {
    assert.ok(correctNotes(0, c, 0)[0] >= correctNotes(0, c - 1, 0)[0]);
  }
  assert.ok(correctNotes(3, 8, 0)[0] > correctNotes(3, 1, 0)[0]);
  assert.deepEqual(correctNotes(0, 30, 0), correctNotes(0, 8, 0));
});

test('カウントダウンの音は数字が減るほど音階を上がる', () => {
  const notes = [5, 4, 3, 2, 1].map((n) => degreeToMidi(countdownDegree(n)));
  assert.deepEqual(notes, [72, 74, 76, 77, 79]);
  assert.equal(countdownDegree(9), countdownDegree(5));
  assert.equal(countdownDegree(0), countdownDegree(1));
});

test('コンボのレイヤー: 5 で 16 分のハイハット、10 でオープンハット + 毎拍のクラップ、20 で倍テン + リード 1 オクターブ上', () => {
  assert.deepEqual(comboLayers(0), { hat16: false, openHat: false, clapBeats: false, doubleTime: false, leadUp: false });
  assert.deepEqual(comboLayers(4), comboLayers(0));
  assert.deepEqual(comboLayers(5), { hat16: true, openHat: false, clapBeats: false, doubleTime: false, leadUp: false });
  assert.deepEqual(comboLayers(9), comboLayers(5));
  assert.deepEqual(comboLayers(10), { hat16: true, openHat: true, clapBeats: true, doubleTime: false, leadUp: false });
  assert.deepEqual(comboLayers(19), comboLayers(10));
  assert.deepEqual(comboLayers(20), { hat16: true, openHat: true, clapBeats: true, doubleTime: true, leadUp: true });
  assert.deepEqual(comboLayers(120), comboLayers(20));
});

test('量子化: 次の 16 分・拍頭・小節頭の時刻', () => {
  const step = 60 / 120 / 4;   // 120 BPM の 16 分 = 0.125 秒
  assert.equal(nextGridTime(1.0, 1.0, step), 1.0);
  assert.equal(nextGridTime(1.01, 1.0, step), 1.125);
  assert.equal(nextGridTime(1.124, 1.0, step), 1.125);
  assert.equal(nextGridTime(1.3, 1.0, step * 4), 1.5);
  assert.equal(nextGridTime(1.3, 1.0, step * STEPS_PER_BAR), 3.0);
  assert.ok(Math.abs(nextGridTime(3.2, 1.0, step) - 3.25) < 1e-9);
  // 小節頭より前の時刻も同じ格子で探す
  assert.ok(Math.abs(nextGridTime(0.8, 1.0, step) - 0.875) < 1e-9);
  assert.equal(nextGridTime(0.9, 1.0, step), 1.0);
  assert.equal(nextGridTime(2, 1, 0), 2);
});

test('ビルド: スネアの連打は 8 分 -> 16 分へ密になり、ローパスは開いていく', () => {
  // 1 問め: 4 小節の後半だけ 8 分、3 問め: 後半は 16 分
  assert.deepEqual([0, 1, 2, 3].map((b) => snareRoll(0, b)), [0, 0, 2, 2]);
  assert.deepEqual([0, 1, 2, 3].map((b) => snareRoll(1 / 3, b)), [0, 2, 2, 4]);
  assert.deepEqual([0, 1, 2, 3].map((b) => snareRoll(2 / 3, b)), [2, 2, 4, 4]);
  let prev = 0;
  for (const p of [0, 1 / 3, 2 / 3]) {
    for (let bar = 0; bar < 4; bar += 1) {
      for (const at of [0, 0.5, 1]) {
        const f = buildCutoff(p, bar, at);
        assert.ok(f >= prev, `p=${p} bar=${bar} at=${at}`);
        prev = f;
      }
    }
  }
  assert.ok(Math.abs(buildCutoff(2 / 3, 3, 1) - 18000) < 1e-6);
  assert.deepEqual([0, 1, 2, 3].map((b) => riserBars(0, b)), [0, 0, 0, 1]);
  assert.deepEqual([4, 5, 6, 7].map((b) => riserBars(1 / 3, b)), [0, 0, 2, 0]);
  assert.deepEqual([0, 1, 2, 3].map((b) => riserBars(2 / 3, b)), [4, 0, 0, 0]);
});

test('ドラムフィルは 8 小節ごと', () => {
  assert.deepEqual(Array.from({ length: 17 }, (_, b) => b).filter(isFillBar), [7, 15]);
});

test('旋律はキーの中の音だけで、拍頭は構成音、16 分の格子に収まる', () => {
  for (const stage of [1, 2, 3]) {
    const seed = stageSeed(stage);
    for (const section of SONG) {
      for (let bar = 0; bar < 32; bar += 1) {
        const root = chordAtBar(section, bar);
        for (const e of melodyBar(seed, section, bar)) {
          assert.ok(Number.isInteger(e.step) && e.step >= 0 && e.step < STEPS_PER_BAR);
          assert.ok(e.len >= 1 && e.step + e.len <= STEPS_PER_BAR);
          assert.ok(inKey(degreeToMidi(e.degree, sectionKey(section), 72), sectionKey(section)));
          if (e.step % 4 === 0) {
            assert.ok(isChordTone(e.degree, root), `stage ${stage} ${section} bar ${bar} step ${e.step}`);
          }
        }
      }
    }
  }
});

/** 32 小節の旋律を 4 小節ずつ区切り、前に出たものと同じ区切りの数 */
function repeatedWindows(seed, section) {
  const windows = [];
  for (let w = 0; w < 8; w += 1) {
    const bars = [];
    for (let b = w * 4; b < w * 4 + 4; b += 1) {
      bars.push(melodyBar(seed, section, b).map((e) => `${e.step}:${e.len}:${e.degree}`).join(','));
    }
    windows.push(bars.join('|'));
  }
  return windows.filter((w, i) => windows.indexOf(w) < i).length;
}

test('旋律は同じ 4 小節をそのまま繰り返さず、ステージで変奏が変わる', () => {
  for (const stage of [1, 2, 3, 4]) {
    for (const section of SONG) {
      assert.equal(repeatedWindows(stageSeed(stage), section), 0, `stage ${stage} ${section}`);
    }
  }
  const a = JSON.stringify(Array.from({ length: 8 }, (_, b) => melodyBar(stageSeed(1), SECTION_CHORUS, b)));
  const b = JSON.stringify(Array.from({ length: 8 }, (_, b2) => melodyBar(stageSeed(2), SECTION_CHORUS, b2)));
  assert.notEqual(a, b);
  // 同じ seed なら同じ旋律 (描画し直しても変わらない)
  assert.deepEqual(melodyBar(stageSeed(1), SECTION_B, 5), melodyBar(stageSeed(1), SECTION_B, 5));
});

test('テープストップの遅延は t²/2D: 0 から D/2 へ増え、傾き (再生速度の落ち幅) は 0 -> 1', () => {
  const c = tapeStopCurve(1, 101);
  assert.equal(c[0], 0);
  assert.ok(Math.abs(c[100] - 0.5) < 1e-6);
  for (let i = 1; i < c.length; i += 1) {
    assert.ok(c[i] > c[i - 1]);
  }
  const slopeStart = (c[1] - c[0]) / 0.01;
  const slopeEnd = (c[100] - c[99]) / 0.01;
  assert.ok(slopeStart < 0.02);
  assert.ok(slopeEnd > 0.98 && slopeEnd <= 1.0 + 1e-6);
});

test('cue の名前は契約どおり。知らない名前は警告して無視し、例外を投げない', () => {
  assert.deepEqual(CUE_NAMES, [
    'correct', 'close', 'wrong', 'lifeLost', 'timeout', 'safe', 'countdown', 'lastProblem',
    'stageClear', 'comboMilestone', 'dopaMilestone', 'gameOver', 'retry', 'whoosh', 'blip'
  ]);
  const sound = new Sound();
  const warned = [];
  const original = console.warn;
  console.warn = (...args) => warned.push(args.join(' '));
  try {
    sound.cue('fanfare9000');
    sound.cue(undefined);
    for (const name of CUE_NAMES) {
      sound.cue(name, {});   // 音を始める前は何もしない
    }
  } finally {
    console.warn = original;
  }
  assert.equal(warned.length, 2);
  assert.match(warned[0], /fanfare9000/);
});

test('旧 API (個別の効果音メソッドと setTempo) は無い', () => {
  const sound = new Sound();
  for (const name of ['correct', 'close', 'wrong', 'comboFanfare', 'milestone', 'blip', 'finale', 'setTempo']) {
    assert.equal(typeof sound[name], 'undefined', name);
  }
  for (const name of ['ensureStarted', 'setEnabled', 'setVolume', 'startMusic', 'stopMusic', 'setProgress', 'cue']) {
    assert.equal(typeof sound[name], 'function', name);
  }
  assert.equal(masterGain(50), 0.425);
  assert.equal(masterGain(80, false), 0);
});

test('setProgress は欠けた値を前の値のまま残し、範囲の外を丸める', () => {
  const sound = new Sound();
  sound.setProgress({ stage: 2, index: 3, total: 10, combo: 7, lives: 2, intensity: 1.1 });
  sound.setProgress({ index: 4 });
  assert.deepEqual(sound.progress, { stage: 2, index: 4, total: 10, combo: 7, lives: 2, intensity: 1.1 });
  sound.setProgress({ stage: 0, index: -2, combo: -1 });
  assert.equal(sound.progress.stage, 1);
  assert.equal(sound.progress.index, 0);
  assert.equal(sound.progress.combo, 0);
});
