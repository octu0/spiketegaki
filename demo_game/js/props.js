// 画面に重なる飾り: 波打つストリーマー、三角旗のガーランド、硬貨の雨、包みキャンディ、
// 下から上がる風船、観客が撒く紙吹雪。overlay.js の 2 枚の canvas に描き分ける
// (筆記領域の枠内は overlay が切り抜く)。
//
// 量は強度 E で決まる (escalation.js の propRates / correctProps)。E が上がるほど常時わき出る量が増え、
// ステージの最終問やステージ 2 以降では画面が飾りで埋まる。個数は MAX_PROPS で頭打ち。

import { MAX_PROPS, propRates } from './escalation.js';
import { COIN, CONFETTI, GOLD, NAVY, PASTELS, drawShape } from './fx.js';

const STREAMER = 'streamer';
const CANDY = 'candy';
const BALLOON = 'balloon';

/** ストリーマーの色 (6 色) */
const STREAMER_COLORS = ['#f7a8c4', '#f9d65c', '#7fb3f5', '#8fd8b5', '#c7a6f0', '#ffb37a'];
/** 包みキャンディの 2 色の組 */
const CANDY_COLORS = [['#f7a8c4', '#fff4e1'], ['#7fb3f5', '#ffffff'], ['#f9d65c', '#ffb37a'], ['#8fd8b5', '#ffffff'], ['#c7a6f0', '#f7a8c4']];
/** 風船の色 */
const BALLOON_COLORS = ['#f7a8c4', '#7fb3f5', '#f9d65c', '#8fd8b5', '#c7a6f0', '#ff8f8f'];

const rand = (lo, hi) => lo + Math.random() * (hi - lo);
const pick = (list) => list[Math.floor(Math.random() * list.length)];

export class Props {
  constructor() {
    this.items = [];
    this.intensity = 0;
    this.garlands = 0;
    this.carry = { streamer: 0, candy: 0, balloon: 0, coin: 0 };
  }

  /** 常時わき出る量を決める強度 E (0 で止まる) */
  setIntensity(e) {
    this.intensity = Math.max(0, e);
  }

  /** 画面上部のガーランドの本数 (0〜3) */
  setGarlands(n) {
    this.garlands = Math.max(0, Math.min(3, n));
  }

  get count() {
    return this.items.length;
  }

  /** ぜんぶ消す (タイトルへ戻るとき) */
  clear() {
    this.items = [];
    this.carry = { streamer: 0, candy: 0, balloon: 0, coin: 0 };
  }

  push(item) {
    if (this.items.length >= MAX_PROPS) {
      this.items.shift();
    }
    this.items.push(item);
  }

  /**
   * 正解の一撃。escalation.js の correctProps が返す個数ぶん出す。
   * @param {{streamer: number, candy: number, balloon: number, coin: number}} counts
   * @param {{w: number, h: number}} layout
   */
  burst(counts, layout) {
    for (let i = 0; i < counts.streamer; i += 1) {
      this.streamer(layout);
    }
    for (let i = 0; i < counts.candy; i += 1) {
      this.candy(layout);
    }
    for (let i = 0; i < counts.balloon; i += 1) {
      this.balloon(layout, rand(0, layout.h * 0.25));
    }
    this.coinRain(counts.coin, layout);
  }

  /** ステージクリア: ストリーマーと風船を一斉に */
  finale(layout) {
    this.burst({ streamer: 10, candy: 6, balloon: 12, coin: 40 }, layout);
  }

  /** 画面の上から硬貨が降る */
  coinRain(count, layout) {
    for (let i = 0; i < count; i += 1) {
      this.push({
        kind: COIN,
        x: Math.random() * layout.w,
        y: -20 - Math.random() * layout.h * 0.5,
        vx: rand(-20, 20),
        vy: rand(140, 280),
        rotation: Math.random() * Math.PI,
        spin: rand(3, 8),
        size: rand(13, 22),
        color: pick(GOLD)
      });
    }
  }

  /** 太い波打つリボンが画面を横切る (左右どちらからも、少し斜めに) */
  streamer(layout) {
    const dir = Math.random() < 0.5 ? 1 : -1;
    const len = rand(180, 320);
    this.push({
      kind: STREAMER,
      dir,
      x: dir > 0 ? -20 : layout.w + 20,
      y: rand(layout.h * 0.05, layout.h * 0.95),
      slope: rand(-0.35, 0.35),
      speed: rand(300, 440),
      len,
      amp: rand(9, 18),
      wave: rand(80, 130),
      phase: Math.random() * Math.PI * 2,
      thick: rand(8, 13),
      color: pick(STREAMER_COLORS),
      t: 0
    });
  }

  /** 大きな包みキャンディ。画面の下の左右から回りながら投げ上げる */
  candy(layout) {
    const fromLeft = Math.random() < 0.5;
    const [a, b] = pick(CANDY_COLORS);
    this.push({
      kind: CANDY,
      x: fromLeft ? rand(-20, layout.w * 0.2) : rand(layout.w * 0.8, layout.w + 20),
      y: layout.h + 20,
      vx: (fromLeft ? 1 : -1) * rand(60, 200),
      vy: -rand(620, 860),
      rotation: Math.random() * Math.PI,
      spin: rand(-6, 6),
      size: rand(30, 44),
      color: a,
      stripe: b
    });
  }

