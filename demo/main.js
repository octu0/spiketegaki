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
const PAD = 256;          // 筆記領域の一辺
const TOP_K = 5;
// 墨がマス目の長辺に占める割合。フォントから作った学習データでは字の高さが em ボックスの
// 0.81〜0.88 に集まるので、クロップした墨をこの割合で正方形の中央に置くと学習時と同じ大きさになる。
const INK_RATIO = 0.85;
// クロップ後のマス目の最小の一辺。太い筆で小さく書くと外接矩形が 32 画素を下回り、
// 拡大しても情報が増えないどころか筆の粒が拡大されるだけなので、そこで止める。
const MIN_CELL = SIDE;
// 筆幅 (筆記領域 256px 上の px)。
// 32x32 換算の太さはクロップの倍率 (= 32 / マス目の一辺) 次第で、書いた大きさによって変わる。
const PEN_MIN = 6;
const PEN_MAX = 24;
const PEN_DEFAULT = 10;
const PEN_KEY = 'spiketegaki.penWidth';
const IDLE_MS = 150;      // ペンを離してから認識するまで
// 薄墨ガード。クロップ**前**の筆記領域 (256px) 上の墨で判定する。
// クロップは小さな墨も 32x32 いっぱいに拡大するので、正規化後の墨量では
// 「点 1 つ」「短い線」を弾けない (拡大後は墨が十分に見えてしまう)。
// 外接矩形の長辺と墨画素数の両方がこれらを満たさない入力は、文字として成立していない。
const MIN_INK_SIDE = 24;      // 墨の外接矩形の長辺の下限 (筆記領域 256px 上の px)
const MIN_INK_PIXELS = 300;   // 閾値を越えた墨画素数の下限
// 墨とみなす下限 (0..255)。ImageNormalizer.inkThreshold = 0.1 と同じ (0.1 * 255 = 25.5 -> 26)
const INK_THRESHOLD = 26;

const pad = document.getElementById('pad');
const preview = document.getElementById('preview');
const results = document.getElementById('results');
const statusLine = document.getElementById('status');
const timing = document.getElementById('timing');
const clearButton = document.getElementById('clear');
const penInput = document.getElementById('pen');
const penValue = document.getElementById('penValue');
const strokeWidthLine = document.getElementById('strokeWidth');

const padCtx = pad.getContext('2d', { willReadFrequently: true });
const previewCtx = preview.getContext('2d');

padCtx.lineCap = 'round';
padCtx.lineJoin = 'round';
padCtx.strokeStyle = '#1c1b18';

// wasm 側の状態
let wasm = null;          // { exports, inPtr, idxPtr, probPtr, normPtr }
let drawing = false;
let idleTimer = 0;
let penWidth = loadPenWidth();   // 次の筆記から使う筆幅 (px)

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

  // 使い回すバッファを 1 回だけ確保する (解放する関数は無い)。
  // クロップ後のマス目は最大で一辺 ceil(PAD / INK_RATIO) (墨が筆記領域いっぱいのとき)
  const maxCell = Math.ceil(PAD / INK_RATIO);
  wasm = {
    exports,
    inPtr: exports.stg_alloc(maxCell * maxCell),
    idxPtr: exports.stg_alloc(TOP_K * 4),
    probPtr: exports.stg_alloc(TOP_K * 4),
    normPtr: exports.stg_alloc(SIDE * SIDE)
  };
  setStatus(`準備完了 (重み ${(weights.length / 1048576).toFixed(1)} MiB)。枠の中に 1 文字書いてください (大きさ・位置は問いません)。`);
}

async function fetchArrayBuffer(url) {
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`${url} を取得できませんでした (HTTP ${res.status})`);
  }
  return res.arrayBuffer();
}

// MARK: - 認識

/** 筆記領域の墨 (アルファ値) を 0 = 紙 / 255 = 墨 の並びで取り出す */
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

