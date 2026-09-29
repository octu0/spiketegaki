// 画面の組み立てと、筆記・判定・演出のつなぎこみ。
//
// 認識は recognizer.js (demo/ と共有。配信時にこの隣に置かれる) がぜんぶ引き受ける。
// ルールと計算は game.js / scoring.js / problems.js にあり、ここは DOM と演出だけを扱う。
//
// 判定はすべて自動。ペンを離して 600 ms で認識し、正解なら確定する。一致しなければ
// 書き続けられ、最後のペンアップから 1800 ms 書き足しが無ければ誤答を宣言する。

import { boot, loadWeights, readInk, classify } from './recognizer.js';
import {
  Game,
  TOP_K,
  CORRECT,
  CLOSE,
  EXTRA_MS,
  PHASE_EXTRA,
  PHASE_DONE,
  JUDGE_AUTO,
  JUDGE_DECLARE,
  acceptAuto,
  judgeDelay,
  nextJudge
} from './game.js';
import { blankedWord, BLANK } from './problems.js';
import {
  COMBO_LIMIT_MS,
  COMBO_REPORT_MIN,
  DOPA_MAX,
  LIGHTS_FROM,
  audienceCount,
  baseTempo,
  comboSpin,
  extraTempo,
  formatBestDopa,
  formatDopa,
  isComboReach
} from './scoring.js';
import { Effects, starburstPoints } from './fx.js';
import { Sound } from './audio.js';
import { Mascot } from './mascot.js';
import { Crowd } from './crowd.js';
import { Collected, Hanamaru, Lights, Wipe } from './stage.js';
import {
  load as loadStore,
  save as saveStore,
  recordBest,
  clampVolume,
  PEN_MIN,
  PEN_MAX
} from './store.js';

const WEIGHTS_URL = 'kanji80.stgw';   // 小学 1 年の 80 字で学習した重み
const KANJI_MASK = 1 << 6;            // 漢字モード (候補を漢字に絞る)
const PAD = 256;                      // 筆記領域の一辺 (canvas の画素)
const HINT_ALPHA = 0.15;              // なぞり用の見本の濃さ
const DOPA_ROLL_MS = 200;             // ドパのカウントアップの長さ
const FOCUS_COMBO = 10;               // 集中線を出すコンボ数
const MAX_COMBO = 20;                 // 虹色の縁取り・電飾の全点灯になるコンボ数
const DANCE_EVERY = 5;                // マスコットがダンスするコンボの間隔
const VERDICT_GOOD_MS = 450;          // 正解の判定バースト (この間に次の問題が来る)
const VERDICT_MISS_MS = 400;          // 誤答の判定バースト
const HANAMARU_DELAY_MS = 190;        // 判定バーストが縮み始めてから はなまる を描く
const CLAP_DELAY_MS = 430;            // はなまるを見てマスコットが拍手するまで
const WHOOSH_DELAY_S = 0.16;          // 正解の効果音のあと「シュッ」を鳴らすまで (秒)
const BLIP_MIN_GAP_MS = 140;          // 音量スライダーの確認音の最短間隔

const el = (id) => document.getElementById(id);

const screens = {
  title: el('screen-title'),
  play: el('screen-play'),
  result: el('screen-result')
};

const pad = el('pad');
const padCtx = pad.getContext('2d', { willReadFrequently: true });
const hintCtx = el('hintPad').getContext('2d');
const padwrap = el('padwrap');
const verdictBox = el('verdict');
const timerBar = el('timerBar');

const effects = new Effects(el('bg'), el('fx'), el('shake'));
const sound = new Sound();
const mascots = {
  title: new Mascot(el('titleMascot')),
  play: new Mascot(el('playMascot')),
  result: new Mascot(el('resultMascot'))
};
const crowd = new Crowd(el('audience'), el('parade'), (x, y) => effects.trail({ x, y }));
const lights = new Lights(el('lights'));
const hanamaru = new Hanamaru(el('hanamaru'));
const wipe = new Wipe(el('padWipe'));
const collected = new Collected(el('collected'), el('flights'));
const reachTag = el('reach');