  /** 風船。画面の下から揺れながら上がる */
  balloon(layout, lift = 0) {
    this.push({
      kind: BALLOON,
      x: rand(10, layout.w - 10),
      y: layout.h + 40 - lift,
      vy: -rand(90, 150),
      phase: Math.random() * Math.PI * 2,
      size: rand(20, 28),
      color: pick(BALLOON_COLORS),
      t: 0
    });
  }

  /** 観客の手元から紙吹雪を撒く */
  confetti(x, y, count = 6) {
    for (let i = 0; i < count; i += 1) {
      const a = -Math.PI / 2 + rand(-1.1, 1.1);
      const speed = rand(90, 220);
      this.push({
        kind: CONFETTI,
        x,
        y,
        vx: Math.cos(a) * speed,
        vy: Math.sin(a) * speed,
        rotation: Math.random() * Math.PI,
        spin: rand(-10, 10),
        size: rand(5, 9),
        color: pick(PASTELS),
        life: 0,
        ttl: rand(0.7, 1.2)
      });
    }
  }

  // MARK: - 更新

  /** 常時わき出る分を足してから、すべてを動かす */
  update(dt, layout) {
    const rates = propRates(this.intensity);
    for (const key of Object.keys(this.carry)) {
      this.carry[key] += rates[key] * dt;
    }
    while (this.carry.streamer >= 1) {
      this.carry.streamer -= 1;
      this.streamer(layout);
    }
    while (this.carry.candy >= 1) {
      this.carry.candy -= 1;
      this.candy(layout);
    }
    while (this.carry.balloon >= 1) {
      this.carry.balloon -= 1;
      this.balloon(layout);
    }
    if (this.carry.coin >= 1) {
      const n = Math.floor(this.carry.coin);
      this.carry.coin -= n;
      this.coinRain(n, layout);
    }

    const alive = [];
    for (const p of this.items) {
      if (this.move(p, dt, layout)) {
        alive.push(p);
      }
    }
    this.items = alive;
  }

  /** 1 つ動かす。画面の外へ出きった / 寿命が来たら false */
  move(p, dt, layout) {
    if (p.kind === STREAMER) {
      p.t += dt;
      p.x += p.dir * p.speed * dt;
      return p.dir > 0 ? p.x - p.len < layout.w + 40 : p.x + p.len > -40;
    }
    if (p.kind === BALLOON) {
      p.t += dt;
      p.y += p.vy * dt;
      p.x += Math.sin(p.t * 1.8 + p.phase) * 18 * dt;
      return p.y > -p.size * 3;
    }
    p.rotation += p.spin * dt;
    if (p.kind === CONFETTI) {
      p.life += dt;
      p.vy += 700 * dt;
      p.vx *= Math.pow(0.3, dt);
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      return p.life < p.ttl;
    }
    if (p.kind === CANDY) {
      p.vy += 820 * dt;
    }
    p.x += p.vx * dt;
    p.y += p.vy * dt;
    return p.y < layout.h + 60;
  }

  // MARK: - 描画

  /** ガーランド (観客の後ろ、帯の上端に張る) */
  drawGarlands(ctx, layout, time) {
    if (this.garlands === 0 || layout.band === null) {
      return;
    }
    const w = layout.w;
    for (let g = 0; g < this.garlands; g += 1) {
      const y0 = layout.band.y - 14 + g * 7;
      const sag = 16 + g * 6;
      const offset = g * 11;
      // 紐 (2 次ベジェ)。端は画面の外
      const x0 = -12;
      const x1 = w + 12;
      const cx = w / 2;
      const cy = y0 + sag * 2;
      ctx.strokeStyle = NAVY;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(x0, y0);
      ctx.quadraticCurveTo(cx, cy, x1, y0);
      ctx.stroke();
      const flags = Math.floor(w / 20);
      for (let k = 0; k <= flags; k += 1) {
        const t = (k * 20 + offset) / (x1 - x0);
        if (t > 1) {
          break;
        }
        const u = 1 - t;
        const x = u * u * x0 + 2 * u * t * cx + t * t * x1;
        const y = u * u * y0 + 2 * u * t * cy + t * t * y0;
        const flutter = Math.sin(time * 0.004 + k * 0.9 + g) * 0.18;
        ctx.save();
        ctx.translate(x, y);
        ctx.rotate(flutter);
        ctx.beginPath();
        ctx.moveTo(-6, 0);
        ctx.lineTo(6, 0);
        ctx.lineTo(0, 12);
        ctx.closePath();
        ctx.fillStyle = PASTELS[(k + g * 2) % (PASTELS.length - 1)];
        ctx.fill();
        ctx.lineWidth = 1.6;
        ctx.stroke();
        ctx.restore();
      }
    }
  }

