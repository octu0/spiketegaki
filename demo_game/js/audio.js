// Web Audio の発振器とノイズだけで組み立てる BGM と効果音。外部の音源は読み込まない。
//
// 音源は 4 種類の合成音 (FM の鍵盤、鋸歯 2 本のパッド、三角 + サブの低音、ノイズの打楽器) で、
// どれも GainNode の ADSR を通る。マスターにコンプレッサー、生成したインパルス応答の
// リバーブを send/return で薄く、旋律には 8 分のディレイを掛ける。
//
// BGM は 4 小節 (8 分音符 32 個) のループを 1 音ずつ先読みして鳴らす。コード進行は I–V–vi–IV。
// テンポ・移調・レイヤーの数は呼び出し側 (強度 E から計算) が setTempo で変える。
//
// AudioContext はブラウザの制約で最初のユーザー操作のときにしか始められない。
// その resume() は解決しないことがあるので、呼び出し側は待たずに投げっぱなしにする。
// 開始を待つ必要のある操作 (音量・BGM の開始) は whenStarted でこちらが待つ。

const LOOKAHEAD_MS = 25;      // スケジューラを回す間隔
const SCHEDULE_AHEAD = 0.14;  // 先読みする秒数

const STEPS_PER_BAR = 8;                  // 1 小節 = 8 分音符 8 個
const BARS = 4;                           // ループの長さ
const STEPS = BARS * STEPS_PER_BAR;       // 32

/** レイヤーを足す強度 E のしきい値 */
const ARPEGGIO_FROM = 0.3;
const FULL_FROM = 0.6;

/**
 * コード進行 I–V–vi–IV (ハ長調)。MIDI ノート番号。
 * bass は低音の根音、chord は和音の構成音 (低い順)。
 */
const PROGRESSION = [
  { bass: 36, chord: [60, 64, 67, 72] },  // C
  { bass: 43, chord: [59, 62, 67, 71] },  // G
  { bass: 45, chord: [57, 60, 64, 69] },  // Am
  { bass: 41, chord: [57, 60, 65, 69] }   // F
];

/** 旋律 (8 分音符 32 個、MIDI ノート番号。null は休み)。裏拍に入るシンコペーション */
const MELODY = [
  72, null, 76, 79, null, 76, 74, null,
  79, null, 78, 74, null, 71, 74, null,
  76, null, 81, 79, null, 76, 72, null,
  81, null, 79, 77, null, 76, 74, null
];

/** 低音の 1 小節ぶん。0 = 根音、7 = 5 度、null = 休み */
const BASS_PATTERN = [0, null, null, 0, null, 7, null, null];
/** 打楽器の 1 小節ぶん (8 分音符の位置) */
const KICK_STEPS = [0, 3, 4];
const SNARE_STEPS = [2, 6];
/** 強度が高いときにオープンハットにする位置 */
const OPEN_HAT_STEP = 7;

function midiToFreq(note) {
  return 440 * Math.pow(2, (note - 69) / 12);
}

/** 音量を最大にしたときのマスターの利得 */
export const MASTER_GAIN = 0.85;

/**
 * マスターの利得。音量スライダー (0〜100) に比例させ、「おと」を切ったら 0 にする。
 * 既定の 50 では 0.85 * 0.5 = 0.425。
 *
 * @param {number} volume 0〜100
 * @param {boolean} enabled 「おと」が入っているか
 */
export function masterGain(volume, enabled = true) {
  if (!enabled) {
    return 0;
  }
  const v = Number.isFinite(volume) ? Math.min(100, Math.max(0, volume)) : 100;
  return MASTER_GAIN * (v / 100);
}

export class Sound {
  /**
   * @param {object} options
   * @param {BaseAudioContext} options.context 使う AudioContext。省略すると最初の操作で作る
   *   (検証では OfflineAudioContext を渡して同じ生成コードを描画する)
   */
  constructor({ context = null } = {}) {
    this.given = context;
    this.ctx = null;
    this.master = null;
    this.musicGain = null;
    this.sfxGain = null;
    this.melodyBus = null;
    this.reverbSend = null;
    this.noiseBuffer = null;
    this.enabled = true;
    this.volume = 100;      // 0〜100。呼び出し側が setVolume で保存値に合わせる
    this.starting = null;   // ensureStarted の Promise (1 回だけ作る)
    this.wantsMusic = false;
    this.playing = false;
    this.tempo = 112;
    this.transpose = 0;
    this.intensity = 0.5;
    this.step = 0;
    this.nextTime = 0;
    this.timer = 0;
  }