const settings = loadStore();
let game = null;
let drawing = false;
let ready = false;
let frame = 0;

// 判定タイマーの状態 (game.js の nextJudge / judgeDelay に渡す)
let judgeTimer = 0;
let penDown = false;
let autoTried = false;
let lastUpAt = 0;

// ドパの表示 (カウントアップ中は実際の値より遅れる)
let displayDopa = 0;
let dopaRoll = null;

// 書いた墨の重心 (星を噴き出す位置)。筆記領域の座標で足しこむ
let ink = { x: 0, y: 0, n: 0 };
let reaching = false;
let clapTimer = 0;
let hanamaruTimer = 0;

padCtx.lineCap = 'round';
padCtx.lineJoin = 'round';
padCtx.strokeStyle = '#23313f';

// 判定表示は放射状のバースト (SVG) の上に文字を載せる。形は 1 度だけ作る
verdictBox.innerHTML =
  `<svg class="verdict__burst" viewBox="0 0 100 100" aria-hidden="true">`
  + `<polygon class="verdict__shape" points="${starburstPoints(14)}"/></svg>`
  + `<span class="verdict__text"></span>`;
const verdictText = verdictBox.querySelector('.verdict__text');

// 拍のたびに電飾を送り、リーチのタグを脈動させる (背景の脈動と同じ拍に乗る)
effects.onBeat = (beat) => {
  lights.tick(beat);
  if (!reaching) {
    return;
  }
  reachTag.classList.remove('reach--pulse');
  void reachTag.offsetWidth;
  reachTag.classList.add('reach--pulse');
};

// MARK: - iOS Safari の長押し対策
//
// 長押しでテキスト選択とコールアウト (コピー / 選択部分を検索 / 調べる) が出るのを止める。
// CSS の user-select / -webkit-touch-callout と合わせて、イベントも押さえる。
document.addEventListener('contextmenu', (event) => event.preventDefault());
document.addEventListener('selectstart', (event) => event.preventDefault());
for (const name of ['touchstart', 'touchmove', 'touchend']) {
  pad.addEventListener(name, (event) => event.preventDefault(), { passive: false });
}

// MARK: - 画面の切り替え

function show(name) {
  for (const [key, node] of Object.entries(screens)) {
    node.classList.toggle('screen--on', key === name);
  }
}

// MARK: - 起動

async function start() {
  try {
    el('boot').textContent = 'にんしきき を よみこみ中…';
    await boot();
    const bytes = await loadWeights(WEIGHTS_URL);
    el('boot').textContent = `よういできました (${(bytes / 1048576).toFixed(1)} MiB)`;
    ready = true;
    el('startButton').disabled = false;
  } catch (error) {
    el('boot').textContent = `よみこめませんでした: ${error.message}`;
    console.error(error);
  }
}

// MARK: - タイトル

function showRecords() {
  el('bestScore').textContent = String(settings.bestScore);
  el('bestDopa').textContent = formatBestDopa(settings.bestDopa);
  el('bestCombo').textContent = String(settings.bestCombo);
}

el('soundToggle').checked = settings.sound;
el('penInput').value = String(settings.penWidth);
el('penValue').textContent = String(settings.penWidth);
el('volumeInput').value = String(settings.volume);
el('volumeValue').textContent = String(settings.volume);
sound.setVolume(settings.volume);
showRecords();

el('soundToggle').addEventListener('change', () => {
  settings.sound = el('soundToggle').checked;
  sound.setEnabled(settings.sound);
  saveStore(settings);
});

// 音量スライダー。動かすたびに反映し、確認音を鳴らす (鳴らしすぎないよう間隔をあける)
let blipAt = 0;
el('volumeInput').addEventListener('input', () => {
  const value = Number.parseInt(el('volumeInput').value, 10);
  if (!Number.isFinite(value)) {
    return;
  }
  settings.volume = clampVolume(value);
  el('volumeValue').textContent = String(settings.volume);
  sound.setVolume(settings.volume);
  saveStore(settings);
  const now = performance.now();
  if (now - blipAt >= BLIP_MIN_GAP_MS) {
    blipAt = now;
    sound.blip();
  }
});

