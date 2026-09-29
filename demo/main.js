// ブラウザから wasm の SNN を呼ぶデモ。
//
// wasm の起動・重み読込・クロップ・薄墨ガード・分類は demo/recognizer.js に置いてある
// (書き取りゲームと共有する)。ここはこのページの UI (筆記・表示・モード・筆幅) だけ。

import {
  SIDE,
  INK_THRESHOLD,
  GUARD_EMPTY,
  boot,
  loadWeights,
  readInk,
  classify,
  isReady
} from './recognizer.js';

// 読み込める重み。語彙は共通 (3212 クラス) なので wasm はそのままで、
// stg_load_weights を呼び直すだけで差し替えられる。
const WEIGHT_SETS = [
  { id: 'kana',    label: 'かな',      url: 'kana.stgw' },
  { id: 'kanji80', label: '漢字 80 字', url: 'kanji80.stgw' }
];
const WEIGHTS_KEY = 'spiketegaki.weights';
const WEIGHTS_DEFAULT = 'kana';

const PAD = 256;          // 筆記領域の一辺
const TOP_K = 5;
// 筆幅 (筆記領域 256px 上の px)。
// 32x32 換算の太さはクロップの倍率 (= 32 / マス目の一辺) 次第で、書いた大きさによって変わる。
const PEN_MIN = 6;
const PEN_MAX = 24;
const PEN_DEFAULT = 10;
const PEN_KEY = 'spiketegaki.penWidth';
// 認識モード (区分マスク)。値は stg_classify の scriptMask で、0 = 全部。
// bit0 digits / bit1 ascii / bit2 latinUpper / bit3 latinLower / bit4 hiragana / bit5 katakana / bit6 kanji
const MODES = [
  { id: 'all',      label: '全部',     mask: 0 },
  { id: 'hiragana', label: 'ひらがな', mask: 1 << 4 },
  { id: 'katakana', label: 'カタカナ', mask: 1 << 5 },
  { id: 'alnum',    label: '英数',     mask: (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) },
  { id: 'kanji',    label: '漢字',     mask: 1 << 6 }
];
const MODE_KEY = 'spiketegaki.scriptMode';
const MODE_DEFAULT = 'all';
const IDLE_MS = 150;      // ペンを離してから認識するまで

const pad = document.getElementById('pad');
const preview = document.getElementById('preview');
const results = document.getElementById('results');
const statusLine = document.getElementById('status');
const timing = document.getElementById('timing');
const clearButton = document.getElementById('clear');
const penInput = document.getElementById('pen');
const penValue = document.getElementById('penValue');
const strokeWidthLine = document.getElementById('strokeWidth');
const modeSelect = document.getElementById('mode');
const weightsSelect = document.getElementById('weights');

const padCtx = pad.getContext('2d', { willReadFrequently: true });
const previewCtx = preview.getContext('2d');

padCtx.lineCap = 'round';
padCtx.lineJoin = 'round';
padCtx.strokeStyle = '#1c1b18';

let drawing = false;
let idleTimer = 0;
let penWidth = loadPenWidth();   // 次の筆記から使う筆幅 (px)
let modeId = loadMode();         // 認識モード (区分マスク) の id
let weightsId = loadWeightsId(); // 読み込む重みの id

function setStatus(text) {
  statusLine.textContent = text;
}

// MARK: - 起動

async function start() {
  setStatus('wasm を読み込み中…');
  await boot();
  setStatus(`重み (${weightsLabelOf(weightsId)}) を読み込み中…`);
  const bytes = await loadWeights(weightsUrlOf(weightsId));
  setStatus(`準備完了 (重み ${weightsLabelOf(weightsId)} ${(bytes / 1048576).toFixed(1)} MiB)。枠の中に 1 文字書いてください (大きさ・位置は問いません)。`);
}

// MARK: - 認識