  /**
   * 最初のユーザー操作から呼ぶ。待たなくてよい (2 回目以降は同じ Promise を返す)。
   * 音を始められなくても呼び出し側が止まらないよう、失敗は false に畳む。
   */
  ensureStarted() {
    if (this.starting === null) {
      this.starting = this.open().catch(() => false);
    }
    return this.starting;
  }

  async open() {
    if (this.ctx === null) {
      if (this.given !== null) {
        this.ctx = this.given;
      } else {
        const Ctor = window.AudioContext || window.webkitAudioContext;
        if (Ctor === undefined) {
          return false;
        }
        this.ctx = new Ctor();
      }
      this.build();
    }
    // オフライン描画の context は startRendering まで suspended のままなので resume しない
    if (this.ctx.state === 'suspended' && typeof this.ctx.startRendering !== 'function') {
      await this.ctx.resume();
    }
    return true;
  }

  /** 音の通り道を組み立てる。context ごとに 1 回だけ */
  build() {
    const ctx = this.ctx;

    // マスター: 音量 -> コンプレッサー -> 出力
    const comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -14;
    comp.knee.value = 14;
    comp.ratio.value = 6;
    comp.attack.value = 0.004;
    comp.release.value = 0.14;
    comp.connect(ctx.destination);

    this.master = ctx.createGain();
    this.master.gain.value = masterGain(this.volume, this.enabled);
    this.master.connect(comp);

    this.musicGain = ctx.createGain();
    this.musicGain.gain.value = 0.34;
    this.musicGain.connect(this.master);

    this.sfxGain = ctx.createGain();
    this.sfxGain.gain.value = 0.5;
    this.sfxGain.connect(this.master);

    // リバーブ (send/return)。インパルスは減衰ノイズをその場で作る
    const convolver = ctx.createConvolver();
    convolver.buffer = this.impulse(1.4);
    this.reverbSend = ctx.createGain();
    this.reverbSend.gain.value = 1;
    this.reverbSend.connect(convolver);
    const wet = ctx.createGain();
    wet.gain.value = 0.22;
    convolver.connect(wet);
    wet.connect(this.master);

    // 旋律のディレイ (1/8 拍ぶん。テンポが変わっても違和感が出ない程度に固定)
    this.melodyBus = ctx.createGain();
    this.melodyBus.gain.value = 1;
    this.melodyBus.connect(this.musicGain);
    const delay = ctx.createDelay(1);
    delay.delayTime.value = 0.26;
    const feedback = ctx.createGain();
    feedback.gain.value = 0.25;
    const delayOut = ctx.createGain();
    delayOut.gain.value = 0.3;
    this.melodyBus.connect(delay);
    delay.connect(feedback);
    feedback.connect(delay);
    delay.connect(delayOut);
    delayOut.connect(this.musicGain);

    // 打楽器のノイズは 1 回だけ作って使い回す
    const frames = Math.floor(ctx.sampleRate * 1.0);
    this.noiseBuffer = ctx.createBuffer(1, frames, ctx.sampleRate);
    const data = this.noiseBuffer.getChannelData(0);
    for (let i = 0; i < frames; i += 1) {
      data[i] = Math.random() * 2 - 1;
    }
  }

  /** 減衰ノイズのインパルス応答 (ステレオ) */
  impulse(seconds) {
    const frames = Math.floor(this.ctx.sampleRate * seconds);
    const buffer = this.ctx.createBuffer(2, frames, this.ctx.sampleRate);
    for (let c = 0; c < 2; c += 1) {
      const data = buffer.getChannelData(c);
      for (let i = 0; i < frames; i += 1) {
        data[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / frames, 2.6);
      }
    }
    return buffer;
  }