el('penInput').addEventListener('input', () => {
  const value = Number.parseInt(el('penInput').value, 10);
  if (!Number.isFinite(value)) {
    return;
  }
  settings.penWidth = Math.min(PEN_MAX, Math.max(PEN_MIN, value));
  el('penValue').textContent = String(settings.penWidth);
  saveStore(settings);
});

el('startButton').addEventListener('click', () => {
  if (!ready) {
    return;
  }
  // 音はブラウザの制約で、最初のユーザー操作のときにしか始められない。
  // ただし resume() が解決しないことがあるので待たない (音が出なくてもゲームは始める)
  sound.ensureStarted();
  sound.setEnabled(settings.sound);
  sound.setVolume(settings.volume);
  sound.startMusic();
  newGame();
});

// MARK: - ラウンド

function newGame() {
  game = new Game();
  displayDopa = 0;
  dopaRoll = null;
  clearPad();
  collected.reset();
  show('play');
  renderQuestion();
  updateHud();
  updateDopa();
  loop();
}

function renderQuestion() {
  const problem = game.current();
  if (problem === null) {
    return;
  }
  el('questionReading').textContent = problem.reading;
  const blanked = blankedWord(problem);
  el('questionWord').replaceChildren(...[...blanked].map((ch) => {
    const span = document.createElement('span');
    if (ch === BLANK) {
      span.className = 'blank';
    }
    span.textContent = ch;
    return span;
  }), document.createTextNode(`  (${problem.wordReading})`));
  el('questionHint').textContent = '';
  drawHint(false);
  applyIntensity();
  slideInQuestion();
}

/** 次の問題が左からすべり込む (200 ms)。判定バーストが消えるより先に読める */
function slideInQuestion() {
  const node = document.querySelector('.question__text');
  node.classList.remove('question__text--in');
  void node.offsetWidth;
  node.classList.add('question__text--in');
}

function updateHud() {
  setValue('scoreValue', String(game.score()));
  updateCombo();
  if (game.phase === PHASE_EXTRA) {
    el('progressLabel').textContent = 'のこり びょう';
    el('progressValue').textContent = String(Math.ceil(game.extraRemainingMs() / 1000));
  } else {
    el('progressLabel').textContent = 'もんだい';
    el('progressValue').textContent = `${Math.min(game.index + 1, game.questionCount)} / ${game.questionCount}`;
  }
}

function setValue(id, text) {
  const node = el(id);
  if (node.textContent === text) {
    return;
  }
  node.textContent = text;
  node.classList.remove('hud__value--pop');
  void node.offsetWidth;
  node.classList.add('hud__value--pop');
}

/** コンボの表示。弾ませ、5 以上で色を熱くし、10 以上で集中線、MAX で虹色の縁取り */
function updateCombo() {
  const node = el('comboValue');
  const text = game.combo >= 2 ? `${game.combo}${game.combo >= MAX_COMBO ? ' MAX' : ''}` : '0';
  if (node.textContent !== text) {
    node.textContent = text;
    node.classList.remove('hud__value--bounce');
    void node.offsetWidth;
    node.classList.add('hud__value--bounce');
  }
  node.classList.toggle('hud__value--hot1', game.combo >= 5 && game.combo < FOCUS_COMBO);
  node.classList.toggle('hud__value--hot2', game.combo >= FOCUS_COMBO && game.combo < MAX_COMBO);
  node.classList.toggle('hud__value--hot3', game.combo >= MAX_COMBO);
  padwrap.classList.toggle('padwrap--max', game.combo >= MAX_COMBO);
  // 背景はコンボが伸びるほど速く回り、MAX で電飾が虹色に全点灯する
  effects.setSpin(comboSpin(game.combo));
  lights.setRainbow(game.combo >= MAX_COMBO);
  updateReach();
  if (game.combo >= FOCUS_COMBO) {
    const level = Math.min(1, (game.combo - FOCUS_COMBO) / FOCUS_COMBO);
    effects.setFocus(padwrap.getBoundingClientRect(), 0.3 + 0.7 * level);
  } else {
    effects.setFocus(null, 0);
  }
}

