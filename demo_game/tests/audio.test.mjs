// マスターの利得 (音量スライダー + 「おと」)。Web Audio は使わないので node でそのまま試せる。
import test from 'node:test';
import assert from 'node:assert/strict';

import { MASTER_GAIN, masterGain } from '../js/audio.js';

test('masterGain: 音量に比例する。既定の 50 は最大の半分', () => {
  assert.equal(masterGain(100, true), MASTER_GAIN);
  assert.equal(masterGain(50, true), 0.425);
  assert.equal(masterGain(50, true), MASTER_GAIN * 0.5);
  assert.equal(masterGain(0, true), 0);
});

test('masterGain: 「おと」を切ったら音量に関わらず 0', () => {
  assert.equal(masterGain(100, false), 0);
  assert.equal(masterGain(50, false), 0);
  assert.equal(masterGain(0, false), 0);
});

test('masterGain: 範囲外と壊れた値は切り詰める', () => {
  assert.equal(masterGain(140, true), MASTER_GAIN);
  assert.equal(masterGain(-20, true), 0);
  assert.equal(masterGain(Number.NaN, true), MASTER_GAIN);
  assert.equal(masterGain(undefined, true), MASTER_GAIN);
});

test('Sound: setVolume は開始前でも覚えておく', async () => {
  const { Sound } = await import('../js/audio.js');
  const sound = new Sound();
  sound.setVolume(30);
  assert.equal(sound.volume, 30);
  sound.setVolume(500);
  assert.equal(sound.volume, 100);
  sound.setVolume(Number.NaN);
  assert.equal(sound.volume, 100);
});