  /** 音を始めたあとに action を動かす。まだ始めていなければ何もしない */
  whenStarted(action) {
    if (this.starting === null) {
      return;
    }
    this.starting.then(() => {
      if (this.ctx !== null) {
        action();
      }
    });
  }

  setEnabled(on) {
    this.enabled = on;
    this.applyGain();
  }

  /** 音量 (0〜100)。「おと」を切っているあいだは反映しても 0 のまま */
  setVolume(volume) {
    this.volume = Number.isFinite(volume) ? Math.min(100, Math.max(0, volume)) : this.volume;
    this.applyGain();
  }

  /** 今の音量と「おと」をマスターに反映する。開始前でも build() が同じ式で読む */
  applyGain() {
    this.whenStarted(() => {
      this.master.gain.setTargetAtTime(masterGain(this.volume, this.enabled), this.ctx.currentTime, 0.02);
    });
  }

  /**
   * BGM のテンポ (BPM)、移調 (半音)、レイヤーを決める強度 E。
   * E < 0.3 は打楽器 + 低音 + 旋律、0.3 以上でアルペジオ、0.6 以上でパッドと対旋律が加わる。
   */
  setTempo(bpm, transpose = 0, intensity = 0.5) {
    this.tempo = bpm;
    this.transpose = transpose;
    this.intensity = intensity;
  }

  startMusic() {
    this.wantsMusic = true;
    this.whenStarted(() => this.runScheduler());
  }

  stopMusic() {
    this.wantsMusic = false;
    this.playing = false;
    window.clearInterval(this.timer);
    this.timer = 0;
  }

  /** 音が始まってから呼ばれる。待っている間に stopMusic されていたら鳴らさない */
  runScheduler() {
    if (!this.wantsMusic || this.playing) {
      return;
    }
    this.playing = true;
    this.beginMusic(this.ctx.currentTime + 0.08);
    this.timer = window.setInterval(() => {
      if (this.playing) {
        this.pump(this.ctx.currentTime + SCHEDULE_AHEAD);
      }
    }, LOOKAHEAD_MS);
  }

  /** ループを startTime から鳴らし始める */
  beginMusic(startTime) {
    this.step = 0;
    this.nextTime = startTime;
  }

  /** until 秒までの音を先に予約する */
  pump(until) {
    const eighth = 30 / this.tempo;   // (60 / tempo) / 2
    while (this.nextTime < until) {
      this.playStep(this.step % STEPS, this.nextTime, eighth);
      this.step += 1;
      this.nextTime += eighth;
    }
  }

  /** ループの step 番目 (8 分音符) を time に鳴らす */
  playStep(step, time, eighth) {
    if (this.ctx === null) {
      return;
    }
    const e = this.intensity;
    const bar = PROGRESSION[Math.floor(step / STEPS_PER_BAR) % BARS];
    const inBar = step % STEPS_PER_BAR;
    const tr = this.transpose;

    // 打楽器
    if (KICK_STEPS.includes(inBar)) {
      this.kick(time);
    }
    if (SNARE_STEPS.includes(inBar)) {
      this.snare(time);
    }
    if (e >= FULL_FROM && inBar === OPEN_HAT_STEP) {
      this.hat(time, 0.12, 0.07);
    } else {
      this.hat(time, 0.03, inBar % 2 === 0 ? 0.09 : 0.055);
    }

    // 低音
    const bassStep = BASS_PATTERN[inBar];
    if (bassStep !== null) {
      this.bassVoice(time, midiToFreq(bar.bass + bassStep + tr), eighth * 2.2, 0.30);
    }

    // 旋律 (ディレイ付きのバスへ)
    const note = MELODY[step];
    if (note !== null) {
      this.keyVoice(time, midiToFreq(note + tr), eighth * 1.8, 0.26, this.melodyBus, 0.18);
    }

    // アルペジオ
    if (e >= ARPEGGIO_FROM) {
      const arp = bar.chord[(step * 3) % bar.chord.length] + 12;
      this.keyVoice(time, midiToFreq(arp + tr), eighth * 0.9, 0.09, this.musicGain, 0.24);
    }

    // パッドと対旋律
    if (e >= FULL_FROM) {
      if (inBar === 0) {
        for (const n of bar.chord) {
          this.padVoice(time, midiToFreq(n + tr - 12), eighth * 8, 0.055);
        }
      }
      if (inBar === 0 || inBar === 4) {
        const counter = bar.chord[inBar === 0 ? 1 : 2] - 12;
        this.keyVoice(time + eighth * 0.5, midiToFreq(counter + tr), eighth * 2.4, 0.10, this.musicGain, 0.2);
      }
    }
  }