/** ドパの表示とメーター。カウントアップ中は毎フレーム呼ばれる */
function updateDopa() {
  el('dopaValue').textContent = formatDopa(displayDopa);
  el('meterBar').style.transform = `scaleX(${Math.min(1, displayDopa / DOPA_MAX).toFixed(4)})`;
}

/** ドパを from から to へ 200 ms で転がす */
function rollDopa(from, to) {
  dopaRoll = { from, to, start: performance.now() };
  const meter = el('meterBar').parentElement;
  meter.classList.remove('meter--glow');
  void meter.offsetWidth;
  meter.classList.add('meter--glow');
}

function tickDopa(now) {
  if (dopaRoll === null) {
    return;
  }
  const t = Math.min(1, (now - dopaRoll.start) / DOPA_ROLL_MS);
  displayDopa = dopaRoll.from + (dopaRoll.to - dopaRoll.from) * t;
  if (t >= 1) {
    displayDopa = dopaRoll.to;
    dopaRoll = null;
  }
  updateDopa();
}

/** 強度 E を背景・BGM のテンポとレイヤー・拍の脈動に反映する */
function applyIntensity() {
  const e = game.intensity();
  effects.setIntensity(e);
  let bpm;
  let transpose;
  if (game.phase === PHASE_EXTRA) {
    const tier = game.tier();
    bpm = extraTempo(tier);
    transpose = 2 + Math.min(tier, 5);
  } else {
    bpm = baseTempo(e);
    // 最終問だけ 2 半音上げる
    transpose = game.index === game.questionCount - 1 ? 2 : 0;
  }
  sound.setTempo(bpm, transpose, e);
  effects.setBeat(60000 / bpm);
  crowd.setCount(audienceCount(e));
  lights.setOn(e >= LIGHTS_FROM);
}

/** 節目の 1 つ手前 (リーチ)。タグを出し、観客とマスコットが前のめりになる */
function updateReach() {
  const on = isComboReach(game.combo);
  if (on === reaching) {
    return;
  }
  reaching = on;
  reachTag.classList.toggle('reach--on', on);
  crowd.setLean(on);
  if (on) {
    mascots.play.lean();
  }
}

// MARK: - 筆記

function pointOf(event) {
  const rect = pad.getBoundingClientRect();
  return {
    x: (event.clientX - rect.left) * (PAD / rect.width),
    y: (event.clientY - rect.top) * (PAD / rect.height)
  };
}

pad.addEventListener('pointerdown', (event) => {
  if (game === null || game.phase === PHASE_DONE) {
    return;
  }
  event.preventDefault();
  pad.setPointerCapture(event.pointerId);
  // 新しいペンダウンで判定タイマーは必ず解除する
  cancelJudge();
  penDown = true;
  drawing = true;
  padCtx.lineWidth = settings.penWidth;
  const p = pointOf(event);
  padCtx.beginPath();
  padCtx.moveTo(p.x, p.y);
  // 点だけ打った場合にも墨が残るよう、同じ位置へ 1 本引く
  padCtx.lineTo(p.x, p.y);
  padCtx.stroke();
  addInk(p);
});

pad.addEventListener('pointermove', (event) => {
  if (!drawing) {
    return;
  }
  event.preventDefault();
  const p = pointOf(event);
  padCtx.lineTo(p.x, p.y);
  padCtx.stroke();
  addInk(p);
});

function endStroke(event) {
  if (!drawing) {
    return;
  }
  drawing = false;
  penDown = false;
  if (event && pad.hasPointerCapture(event.pointerId)) {
    pad.releasePointerCapture(event.pointerId);
  }
  lastUpAt = performance.now();
  autoTried = false;
  scheduleJudge();
}

