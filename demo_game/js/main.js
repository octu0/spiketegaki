// 画面の組み立てと、筆記・判定・演出のつなぎこみ。
//
// 認識は recognizer.js (demo/ と共有。配信時にこの隣に置かれる) がぜんぶ引き受ける。
// ルールと計算は game.js / scoring.js / problems.js にあり、ここは DOM と演出だけを扱う。
//
// 判定はすべて自動。ペンを離して 600 ms で認識し、正解なら確定する。一致しなければ
// 書き続けられ、最後のペンアップから 1800 ms 書き足しが無ければ誤答を宣言する。
// 1 問 15 秒。0 秒で墨があればその場で認識し、正解ならセーフ、それ以外は時間切れ。
// 誤答の宣言と時間切れはミス (ライフ 3)。10 問で次のステージへ進む。

import { boot, loadWeights, readInk, classify } from './recognizer.js';
import {
  Game,
  TOP_K,
  CORRECT,
  CLOSE,
  TIMEOUT,
  LIVES,
  TIME_LOW,
  REVEAL_MS,
  JUDGE_AUTO,
  JUDGE_DECLARE,
  acceptAuto,
  countdownNumber,
  judgeDelay,
  nextJudge,
  parseProgress,
  timeRatio
} from './game.js';
import { blankedWord, BLANK } from './problems.js';
import {
  DOPA_MAX,
  LIGHTS_FROM,
  formatBestDopa,
  formatDopa,
  isComboReach,
  score as scoreOf
} from './scoring.js';
import {
  SPIN_BASE,
  cheerLevel,
  correctProps,
  crowdCount,
  floatLevel,
  garlandCount,
  leaperCount,
  milestoneLabel,
  sashText,
  spinSpeed
} from './escalation.js';
import { Effects, starburstPoints } from './fx.js';
import { Sound, musicTempo } from './audio.js';
import { Mascot } from './mascot.js';
import { Crowd } from './crowd.js';
import { Props } from './props.js';
import { Overlay } from './overlay.js';
import { Collected, Hanamaru, Lights, Wipe } from './stage.js';
import {
  load as loadStore,
  save as saveStore,
  loadProgress,
  saveProgress,
  clearProgress,
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
const RAINBOW_COMBO = 5;              // はなまるが虹色の渦巻きになるコンボ数
const VERDICT_GOOD_MS = 450;          // 正解の判定バースト (この間に次の問題が来る)
const VERDICT_MISS_MS = 400;          // 誤答の判定バースト
const HANAMARU_DELAY_MS = 190;        // 判定バーストが縮み始めてから はなまる を描く
const CLAP_DELAY_MS = 430;            // はなまるを見てマスコットが拍手するまで
const WHOOSH_DELAY_S = 0.16;          // 正解の効果音のあと「シュッ」を鳴らすまで (秒)
const BLIP_MIN_GAP_MS = 140;          // 音量スライダーの確認音の最短間隔
const FLOAT_STEP_PX = 30;             // 加点の浮遊を 1 段積むときの高さ
const BIGNUM_CLEAR_MS = 600;          // 巨大数字がはずみ終わるまで、横断バナーは待つ (同じ高さに出るため)
const HURT_JOLT_PX = 12;              // ハートが割れたときの画面の揺れ
const HEART_BREAK_MS = 600;           // ハートが割れるアニメ (ゲームオーバーの画面はこのあとに出す)

const el = (id) => document.getElementById(id);

const screens = {
  title: el('screen-title'),
  play: el('screen-play')
};

const pad = el('pad');
const padCtx = pad.getContext('2d', { willReadFrequently: true });
const hintCtx = el('hintPad').getContext('2d');
const padwrap = el('padwrap');
const verdictBox = el('verdict');
const timerBar = el('timerBar');
const countdownBox = el('countdown');
const gameoverBox = el('gameover');

const effects = new Effects(el('bg'), el('fx'), el('shake'));
const sound = new Sound();
const mascots = {
  title: new Mascot(el('titleMascot')),
  play: new Mascot(el('playMascot')),
  result: new Mascot(el('resultMascot'))
};
const props = new Props();
const crowd = new Crowd({
  onConfetti: (x, y, n) => props.confetti(x, y, n),
  onFirework: () => effects.firework()
});
// 観客と飾りの canvas (カードの下と上の 2 枚)。帯と筆記領域の位置を測って、枠内を切り抜いて描く
const overlay = new Overlay(el('overlayBack'), el('overlayFront'), {
  crowd,
  props,
  anchors: () => ({
    pad: screens.play.classList.contains('screen--on') ? padwrap : null,
    band: el('crowdBand')
  })
});
const lights = new Lights(el('lights'));
const hanamaru = new Hanamaru(el('hanamaru'));
const wipe = new Wipe(el('padWipe'));
const collected = new Collected(el('collected'));
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

// 書いた墨の重心 (星を噴き出す位置)。筆記領域の座標で足しこむ。n > 0 なら墨がある
let ink = { x: 0, y: 0, n: 0 };
let reaching = false;
let clapTimer = 0;
let hanamaruTimer = 0;

// カウントダウン中の数字 (5〜1、出していなければ null)
let counting = null;
// 時間切れで正解の字を見せている間のタイマー / ゲームオーバーの画面を出すまでのタイマー
let revealTimer = 0;
let gameoverTimer = 0;

// 最後の誤答 (おしい / もういちど / 時間切れ) の時刻。次の正解で null に戻す (背景の回転が止まる → ゆっくり)
let missAt = null;
// 加点の浮遊を積む段と、最後に浮かべた時刻
let floatStack = { level: 0, at: -Infinity };
// 最後に巨大数字を出した時刻 (横断バナーと重ならないようにずらす)
let bignumAt = -Infinity;

// 背景の回転速度は、問題の進行・コンボ・誤答のあとかどうかで毎フレーム決める
effects.spinTarget = () => {
  if (game === null) {
    return SPIN_BASE;
  }
  return spinSpeed({
    index: game.index,
    total: game.questionCount,
    later: game.stage > 1,
    combo: game.combo,
    sinceMissMs: missAt === null ? null : performance.now() - missAt
  });
};

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
  overlay.measure();
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
    el('continueButton').disabled = false;
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
  el('bestStage').textContent = String(settings.bestStage);
  showContinue();
}

