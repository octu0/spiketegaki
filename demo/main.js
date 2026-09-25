// ブラウザから wasm の SNN を呼ぶデモ。
//
// WASI の最低限 (argv / stdout / clock) は @bjorn3/browser_wasi_shim が満たす。
// 重みは STGW v1 のバイナリを fetch して、そのまま wasm の線形メモリに写す。

import {
  WASI,
  File,
  OpenFile,
  ConsoleStdout
} from 'https://esm.sh/@bjorn3/browser_wasi_shim@0.3.0';

const WASM_URL = 'spiketegaki.wasm';
const WEIGHTS_URL = 'kana.stgw';

const SIDE = 32;          // 正規化後の一辺
const PAD = 256;          // マス目の一辺
const TOP_K = 5;
// 32x32 に落としたときのペンの太さ。学習データの線幅 (同じ測り方で 32x32 換算 3.3〜3.8 画素)
// に対し 1.5 では細すぎたので 2.0 にした。2.25 以上にすると小さい字の輪が潰れて悪化する。
const STROKE_WIDTH = (PAD / SIDE) * 2.0;
const IDLE_MS = 150;      // ペンを離してから認識するまで
// 正規化した 32x32 に残る墨の総量 (0..255 の和) の下限。255 換算で 20 画素ぶん。
// これを下回る入力は線が薄すぎ / 細すぎて、分類器の出力が文字と無関係になる
// (墨が 1 画素も閾値を越えないと ImageNormalizer は全 0 を返す)。
const MIN_INK_SUM = 5100;

const pad = document.getElementById('pad');
const preview = document.getElementById('preview');
const results = document.getElementById('results');
const statusLine = document.getElementById('status');
const timing = document.getElementById('timing');
const clearButton = document.getElementById('clear');

const padCtx = pad.getContext('2d', { willReadFrequently: true });
const previewCtx = preview.getContext('2d');

padCtx.lineWidth = STROKE_WIDTH;
padCtx.lineCap = 'round';
padCtx.lineJoin = 'round';
padCtx.strokeStyle = '#1c1b18';

// wasm 側の状態
let wasm = null;          // { exports, inPtr, idxPtr, probPtr, normPtr }
let drawing = false;
let idleTimer = 0;

function setStatus(text) {
  statusLine.textContent = text;
}

// MARK: - wasm の起動

async function boot() {
  setStatus('wasm を読み込み中…');
  // argv が空だと Swift のランタイム起動に失敗するので argv[0] を必ず渡す
  const fds = [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((m) => console.log(m)),
    ConsoleStdout.lineBuffered((m) => console.warn(m))
  ];
  const wasi = new WASI(['spiketegaki'], [], fds);

  // python3 -m http.server が .wasm に application/wasm を返さない環境があるので
  // instantiateStreaming ではなく arrayBuffer 経由で作る
  const wasmBytes = await fetchArrayBuffer(WASM_URL);
  const { instance } = await WebAssembly.instantiate(wasmBytes, {
    wasi_snapshot_preview1: wasi.wasiImport
  });
  const code = wasi.start(instance);
  if (code !== 0) {
    throw new Error(`wasm の起動が ${code} で終了しました`);
  }
  const exports = instance.exports;

  setStatus('重みを読み込み中…');
  const weights = new Uint8Array(await fetchArrayBuffer(WEIGHTS_URL));
  const weightsPtr = exports.stg_alloc(weights.length);
  if (weightsPtr === 0) {
    throw new Error('重みぶんのメモリを確保できませんでした');
  }
  new Uint8Array(exports.memory.buffer).set(weights, weightsPtr);
  const rc = exports.stg_load_weights(weightsPtr, weights.length);
  if (rc !== 0) {
    throw new Error(`重みを読み込めませんでした (コード ${rc})`);
  }

  // 使い回すバッファを 1 回だけ確保する (解放する関数は無い)
  wasm = {
    exports,
    inPtr: exports.stg_alloc(PAD * PAD),
    idxPtr: exports.stg_alloc(TOP_K * 4),
    probPtr: exports.stg_alloc(TOP_K * 4),
    normPtr: exports.stg_alloc(SIDE * SIDE)
  };
  setStatus(`準備完了 (重み ${(weights.length / 1048576).toFixed(1)} MiB)。内枠いっぱいに 1 文字書いてください。`);
}

async function fetchArrayBuffer(url) {
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`${url} を取得できませんでした (HTTP ${res.status})`);
  }
  return res.arrayBuffer();
}

// MARK: - 認識

/** マス目の墨 (アルファ値) を 0 = 紙 / 255 = 墨 の並びで取り出す */
function readInk() {
  const data = padCtx.getImageData(0, 0, PAD, PAD).data;
  const gray = new Uint8Array(PAD * PAD);
  let sum = 0;
  for (let i = 0; i < gray.length; i += 1) {
    const a = data[i * 4 + 3];
    gray[i] = a;
    sum += a;
  }
  return { gray, sum };
}

function recognize() {
  if (!wasm) {
    return;
  }
  const { gray, sum } = readInk();
  if (sum === 0) {
    showEmpty('まだ認識していません');
    timing.textContent = '';
    clearPreview();
    return;
  }

  const e = wasm.exports;
  new Uint8Array(e.memory.buffer).set(gray, wasm.inPtr);
  const n = e.stg_classify(wasm.inPtr, PAD, PAD, TOP_K, wasm.idxPtr, wasm.probPtr);
  if (n < 0) {
    setStatus(`認識に失敗しました (コード ${n})`);
    return;
  }

  // 正規化した 32x32 の墨が少なすぎるときは、分類器の出力が文字と無関係になるので候補を出さない
  const normalized = e.stg_last_normalized(wasm.normPtr) === SIDE * SIDE
    ? new Uint8Array(e.memory.buffer, wasm.normPtr, SIDE * SIDE)
    : null;
  if (normalized !== null) {
    let inkSum = 0;
    for (let i = 0; i < normalized.length; i += 1) {
      inkSum += normalized[i];
    }
    if (inkSum < MIN_INK_SUM) {
      showEmpty('まだ認識していません (線が薄すぎます)');
      timing.textContent = '';
      clearPreview();
      return;
    }
  }

  const buffer = e.memory.buffer;
  const indices = new Int32Array(buffer, wasm.idxPtr, n);
  const probabilities = new Float32Array(buffer, wasm.probPtr, n);
  const rows = [];
  for (let i = 0; i < n; i += 1) {
    rows.push({
      char: String.fromCodePoint(e.stg_char(indices[i])),
      probability: probabilities[i]
    });
  }
  showResults(rows);

  const micros = Number(e.stg_last_micros());
  timing.textContent = `推論 ${(micros / 1000).toFixed(1)} ms`;

  if (normalized !== null) {
    drawPreview(normalized);
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
});

boot().catch((error) => {
  setStatus(`エラー: ${error.message}`);
  console.error(error);
});