pad.addEventListener('pointerup', endStroke);
pad.addEventListener('pointercancel', endStroke);
pad.addEventListener('pointerleave', endStroke);

/** 通った点を足しこむ。正解のとき、ここから求めた重心で星を噴き出す */
function addInk(p) {
  ink.x += p.x;
  ink.y += p.y;
  ink.n += 1;
}

/** 書いた墨の重心 (画面の座標)。まだ何も書いていなければ筆記領域の中央 */
function inkOrigin(rect) {
  if (ink.n === 0) {
    return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
  }
  return {
    x: rect.x + (ink.x / ink.n) * (rect.width / PAD),
    y: rect.y + (ink.y / ink.n) * (rect.height / PAD)
  };
}

/** 書いた字を写す (「あつめた字」の帯へ飛ばすため)。消す前に呼ぶ */
function snapshotPad() {
  try {
    return pad.toDataURL('image/png');
  } catch (error) {
    console.error(error);
    return null;
  }
}

function clearPad() {
  cancelJudge();
  padCtx.clearRect(0, 0, PAD, PAD);
  ink = { x: 0, y: 0, n: 0 };
}

/**
 * 消して、白い帯を左から右へ走らせる (「消した感」を出す)。
 * 帯の下には消す直前の墨を置くので、帯が通ったところから字が消えていく。
 */
function wipePad(snapshot) {
  const shot = snapshot === undefined ? snapshotPad() : snapshot;
  clearPad();
  wipe.play(shot);
}

el('clearButton').addEventListener('click', () => wipePad());

/** なぞり用の薄い見本。generic family の字を筆記領域の下に敷く */
function drawHint(on) {
  hintCtx.clearRect(0, 0, PAD, PAD);
  if (!on || game === null) {
    return;
  }
  const problem = game.current();
  if (problem === null) {
    return;
  }
  hintCtx.save();
  hintCtx.globalAlpha = HINT_ALPHA;
  hintCtx.fillStyle = '#23313f';
  hintCtx.textAlign = 'center';
  hintCtx.textBaseline = 'middle';
  hintCtx.font = `${Math.round(PAD * 0.78)}px serif`;
  hintCtx.fillText(problem.kanji, PAD / 2, PAD / 2 + PAD * 0.02);
  hintCtx.restore();
}

// MARK: - 判定 (すべて自動)

/** 筆記領域の墨を認識する。呼べない / 失敗したときは null */
function classifyPad() {
  try {
    return classify(readInk(padCtx, PAD, PAD), PAD, PAD, TOP_K, KANJI_MASK);
  } catch (error) {
    console.error(error);
    return null;
  }
}

function cancelJudge() {
  window.clearTimeout(judgeTimer);
  judgeTimer = 0;
  penDown = false;
  autoTried = false;
}

/** 次に判定タイマーがすることまで待つ */
function scheduleJudge() {
  window.clearTimeout(judgeTimer);
  const delay = judgeDelay({ penDown, autoTried }, performance.now() - lastUpAt);
  if (!Number.isFinite(delay)) {
    return;
  }
  judgeTimer = window.setTimeout(runJudge, Math.max(0, delay));
}

function runJudge() {
  const action = nextJudge({ penDown, autoTried }, performance.now() - lastUpAt);
  if (action === JUDGE_AUTO) {
    autoTried = true;
    recognize(false);
    scheduleJudge();
    return;
  }
  if (action === JUDGE_DECLARE) {
    recognize(true);
    return;
  }
  scheduleJudge();
}

/**
 * 筆記領域を認識して反映する。
 *
 * declare が false のときは「正解なら確定」だけに使う (多画の字は 1 画目でも認識に掛かる)。
 * true のときは おしい・もういちど も宣言する。どちらも薄墨ガードに掛かる状態
 * (点 1 つなど、墨が足りない) では何もしない。
 */