/** 途中の状態が保存してあれば「つづきから」を出す (ゲームオーバー後も残る = リトライと同じ位置) */
function showContinue() {
  const saved = parseProgress(loadProgress());
  el('continueButton').hidden = saved === null;
  el('startButton').textContent = saved === null ? 'はじめる' : 'さいしょから';
  el('startButton').classList.toggle('big', saved === null);
  if (saved !== null) {
    const score = scoreOf(saved.firstStageSolved, saved.laterSolved);
    el('continueInfo').textContent = `ステージ ${saved.stage}・${saved.index + 1} もんめ (${score}てん)`;
  }
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
    sound.cue('blip');
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
  clearProgress();
  begin(null);
});

el('continueButton').addEventListener('click', () => {
  if (!ready) {
    return;
  }
  begin(parseProgress(loadProgress()));
});

/** 音を始めてからゲームを始める */
function begin(saved) {
  // 音はブラウザの制約で、最初のユーザー操作のときにしか始められない。
  // ただし resume() が解決しないことがあるので待たない (音が出なくてもゲームは始める)
  sound.ensureStarted();
  sound.setEnabled(settings.sound);
  sound.setVolume(settings.volume);
  sound.startMusic();
  newGame(saved);
}

// MARK: - ステージ

/** 新しいゲーム。saved (parseProgress の結果) があれば、その位置から続ける */
function newGame(saved = null) {
  game = new Game({ saved });
  displayDopa = game.dopa;
  dopaRoll = null;
  missAt = null;
  hideGameover();
  clearPad();
  if (saved === null) {
    collected.reset();
  } else {
    // 画像は保存していないので、あつめた字は活字で並べ直す
    collected.restore(game.collected);
  }
  crowd.reset();
  props.clear();
  resetHearts();
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
  overlay.measure();
  const sash = sashText({ stage: game.stage, index: game.index, total: game.questionCount });
  if (sash !== null) {
    showSash(sash);
  }
  if (game.index === game.questionCount - 1) {
    sound.cue('lastProblem');
  }
  updateCountdown(null);
  syncSound();
  persist();
}