  // MARK: - 音源

  /** リバーブへ送る枝を足す */
  send(node, amount) {
    if (amount <= 0) {
      return;
    }
    const g = this.ctx.createGain();
    g.gain.value = amount;
    node.connect(g);
    g.connect(this.reverbSend);
  }

  /**
   * FM の鍵盤 (マリンバ / エレピ風)。キャリア sine をモジュレーター sine で揺らし、
   * 変調量を速く減衰させて硬い立ち上がりを作る。キャリアは 2 本を微デチューンする。
   */
  keyVoice(time, freq, duration, gain, destination, reverb = 0.15) {
    if (this.ctx === null || !Number.isFinite(freq)) {
      return;
    }
    const ctx = this.ctx;
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, time);
    env.gain.linearRampToValueAtTime(gain, time + 0.006);
    env.gain.exponentialRampToValueAtTime(Math.max(0.0001, gain * 0.25), time + duration * 0.35);
    env.gain.exponentialRampToValueAtTime(0.0001, time + duration);

    const mod = ctx.createOscillator();
    mod.type = 'sine';
    mod.frequency.setValueAtTime(freq * 2, time);
    const modGain = ctx.createGain();
    modGain.gain.setValueAtTime(freq * 2.2, time);
    modGain.gain.exponentialRampToValueAtTime(freq * 0.02, time + Math.min(0.22, duration));
    mod.connect(modGain);

    for (const cents of [-6, 6]) {
      const carrier = ctx.createOscillator();
      carrier.type = 'sine';
      carrier.frequency.setValueAtTime(freq, time);
      carrier.detune.setValueAtTime(cents, time);
      modGain.connect(carrier.frequency);
      carrier.connect(env);
      carrier.start(time);
      carrier.stop(time + duration + 0.05);
    }
    mod.start(time);
    mod.stop(time + duration + 0.05);

