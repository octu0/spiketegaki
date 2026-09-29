// 背景 (パステルのサンバーストと漂う装飾) と、正解・節目で噴き出す粒子。
// Canvas 2D だけで描き、外部の素材は読み込まない。
//
// canvas は 2 枚を画面いっぱいに敷き、どちらも画面の中身より下に置く
// (結果の得点・記録が粒子で隠れないようにするため):
//   #bg  サンバースト + 常時漂う装飾
//   #fx  噴き出す粒子 + コンボの集中線
// 描画は requestAnimationFrame 1 本にまとめ、画面が隠れている間は止める。
//
// 強度 E (0.08〜1.5) で粒子の種類と量を段階的に足す:
//   E < 0.4   紙吹雪・丸
//   E < 0.75  + 星・ハート
//   それ以上  + コイン・リボン・火花

const GRAVITY = 900;          // px/s^2
const MAX_PARTICLES = 600;    // 上限 (これを越えたら古いものから捨てる)

const CONFETTI = 'confetti';
const STAR = 'star';
const CIRCLE = 'circle';
const HEART = 'heart';
const COIN = 'coin';
const RIBBON = 'ribbon';
const SPARK = 'spark';
const ROCKET = 'rocket';

/** 濃紺の輪郭線 */
const NAVY = '#2b2e5a';
/** サンバーストと装飾のパステル (この順で繰り返す) */
const PASTELS = ['#f7a8c4', '#f9d65c', '#7fb3f5', '#8fd8b5', '#c7a6f0', '#fff4e1'];
/** 金色 (フィナーレ用) */
const GOLD = ['#f9d65c', '#ffe9a3', '#e8b93c', '#fff4e1'];

const STRIPES = 18;           // サンバーストのストライプ数
const AMBIENT = 22;           // 常時漂う装飾の数
const BURST_KINDS = [CONFETTI, CIRCLE, STAR, HEART, COIN, RIBBON];
const AMBIENT_KINDS = [CONFETTI, STAR, HEART, COIN, RIBBON, CIRCLE];

function pick(list) {
  return list[Math.floor(Math.random() * list.length)];
}