function recognize(declare) {
  if (game === null || game.phase === PHASE_DONE) {
    return;
  }
  const problem = game.current();
  if (problem === null) {
    return;
  }
  const result = classifyPad();
  if (result === null || !result.ok) {
    return;
  }
  if (!declare && !acceptAuto(result.rows, problem.kanji)) {
    return;
  }
  handle(game.answer(result.rows));
}

function handle(outcome) {
  if (outcome.ignored) {
    // 判定が来たときに 90 秒を過ぎていた。ループより先にここで終わりに気づくことがある
    if (outcome.extraExpired) {
      finishExtra();
    }
    return;
  }
  if (outcome.verdict === CORRECT) {
    onCorrect(outcome);
  } else {
    onMiss(outcome);
  }
  updateHud();
}

function onCorrect(outcome) {
  const e = outcome.intensity;
  const padRect = padwrap.getBoundingClientRect();
  // 書いた字は消す前に写して、そのまま「あつめた字」の帯へ飛ばす
  const written = snapshotPad();
  const origin = inkOrigin(padRect);

  flashVerdict('せいかい!', 'good', VERDICT_GOOD_MS);
  flashPad();
  effects.burst(e, padOrigin());
  effects.sparkle(origin);
  effects.recoil();
  sound.correct(e, outcome.combo);
  // 正解の音のすぐ後ろで「シュッ」。次の問題が来る合図
  sound.whoosh(WHOOSH_DELAY_S);
  mascots.play.correct(e, outcome.comboCelebration || outcome.milestones.length > 0);
  crowd.wave();
  floatText(`+${outcome.gained}`, '');
  floatText(`ドパ +${dopaDelta(outcome.dopaBefore, outcome.dopaAfter)}`, 'dopa');
  rollDopa(displayDopa, outcome.dopaAfter);
  // 正解では字が「あつめた字」の帯へ飛んでいくので、ワイプは帯だけ走らせる
  wipePad(null);
  drawHint(false);
  // 「せいかい!」のバーストが縮み始めたところで はなまる を描く (ふたつが重ならない)
  window.clearTimeout(hanamaruTimer);
  hanamaruTimer = window.setTimeout(() => hanamaru.play(), HANAMARU_DELAY_MS);
  if (written !== null) {
    collected.collect(written, padRect);
  }

  // 祝いの一言。次の問題を出すとお知らせ欄が消えるので、文面だけ先に決めておく
  let notice = '';
  const big = outcome.comboCelebration || outcome.milestones.length > 0;
  if (outcome.combo > 0 && outcome.combo % DANCE_EVERY === 0) {
    mascots.play.dance();
  }
  if (outcome.comboCelebration) {
    notice = `${outcome.combo} コンボ!`;
    effects.celebrate(e);
    sound.comboFanfare();
    showBanner(`${outcome.combo} コンボ!`);
    crowd.jump();
  }
  if (outcome.milestones.length > 0) {
    const reached = outcome.milestones[outcome.milestones.length - 1];
    notice = `ドパ ${formatDopa(game.dopa)} とうたつ!`;
    effects.celebrate(Math.max(1.2, e));
    effects.coinRain();
    sound.milestone();
    showBanner(`${formatDopa(reached)} ドパ とうたつ!`);
    mascots.play.spin();
    crowd.jump();
  }
  // 大きな節目は観客が画面の下を行進する
  if (outcome.milestones.length > 0 || (outcome.comboCelebration && outcome.combo >= MAX_COMBO)) {
    crowd.parade();
  }
  scheduleClap(big);

  if (outcome.baseFinished) {
    finishBase();
    return;
  }
  renderQuestion();
  el('questionHint').textContent = notice;
}

/** はなまるが描き上がったころにマスコットが拍手する (もっと大きな反応があるときは譲る) */
function scheduleClap(big) {
  window.clearTimeout(clapTimer);
  if (big) {
    return;
  }
  clapTimer = window.setTimeout(() => mascots.play.clap(), CLAP_DELAY_MS);
}