  /** カードより下に描く飾り (ゆっくり上がる風船。問題文を隠し続けないように) */
  drawBack(ctx) {
    for (const p of this.items) {
      if (p.kind === BALLOON) {
        drawBalloon(ctx, p);
      }
    }
  }

  /** カードより上に描く飾り (すぐ通り過ぎる / 落ちていくもの) */
  drawFront(ctx) {
    for (const p of this.items) {
      if (p.kind === STREAMER) {
        drawStreamer(ctx, p);
      } else if (p.kind === CANDY) {
        ctx.save();
        ctx.translate(p.x, p.y);
        ctx.rotate(p.rotation);
        drawCandy(ctx, p);
        ctx.restore();
      } else if (p.kind !== BALLOON) {
        ctx.save();
        ctx.globalAlpha = p.kind === CONFETTI ? Math.max(0, 1 - Math.pow(p.life / p.ttl, 2)) : 1;
        ctx.translate(p.x, p.y);
        ctx.rotate(p.rotation);
        drawShape(ctx, p.kind, p.size, p.color, 2, p.rotation);
        ctx.restore();
      }
    }
    ctx.globalAlpha = 1;
  }
}

/** 波打つリボン。頭から尾へ正弦波で折れ線を引き、濃紺の縁 → 色 の順に重ねる */
function drawStreamer(ctx, p) {
  const n = 18;
  ctx.beginPath();
  for (let k = 0; k <= n; k += 1) {
    const s = (p.len * k) / n;
    const x = p.x - p.dir * s;
    const y = p.y + p.slope * (x - p.x) + p.amp * Math.sin((s / p.wave) * Math.PI * 2 + p.phase + p.t * 7);
    if (k === 0) {
      ctx.moveTo(x, y);
    } else {
      ctx.lineTo(x, y);
    }
  }
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  ctx.strokeStyle = NAVY;
  ctx.lineWidth = p.thick + 4;
  ctx.stroke();
  ctx.strokeStyle = p.color;
  ctx.lineWidth = p.thick;
  ctx.stroke();
}

/** 包みキャンディ: 楕円の本体 + 左右のねじった包み + 斜めの縞 */
function drawCandy(ctx, p) {
  const s = p.size;
  const rx = s * 0.36;
  const ry = s * 0.27;
  ctx.lineJoin = 'round';
  ctx.strokeStyle = NAVY;
  ctx.lineWidth = 2.2;
  for (const side of [-1, 1]) {
    ctx.beginPath();
    ctx.moveTo(side * rx * 0.8, 0);
    ctx.lineTo(side * s * 0.72, -ry * 1.05);
    ctx.lineTo(side * s * 0.64, 0);
    ctx.lineTo(side * s * 0.72, ry * 1.05);
    ctx.closePath();
    ctx.fillStyle = p.stripe;
    ctx.fill();
    ctx.stroke();
  }
  ctx.beginPath();
  ctx.ellipse(0, 0, rx, ry, 0, 0, Math.PI * 2);
  ctx.fillStyle = p.color;
  ctx.fill();
  ctx.save();
  ctx.clip();
  ctx.strokeStyle = p.stripe;
  ctx.lineWidth = s * 0.08;
  for (let k = -2; k <= 2; k += 1) {
    ctx.beginPath();
    ctx.moveTo(k * s * 0.16 - ry, -ry);
    ctx.lineTo(k * s * 0.16 + ry, ry);
    ctx.stroke();
  }
  ctx.restore();
  ctx.strokeStyle = NAVY;
  ctx.lineWidth = 2.2;
  ctx.beginPath();
  ctx.ellipse(0, 0, rx, ry, 0, 0, Math.PI * 2);
  ctx.stroke();
}

/** 風船: 楕円 + 結び目 + ゆれる紐 + つや */
function drawBalloon(ctx, p) {
  const r = p.size;
  const sway = Math.sin(p.t * 1.8 + p.phase);
  ctx.save();
  ctx.translate(p.x, p.y);
  ctx.rotate(sway * 0.08);
  ctx.strokeStyle = NAVY;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  ctx.moveTo(0, r + 4);
  ctx.bezierCurveTo(sway * 8, r + 16, -sway * 8, r + 28, sway * 4, r + 40);
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(-4, r + 5);
  ctx.lineTo(4, r + 5);
  ctx.lineTo(0, r - 1);
  ctx.closePath();
  ctx.fillStyle = p.color;
  ctx.fill();
  ctx.lineWidth = 2;
  ctx.stroke();
  ctx.beginPath();
  ctx.ellipse(0, 0, r * 0.84, r, 0, 0, Math.PI * 2);
  ctx.fill();
  ctx.lineWidth = 2.5;
  ctx.stroke();
  ctx.beginPath();
  ctx.ellipse(-r * 0.32, -r * 0.4, r * 0.14, r * 0.26, -0.5, 0, Math.PI * 2);
  ctx.fillStyle = 'rgba(255, 255, 255, 0.75)';
  ctx.fill();
  ctx.restore();
}