export class Effects {
  /**
   * @param {HTMLCanvasElement} bg 背景の canvas
   * @param {HTMLCanvasElement} canvas 粒子の canvas
   * @param {HTMLElement} shakeTarget 揺らす要素
   */
  constructor(bg, canvas, shakeTarget) {
    this.bg = bg;
    this.bgCtx = bg.getContext('2d');
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.shakeTarget = shakeTarget;
    this.particles = [];
    this.ambient = [];
    this.shake = 0;          // 残りの揺れの強さ (px)
    this.angle = 0;          // サンバーストの回転
    this.intensity = 0.3;    // 強度 E
    this.spin = 1;           // 回転の倍率 (コンボで上がる)
    this.recoilMs = 0;       // 残りの「逆回転で弾む」時間
    this.beatMs = 500;       // 1 拍の長さ (背景の脈動)
    this.beatPhase = 0;
    this.beat = 0;           // 数えた拍 (電飾の順送りに使う)
    this.onBeat = null;      // 1 拍ごとに呼ぶ (電飾・リーチの脈動を拍に合わせる)
    this.focus = null;       // 集中線 { rect, level }
    this.last = 0;
    this.running = false;
    this.resize();
    window.addEventListener('resize', () => this.resize());
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) {
        this.start();
      }
    });
    this.start();
  }

  resize() {
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    this.width = this.canvas.clientWidth || window.innerWidth;
    this.height = this.canvas.clientHeight || window.innerHeight;
    for (const [node, ctx] of [[this.bg, this.bgCtx], [this.canvas, this.ctx]]) {
      node.width = Math.round(this.width * dpr);
      node.height = Math.round(this.height * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    this.ambient = [];
    for (let i = 0; i < AMBIENT; i += 1) {
      this.ambient.push(this.makeAmbient(Math.random() * this.height));
    }
  }

  /** 強度 E。背景の回転と脈動、粒子の量と種類に効く */
  setIntensity(e) {
    this.intensity = Math.max(0, e);
  }

  /** BGM の 1 拍の長さ (ms)。背景の脈動をこれに合わせる */
  setBeat(ms) {
    this.beatMs = Math.max(120, ms);
  }

  /** サンバーストの回転倍率 (コンボで 1 倍 → 3 倍) */
  setSpin(rate) {
    this.spin = Math.max(0, rate);
  }

  /** 正解の瞬間に 1 拍だけ逆回転して弾む */
  recoil() {
    this.recoilMs = this.beatMs;
    this.start();
  }

  /**
   * コンボの集中線。level 0 で消える。
   * @param {{x: number, y: number, width: number, height: number}|null} rect 筆記領域
   * @param {number} level 0〜1
   */
  setFocus(rect, level) {
    this.focus = level > 0 && rect !== null ? { rect, level } : null;
  }

  // MARK: - 粒子

  /** 中央付近から粒子を撒く。intensity が上がるほど量と種類が増える */
  burst(intensity, origin = null, palette = PASTELS) {
    const x = origin ? origin.x : this.width / 2;
    const y = origin ? origin.y : this.height * 0.45;
    const e = Math.max(0, intensity);
    const count = Math.round(14 + 46 * Math.min(1.5, e));
    for (let i = 0; i < count; i += 1) {
      this.push(this.makeParticle(x, y, e, palette));
    }
    this.shake = Math.max(this.shake, e < 0.4 ? 0 : 2 + 8 * Math.min(1.5, e));
    this.start();
  }

  /** 節目やコンボ祝いの、より派手な一撃。花火も打ち上げる */
  celebrate(intensity, palette = PASTELS) {
    for (let i = 0; i < 3; i += 1) {
      this.burst(Math.max(1, intensity), {
        x: this.width * (0.25 + 0.25 * i),
        y: this.height * (0.3 + 0.1 * (i % 2))
      }, palette);
    }
    this.firework(palette);
  }

  /** 打ち上げ花火。上がりきったところで破裂する (破裂は step() が作る) */
  firework(palette = PASTELS) {
    this.push({
      kind: ROCKET,
      x: this.width * (0.2 + Math.random() * 0.6),
      y: this.height + 10,
      vx: (Math.random() - 0.5) * 60,
      vy: -(520 + Math.random() * 160),
      life: 0,
      ttl: 0.75 + Math.random() * 0.25,
      size: 4,
      spin: 0,
      rotation: 0,
      color: pick(palette),
      palette
    });
    this.start();
  }

  /** ドパの節目: 画面の上から硬貨が降る */
  coinRain(count = 26) {
    for (let i = 0; i < count; i += 1) {
      this.push({
        kind: COIN,
        x: Math.random() * this.width,
        y: -20 - Math.random() * this.height * 0.5,
        vx: (Math.random() - 0.5) * 40,
        vy: 120 + Math.random() * 140,
        life: 0,
        ttl: 1.6 + Math.random() * 0.8,
        size: 12 + Math.random() * 9,
        spin: 3 + Math.random() * 5,
        rotation: Math.random() * Math.PI,
        color: pick(GOLD),
        palette: GOLD
      });
    }
    this.start();
  }

  /** 完走: 左右の下からリボンを打ち上げる */
  streamers(count = 18) {
    for (let i = 0; i < count; i += 1) {
      const fromLeft = i % 2 === 0;
      this.push({
        kind: RIBBON,
        x: fromLeft ? -10 : this.width + 10,
        y: this.height + 10,
        vx: (fromLeft ? 1 : -1) * (180 + Math.random() * 200),
        vy: -(620 + Math.random() * 220),
        life: 0,
        ttl: 1.6 + Math.random() * 0.6,
        size: 14 + Math.random() * 12,
        spin: (Math.random() - 0.5) * 6,
        rotation: Math.random() * Math.PI,
        color: pick(PASTELS),
        palette: PASTELS
      });
    }
    this.start();
  }

  /** パレードの尾。行進の足もとに紙吹雪をこぼす (画面は揺らさない) */
  trail(origin, count = 5) {
    for (let i = 0; i < count; i += 1) {
      const a = -Math.PI / 2 + (Math.random() - 0.5) * Math.PI;
      const speed = 60 + Math.random() * 120;
      this.push({
        kind: Math.random() < 0.7 ? CONFETTI : RIBBON,
        x: origin.x + (Math.random() - 0.5) * 40,
        y: origin.y,
        vx: Math.cos(a) * speed,
        vy: Math.sin(a) * speed,
        life: 0,
        ttl: 0.7 + Math.random() * 0.6,
        size: 6 + Math.random() * 7,
        spin: (Math.random() - 0.5) * 10,
        rotation: Math.random() * Math.PI,
        color: pick(PASTELS),
        palette: PASTELS
      });
    }
    this.start();
  }

  /** 正解のたび、書いた墨の重心から小さな星が噴き出す */
  sparkle(origin, count = 12) {
    for (let i = 0; i < count; i += 1) {
      const a = -Math.PI / 2 + (Math.random() - 0.5) * Math.PI * 1.6;
      const speed = 120 + Math.random() * 180;
      this.push({
        kind: STAR,
        x: origin.x,
        y: origin.y,
        vx: Math.cos(a) * speed,
        vy: Math.sin(a) * speed,
        life: 0,
        ttl: 0.5 + Math.random() * 0.4,
        size: 6 + Math.random() * 6,
        spin: (Math.random() - 0.5) * 14,
        rotation: Math.random() * Math.PI,
        color: pick(PASTELS),
        palette: PASTELS
      });
    }
    this.start();
  }

  /** 基本完走のフィナーレ。金色の粒子と花火を連発する */
  finale() {
    this.streamers();
    for (let i = 0; i < 6; i += 1) {
      window.setTimeout(() => this.celebrate(1.5, GOLD), i * 220);
      window.setTimeout(() => this.firework(GOLD), i * 220 + 110);
    }
  }

  /** 上限を守って 1 つ足す */
  push(p) {
    if (this.particles.length >= MAX_PARTICLES) {
      this.particles.shift();
    }
    this.particles.push(p);
  }

  makeParticle(x, y, e, palette) {
    const limit = e >= 0.75 ? BURST_KINDS.length : (e >= 0.4 ? 4 : 2);
    const kind = BURST_KINDS[Math.floor(Math.random() * limit)];
    const angle = -Math.PI / 2 + (Math.random() - 0.5) * Math.PI * 1.1;
    const speed = 160 + Math.random() * 260 * (0.6 + e);
    return {
      kind,
      x,
      y,
      vx: Math.cos(angle) * speed,
      vy: Math.sin(angle) * speed,
      life: 0,
      ttl: 0.9 + Math.random() * 0.9,
      size: kind === CONFETTI ? 5 + Math.random() * 7 : 5 + Math.random() * 6,
      spin: (Math.random() - 0.5) * 12,
      rotation: Math.random() * Math.PI,
      color: pick(palette),
      palette
    };
  }

  /** 花火の破裂。火花を放射状に撒く */
  explode(rocket) {
    const n = 26;
    for (let i = 0; i < n; i += 1) {
      const a = (i / n) * Math.PI * 2 + Math.random() * 0.1;
      const speed = 170 + Math.random() * 130;
      this.push({
        kind: SPARK,
        x: rocket.x,
        y: rocket.y,
        vx: Math.cos(a) * speed,
        vy: Math.sin(a) * speed,
        life: 0,
        ttl: 0.7 + Math.random() * 0.5,
        size: 3 + Math.random() * 3,
        spin: 0,
        rotation: 0,
        color: pick(rocket.palette),
        palette: rocket.palette
      });
    }
  }

  /** 常時漂う装飾を 1 つ作る */
  makeAmbient(y) {
    return {
      kind: pick(AMBIENT_KINDS),
      x: Math.random() * this.width,
      y,
      vy: 10 + Math.random() * 22,
      vx: (Math.random() - 0.5) * 10,
      size: 8 + Math.random() * 12,
      rotation: Math.random() * Math.PI * 2,
      spin: (Math.random() - 0.5) * 0.8,
      color: pick(PASTELS)
    };
  }

  // MARK: - ループ

  start() {
    if (this.running) {
      return;
    }
    this.running = true;
    this.last = performance.now();
    window.requestAnimationFrame((t) => this.frame(t));
  }

  frame(time) {
    const dt = Math.min(0.05, (time - this.last) / 1000);
    this.last = time;
    if (document.hidden) {
      // 見えていない間は描かない (見えたら visibilitychange が start() し直す)
      this.running = false;
      return;
    }
    this.step(dt);
    this.drawBackdrop();
    this.draw();
    window.requestAnimationFrame((t) => this.frame(t));
  }

  step(dt) {
    const e = Math.min(1.5, this.intensity);
    // 1 拍だけ逆回転して弾む (正解の瞬間)。それ以外はコンボの倍率ぶん速く回す
    const speed = (0.02 + 0.07 * e) * this.spin;
    if (this.recoilMs > 0) {
      this.recoilMs -= dt * 1000;
      this.angle -= speed * 1.8 * dt;
    } else {
      this.angle += speed * dt;
    }
    const phase = this.beatPhase + (dt * 1000) / this.beatMs;
    this.beatPhase = phase % 1;
    if (phase >= 1) {
      this.beat += 1;
      if (this.onBeat !== null) {
        this.onBeat(this.beat);
      }
    }

    for (const a of this.ambient) {
      a.y += a.vy * dt;
      a.x += a.vx * dt;
      a.rotation += a.spin * dt;
      if (a.y - a.size > this.height) {
        Object.assign(a, this.makeAmbient(-a.size - Math.random() * 60));
      }
    }

    const alive = [];
    for (const p of this.particles) {
      p.life += dt;
      if (p.life >= p.ttl) {
        if (p.kind === ROCKET) {
          this.explode(p);
        }
        continue;
      }
      p.vy += GRAVITY * (p.kind === SPARK ? 0.3 : (p.kind === ROCKET ? 0.42 : 1)) * dt;
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      p.rotation += p.spin * dt;
      alive.push(p);
    }
    this.particles = alive;

    if (this.shake > 0.1) {
      this.shake *= Math.pow(0.02, dt);
      const dx = (Math.random() - 0.5) * 2 * this.shake;
      const dy = (Math.random() - 0.5) * 2 * this.shake;
      this.shakeTarget.style.transform = `translate(${dx.toFixed(2)}px, ${dy.toFixed(2)}px)`;
    } else if (this.shake !== 0) {
      this.shake = 0;
      this.shakeTarget.style.transform = '';
    }
  }

  // MARK: - 背景

  drawBackdrop() {
    const ctx = this.bgCtx;
    const w = this.width;
    const h = this.height;
    ctx.clearRect(0, 0, w, h);

    const cx = w * 0.5;
    const cy = h * 0.3;
    // 拍に合わせてわずかに脈動する (強度が高いほど強く)
    const amp = 0.012 + 0.03 * Math.min(1.5, this.intensity);
    const scale = 1 + amp * Math.pow(1 - this.beatPhase, 3);
    const radius = Math.hypot(Math.max(cx, w - cx), Math.max(cy, h - cy)) * 1.15 * scale;

    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate(this.angle);
    ctx.lineWidth = 3;
    ctx.strokeStyle = NAVY;
    ctx.lineJoin = 'round';
    for (let i = 0; i < STRIPES; i += 1) {
      const a0 = (i / STRIPES) * Math.PI * 2;
      const a1 = ((i + 1) / STRIPES) * Math.PI * 2;
      ctx.beginPath();
      ctx.moveTo(0, 0);
      ctx.arc(0, 0, radius, a0, a1);
      ctx.closePath();
      ctx.fillStyle = PASTELS[i % PASTELS.length];
      ctx.fill();
      ctx.stroke();
    }
    ctx.restore();

    // 中心はストライプが収束して文字が読みにくいので、白くぼかす
    const glow = ctx.createRadialGradient(cx, cy, 0, cx, cy, radius * 0.34);
    glow.addColorStop(0, 'rgba(255, 255, 255, 0.82)');
    glow.addColorStop(0.55, 'rgba(255, 255, 255, 0.34)');
    glow.addColorStop(1, 'rgba(255, 255, 255, 0)');
    ctx.fillStyle = glow;
    ctx.fillRect(0, 0, w, h);

    for (const a of this.ambient) {
      ctx.save();
      ctx.globalAlpha = 0.9;
      ctx.translate(a.x, a.y);
      ctx.rotate(a.rotation);
      drawShape(ctx, a.kind, a.size, a.color, 2, a.rotation);
      ctx.restore();
    }
    ctx.globalAlpha = 1;
  }

  // MARK: - 粒子と集中線

  draw() {
    const ctx = this.ctx;
    ctx.clearRect(0, 0, this.width, this.height);
    this.drawFocus();
    for (const p of this.particles) {
      ctx.globalAlpha = Math.max(0, 1 - Math.pow(p.life / p.ttl, 2));
      ctx.save();
      ctx.translate(p.x, p.y);
      ctx.rotate(p.rotation);
      drawShape(ctx, p.kind, p.size, p.color, 2, p.rotation);
      ctx.restore();
    }
    ctx.globalAlpha = 1;
  }

  /** 筆記領域の周りの集中線 (コンボが乗ったとき) */
  drawFocus() {
    if (this.focus === null) {
      return;
    }
    const { rect, level } = this.focus;
    const ctx = this.ctx;
    const cx = rect.x + rect.width / 2;
    const cy = rect.y + rect.height / 2;
    const inner = Math.hypot(rect.width, rect.height) / 2 + 6;
    const outer = inner + 70 + 90 * level;
    const lines = 26;
    ctx.save();
    ctx.translate(cx, cy);
    ctx.globalAlpha = 0.28 + 0.4 * level;
    ctx.strokeStyle = NAVY;
    ctx.lineCap = 'round';
    for (let i = 0; i < lines; i += 1) {
      const a = (i / lines) * Math.PI * 2 + this.angle * 1.6;
      const wobble = 0.85 + 0.3 * Math.sin(i * 2.7 + this.beatPhase * Math.PI * 2);
      ctx.lineWidth = 1.5 + 3 * level * (i % 2 === 0 ? 1 : 0.5);
      ctx.beginPath();
      ctx.moveTo(Math.cos(a) * inner, Math.sin(a) * inner);
      ctx.lineTo(Math.cos(a) * outer * wobble, Math.sin(a) * outer * wobble);
      ctx.stroke();
    }
    ctx.restore();
    ctx.globalAlpha = 1;
  }
}

/**
 * 輪郭線つきの図形を原点に描く。
 * phase は硬貨の「回って見える」つぶれ具合に使う (呼び出し側の回転角)。
 */
function drawShape(ctx, kind, size, color, lineWidth, phase = 0) {
  ctx.fillStyle = color;
  ctx.strokeStyle = NAVY;
  ctx.lineWidth = lineWidth;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  if (kind === CONFETTI) {
    ctx.beginPath();
    ctx.rect(-size / 2, -size / 3, size, size / 1.5);
    ctx.fill();
    ctx.stroke();
    return;
  }
  if (kind === STAR) {
    starPath(ctx, size);
    ctx.fill();
    ctx.stroke();
    return;
  }
  if (kind === HEART) {
    heartPath(ctx, size);
    ctx.fill();
    ctx.stroke();
    return;
  }
  if (kind === COIN) {
    // 回転して見えるよう、横幅を回転角で縮める
    const squash = Math.max(0.12, Math.abs(Math.cos(phase * 1.7)));
    ctx.beginPath();
    ctx.ellipse(0, 0, size / 2, (size / 2) * squash, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.stroke();
    ctx.beginPath();
    ctx.ellipse(0, 0, size / 3.2, (size / 3.2) * squash, 0, 0, Math.PI * 2);
    ctx.stroke();
    return;
  }
  if (kind === RIBBON) {
    ctx.beginPath();
    ctx.moveTo(-size * 0.5, -size * 0.6);
    ctx.bezierCurveTo(size * 0.6, -size * 0.3, -size * 0.6, size * 0.3, size * 0.5, size * 0.6);
    ctx.lineWidth = Math.max(2.5, size / 3.5);
    ctx.strokeStyle = color;
    ctx.stroke();
    ctx.lineWidth = lineWidth * 0.6;
    ctx.strokeStyle = NAVY;
    ctx.stroke();
    return;
  }
  // 丸・火花
  ctx.beginPath();
  ctx.arc(0, 0, size / 2, 0, Math.PI * 2);
  ctx.fill();
  if (kind !== SPARK) {
    ctx.stroke();
  }
}

function starPath(ctx, size) {
  const outer = size * 0.75;
  const inner = outer * 0.45;
  ctx.beginPath();
  for (let i = 0; i < 10; i += 1) {
    const r = i % 2 === 0 ? outer : inner;
    const a = (Math.PI / 5) * i - Math.PI / 2;
    const x = Math.cos(a) * r;
    const y = Math.sin(a) * r;
    if (i === 0) {
      ctx.moveTo(x, y);
    } else {
      ctx.lineTo(x, y);
    }
  }
  ctx.closePath();
}

function heartPath(ctx, size) {
  const s = size * 0.6;
  ctx.beginPath();
  ctx.moveTo(0, s * 0.9);
  ctx.bezierCurveTo(-s * 1.5, -s * 0.2, -s * 0.6, -s * 1.2, 0, -s * 0.35);
  ctx.bezierCurveTo(s * 0.6, -s * 1.2, s * 1.5, -s * 0.2, 0, s * 0.9);
  ctx.closePath();
}

/**
 * 「せいかい!」などを載せる放射状のバースト形。SVG の polygon の points を作る。
 * @param {number} spikes とがりの数
 */
export function starburstPoints(spikes = 14) {
  const pts = [];
  for (let i = 0; i < spikes * 2; i += 1) {
    const r = i % 2 === 0 ? 50 : 33;
    const a = (Math.PI / spikes) * i - Math.PI / 2;
    pts.push(`${(50 + Math.cos(a) * r).toFixed(2)},${(50 + Math.sin(a) * r).toFixed(2)}`);
  }
  return pts.join(' ');
}

/**
 * 「はなまる」の花の輪郭。中心 (50, 50) のまわりに花びらを並べた閉じたパス。
 * @param {number} petals 花びらの数
 * @param {number} outer 花びらの先の半径
 * @param {number} inner 花びらの谷の半径
 */
export function flowerPath(petals = 8, outer = 44, inner = 30) {
  const at = (r, a) => [50 + Math.cos(a) * r, 50 + Math.sin(a) * r];
  const step = (Math.PI * 2) / petals;
  const [sx, sy] = at(inner, -Math.PI / 2);
  const parts = [`M${sx.toFixed(2)} ${sy.toFixed(2)}`];
  for (let i = 0; i < petals; i += 1) {
    const a0 = -Math.PI / 2 + step * i;
    // 花びら 1 枚を 2 本の 2 次ベジェで描く (谷 → 先 → 次の谷)
    const [cx1, cy1] = at(outer * 1.22, a0 + step * 0.22);
    const [px, py] = at(outer, a0 + step * 0.5);
    const [cx2, cy2] = at(outer * 1.22, a0 + step * 0.78);
    const [nx, ny] = at(inner, a0 + step);
    parts.push(`Q${cx1.toFixed(2)} ${cy1.toFixed(2)} ${px.toFixed(2)} ${py.toFixed(2)}`);
    parts.push(`Q${cx2.toFixed(2)} ${cy2.toFixed(2)} ${nx.toFixed(2)} ${ny.toFixed(2)}`);
  }
  parts.push('Z');
  return parts.join(' ');
}