function onMiss(outcome) {
  const close = outcome.verdict === CLOSE;
  flashVerdict(close ? 'おしい!' : 'もういちど', close ? 'close' : 'bad', VERDICT_MISS_MS);
  if (close) {
    sound.close();
    mascots.play.close();
  } else {
    sound.wrong();
    mascots.play.wrong();
  }
  crowd.startle();
  window.clearTimeout(clapTimer);
  window.clearTimeout(hanamaruTimer);
  // 待ち時間を作らないよう、筆記領域はすぐ消す (判定の表示だけが 400 ms 残る)
  wipePad();
  if (outcome.showsHint) {
    el('questionHint').textContent = 'うすい おてほんを なぞってみよう';
    drawHint(true);
  } else if (outcome.brokenCombo > 0) {
    el('questionHint').textContent = `${outcome.brokenCombo} コンボ しゅうりょう`;
  }
}

// MARK: - 演出の小道具

function flashVerdict(text, kind, durationMs) {
  verdictBox.className = `verdict verdict--${kind}`;
  verdictBox.style.setProperty('--verdict-ms', `${durationMs}ms`);
  verdictText.textContent = text;
  void verdictBox.offsetWidth;
  verdictBox.classList.add('verdict--show');
}

/** 筆記領域が一瞬光る */
function flashPad() {
  const node = el('padFlash');
  node.classList.remove('flash--on');
  void node.offsetWidth;
  node.classList.add('flash--on');
}

/** 粒子を噴き出させる位置 (筆記領域の中央) */
function padOrigin() {
  const rect = padwrap.getBoundingClientRect();
  return { x: rect.x + rect.width / 2, y: rect.y + rect.height * 0.5 };
}

/** 筆記領域から上へ浮いて消える文字 */
function floatText(text, kind) {
  const rect = padwrap.getBoundingClientRect();
  const node = document.createElement('div');
  node.className = kind ? `float float--${kind}` : 'float';
  node.textContent = text;
  // 判定表示 (中央のバースト) に重ならないよう、得点は上、ドパは下へ寄せる
  const dopa = kind === 'dopa';
  const offset = (dopa ? 0.22 : -0.24) + (Math.random() - 0.5) * 0.1;
  node.style.left = `${rect.x + rect.width / 2 + rect.width * offset}px`;
  node.style.top = `${rect.y + rect.height * (dopa ? 0.82 : 0.18)}px`;
  el('floats').append(node);
  node.addEventListener('animationend', () => node.remove());
}

/** ドパの増分 (実数) の表示 */
function dopaDelta(before, after) {
  const delta = Math.pow(10, after) - Math.pow(10, before);
  return formatDopa(Math.log10(Math.max(1, delta)));
}

/** 画面中央のバナー (節目の祝い) */
function showBanner(text) {
  const node = el('banner');
  node.textContent = text;
  node.classList.remove('banner--show');
  void node.offsetWidth;
  node.classList.add('banner--show');
}

el('passButton').addEventListener('click', () => {
  if (game === null || game.phase === PHASE_DONE) {
    return;
  }
  const outcome = game.pass();
  wipePad();
  drawHint(false);
  if (outcome.baseFinished) {
    finishBase();
    return;
  }
  renderQuestion();
  el('questionHint').textContent = outcome.brokenCombo > 0
    ? `${outcome.brokenCombo} コンボ しゅうりょう`
    : '';
  updateHud();
});

el('quitButton').addEventListener('click', () => {
  if (game === null || !window.confirm('やめますか? ここまでの きろくは のこります')) {
    return;
  }
  window.cancelAnimationFrame(frame);
  cancelJudge();
  recordBest(settings, game.summary());
  game = null;
  sound.stopMusic();
  quietStage();
  showRecords();
  show('title');
});

/** プレイ画面を離れるときに、動いているものをぜんぶ静める */
function quietStage() {
  window.clearTimeout(clapTimer);
  window.clearTimeout(hanamaruTimer);
  effects.setFocus(null, 0);
  effects.setSpin(1);
  lights.setOn(false);
  lights.setRainbow(false);
  crowd.stop();
  reaching = false;
  reachTag.classList.remove('reach--on', 'reach--pulse');
  padwrap.classList.remove('padwrap--max');
}

