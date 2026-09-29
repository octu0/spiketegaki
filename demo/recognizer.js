// ブラウザから wasm の SNN を呼ぶための認識器。
//
// WASI の最低限 (argv / stdout / clock) は @bjorn3/browser_wasi_shim が満たす。
// 重みは STGW v1 のバイナリを fetch して、そのまま wasm の線形メモリに写す。
//
// 筆記領域の canvas を持つ側 (デモ・ゲーム) が readInk で墨を取り出し、classify に渡す。
// クロップと薄墨ガードはここに閉じているので、調整すると両方に同時に効く。

import {
  WASI,
  File,
  OpenFile,
  ConsoleStdout
} from 'https://esm.sh/@bjorn3/browser_wasi_shim@0.3.0';

export const SIDE = 32;          // 正規化後の一辺
// 墨がマス目の長辺に占める割合。フォントから作った学習データでは字の高さが em ボックスの
// 0.81〜0.88 に集まるので、クロップした墨をこの割合で正方形の中央に置くと学習時と同じ大きさになる。
const INK_RATIO = 0.85;
// クロップ後のマス目の最小の一辺。太い筆で小さく書くと外接矩形が 32 画素を下回り、
// 拡大しても情報が増えないどころか筆の粒が拡大されるだけなので、そこで止める。
const MIN_CELL = SIDE;
// 薄墨ガード。クロップ**前**の筆記領域 (256px) 上の墨で判定する。
// クロップは小さな墨も 32x32 いっぱいに拡大するので、正規化後の墨量では
// 「点 1 つ」「短い線」を弾けない (拡大後は墨が十分に見えてしまう)。
// 外接矩形の長辺と墨画素数の両方がこれらを満たさない入力は、文字として成立していない。
const MIN_INK_SIDE = 24;      // 墨の外接矩形の長辺の下限 (筆記領域 256px 上の px)
const MIN_INK_PIXELS = 300;   // 閾値を越えた墨画素数の下限
// 墨とみなす下限 (0..255)。ImageNormalizer.inkThreshold = 0.1 と同じ (0.1 * 255 = 25.5 -> 26)
export const INK_THRESHOLD = 26;

// classify が分類まで進まなかった理由
export const GUARD_EMPTY = 'empty';         // 墨が 1 画素も無い
const GUARD_TOO_SMALL = 'tooSmall';  // 墨はあるが文字として成立していない (点・短い線)

const DEFAULT_WASM_URL = 'spiketegaki.wasm';

// wasm 側の状態。boot が入れるまで null
let wasm = null;

/** boot 済みかどうか */
export function isReady() {
  return wasm !== null;
}

// MARK: - wasm の起動

/** wasm を立ち上げて呼び出し用のバッファを確保する。重みはまだ読まない */
export async function boot(wasmUrl = DEFAULT_WASM_URL) {
  // argv が空だと Swift のランタイム起動に失敗するので argv[0] を必ず渡す
  const fds = [
    new OpenFile(new File([])),
    ConsoleStdout.lineBuffered((m) => console.log(m)),
    ConsoleStdout.lineBuffered((m) => console.warn(m))
  ];
  const wasi = new WASI(['spiketegaki'], [], fds);

  // python3 -m http.server が .wasm に application/wasm を返さない環境があるので
  // instantiateStreaming ではなく arrayBuffer 経由で作る
  const wasmBytes = await fetchArrayBuffer(wasmUrl);
  const { instance } = await WebAssembly.instantiate(wasmBytes, {
    wasi_snapshot_preview1: wasi.wasiImport
  });
  const code = wasi.start(instance);
  if (code !== 0) {
    throw new Error(`wasm の起動が ${code} で終了しました`);
  }
  const exports = instance.exports;

  // 使い回すバッファ (解放する関数は無いので、足りている限り確保し直さない)
  wasm = {
    exports,
    normPtr: exports.stg_alloc(SIDE * SIDE),
    inPtr: 0,
    inCapacity: 0,
    idxPtr: 0,
    probPtr: 0,
    topCapacity: 0,
    weightsPtr: 0,
    weightsCapacity: 0
  };
}

/** 重み (STGW) を取得して wasm に読ませる。読み込んだバイト数を返す。
    語彙と入出力次元は共通なので、stg_load_weights を呼び直せば分類器が差し替わる。
    重み用のバッファは足りている限り使い回す (解放する関数が無いため) */