// === crop:begin === (.tmp のオフライン検証がこの範囲をそのまま切り出して使う)
/**
 * 墨の外接矩形を切り出して「1 マス目」に仕立てる。
 *
 * 枠 (中心線・内枠) を出すと人は枠の内側に小さく書いてしまい、フォント (em の約 85% を字が
 * 占める) との大きさのずれで誤認識する。小書き仮名は語彙に無いので大きさの情報は要らない。
 * そこで墨の外接矩形を取り、長辺 L が一辺の `inkRatio` を占めるような白い正方形
 * (一辺 S = ceil(L / inkRatio)、ただし `minCell` 未満にはしない) の中央に置く。
 *
 * `inkWidth` / `inkHeight` / `inkPixels` はクロップ**前**の筆記領域上の実寸で、
 * 薄墨ガード (呼び出し側) が「文字として成立しているか」を測るのに使う。
 *
 * @param {Uint8Array} gray 墨の濃さ (0 = 紙, 255 = 墨) の width * height 配列
 * @param {number} threshold 墨とみなす下限 (0..255)
 * @returns {{cell: Uint8Array, side: number, inkWidth: number, inkHeight: number, inkPixels: number}|null}
 *          しきい値を越える墨が 1 画素も無ければ null
 */
function cropToCell(gray, width, height, threshold, inkRatio, minCell) {
  let minX = width;
  let minY = height;
  let maxX = -1;
  let maxY = -1;
  let inkPixels = 0;
  for (let y = 0; y < height; y += 1) {
    for (let x = 0; x < width; x += 1) {
      if (gray[y * width + x] < threshold) {
        continue;
      }
      inkPixels += 1;
      if (x < minX) { minX = x; }
      if (x > maxX) { maxX = x; }
      if (y < minY) { minY = y; }
      if (y > maxY) { maxY = y; }
    }
  }
  if (maxX < 0) {
    return null;
  }
  const inkWidth = maxX - minX + 1;
  const inkHeight = maxY - minY + 1;
  const side = Math.max(minCell, Math.ceil(Math.max(inkWidth, inkHeight) / inkRatio));
  // 0 = 紙 なので、確保したままが白地
  const cell = new Uint8Array(side * side);
  const offsetX = Math.floor((side - inkWidth) / 2);
  const offsetY = Math.floor((side - inkHeight) / 2);
  for (let y = 0; y < inkHeight; y += 1) {
    for (let x = 0; x < inkWidth; x += 1) {
      // しきい値未満の縁 (アンチエイリアス) も外接矩形の中なら濃さのまま写す
      cell[(offsetY + y) * side + offsetX + x] = gray[(minY + y) * width + minX + x];
    }
  }
  return { cell, side, inkWidth, inkHeight, inkPixels };
}
// === crop:end ===

function recognize() {
  if (!wasm) {
    return;
  }
  const { gray, sum } = readInk();
  const crop = sum === 0 ? null : cropToCell(gray, PAD, PAD, INK_THRESHOLD, INK_RATIO, MIN_CELL);
  if (crop === null) {
    showEmpty('まだ認識していません');
    timing.textContent = '';
    clearPreview();
    showStrokeWidth(null);
    return;
  }

  // 薄墨ガード。クロップ前の実寸で見るので、点や短い線はここで止まる
  if (Math.max(crop.inkWidth, crop.inkHeight) < MIN_INK_SIDE || crop.inkPixels < MIN_INK_PIXELS) {
    showEmpty('まだ認識していません (線が短すぎます)');
    timing.textContent = '';
    clearPreview();
    showStrokeWidth(null);
    return;
  }

  const e = wasm.exports;
  new Uint8Array(e.memory.buffer).set(crop.cell, wasm.inPtr);
  const n = e.stg_classify(wasm.inPtr, crop.side, crop.side, TOP_K, wasm.idxPtr, wasm.probPtr);
  if (n < 0) {
    setStatus(`認識に失敗しました (コード ${n})`);
    return;
  }

  // プレビューと線幅表示に使う 32x32 (薄墨の判定はクロップ前に済ませてある)
  const normalized = e.stg_last_normalized(wasm.normPtr) === SIDE * SIDE
    ? new Uint8Array(e.memory.buffer, wasm.normPtr, SIDE * SIDE)
    : null;

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
    showStrokeWidth(estimateStrokeWidth(normalized));
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

boot().catch((error) => {
  setStatus(`エラー: ${error.message}`);
  console.error(error);
});