function recognize() {
  if (!isReady()) {
    return;
  }
  let result;
  try {
    result = classify(readInk(padCtx, PAD, PAD), PAD, PAD, TOP_K, maskOf(modeId));
  } catch (error) {
    setStatus(`エラー: ${error.message}`);
    console.error(error);
    return;
  }
  if (!result.ok) {
    // 墨が無い / 点や短い線 (薄墨ガード)。どちらも候補は出さない
    showEmpty(result.reason === GUARD_EMPTY
      ? 'まだ認識していません'
      : 'まだ認識していません (線が短すぎます)');
    timing.textContent = '';
    clearPreview();
    showStrokeWidth(null);
    return;
  }

  showResults(result.rows);
  timing.textContent = `推論 ${(result.micros / 1000).toFixed(1)} ms`;

  if (result.normalized !== null) {
    drawPreview(result.normalized);
    showStrokeWidth(estimateStrokeWidth(result.normalized));
  }
}

function showResults(rows) {
  results.replaceChildren(...rows.map((r) => {
    const li = document.createElement('li');

    const glyph = document.createElement('span');
    glyph.className = 'glyph';
    glyph.textContent = r.char;

    const bar = document.createElement('span');
    bar.className = 'bar';
    const fill = document.createElement('span');
    fill.style.width = `${Math.max(0, Math.min(1, r.probability)) * 100}%`;
    bar.appendChild(fill);

    const pct = document.createElement('span');
    pct.className = 'pct';
    pct.textContent = `${(r.probability * 100).toFixed(1)}%`;

    li.append(glyph, bar, pct);
    return li;
  }));
}

function showEmpty(text) {
  const li = document.createElement('li');
  li.className = 'empty';
  li.textContent = text;
  results.replaceChildren(li);
}

/** 32x32 の正規化結果を描く (拡大は CSS の image-rendering: pixelated に任せる) */
function drawPreview(bytes) {
  const image = previewCtx.createImageData(SIDE, SIDE);
  for (let i = 0; i < SIDE * SIDE; i += 1) {
    const v = 255 - bytes[i];   // 墨 255 -> 黒
    image.data[i * 4 + 0] = v;
    image.data[i * 4 + 1] = v;
    image.data[i * 4 + 2] = v;
    image.data[i * 4 + 3] = 255;
  }
  previewCtx.putImageData(image, 0, 0);
}

function clearPreview() {
  previewCtx.clearRect(0, 0, SIDE, SIDE);
}

// MARK: - 線幅の推定

/**
 * 正規化後 32x32 の線幅 (画素) の粗い推定。
 *
 * 3x3 最小値フィルタを 1 回かけると幅 w の線は幅 w-2 になるので、墨画素の残存率
 * r = 収縮後の墨画素数 / 墨画素数 から w ≒ 2 / (1 - r)。墨の判定は 0.1 (= 26/255) 以上で、
 * 先に孤立画素 (8 近傍の墨が 2 画素未満) を落とす。アンチエイリアスの縁を拾うぶん
 * 真値より +0.9 画素ほど上に出るが、同じ式で測った学習データとの比較には使える。
 * 墨が無い / 収縮しても減らないときは null を返す。
 */
function estimateStrokeWidth(bytes) {
  const ink = new Uint8Array(bytes);   // 元の配列 (wasm メモリ) を壊さないよう写す

  // 孤立画素を落とす (学習データのごま塩ノイズと同じ前処理)
  const denoised = new Uint8Array(ink);
  for (let y = 0; y < SIDE; y += 1) {
    for (let x = 0; x < SIDE; x += 1) {
      if (ink[y * SIDE + x] < INK_THRESHOLD) {
        continue;
      }
      let neighbours = 0;
      for (let dy = -1; dy <= 1; dy += 1) {
        for (let dx = -1; dx <= 1; dx += 1) {
          if (dx === 0 && dy === 0) {
            continue;
          }
          const nx = x + dx;
          const ny = y + dy;
          if (nx >= 0 && ny >= 0 && nx < SIDE && ny < SIDE && ink[ny * SIDE + nx] >= INK_THRESHOLD) {
            neighbours += 1;
          }
        }
      }
      if (neighbours < 2) {
        denoised[y * SIDE + x] = 0;
      }
    }
  }

  // 3x3 最小値フィルタ (枠外は紙)
  let before = 0;
  let after = 0;
  for (let y = 0; y < SIDE; y += 1) {
    for (let x = 0; x < SIDE; x += 1) {
      if (denoised[y * SIDE + x] >= INK_THRESHOLD) {
        before += 1;
      }
      let m = 255;
      for (let dy = -1; dy <= 1; dy += 1) {
        for (let dx = -1; dx <= 1; dx += 1) {
          const nx = x + dx;
          const ny = y + dy;
          const v = (nx < 0 || ny < 0 || nx >= SIDE || ny >= SIDE) ? 0 : denoised[ny * SIDE + nx];
          if (v < m) {
            m = v;
          }
        }
      }
      if (m >= INK_THRESHOLD) {
        after += 1;
      }
    }
  }
  if (before === 0 || after >= before) {
    return null;
  }
  return 2 / (1 - after / before);
}

