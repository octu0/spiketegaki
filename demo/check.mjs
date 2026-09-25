// wasm 側の推論が CPU 側 (recognize --dataset) と同じ結果になることを node で確かめる。
//
//   node demo/check.mjs [--limit 50]
//
// 使うファイル:
//   .tmp/demo/spiketegaki.wasm         make wasm で作る
//   .tmp/demo/kana.stgw                recognize --export-weights で作る
//   .tmp/datasets/kana_eval.stgk       評価データ (label u16 + 1024 byte が count 個)
//
// stgk の画素は「墨の濃さ」(0 = 紙, 255 = 墨) で、stg_classify が受け取る向きと同じなので
// そのまま渡せる。

import { readFile } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { WASI } from 'node:wasi';

const WASM_PATH = '.tmp/demo/spiketegaki.wasm';
const WEIGHTS_PATH = '.tmp/demo/kana.stgw';
const DATASET_PATH = '.tmp/datasets/kana_eval.stgk';
const JSON_WEIGHTS_PATH = '.tmp/weights/kana_R7.json';

const STGK_HEADER = 16;
const STGK_PIXELS = 32 * 32;
const STGK_SAMPLE = 2 + STGK_PIXELS;
const SIDE = 32;
const TOP_K = 5;

function parseArgs(argv) {
  const o = { limit: 50, cpu: true };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--limit') {
      o.limit = Number(argv[i + 1]);
      i += 1;
    } else if (argv[i] === '--skip-cpu') {
      o.cpu = false;
    } else if (argv[i] === '--help' || argv[i] === '-h') {
      console.log('node demo/check.mjs [--limit N] [--skip-cpu]');
      process.exit(0);
    }
  }
  return o;
}