export async function loadWeights(url) {
  const weights = new Uint8Array(await fetchArrayBuffer(url));
  const { exports } = wasm;
  if (wasm.weightsCapacity < weights.length) {
    const ptr = exports.stg_alloc(weights.length);
    if (ptr === 0) {
      throw new Error('重みぶんのメモリを確保できませんでした');
    }
    wasm.weightsPtr = ptr;
    wasm.weightsCapacity = weights.length;
  }
  new Uint8Array(exports.memory.buffer).set(weights, wasm.weightsPtr);
  const rc = exports.stg_load_weights(wasm.weightsPtr, weights.length);
  if (rc !== 0) {
    throw new Error(`重みを読み込めませんでした (コード ${rc})`);
  }
  return weights.length;
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
export function readInk(ctx, width, height) {
  const data = ctx.getImageData(0, 0, width, height).data;
  const gray = new Uint8Array(width * height);
  for (let i = 0; i < gray.length; i += 1) {
    gray[i] = data[i * 4 + 3];
  }
  return gray;
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

/** 墨が文字として成立しているか (薄墨ガード)。crop は cropToCell の戻り値 */
function passesInkGuard(crop) {
  return Math.max(crop.inkWidth, crop.inkHeight) >= MIN_INK_SIDE && crop.inkPixels >= MIN_INK_PIXELS;
}

function ensureBuffers(inputLength, topK) {
  const { exports } = wasm;
  if (wasm.inCapacity < inputLength) {
    // 解放する関数が無いので、確保し直す回数を抑えるために倍々で伸ばす
    const size = Math.max(inputLength, wasm.inCapacity * 2);
    const ptr = exports.stg_alloc(size);
    if (ptr === 0) {
      throw new Error('入力ぶんのメモリを確保できませんでした');
    }
    wasm.inPtr = ptr;
    wasm.inCapacity = size;
  }
  if (wasm.topCapacity < topK) {
    const idxPtr = exports.stg_alloc(topK * 4);
    const probPtr = exports.stg_alloc(topK * 4);
    if (idxPtr === 0 || probPtr === 0) {
      throw new Error('候補ぶんのメモリを確保できませんでした');
    }
    wasm.idxPtr = idxPtr;
    wasm.probPtr = probPtr;
    wasm.topCapacity = topK;
  }
}

/**
 * 筆記領域の墨をクロップして分類する。
 *
 * @param {Uint8Array} gray 墨の濃さ (0 = 紙, 255 = 墨) の width * height 配列
 * @param {number} topK 返す候補の数
 * @param {number} mask 区分ビットマスク (0 = 全部。bit0 digits / bit1 ascii /
 *                      bit2 latinUpper / bit3 latinLower / bit4 hiragana / bit5 katakana / bit6 kanji)
 * @returns {{ok: true, rows: {char: string, probability: number}[], normalized: Uint8Array|null,
 *            micros: number, crop: object}
 *         | {ok: false, reason: string, crop: object|null}}
 */
export function classify(gray, width, height, topK, mask) {
  const crop = cropToCell(gray, width, height, INK_THRESHOLD, INK_RATIO, MIN_CELL);
  if (crop === null) {
    return { ok: false, reason: GUARD_EMPTY, crop: null };
  }
  // 薄墨ガード。クロップ前の実寸で見るので、点や短い線はここで止まる
  if (!passesInkGuard(crop)) {
    return { ok: false, reason: GUARD_TOO_SMALL, crop };
  }

  const e = wasm.exports;
  ensureBuffers(crop.cell.length, topK);
  new Uint8Array(e.memory.buffer).set(crop.cell, wasm.inPtr);
  const n = e.stg_classify(
    wasm.inPtr, crop.side, crop.side, topK, mask, wasm.idxPtr, wasm.probPtr
  );
  if (n < 0) {
    throw new Error(`認識に失敗しました (コード ${n})`);
  }

  // 32x32 の正規化結果 (薄墨の判定はクロップ前に済ませてある)。
  // wasm のメモリは伸びると別の ArrayBuffer になるので、呼び出し側には写しを渡す
  const normalized = e.stg_last_normalized(wasm.normPtr) === SIDE * SIDE
    ? new Uint8Array(e.memory.buffer, wasm.normPtr, SIDE * SIDE).slice()
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

  return { ok: true, rows, normalized, micros: Number(e.stg_last_micros()), crop };
}