function showStrokeWidth(width) {
  strokeWidthLine.textContent = width === null
    ? '線幅 (32px 換算): — px'
    : `線幅 (32px 換算): ${width.toFixed(1)} px`;
}

// MARK: - 認識モード (区分マスク)

/** モード id から stg_classify に渡すビットマスク。知らない id は「全部」 */
function maskOf(id) {
  const mode = MODES.find((m) => m.id === id);
  return mode === undefined ? 0 : mode.mask;
}

/** localStorage に覚えたモード。無い / 知らない値なら既定値 */
function loadMode() {
  let stored = null;
  try {
    stored = window.localStorage.getItem(MODE_KEY);
  } catch (error) {
    // プライベートウィンドウなどで localStorage が使えない場合は既定値で続ける
    stored = null;
  }
  return MODES.some((m) => m.id === stored) ? stored : MODE_DEFAULT;
}

function saveMode(id) {
  try {
    window.localStorage.setItem(MODE_KEY, id);
  } catch (error) {
    // 保存できなくても認識には影響しない
  }
}

function buildModeSelect() {
  modeSelect.replaceChildren(...MODES.map((m) => {
    const option = document.createElement('option');
    option.value = m.id;
    option.textContent = m.label;
    return option;
  }));
  modeSelect.value = modeId;
}

modeSelect.addEventListener('change', () => {
  modeId = MODES.some((m) => m.id === modeSelect.value) ? modeSelect.value : MODE_DEFAULT;
  modeSelect.value = modeId;
  saveMode(modeId);
  // 直前の筆記 (canvas に残っている墨) をそのまま新しいモードで引き直す。
  // 墨が無ければ recognize が「まだ認識していません」を出す
  window.clearTimeout(idleTimer);
  recognize();
});

buildModeSelect();

// MARK: - 重みの切り替え

function weightsUrlOf(id) {
  const w = WEIGHT_SETS.find((x) => x.id === id);
  return (w === undefined ? WEIGHT_SETS[0] : w).url;
}

function weightsLabelOf(id) {
  const w = WEIGHT_SETS.find((x) => x.id === id);
  return (w === undefined ? WEIGHT_SETS[0] : w).label;
}

/** localStorage に覚えた重み。無い / 知らない値なら既定値 (かな) */
function loadWeightsId() {
  let stored = null;
  try {
    stored = window.localStorage.getItem(WEIGHTS_KEY);
  } catch (error) {
    // プライベートウィンドウなどで localStorage が使えない場合は既定値で続ける
    stored = null;
  }
  return WEIGHT_SETS.some((w) => w.id === stored) ? stored : WEIGHTS_DEFAULT;
}

function saveWeightsId(id) {
  try {
    window.localStorage.setItem(WEIGHTS_KEY, id);
  } catch (error) {
    // 保存できなくても認識には影響しない
  }
}

function buildWeightsSelect() {
  weightsSelect.replaceChildren(...WEIGHT_SETS.map((w) => {
    const option = document.createElement('option');
    option.value = w.id;
    option.textContent = w.label;
    return option;
  }));
  weightsSelect.value = weightsId;
}