/** CPU 側の recognize --dataset を実際に回して top-1 / top-5 の件数を取り出す */
function runCPURecognize(limit) {
  const args = [
    'run', '-c', 'release', 'recognize',
    '--weights', JSON_WEIGHTS_PATH,
    '--dataset', DATASET_PATH,
    '--limit', String(limit)
  ];
  const out = execFileSync('swift', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  const grab = (label) => {
    const m = out.match(new RegExp(`${label} 正解率: [0-9.]+\\s+\\((\\d+) / (\\d+)\\)`));
    if (!m) throw new Error(`recognize の出力から ${label} を読めません`);
    return { hit: Number(m[1]), total: Number(m[2]) };
  };
  return { top1: grab('top-1'), top5: grab('top-5'), command: `swift ${args.join(' ')}` };
}

/** stgk を読んでヘッダを検証し、サンプル配列を返す */
function readDataset(buf, limit) {
  if (buf.length < STGK_HEADER) {
    throw new Error(`${DATASET_PATH}: ヘッダが足りません (${buf.length} バイト)`);
  }
  const magic = buf.toString('latin1', 0, 4);
  if (magic !== 'STGK') {
    throw new Error(`${DATASET_PATH}: magic が STGK ではありません (${magic})`);
  }
  const version = buf.readUInt32LE(4);
  const count = buf.readUInt32LE(8);
  const side = buf.readUInt8(12);
  if (version !== 1) throw new Error(`未対応の version ${version}`);
  if (side !== SIDE) throw new Error(`side が ${side} (32 を期待)`);
  const expected = STGK_HEADER + count * STGK_SAMPLE;
  if (buf.length !== expected) {
    throw new Error(`ファイル長 ${buf.length} がヘッダから決まる ${expected} と違います`);
  }
  const n = Math.min(limit, count);
  const samples = [];
  for (let i = 0; i < n; i += 1) {
    const off = STGK_HEADER + i * STGK_SAMPLE;
    samples.push({
      label: buf.readUInt16LE(off),
      pixels: buf.subarray(off + 2, off + 2 + STGK_PIXELS)
    });
  }
  return { count, samples };
}

/** wasm を立ち上げ、重みを読み込む */
async function boot() {
  // argv が空だと Swift のランタイム起動が 71 で失敗するので、必ず argv[0] を渡す
  const wasi = new WASI({ version: 'preview1', args: ['spiketegaki'], env: {}, returnOnExit: true });
  const module = await WebAssembly.compile(await readFile(WASM_PATH));
  const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
  // SwiftPM の executable は command モジュールなので _start を通してから export を呼ぶ
  const code = wasi.start(instance);
  if (code !== 0) {
    throw new Error(`_start が ${code} で終了しました`);
  }
  const e = instance.exports;
  const mem = () => new Uint8Array(e.memory.buffer);

  const weights = await readFile(WEIGHTS_PATH);
  const wPtr = e.stg_alloc(weights.length);
  if (wPtr === 0) throw new Error('stg_alloc が失敗しました (重み)');
  mem().set(weights, wPtr);
  const rc = e.stg_load_weights(wPtr, weights.length);
  if (rc !== 0) throw new Error(`stg_load_weights が ${rc} を返しました`);
  return { e, mem, weightsBytes: weights.length };
}

/** 幅 w x 高さ h の墨マップ (Uint8Array) を分類して top-k を返す */
function classify(ctx, gray, w, h) {
  const { e, mem } = ctx;
  if (!ctx.inPtr || ctx.inLen < gray.length) {
    ctx.inPtr = e.stg_alloc(gray.length);
    ctx.inLen = gray.length;
    if (ctx.inPtr === 0) throw new Error('stg_alloc が失敗しました (入力)');
  }
  if (!ctx.idxPtr) {
    ctx.idxPtr = e.stg_alloc(TOP_K * 4);
    ctx.probPtr = e.stg_alloc(TOP_K * 4);
    ctx.normPtr = e.stg_alloc(SIDE * SIDE);
  }
  mem().set(gray, ctx.inPtr);
  const n = e.stg_classify(ctx.inPtr, w, h, TOP_K, ctx.idxPtr, ctx.probPtr);
  if (n < 0) throw new Error(`stg_classify が ${n} を返しました`);
  const buf = e.memory.buffer;
  const idx = new Int32Array(buf, ctx.idxPtr, n);
  const prob = new Float32Array(buf, ctx.probPtr, n);
  const out = [];
  for (let i = 0; i < n; i += 1) {
    out.push({
      index: idx[i],
      probability: prob[i],
      char: String.fromCodePoint(e.stg_char(idx[i]))
    });
  }
  return { top: out, micros: Number(e.stg_last_micros()) };
}

/** 256x256 のマス目に太い線分を引いた合成入力 (手書き相当) を作る */
function strokeCanvas(size, segments, width) {
  const gray = new Uint8Array(size * size);
  const r = width / 2;
  for (const [x0, y0, x1, y1] of segments) {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len2 = dx * dx + dy * dy;
    const minX = Math.max(0, Math.floor(Math.min(x0, x1) - r - 1));
    const maxX = Math.min(size - 1, Math.ceil(Math.max(x0, x1) + r + 1));
    const minY = Math.max(0, Math.floor(Math.min(y0, y1) - r - 1));
    const maxY = Math.min(size - 1, Math.ceil(Math.max(y0, y1) + r + 1));
    for (let y = minY; y <= maxY; y += 1) {
      for (let x = minX; x <= maxX; x += 1) {
        let t = len2 === 0 ? 0 : ((x - x0) * dx + (y - y0) * dy) / len2;
        t = Math.max(0, Math.min(1, t));
        const px = x0 + t * dx;
        const py = y0 + t * dy;
        const d = Math.hypot(x - px, y - py);
        if (d <= r) {
          gray[y * size + x] = 255;
        }
      }
    }
  }
  return gray;
}

function asciiPreview(bytes) {
  const ramp = ' .:-=+*#%@';
  const lines = [];
  for (let y = 0; y < SIDE; y += 1) {
    let line = '';
    for (let x = 0; x < SIDE; x += 1) {
      const v = bytes[y * SIDE + x];
      line += ramp[Math.min(ramp.length - 1, Math.floor((v / 255) * (ramp.length - 1) + 0.5))];
    }
    lines.push(line);
  }
  return lines.join('\n');
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const ctx = await boot();
  console.log(`wasm      : ${WASM_PATH}`);
  console.log(`重み      : ${WEIGHTS_PATH} (${ctx.weightsBytes} バイト)`);

  const { count, samples } = readDataset(await readFile(DATASET_PATH), opts.limit);
  console.log(`データセット: ${DATASET_PATH} (全 ${count} 件のうち先頭 ${samples.length} 件)`);

  // ウォームアップ (1 件目で確保・分岐予測を温めてから計測する)
  classify(ctx, samples[0].pixels, SIDE, SIDE);

  let top1 = 0;
  let top5 = 0;
  let totalMicros = 0;
  const predictions = [];
  for (const s of samples) {
    const { top, micros } = classify(ctx, s.pixels, SIDE, SIDE);
    totalMicros += micros;
    predictions.push(top[0].index);
    if (top[0].index === s.label) top1 += 1;
    if (top.some((t) => t.index === s.label)) top5 += 1;
  }
  const n = samples.length;
  console.log('');
  console.log('-- wasm (node) の結果 --');
  console.log(`  top-1 正解率: ${(top1 / n).toFixed(4)}  (${top1} / ${n})`);
  console.log(`  top-5 正解率: ${(top5 / n).toFixed(4)}  (${top5} / ${n})`);
  console.log(`  推論時間    : ${(totalMicros / n / 1000).toFixed(2)} ms/件 (合計 ${(totalMicros / 1000).toFixed(1)} ms)`);
  console.log(`  予測 index  : ${predictions.join(',')}`);

  let mismatch = false;
  if (opts.cpu) {
    console.log('');
    console.log('-- CPU (recognize) との照合 --');
    const cpu = runCPURecognize(n);
    console.log(`  ${cpu.command}`);
    console.log(`  CPU  top-1 ${cpu.top1.hit} / ${cpu.top1.total}   top-5 ${cpu.top5.hit} / ${cpu.top5.total}`);
    console.log(`  wasm top-1 ${top1} / ${n}   top-5 ${top5} / ${n}`);
    // recognize には 1 件ごとの予測を出す機能が無いので、top-1 / top-5 の正解数で突き合わせる
    if (cpu.top1.total !== n || cpu.top1.hit !== top1 || cpu.top5.hit !== top5) {
      console.log('  不一致: wasm と CPU で正解数が違います');
      mismatch = true;
    } else {
      console.log('  一致: wasm と CPU で top-1 / top-5 の正解数が同じ');
      console.log('  (recognize は 1 件ごとの予測を出さないので、正解数の一致で代替している)');
    }
  } else {
    console.log('');
    console.log('-- CPU との照合はスキップ (--skip-cpu) --');
  }

  // 手描き相当の合成入力 (256x256 のマス目、線幅 256/32*1.5 = 12)
  const size = 256;
  const width = (size / SIDE) * 1.5;
  const shapes = {
    '横棒 (一 のつもり)': [[40, 128, 216, 128]],
    'L 字': [[70, 40, 70, 210], [70, 210, 200, 210]],
    '縦棒': [[128, 30, 128, 226]]
  };
  console.log('');
  console.log(`-- 合成入力 (${size}x${size}、線幅 ${width}) の top-5 --`);
  for (const [name, segs] of Object.entries(shapes)) {
    const gray = strokeCanvas(size, segs, width);
    const { top, micros } = classify(ctx, gray, size, size);
    const list = top.map((t) => `${t.char}(${t.probability.toFixed(3)})`).join(' ');
    console.log(`  ${name}: ${list}   ${(micros / 1000).toFixed(2)} ms`);
  }

  // 最後の合成入力の 32x32 正規化結果 (stg_last_normalized の動作確認)
  const written = ctx.e.stg_last_normalized(ctx.normPtr);
  if (written !== SIDE * SIDE) {
    throw new Error(`stg_last_normalized が ${written} を返しました (1024 を期待)`);
  }
  const norm = new Uint8Array(ctx.e.memory.buffer, ctx.normPtr, SIDE * SIDE).slice();
  console.log('');
  console.log('-- 直前の入力 (縦棒) の 32x32 正規化結果 --');
  console.log(asciiPreview(norm));

  if (mismatch) {
    process.exit(1);
  }
}

main().catch((e) => {
  console.error('error:', e.message);
  process.exit(1);
});