// MARK: - ループ (残り時間と時間切れ)

function loop() {
  window.cancelAnimationFrame(frame);
  const step = (now) => {
    if (game === null || game.phase === PHASE_DONE) {
      return;
    }
    tickDopa(now);
    const events = game.tick();
    if (events.comboExpired) {
      el('questionHint').textContent = events.brokenCombo >= COMBO_REPORT_MIN
        ? `${events.brokenCombo} コンボ しゅうりょう`
        : '';
      updateHud();
    }
    if (events.extraExpired) {
      finishExtra();
      return;
    }
    updateTimerBar();
    if (game.phase === PHASE_EXTRA) {
      updateHud();
    }
    frame = window.requestAnimationFrame(step);
  };
  frame = window.requestAnimationFrame(step);
}

function updateTimerBar() {
  // コンボの残り時間。1 コンボ以下は時間切れの対象外なので満タンのまま
  const remaining = game.comboRemainingMs();
  const ratio = remaining === Infinity ? 1 : Math.min(1, remaining / COMBO_LIMIT_MS);
  timerBar.style.transform = `scaleX(${ratio.toFixed(3)})`;
  timerBar.classList.toggle('timer__bar--low', ratio < 0.3);
}

// MARK: - 結果

function finishBase() {
  // 1 問も正解していない (ぜんぶパスした) ときは、祝わずに静かに結果へ。
  // エクストラへは正解数に関係なく進める
  if (game.correctCount === 0) {
    showResult('けっか', true, false);
    return;
  }
  effects.finale();
  sound.finale();
  mascots.result.giant();
  showResult('かんそう!', true, true);
  // パレードは結果の上を横切らせる (quietStage で止まらないよう、画面を切り替えた後に出す)
  crowd.parade();
}

function finishExtra() {
  sound.finale();
  effects.finale();
  showResult('エクストラ しゅうりょう', false, true);
  crowd.parade();
}

function showResult(title, canGoExtra, celebrate) {
  window.cancelAnimationFrame(frame);
  clearPad();
  drawHint(false);
  quietStage();
  const summary = game.summary();
  displayDopa = summary.dopa;
  dopaRoll = null;
  updateDopa();
  el('resultTitle').textContent = title;
  countUp(el('resultScore'), summary.score, celebrate ? 900 : 0);
  el('resultDopa').textContent = formatDopa(summary.dopa);
  el('resultCombo').textContent = String(summary.maxCombo);
  el('resultCorrect').textContent = String(summary.correctCount);
  el('resultClose').textContent = String(summary.closeCount);
  const updated = recordBest(settings, summary);
  el('resultBest').textContent = updated.length > 0 ? 'さいこう きろく こうしん!' : '';
  el('extraButton').style.display = canGoExtra ? '' : 'none';
  showRecords();
  show('result');
}

/** 数字を 0 から value まで転がす (duration が 0 ならそのまま出す) */
function countUp(node, value, duration) {
  if (duration <= 0) {
    node.textContent = String(value);
    return;
  }
  const started = performance.now();
  const step = (now) => {
    const t = Math.min(1, (now - started) / duration);
    node.textContent = String(Math.round(value * t));
    if (t < 1) {
      window.requestAnimationFrame(step);
    }
  };
  window.requestAnimationFrame(step);
}

el('extraButton').addEventListener('click', () => {
  if (game === null) {
    return;
  }
  game.startExtra();
  clearPad();
  show('play');
  renderQuestion();
  updateHud();
  el('questionHint').textContent = `${EXTRA_MS / 1000} びょう! どんどん 書こう`;
  loop();
});

el('againButton').addEventListener('click', () => {
  newGame();
});

el('homeButton').addEventListener('click', () => {
  game = null;
  sound.stopMusic();
  quietStage();
  showRecords();
  show('title');
});

// MARK: - 開始

start();