weightsSelect.addEventListener('change', () => {
  const next = WEIGHT_SETS.some((w) => w.id === weightsSelect.value)
    ? weightsSelect.value
    : WEIGHTS_DEFAULT;
  weightsSelect.value = next;
  if (!isReady()) {
    // 起動前は切り替えても読み込む先が無い。選択だけ覚えておく
    weightsId = next;
    saveWeightsId(next);
    return;
  }
  weightsSelect.disabled = true;
  window.clearTimeout(idleTimer);
  setStatus(`重み (${weightsLabelOf(next)}) を読み込み中…`);
  loadWeights(weightsUrlOf(next)).then((bytes) => {
    weightsId = next;
    saveWeightsId(next);
    setStatus(`重みを ${weightsLabelOf(next)} に切り替えました (${(bytes / 1048576).toFixed(1)} MiB)。`);
    // 直前の筆記 (canvas に残っている墨) を新しい重みで引き直す
    recognize();
  }).catch((error) => {
    // 失敗したら選択を元に戻す (読み込み済みの重みはそのまま使える)
    weightsSelect.value = weightsId;
    setStatus(`エラー: ${error.message}`);
    console.error(error);
  }).finally(() => {
    weightsSelect.disabled = false;
  });
});

buildWeightsSelect();

// MARK: - 筆記

/** ポインタ座標を canvas の画素座標に直す (CSS で拡縮されていてもずれない) */
function pointOf(event) {
  const rect = pad.getBoundingClientRect();
  return {
    x: (event.clientX - rect.left) * (PAD / rect.width),
    y: (event.clientY - rect.top) * (PAD / rect.height)
  };
}

pad.addEventListener('pointerdown', (event) => {
  event.preventDefault();
  pad.setPointerCapture(event.pointerId);
  window.clearTimeout(idleTimer);
  drawing = true;
  // 筆幅はこの画にだけ効く。描画済みの墨は canvas のビットマップなので変わらない
  padCtx.lineWidth = penWidth;
  const p = pointOf(event);
  padCtx.beginPath();
  padCtx.moveTo(p.x, p.y);
  // 点だけ打った場合にも墨が残るよう、同じ位置へ 1 本引く
  padCtx.lineTo(p.x, p.y);
  padCtx.stroke();
});

pad.addEventListener('pointermove', (event) => {
  if (!drawing) {
    return;
  }
  event.preventDefault();
  const p = pointOf(event);
  padCtx.lineTo(p.x, p.y);
  padCtx.stroke();
});

function endStroke(event) {
  if (!drawing) {
    return;
  }
  drawing = false;
  if (event && pad.hasPointerCapture(event.pointerId)) {
    pad.releasePointerCapture(event.pointerId);
  }
  window.clearTimeout(idleTimer);
  idleTimer = window.setTimeout(recognize, IDLE_MS);
}

pad.addEventListener('pointerup', endStroke);
pad.addEventListener('pointercancel', endStroke);
pad.addEventListener('pointerleave', endStroke);

clearButton.addEventListener('click', () => {
  window.clearTimeout(idleTimer);
  padCtx.clearRect(0, 0, PAD, PAD);
  showEmpty('まだ認識していません');
  timing.textContent = '';
  clearPreview();
  showStrokeWidth(null);
});

// MARK: - 筆幅

/** localStorage に覚えた筆幅。無い / 壊れている / 範囲外なら既定値 */
function loadPenWidth() {
  let stored = null;
  try {
    stored = window.localStorage.getItem(PEN_KEY);
  } catch (error) {
    // プライベートウィンドウなどで localStorage が使えない場合は既定値で続ける
    stored = null;
  }
  const value = Number.parseInt(stored ?? '', 10);
  if (!Number.isFinite(value)) {
    return PEN_DEFAULT;
  }
  return Math.min(PEN_MAX, Math.max(PEN_MIN, value));
}

function savePenWidth(value) {
  try {
    window.localStorage.setItem(PEN_KEY, String(value));
  } catch (error) {
    // 保存できなくても筆記には影響しない
  }
}

/** スライダーの表示を今の筆幅に合わせる。
    32x32 換算の太さはクロップの倍率で変わるので、ここには出さない
    (認識後の「線幅 (32px 換算)」が実測値) */
function showPenWidth() {
  penInput.value = String(penWidth);
  penValue.textContent = `${penWidth} px`;
}

penInput.addEventListener('input', () => {
  const value = Number.parseInt(penInput.value, 10);
  if (!Number.isFinite(value)) {
    return;
  }
  penWidth = Math.min(PEN_MAX, Math.max(PEN_MIN, value));
  showPenWidth();
  savePenWidth(penWidth);
});

showPenWidth();

start().catch((error) => {
  setStatus(`エラー: ${error.message}`);
  console.error(error);
});