/** 曲に今の進行を伝える (問題の開始と判定のたび)。曲はここからセクションとレイヤーを選ぶ */
function syncSound() {
  sound.setProgress({
    stage: game.stage,
    index: game.index,
    total: game.questionCount,
    combo: game.combo,
    lives: game.lives,
    intensity: game.intensity()
  });
}

/** つづきから用に今の状態を保存する */
function persist() {
  saveProgress(game.snapshot());
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
  el('progressLabel').textContent = `ステージ ${game.stage}`;
  el('progressValue').textContent = `${game.index + 1} / ${game.questionCount}`;
  el('passLeft').textContent = String(game.passesLeft());
  el('passButton').disabled = !game.playing() || game.passesLeft() === 0;
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
  // MAX で電飾が虹色に全点灯する (背景の回転は effects.spinTarget が毎フレーム読む)
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

/**
 * 強度 E と正解数を、背景の脈動・観客の人数・飾りの量に反映する (曲には syncSound で伝える)。
 * 背景の脈動と電飾は曲と同じテンポで打つ
 */
function applyIntensity() {
  const e = game.intensity();
  effects.setIntensity(e);
  effects.setBeat(60000 / musicTempo(game.stage, e));
  crowd.setCount(crowdCount(game.correctCount, e));
  crowd.setIntensity(e);
  props.setIntensity(e);
  props.setGarlands(garlandCount(game.correctCount));
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
  crowd.setLean(reaching || counting !== null);
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
  if (game === null || !game.playing()) {
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

/** 書いた字を写す (「あつめた字」の帯に並べるため)。消す前に呼ぶ */
function snapshotPad() {
  try {
    return pad.toDataURL('image/png');
  } catch (error) {
    console.error(error);
    return null;
  }
}

/** 書いた字を canvas に写す (観客が帯まで運ぶ間に描くため)。消す前に呼ぶ */
function copyPad() {
  const copy = document.createElement('canvas');
  copy.width = PAD;
  copy.height = PAD;
  copy.getContext('2d').drawImage(pad, 0, 0);
  return copy;
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
  if (game === null || !game.playing()) {
    return;
  }
  const problem = game.current();
  const result = classifyPad();
  if (result === null || !result.ok) {
    return;
  }
  if (!declare && !acceptAuto(result.rows, problem.kanji)) {
    return;
  }
  handle(game.answer(result.rows));
}

/**
 * 0 秒になった。書いている途中の画もそこまでの墨で認識し、正解ならセーフ、それ以外は時間切れ。
 * 墨が無い・薄墨ガードに掛かるときは認識せずに時間切れ。
 */
function timeUp() {
  cancelJudge();
  drawing = false;
  const result = ink.n > 0 ? classifyPad() : null;
  handle(game.timeUp(result !== null && result.ok ? result.rows : null));
}

function handle(outcome) {
  if (outcome.ignored) {
    return;
  }
  if (outcome.verdict === CORRECT) {
    onCorrect(outcome);
  } else if (outcome.verdict === TIMEOUT) {
    onTimeout(outcome);
  } else {
    onMiss(outcome);
  }
  updateHud();
  syncSound();
  persist();
}

function onCorrect(outcome) {
  const e = outcome.intensity;
  const padRect = padwrap.getBoundingClientRect();
  // 書いた字は消す前に写して、観客が「あつめた字」の帯へ運ぶ
  const written = snapshotPad();
  const inkCopy = copyPad();
  const origin = inkOrigin(padRect);
  const milestone = outcome.milestones.length > 0;
  missAt = null;

  flashVerdict(outcome.safe ? 'セーフ!' : 'せいかい!', 'good', VERDICT_GOOD_MS);
  flashPad();
  effects.burst(e, padOrigin());
  effects.sparkle(origin);
  effects.recoil();
  // 0 秒ぎりぎりの正解は「セーフ!」の音
  if (outcome.safe) {
    sound.cue('safe');
  } else {
    sound.cue('correct', { combo: outcome.combo });
  }
  // 正解の音のすぐ後ろで「シュッ」。次の問題が来る合図
  sound.cue('whoosh', { delay: WHOOSH_DELAY_S });
  mascots.play.correct(e, outcome.comboCelebration || milestone);
  // 観客: 正解数で喜び方が上がる。高い E では画面を飛び越え、飾りも E に応じて噴き出す
  crowd.cheer(cheerLevel(game.correctCount));
  crowd.leap(leaperCount(e), overlay.layout);
  props.burst(correctProps(e, milestone), overlay.layout);
  floatScore(`+${outcome.gained}`, `ドパ +${dopaDelta(outcome.dopaBefore, outcome.dopaAfter)}`);
  rollDopa(displayDopa, outcome.dopaAfter);
  // 正解では字を観客が運んでいくので、ワイプは帯だけ走らせる
  wipePad(null);
  drawHint(false);
  // 「せいかい!」のバーストが縮み始めたところで はなまる を描く (ふたつが重ならない)。
  // コンボが乗っていれば虹色の渦巻き
  const rainbow = outcome.combo >= RAINBOW_COMBO;
  window.clearTimeout(hanamaruTimer);
  hanamaruTimer = window.setTimeout(() => hanamaru.play(rainbow), HANAMARU_DELAY_MS);
  if (written !== null) {
    carryWritten(inkCopy, written, padRect, origin);
  }

  // 祝いの一言。次の問題を出すとお知らせ欄が消えるので、文面だけ先に決めておく
  let notice = outcome.safe ? 'ぎりぎり セーフ!' : '';
  const big = outcome.comboCelebration || outcome.milestones.length > 0;
  if (outcome.combo > 0 && outcome.combo % DANCE_EVERY === 0) {
    mascots.play.dance();
  }
  if (outcome.comboCelebration) {
    notice = `${outcome.combo} コンボ!`;
    effects.celebrate(e);
    sound.cue('comboMilestone', { combo: outcome.combo });
    showBanner(`${outcome.combo} コンボ!`);
    crowd.jump();
  }
  if (milestone) {
    const reached = outcome.milestones[outcome.milestones.length - 1];
    notice = `ドパ ${formatDopa(game.dopa)} とうたつ!`;
    effects.celebrate(Math.max(1.2, e));
    sound.cue('dopaMilestone', { level: reached });
    // ドパの節目は黄色の巨大な数字がはずんで出る (硬貨の雨は props.burst が降らせる)
    showBigNumber(milestoneLabel(reached));
    mascots.play.spin();
    crowd.jump();
  }
  // 大きな節目は観客が画面の下を行進する
  if (milestone || (outcome.comboCelebration && outcome.combo >= MAX_COMBO)) {
    crowd.parade();
  }
  scheduleClap(big);

  nextQuestion(outcome);
  if (notice !== '') {
    el('questionHint').textContent = notice;
  }
}

/**
 * 次の問題を出す。ステージの最終問を終えていれば (正解・パス・時間切れのどれでも)、
 * そのステージに正解があれば完走のフィナーレで祝い、次のステージの 1 問目で「ステージ n」の横断バナー。
 * @param {{stageCleared: number, clearedCorrect: number}} step Game#advance() の結果
 */
function nextQuestion(step) {
  if (step.stageCleared > 0 && step.clearedCorrect > 0) {
    effects.finale();
    sound.cue('stageClear', { stage: step.stageCleared });
    mascots.play.giant();
    crowd.parade();
    props.finale(overlay.layout);
  }
  renderQuestion();
}

/** はなまるが描き上がったころにマスコットが拍手する (もっと大きな反応があるときは譲る) */
function scheduleClap(big) {
  window.clearTimeout(clapTimer);
  if (big) {
    return;
  }
  clapTimer = window.setTimeout(() => mascots.play.clap(), CLAP_DELAY_MS);
}

/** 書いた字を観客の腕が掴んで「あつめた字」の空き枠へ運ぶ */
function carryWritten(inkCopy, dataUrl, padRect, origin) {
  const slot = collected.reserve();
  crowd.carry({
    ink: inkCopy,
    from: overlay.toLocal(padRect),
    grab: overlay.toLocal({ x: origin.x, y: origin.y, width: 0, height: 0 }),
    to: overlay.toLocal(slot.getBoundingClientRect()),
    onLand: () => collected.land(slot, dataUrl)
  });
}

/** 誤答の宣言 (おしい / もういちど) = ミス 1。同じ問題を続ける (残り時間はそのまま) */
function onMiss(outcome) {
  const close = outcome.verdict === CLOSE;
  missAt = performance.now();
  flashVerdict(close ? 'おしい!' : 'もういちど', close ? 'close' : 'bad', VERDICT_MISS_MS);
  if (close) {
    sound.cue('close');
    mascots.play.close();
  } else {
    sound.cue('wrong');
    mascots.play.wrong();
  }
  loseHeart(outcome);
  // 待ち時間を作らないよう、筆記領域はすぐ消す (判定の表示だけが 400 ms 残る)
  wipePad();
  if (outcome.gameOver) {
    scheduleGameover(HEART_BREAK_MS);
    return;
  }
  if (outcome.showsHint) {
    el('questionHint').textContent = 'うすい おてほんを なぞってみよう';
    drawHint(true);
  } else if (outcome.brokenCombo > 0) {
    el('questionHint').textContent = `${outcome.brokenCombo} コンボ しゅうりょう`;
  }
}

/**
 * 時間切れ = ミス 1。正解の字を 800 ms 見せてから次の問題へ (書き取りの学習になる)。
 * ライフが尽きたら、見せ終えてからゲームオーバーの画面を出す。
 */
function onTimeout(outcome) {
  missAt = performance.now();
  sound.cue('timeout');
  mascots.play.wrong();
  loseHeart(outcome);
  wipePad();
  drawHint(false);
  updateCountdown(null);
  showAnswer(outcome.problem.kanji);
  el('questionHint').textContent = outcome.brokenCombo > 0
    ? `${outcome.brokenCombo} コンボ しゅうりょう`
    : '';
  if (outcome.gameOver) {
    scheduleGameover(REVEAL_MS);
    return;
  }
  window.clearTimeout(revealTimer);
  revealTimer = window.setTimeout(() => {
    hideAnswer();
    if (game === null) {
      return;
    }
    const step = game.finishReveal();
    if (step !== null) {
      nextQuestion(step);
      updateHud();
    }
  }, REVEAL_MS);
}

/** 筆記領域に「じかんぎれ! こたえは 林」を出す */
function showAnswer(kanji) {
  el('answerChar').textContent = kanji;
  const node = el('answer');
  node.classList.remove('answer--on');
  void node.offsetWidth;
  node.classList.add('answer--on');
}

function hideAnswer() {
  el('answer').classList.remove('answer--on');
}

// MARK: - ライフ

/** HUD のハートを 3 つ満タンに並べ直す */
function resetHearts() {
  const host = el('lives');
  host.replaceChildren();
  for (let i = 0; i < game.lives; i += 1) {
    host.append(makeHeart());
  }
  for (let i = game.lives; i < LIVES; i += 1) {
    const heart = makeHeart();
    heart.classList.add('heart--lost');
    host.append(heart);
  }
}

/** ハート。ふだんは 1 枚で描き、割れるときだけ左右の半分 (ぎざぎざの割れ目) に差し替える */
function makeHeart() {
  const node = document.createElement('span');
  node.className = 'heart';
  node.innerHTML =
    '<svg viewBox="0 0 24 22" aria-hidden="true">'
    + '<path class="heart__whole" d="M12 21 C5 16 1 12 1 7 C1 3.5 3.6 1 6.6 1 C9 1 11 2.4 12 4.4 C13 2.4 15 1 17.4 1 C20.4 1 23 3.5 23 7 C23 12 19 16 12 21 Z"/>'
    + '<path class="heart__half heart__half--l" d="M12 21 C5 16 1 12 1 7 C1 3.5 3.6 1 6.6 1 C9 1 11 2.4 12 4.4 L10.4 8 L12.6 11 L11 14.5 Z"/>'
    + '<path class="heart__half heart__half--r" d="M12 21 C19 16 23 12 23 7 C23 3.5 20.4 1 17.4 1 C15 1 13 2.4 12 4.4 L10.4 8 L12.6 11 L11 14.5 Z"/>'
    + '</svg>';
  return node;
}

/**
 * ミス 1: ハートが割れ、画面が一瞬赤く揺れる。観客は驚き、背景の回転は止まる (missAt)。
 * @param {{lives: number}} outcome ミスのあとのライフ
 */
function loseHeart(outcome) {
  const hearts = el('lives').children;
  const heart = hearts[outcome.lives];
  if (heart) {
    heart.classList.remove('heart--refill');
    heart.classList.add('heart--break');
    window.setTimeout(() => heart.classList.add('heart--lost'), HEART_BREAK_MS);
  }
  sound.cue('lifeLost', { lives: outcome.lives });
  crowd.startle();
  window.clearTimeout(clapTimer);
  window.clearTimeout(hanamaruTimer);
  effects.jolt(HURT_JOLT_PX);
  const hurt = el('hurt');
  hurt.classList.remove('hurt--on');
  void hurt.offsetWidth;
  hurt.classList.add('hurt--on');
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

/**
 * 加点とドパの増分を浮かべる。続けて正解して前の浮遊がまだ見えているうちは 1 段上に積む
 * (連続正解が「積み上がって」見える)。
 */
function floatScore(scoreText, dopaText) {
  const now = performance.now();
  const level = floatLevel(floatStack.level, now - floatStack.at);
  floatStack = { level, at: now };
  floatText(scoreText, '', level);
  floatText(dopaText, 'dopa', level);
}

/** 筆記領域から上へ浮いて消える文字。level 段ぶん上にずらす */
function floatText(text, kind, level) {
  const rect = padwrap.getBoundingClientRect();
  const node = document.createElement('div');
  node.className = kind ? `float float--${kind}` : 'float';
  node.textContent = text;
  // 判定表示 (中央のバースト) に重ならないよう、得点は上、ドパは下へ寄せる
  const dopa = kind === 'dopa';
  const offset = (dopa ? 0.22 : -0.2) + (Math.random() - 0.5) * 0.1;
  node.style.left = `${rect.x + rect.width / 2 + rect.width * offset}px`;
  node.style.top = `${rect.y + rect.height * (dopa ? 0.82 : 0.2) - level * FLOAT_STEP_PX}px`;
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

/**
 * 横断バナーと巨大数字を置く高さ (画面の座標)。プレイ中は HUD と筆記領域の間
 * (問題文のあたり)、それ以外は画面の上から 24%。
 */
function upperBandY() {
  if (!screens.play.classList.contains('screen--on')) {
    return window.innerHeight * 0.24;
  }
  const hud = document.querySelector('.hudwrap').getBoundingClientRect();
  const top = padwrap.getBoundingClientRect().top;
  return (hud.bottom + top) / 2;
}

/** 濃紺の斜めストライプの帯に巨大な白文字 (ラスト1もん / 100てん! / EX n) が左から右へ横切る */
function showSash(text) {
  const node = el('sash');
  node.querySelector('.sash__text').textContent = text;
  node.style.setProperty('--sash-y', `${upperBandY()}px`);
  // 同じ正解でドパの節目の数字も出ていれば、はずみ終わってから横切らせる
  const wait = Math.max(0, bignumAt + BIGNUM_CLEAR_MS - performance.now());
  node.style.animationDelay = `${Math.round(wait)}ms`;
  node.classList.remove('sash--show');
  void node.offsetWidth;
  node.classList.add('sash--show');
}

/** ドパの節目: 黄色の巨大ステッカー数字 (1万 / 10万 …) がはずんで出る */
function showBigNumber(text) {
  const node = el('bignum');
  node.textContent = text;
  node.style.setProperty('--bignum-y', `${upperBandY()}px`);
  bignumAt = performance.now();
  node.classList.remove('bignum--show');
  void node.offsetWidth;
  node.classList.add('bignum--show');
}

el('passButton').addEventListener('click', () => {
  if (game === null) {
    return;
  }
  const outcome = game.pass();
  if (!outcome.passed) {
    return;
  }
  wipePad();
  drawHint(false);
  nextQuestion(outcome);
  el('questionHint').textContent = outcome.brokenCombo > 0
    ? `${outcome.brokenCombo} コンボ しゅうりょう`
    : '';
  updateHud();
});

el('quitButton').addEventListener('click', () => {
  if (game === null || !window.confirm('やめますか? つづきから あそべます')) {
    return;
  }
  recordBest(settings, game.summary());
  goTitle();
});

/** タイトルへ戻る。途中の状態は保存したまま (つづきから) */
function goTitle() {
  window.cancelAnimationFrame(frame);
  cancelJudge();
  game = null;
  sound.stopMusic();
  hideGameover();
  quietStage();
  props.clear();
  showRecords();
  show('title');
}

/** プレイ画面を離れるときに、動いているものをぜんぶ静める (常時わき出る飾りも止める) */
function quietStage() {
  window.clearTimeout(clapTimer);
  window.clearTimeout(hanamaruTimer);
  window.clearTimeout(revealTimer);
  window.clearTimeout(gameoverTimer);
  hideAnswer();
  updateCountdown(null);
  missAt = null;
  effects.setFocus(null, 0);
  props.setIntensity(0);
  props.setGarlands(0);
  lights.setOn(false);
  lights.setRainbow(false);
  crowd.stop();
  reaching = false;
  reachTag.classList.remove('reach--on', 'reach--pulse');
  padwrap.classList.remove('padwrap--max');
}

// MARK: - ループ (残り時間・カウントダウン・時間切れ)

function loop() {
  window.cancelAnimationFrame(frame);
  const step = (now) => {
    if (game === null) {
      return;
    }
    tickDopa(now);
    if (game.tick().timeUp) {
      timeUp();
    }
    if (game !== null) {
      updateTimer();
    }
    frame = window.requestAnimationFrame(step);
  };
  frame = window.requestAnimationFrame(step);
}

/** 残り時間のバー (30% 未満で赤く脈動) と、残り 5 秒からの巨大なカウントダウン */
function updateTimer() {
  const remaining = game.playing() ? game.remainingMs() : Infinity;
  // 時間切れで字を見せている間とゲームオーバーでは空のまま
  const ratio = game.playing() ? timeRatio(remaining) : 0;
  timerBar.style.transform = `scaleX(${ratio.toFixed(3)})`;
  timerBar.classList.toggle('timer__bar--low', ratio < TIME_LOW);
  updateCountdown(countdownNumber(remaining));
}

/**
 * カウントダウンの数字を出し替える (数字が変わったときだけ)。null で消す。
 * 出している間は観客とマスコットが筆記領域の方へ身を乗り出す (固唾をのむ)。
 */
function updateCountdown(n) {
  if (n === counting) {
    return;
  }
  const started = counting === null && n !== null;
  counting = n;
  crowd.setLean(reaching || counting !== null);
  if (n === null) {
    countdownBox.classList.remove('countdown--show');
    return;
  }
  if (started) {
    mascots.play.lean();
  }
  const rect = padwrap.getBoundingClientRect();
  countdownBox.style.setProperty('--countdown-y', `${rect.y + rect.height / 2}px`);
  countdownBox.textContent = String(n);
  countdownBox.dataset.n = String(n);
  countdownBox.classList.remove('countdown--show');
  void countdownBox.offsetWidth;
  countdownBox.classList.add('countdown--show');
  sound.cue('countdown', { n });
}

// MARK: - ゲームオーバー

/** ハートが割れる (または正解の字を見せ終える) のを待ってからゲームオーバーの画面を出す */
function scheduleGameover(delay) {
  window.clearTimeout(gameoverTimer);
  gameoverTimer = window.setTimeout(showGameover, delay);
}

/** 終了画面: 得点・ドパ・最大コンボ・到達ステージ・あつめた字。観客はしょんぼり座る */
function showGameover() {
  if (game === null) {
    return;
  }
  cancelJudge();
  hideAnswer();
  updateCountdown(null);
  const summary = game.summary();
  sound.cue('gameOver');
  crowd.sulk(true);
  mascots.play.gloom();
  mascots.result.gloom();
  effects.setFocus(null, 0);
  props.setIntensity(0);
  countUp(el('resultScore'), summary.score, 600);
  el('resultDopa').textContent = formatDopa(summary.dopa);
  el('resultCombo').textContent = String(summary.maxCombo);
  el('resultStage').textContent = String(summary.stage);
  el('resultCount').textContent = String(summary.collected.length);
  el('resultChars').replaceChildren(...summary.collected.map((ch) => {
    const span = document.createElement('span');
    span.className = 'gameover__char';
    span.textContent = ch;
    return span;
  }));
  const updated = recordBest(settings, summary);
  el('resultBest').textContent = updated.length > 0 ? 'さいこう きろく こうしん!' : '';
  // ゲームオーバーでも つづきから はリトライと同じ位置 (失敗した問題、ライフ 3) で残る
  persist();
  // 観客の帯は見せたまま、その下 (あつめた字の帯) から重ねる
  gameoverBox.style.top = `${el('collected').offsetTop}px`;
  gameoverBox.hidden = false;
  gameoverBox.classList.remove('gameover--in');
  void gameoverBox.offsetWidth;
  gameoverBox.classList.add('gameover--in');
}

/** 終了画面を閉じる。観客とマスコットは立ち直る */
function hideGameover() {
  window.clearTimeout(gameoverTimer);
  if (!gameoverBox.hidden) {
    mascots.play.correct(1);
  }
  gameoverBox.hidden = true;
  crowd.sulk(false);
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

/** リトライ: ライフ 3 に戻して、同じステージの失敗した問題から (得点・ドパ・あつめた字は保持) */
el('retryButton').addEventListener('click', () => {
  if (game === null || !game.retry()) {
    return;
  }
  hideGameover();
  clearPad();
  resetHearts();
  for (const heart of el('lives').children) {
    heart.classList.add('heart--refill');
  }
  sound.cue('retry');
  renderQuestion();
  updateHud();
});

el('restartButton').addEventListener('click', () => {
  clearProgress();
  sound.cue('retry');
  newGame(null);
});

el('homeButton').addEventListener('click', () => {
  goTitle();
});

// MARK: - 開始

start();