    env.connect(destination ?? this.musicGain);
    this.send(env, reverb);
  }

  /** パッド。鋸歯 2 本を微デチューンしてローパス (周波数エンベロープ付き) に通す */
  padVoice(time, freq, duration, gain) {
    if (this.ctx === null || !Number.isFinite(freq)) {
      return;
    }
    const ctx = this.ctx;
    const filter = ctx.createBiquadFilter();
    filter.type = 'lowpass';
    filter.Q.value = 0.8;
    filter.frequency.setValueAtTime(Math.max(200, freq * 1.5), time);
    filter.frequency.linearRampToValueAtTime(Math.max(600, freq * 6), time + duration * 0.3);
    filter.frequency.linearRampToValueAtTime(Math.max(300, freq * 2), time + duration);

    const env = ctx.createGain();
    env.gain.setValueAtTime(0, time);
    env.gain.linearRampToValueAtTime(gain, time + duration * 0.18);
    env.gain.setTargetAtTime(gain * 0.7, time + duration * 0.2, duration * 0.3);
    env.gain.linearRampToValueAtTime(0, time + duration);

    for (const cents of [-8, 8]) {
      const osc = ctx.createOscillator();
      osc.type = 'sawtooth';
      osc.frequency.setValueAtTime(freq, time);
      osc.detune.setValueAtTime(cents, time);
      osc.connect(filter);
      osc.start(time);
      osc.stop(time + duration + 0.05);
    }
    filter.connect(env);
    env.connect(this.musicGain);
    this.send(env, 0.35);
  }

  /** 低音。三角波にサブの sine (1 オクターブ下) を重ねる */
  bassVoice(time, freq, duration, gain) {
    if (this.ctx === null || !Number.isFinite(freq)) {
      return;
    }
    const ctx = this.ctx;
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, time);
    env.gain.linearRampToValueAtTime(gain, time + 0.014);
    env.gain.setTargetAtTime(gain * 0.55, time + 0.02, duration * 0.25);
    env.gain.exponentialRampToValueAtTime(0.0001, time + duration);

    const tri = ctx.createOscillator();
    tri.type = 'triangle';
    tri.frequency.setValueAtTime(freq, time);
    tri.connect(env);
    tri.start(time);
    tri.stop(time + duration + 0.05);

    const sub = ctx.createOscillator();
    const subGain = ctx.createGain();
    subGain.gain.value = 0.6;
    sub.type = 'sine';
    sub.frequency.setValueAtTime(freq / 2, time);
    sub.connect(subGain);
    subGain.connect(env);
    sub.start(time);
    sub.stop(time + duration + 0.05);

    env.connect(this.musicGain);
  }

  /** 使い回しのノイズをフィルターに通して鳴らす */
  noise(time, duration, gain, type, frequency, q, destination) {
    if (this.ctx === null || this.noiseBuffer === null) {
      return;
    }
    const ctx = this.ctx;
    const src = ctx.createBufferSource();
    src.buffer = this.noiseBuffer;
    src.loop = true;
    const filter = ctx.createBiquadFilter();
    filter.type = type;
    filter.frequency.value = frequency;
    filter.Q.value = q;
    const env = ctx.createGain();
    env.gain.setValueAtTime(gain, time);
    env.gain.exponentialRampToValueAtTime(0.0001, time + duration);
    src.connect(filter);
    filter.connect(env);
    env.connect(destination ?? this.musicGain);
    src.start(time, Math.random() * 0.5);
    src.stop(time + duration + 0.02);
  }

  /** キック: sine のピッチスイープ (150 -> 50 Hz、100 ms) にクリックを足す */
  kick(time) {
    if (this.ctx === null) {
      return;
    }
    const ctx = this.ctx;
    const osc = ctx.createOscillator();
    const env = ctx.createGain();
    osc.type = 'sine';
    osc.frequency.setValueAtTime(150, time);
    osc.frequency.exponentialRampToValueAtTime(50, time + 0.10);
    env.gain.setValueAtTime(0, time);
    env.gain.linearRampToValueAtTime(0.62, time + 0.004);
    env.gain.exponentialRampToValueAtTime(0.0001, time + 0.24);
    osc.connect(env);
    env.connect(this.musicGain);
    osc.start(time);
    osc.stop(time + 0.26);
    this.noise(time, 0.012, 0.16, 'highpass', 2200, 0.7);
  }

  /** スネア: ノイズ (バンドパス 1.8 kHz) に 200 Hz の短い音を足す */
  snare(time) {
    if (this.ctx === null) {
      return;
    }
    this.noise(time, 0.14, 0.24, 'bandpass', 1800, 0.7);
    const ctx = this.ctx;
    const osc = ctx.createOscillator();
    const env = ctx.createGain();
    osc.type = 'triangle';
    osc.frequency.setValueAtTime(200, time);
    env.gain.setValueAtTime(0.16, time);
    env.gain.exponentialRampToValueAtTime(0.0001, time + 0.07);
    osc.connect(env);
    env.connect(this.musicGain);
    osc.start(time);
    osc.stop(time + 0.09);
    this.send(env, 0.18);
  }

  /** ハイハット: ノイズ (ハイパス 8 kHz)。閉じ 30 ms / 開き 120 ms */
  hat(time, duration, gain) {
    this.noise(time, duration, gain, 'highpass', 8000, 0.6);
  }

  // MARK: - 効果音

  /** 効果音の基準音 (曲のキーに合わせる) */
  root(offset = 0) {
    return midiToFreq(72 + this.transpose + offset);
  }

  /** 正解。上昇アルペジオ。コンボが伸びるほど半音ずつ上げる (最大 +12) */
  correct(intensity = 1, combo = 1) {
    if (this.ctx === null) {
      return;
    }
    const t = this.ctx.currentTime;
    const shift = Math.min(12, Math.max(0, combo - 1));
    const steps = [0, 4, 7, 12, 16];
    const n = 3 + Math.round(Math.min(1.5, Math.max(0, intensity)) * 1.3);
    for (let i = 0; i < Math.min(steps.length, n); i += 1) {
      this.keyVoice(t + i * 0.055, this.root(steps[i] + shift), 0.34, 0.26, this.sfxGain, 0.25);
    }
  }

  /** おしい: 柔らかい二音 */
  close() {
    if (this.ctx === null) {
      return;
    }
    const t = this.ctx.currentTime;
    this.keyVoice(t, this.root(4), 0.34, 0.32, this.sfxGain, 0.22);
    this.keyVoice(t + 0.11, this.root(0), 0.52, 0.32, this.sfxGain, 0.22);
  }

  /** もういちど: 低い一音 (とがらせず、短い減衰で) */
  wrong() {
    if (this.ctx === null) {
      return;
    }
    const t = this.ctx.currentTime;
    this.keyVoice(t, this.root(-17), 0.70, 0.32, this.sfxGain, 0.2);
    this.keyVoice(t, this.root(-29), 0.70, 0.18, this.sfxGain, 0.1);
  }

  /** コンボの節目: 和音のファンファーレ */
  comboFanfare() {
    if (this.ctx === null) {
      return;
    }
    const t = this.ctx.currentTime;
    [[0, 0.16], [0.13, 0.16], [0.28, 0.5]].forEach(([offset, duration]) => {
      for (const s of [0, 4, 7, 12]) {
        this.keyVoice(t + offset, this.root(s), duration, 0.14, this.sfxGain, 0.3);
      }
    });
  }

  /** ドパの節目: 高域のアルペジオ (シマー)。リバーブを多めに送る */
  milestone() {
    if (this.ctx === null) {
      return;
    }
    const t = this.ctx.currentTime;
    [12, 16, 19, 24, 28, 31].forEach((s, i) => {
      this.keyVoice(t + i * 0.055, this.root(s), 0.6, 0.16, this.sfxGain, 0.6);
    });
    this.noise(t, 0.6, 0.07, 'highpass', 6000, 0.5, this.sfxGain);
  }

  /**
   * 次の問題の到着を鳴らす「シュッ」。ノイズをバンドパスで 80 ms のあいだ上へ掃く。
   * 正解の効果音のすぐ後ろに置くので、delay (秒) で少しずらす。
   */
  whoosh(delay = 0) {
    if (this.ctx === null || this.noiseBuffer === null) {
      return;
    }
    const ctx = this.ctx;
    const t = ctx.currentTime + Math.max(0, delay);
    const duration = 0.08;
    const src = ctx.createBufferSource();
    src.buffer = this.noiseBuffer;
    src.loop = true;
    const filter = ctx.createBiquadFilter();
    filter.type = 'bandpass';
    filter.Q.value = 1.1;
    filter.frequency.setValueAtTime(600, t);
    filter.frequency.exponentialRampToValueAtTime(5200, t + duration);
    const env = ctx.createGain();
    env.gain.setValueAtTime(0, t);
    env.gain.linearRampToValueAtTime(0.22, t + 0.012);
    env.gain.exponentialRampToValueAtTime(0.0001, t + duration);
    src.connect(filter);
    filter.connect(env);
    env.connect(this.sfxGain);
    this.send(env, 0.12);
    src.start(t, Math.random() * 0.5);
    src.stop(t + duration + 0.02);
  }

  /** 音量スライダーを動かしたときの確認音 (正解の効果音の 1 音め) */
  blip() {
    if (this.ctx === null) {
      return;
    }
    this.keyVoice(this.ctx.currentTime, this.root(0), 0.34, 0.26, this.sfxGain, 0.25);
  }

  /** 完走: 短いファンファーレ */
  finale() {
    if (this.ctx === null) {
      return;
    }
    const t = this.ctx.currentTime;
    [0, 4, 7, 12].forEach((s, i) => {
      this.keyVoice(t + i * 0.09, this.root(s), 0.4, 0.2, this.sfxGain, 0.3);
    });
    for (const s of [12, 16, 19, 24]) {
      this.keyVoice(t + 0.42, this.root(s), 1.0, 0.13, this.sfxGain, 0.45);
      this.padVoice(t + 0.42, this.root(s - 12), 1.2, 0.05);
    }
  }
}
