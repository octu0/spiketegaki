// 観客 (色違いの小さなマスコット) を canvas のスプライトで描く。帯と歩く観客は overlay.js の
// カードより下の canvas (カードの後ろからのぞく)、飛び越え・パレード・運搬はカードより上の canvas。
// 筆記領域の枠内は overlay が切り抜く (運搬の腕と字のカードだけは判定のあとの一瞬なので枠に掛かってよい)。
//
// - 帯: HUD の下の帯 (#crowdBand) に何列も重なって並ぶ。人数は escalation.js の crowdCount。
//   新しく増えた観客は上から落ちてくる。
// - 歩き回る: 一部 (walkerCount) は帯を離れて、筆記領域の左の余白 → 帯 → 右の余白 の
//   コの字の道を行き来する (問題文や筆記領域を横切らない)。
// - 反応: 正解数で喜び方が段階化 (跳ねる → 紙吹雪 → 踊る → 筆記領域を囲む輪)。誤答で驚いて縮み、
//   歩いている観客は 1 秒止まる。リーチで筆記領域の方へ前のめり。節目で全員ジャンプ。
// - 飛び越え: 高い E の正解で、画面の下の端から反対の端へ放物線で跳ぶ。
// - パレード: 完走と大きな節目で、画面の下を行進する。
// - 運搬: 正解のたび、1 体の腕がゴムのように伸びて書いた字を掴み、「あつめた字」の枠へ運ぶ。
//
// マスコットの SVG は色 × 表情ごとに 1 度だけ canvas へラスタライズし、腕は canvas で描く
// (伸ばす・上げるため)。すべて requestAnimationFrame 1 本 (overlay) で更新する。

import { CROWD_COLORS, FACES, SPRITE_BOX, spriteSVG } from './mascot.js';
import {
  CHEER_CONFETTI,
  CHEER_DANCE,
  CHEER_HOP,
  CHEER_RING,
  CROWD_MAX,
  LEAPER_MAX,
  MARCHERS,
  walkerCount
} from './escalation.js';
import { NAVY } from './fx.js';

/** 帯の最前列の観客の幅 (CSS px) */
const SPRITE_W = 40;
/** 歩き回る観客・飛び越える観客・パレードの幅 */
const WALKER_W = 26;
const LEAPER_W = 44;
const MARCHER_W = 44;
/** 帯の中で隣と並べる間隔 (重なって見える幅) と、後ろの列の上がり幅 */
const SEAT_GAP = 20;
const ROW_RISE = 12;
/** ラスタライズの倍率 (高精細の画面でもにじまないように) */
const RASTER_SCALE = 2;

/** 反応の長さ (ms) */
const HOP_MS = 500;
const WAVE_STEP_MS = 18;
const STARTLE_MS = 500;
const STARTLE_PAUSE_MS = 1000;
const JUMP_MS = 1200;
const DANCE_MS = 1200;
const RING_MS = 1700;
const RING_BLEND_MS = 260;
const LEAP_MS = 1100;
/** パレードが画面を横切る時間 (ms) と、紙吹雪の尾を出す間隔 (ms) */
const PARADE_MS = 2500;
const TRAIL_MS = 130;
/** 運搬: 腕が伸びる → 運ぶ → 縮む (ms) */
const REACH_MS = 200;
const CARRY_MS = 300;
const RETRACT_MS = 200;

const ease = (t) => t * t * (3 - 2 * t);
const clamp01 = (t) => Math.min(1, Math.max(0, t));
const rand = (lo, hi) => lo + Math.random() * (hi - lo);

export class Crowd {
  /**
   * @param {object} hooks
   * @param {(x: number, y: number, n: number) => void} hooks.onConfetti 観客の手元から紙吹雪を撒く
   * @param {() => void} hooks.onFirework 花火を打ち上げる
   */
  constructor({ onConfetti = () => {}, onFirework = () => {} } = {}) {
    this.onConfetti = onConfetti;
    this.onFirework = onFirework;
    this.rasters = CROWD_COLORS.map(() => ({}));
    this.sprites = [];
    this.leapers = [];
    this.marchers = [];
    this.carries = [];
    this.paradeAt = -Infinity;
    this.trailAt = 0;
    this.lean = false;
    this.sulking = false;
    this.ringAt = -Infinity;
    this.intensity = 0;
    this.nextId = 0;
    this.load();
  }

  /** 色 × 表情ごとに SVG を canvas へ焼く (非同期。焼けるまでその組み合わせは描かない) */
  load() {
    CROWD_COLORS.forEach(([body, dark], c) => {
      for (const face of FACES) {
        const image = new Image();
        image.onload = () => {
          const canvas = document.createElement('canvas');
          canvas.width = SPRITE_BOX.width * RASTER_SCALE;
          canvas.height = SPRITE_BOX.height * RASTER_SCALE;
          canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
          this.rasters[c][face] = canvas;
        };
        image.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(spriteSVG(body, dark, face))}`;
      }
    });
  }

  /** 帯と歩き回る観客の人数 */
  get count() {
    return this.sprites.length;
  }

  /** 今描いているスプライトの総数 (帯 + 飛び越え + パレード) */
  get spriteCount() {
    return this.sprites.length + this.leapers.length + this.marchers.length;
  }

  /** 人数を合わせる。増えたぶんは画面の上から落ちてくる */
  setCount(n) {
    const target = Math.max(0, Math.min(CROWD_MAX, n));
    while (this.sprites.length > target) {
      this.sprites.pop();
    }
    while (this.sprites.length < target) {
      const id = this.nextId;
      this.nextId += 1;
      this.sprites.push({
        id,
        color: id % CROWD_COLORS.length,
        x: null,
        y: -60 - Math.random() * 40,
        vy: 0,
        falling: true,
        walker: false,
        pathPos: null,
        targetPos: null,
        dir: Math.random() < 0.5 ? 1 : -1,
        bob: Math.random() * Math.PI * 2,
        hopAt: -Infinity,
        hopDelay: 0,
        danceAt: -Infinity,
        startleAt: -Infinity,
        jumpAt: -Infinity,
        pauseUntil: 0
      });
    }
  }

  /** 新しいラウンド: 1 体から始め直す */
  reset() {
    this.stop();
    this.sprites = [];
    this.nextId = 0;
    this.setCount(1);
  }

  /** 歩く速さと飛び越えの量に使う強度 E */
  setIntensity(e) {
    this.intensity = Math.max(0, e);
  }

  // MARK: - 反応

  /**
   * 正解の喜び方。level は escalation.js の cheerLevel (正解数で段階化)。
   * 跳ねるのは全段階で共通 (左から波)。紙吹雪・踊る・輪を上に重ねる。
   */
  cheer(level, now = performance.now()) {
    if (level < CHEER_HOP) {
      return;
    }
    const band = this.sprites.filter((s) => !s.walker && s.x !== null).sort((a, b) => a.x - b.x);
    band.forEach((s, i) => {
      s.hopAt = now;
      s.hopDelay = i * WAVE_STEP_MS;
    });
    for (const s of this.sprites) {
      if (s.walker) {
        s.hopAt = now;
        s.hopDelay = 0;
      }
      if (level >= CHEER_DANCE) {
        s.danceAt = now;
      }
    }
    if (level >= CHEER_CONFETTI) {
      // 撒くのは 12 体まで (粒子を増やしすぎない)
      const throwers = this.sprites.filter((s) => s.x !== null).slice(-12);
      for (const s of throwers) {
        this.onConfetti(s.x, s.y - SPRITE_W * 1.1, 4);
      }
    }
    if (level >= CHEER_RING) {
      this.ringAt = now;
      this.onFirework();
      this.onFirework();
    }
  }

  /** 誤答: 驚いて縮み、歩いている観客は 1 秒止まる */
  startle(now = performance.now()) {
    for (const s of this.sprites) {
      s.startleAt = now;
      s.hopAt = -Infinity;
      s.danceAt = -Infinity;
      if (s.walker) {
        s.pauseUntil = now + STARTLE_PAUSE_MS;
      }
    }
    this.ringAt = -Infinity;
  }

  /** 節目: 全員が両手を上げて連続ジャンプ */
  jump(now = performance.now()) {
    for (const s of this.sprites) {
      s.jumpAt = now;
    }
  }

  /** リーチ・カウントダウン: 筆記領域の方へ前のめりになる (固唾をのむ) */
  setLean(on) {
    this.lean = on;
  }

  /** ゲームオーバー: 全員しょんぼり座り込み、歩いている観客もその場で止まる */
  sulk(on) {
    this.sulking = on;
    if (on) {
      this.ringAt = -Infinity;
      for (const s of this.sprites) {
        s.hopAt = -Infinity;
        s.danceAt = -Infinity;
        s.jumpAt = -Infinity;
      }
    }
  }

  /** 画面の下の端から反対の端へ、放物線で跳び越える観客を n 体出す */
  leap(n, layout) {
    for (let i = 0; i < n && this.leapers.length < LEAPER_MAX; i += 1) {
      const fromLeft = Math.random() < 0.5;
      const y0 = layout.h * rand(0.72, 0.92);
      this.leapers.push({
        color: Math.floor(Math.random() * CROWD_COLORS.length),
        x0: fromLeft ? -LEAPER_W : layout.w + LEAPER_W,
        x1: fromLeft ? layout.w + LEAPER_W : -LEAPER_W,
        y0,
        y1: layout.h * rand(0.72, 0.92),
        apex: layout.h * rand(0.04, 0.16),
        t: -i * 0.12,
        spin: (fromLeft ? 1 : -1) * rand(4, 8)
      });
    }
  }

  /** 完走・大きな節目: 画面の下を行進する (紙吹雪の尾つき) */
  parade(now = performance.now()) {
    this.paradeAt = now;
    this.trailAt = now;
    this.marchers = [];
    for (let i = 0; i < MARCHERS; i += 1) {
      this.marchers.push({ color: i % CROWD_COLORS.length, x: -MARCHER_W, y: 0 });
    }
  }

  /**
   * 書いた字を観客の腕が掴んで「あつめた字」の枠へ運ぶ。
   * @param {object} job
   * @param {HTMLCanvasElement} job.ink 書いた字 (筆記領域の写し)
   * @param {{x: number, y: number, w: number, h: number}} job.from 筆記領域 (overlay の座標)
   * @param {{x: number, y: number}} job.grab 掴む点 (墨の重心)
   * @param {{x: number, y: number, w: number, h: number}} job.to 枠 (overlay の座標)
   * @param {() => void} job.onLand 枠に入ったとき
   */
  carry(job, now = performance.now()) {
    const busy = new Set(this.carries.map((c) => c.carrier));
    const seated = this.sprites.filter((s) => !s.walker && !s.falling && s.x !== null && !busy.has(s));
    let carrier = null;
    let best = Infinity;
    for (const s of seated) {
      // 運ぶ先の枠の真上に近い 1 体 (前の列を優先)
      const d = Math.abs(s.x - (job.to.x + job.to.w / 2)) + (s.row ?? 0) * 30;
      if (d < best) {
        best = d;
        carrier = s;
      }
    }
    this.carries.push({ ...job, carrier, start: now, landed: false });
  }

  /** 画面を離れるときに動きを止める (人数はそのまま) */
  stop() {
    for (const c of this.carries) {
      if (!c.landed) {
        c.onLand();
      }
    }
    this.carries = [];
    this.leapers = [];
    this.marchers = [];
    this.paradeAt = -Infinity;
    this.ringAt = -Infinity;
    this.lean = false;
    this.sulking = false;
    for (const s of this.sprites) {
      s.hopAt = -Infinity;
      s.danceAt = -Infinity;
      s.startleAt = -Infinity;
      s.jumpAt = -Infinity;
    }
  }

  // MARK: - 更新

  /**
   * @param {number} dt 秒
   * @param {number} now ms
   * @param {object} layout overlay.js の measure() の結果
   */
  update(dt, now, layout) {
    this.updateSeats(dt, now, layout);
    this.updateLeapers(dt);
    this.updateParade(now, layout);
    this.updateCarries(now);
  }

  /** 帯の席を割り当てて寄せる。歩き回る観客は目的地へ歩かせる */
  updateSeats(dt, now, layout) {
    const band = layout.band;
    if (band === null) {
      return;
    }
    const walkers = walkerCount(this.sprites.length);
    // 帯を離れるのは 2 体目から (1 体目は帯に残って字を運ぶ)
    this.sprites.forEach((s, i) => {
      s.walker = i >= 1 && i <= walkers;
    });
    const seated = this.sprites.filter((s) => !s.walker);
    const perRow = Math.max(6, Math.floor((band.w - 16) / SEAT_GAP));
    const cx = band.x + band.w / 2;
    const floor = band.y + band.h;
    seated.forEach((s, j) => {
      const row = Math.floor(j / perRow);
      const k = j % perRow;
      // 真ん中から左右へ交互に詰める。後ろの列は半分ずらして上げる
      const pos = k % 2 === 0 ? k / 2 : -(k + 1) / 2;
      s.row = row;
      s.homeX = cx + pos * SEAT_GAP + (row % 2) * (SEAT_GAP / 2);
      s.homeY = floor - row * ROW_RISE;
      s.scale = 1 - row * 0.1;
    });

    for (const s of this.sprites) {
      if (s.walker) {
        this.walk(s, dt, now, layout);
        continue;
      }
      if (s.x === null) {
        s.x = s.homeX;
      }
      if (s.falling) {
        // 上から落ちてきて、席で 1 度弾む
        s.vy += 1800 * dt;
        s.y += s.vy * dt;
        if (s.y >= s.homeY) {
          s.y = s.homeY;
          if (s.vy > 260) {
            s.vy = -s.vy * 0.32;
          } else {
            s.vy = 0;
            s.falling = false;
          }
        }
      } else {
        s.y += (s.homeY - s.y) * Math.min(1, dt * 8);
      }
      s.x += (s.homeX - s.x) * Math.min(1, dt * 6);
    }
  }

  /**
   * 歩く観客: コの字の道 (walkPath) の上で目的地を選び、道に沿って歩く。着いたら少し休んで次を選ぶ。
   * 帯から道へ移るときは、今いる所から道の最寄りの点へ寄っていく。
   */
  walk(s, dt, now, layout) {
    s.scale = WALKER_W / SPRITE_W;
    s.row = 0;
    s.falling = false;
    const path = walkPath(layout);
    if (path === null) {
      return;
    }
    if (s.pathPos === null) {
      // 帯の中の今の位置から道に乗る (帯の床は道の中ほど)
      const x = s.x ?? layout.band.x + layout.band.w / 2;
      s.pathPos = path.column + Math.min(path.span, Math.max(0, x - path.left));
    }
    s.pathPos = Math.min(path.length, Math.max(0, s.pathPos));
    if (now >= s.pauseUntil && !this.sulking) {
      if (s.targetPos === null) {
        s.targetPos = Math.random() * path.length;
      }
      const d = s.targetPos - s.pathPos;
      const speed = 34 + 46 * Math.min(1.5, this.intensity);
      if (Math.abs(d) < 2) {
        s.targetPos = null;
        s.pauseUntil = now + rand(200, 900);
      } else {
        const step = Math.sign(d) * Math.min(Math.abs(d), speed * dt);
        s.pathPos += step;
        s.bob += Math.abs(step) * 0.28;
      }
    }
    const p = pathPoint(path, s.pathPos);
    if (s.x === null) {
      s.x = p.x;
      s.y = p.y;
    }
    // 道に乗るまではなめらかに寄せる (急に跳ばない)
    const k = Math.min(1, dt * 10);
    const nx = s.x + (p.x - s.x) * k;
    if (Math.abs(nx - s.x) > 0.05) {
      s.dir = nx > s.x ? 1 : -1;
    }
    s.x = nx;
    s.y += (p.y - s.y) * k;
  }

  updateLeapers(dt) {
    const alive = [];
    for (const l of this.leapers) {
      l.t += dt / (LEAP_MS / 1000);
      if (l.t < 1) {
        alive.push(l);
      }
    }
    this.leapers = alive;
  }

  updateParade(now, layout) {
    if (this.marchers.length === 0) {
      return;
    }
    const t = (now - this.paradeAt) / PARADE_MS;
    if (t >= 1) {
      this.marchers = [];
      return;
    }
    const spacing = MARCHER_W + 8;
    const head = -MARCHER_W + (layout.w + MARCHER_W * 2 + spacing * MARCHERS) * t;
    this.marchers.forEach((m, i) => {
      m.x = head - i * spacing;
      m.y = layout.h - 6 - Math.abs(Math.sin(now / 160 + i)) * 8;
    });
    if (now - this.trailAt >= TRAIL_MS) {
      this.trailAt = now;
      this.onConfetti(head, layout.h - MARCHER_W, 5);
    }
  }

  updateCarries(now) {
    const alive = [];
    for (const c of this.carries) {
      const t = now - c.start;
      if (!c.landed && t >= REACH_MS + CARRY_MS) {
        c.landed = true;
        c.onLand();
      }
      if (t < REACH_MS + CARRY_MS + RETRACT_MS) {
        alive.push(c);
      }
    }
    this.carries = alive;
  }

  // MARK: - 描画

  /** 帯の観客と歩く観客 (後ろの列から。カードより下の canvas) */
  drawCrowd(ctx, layout, now) {
    if (layout.band === null) {
      return;
    }
    const carriers = new Set(this.carries.map((c) => c.carrier));
    const ringOn = now - this.ringAt < RING_MS;
    const order = this.sprites.filter((s) => s.x !== null).sort((a, b) => (b.row - a.row) || (a.y - b.y));
    order.forEach((s) => {
      const pose = this.pose(s, now, layout, carriers.has(s), ringOn);
      this.drawSprite(ctx, s.color, pose);
    });
  }

  /** 飛び越える観客とパレード (カードより上の canvas) */
  drawVisitors(ctx, layout, now) {
    for (const l of this.leapers) {
      if (l.t < 0) {
        continue;
      }
      const u = ease(l.t);
      const x = l.x0 + (l.x1 - l.x0) * l.t;
      const base = l.y0 + (l.y1 - l.y0) * u;
      const y = base - 4 * (base - l.apex) * l.t * (1 - l.t);
      this.drawSprite(ctx, l.color, {
        x, y, scale: LEAPER_W / SPRITE_W, sx: 1, sy: 1, rot: l.spin * l.t, face: 'joy', arms: 'up'
      });
    }
    for (const m of this.marchers) {
      this.drawSprite(ctx, m.color, {
        x: m.x, y: m.y, scale: MARCHER_W / SPRITE_W, sx: 1, sy: 1,
        rot: Math.sin(now / 160) * 0.08, face: 'joy', arms: 'up'
      });
    }
  }

  /** 運搬の腕と、運ばれる字のカード (枠に掛かってよいので切り抜かない) */
  drawCarries(ctx, layout, now) {
    for (const c of this.carries) {
      const t = now - c.start;
      const card = carryCard(c, t);
      // 腕の付け根: 運ぶ観客の肩 (いなければ帯の中央)
      let shoulder;
      let color = CROWD_COLORS[0][1];
      if (c.carrier && c.carrier.x !== null) {
        const s = c.carrier;
        const k = (SPRITE_W * s.scale) / SPRITE_BOX.width;
        const side = card.x >= s.x ? 1 : 0;
        const [sx, sy] = SPRITE_BOX.shoulders[side];
        shoulder = { x: s.x + (sx - SPRITE_BOX.width / 2) * k, y: s.y + (sy - SPRITE_BOX.feet) * k };
        color = CROWD_COLORS[s.color][1];
      } else if (layout.band !== null) {
        shoulder = { x: layout.band.x + layout.band.w / 2, y: layout.band.y + layout.band.h - 14 };
      } else {
        shoulder = { x: card.x, y: 0 };
      }
      // 手の位置: 伸びる間は肩から掴む点へ、運ぶ間はカードの上端、縮む間は枠から肩へ
      let hand;
      if (t < REACH_MS) {
        const u = ease(t / REACH_MS);
        hand = { x: shoulder.x + (card.x - shoulder.x) * u, y: shoulder.y + (card.top - shoulder.y) * u };
      } else if (t < REACH_MS + CARRY_MS) {
        hand = { x: card.x, y: card.top };
      } else {
        const u = ease(clamp01((t - REACH_MS - CARRY_MS) / RETRACT_MS));
        hand = { x: card.x + (shoulder.x - card.x) * u, y: card.top + (shoulder.y - card.top) * u };
      }
      if (t < REACH_MS + CARRY_MS) {
        drawCard(ctx, c.ink, card);
      }
      drawArm(ctx, shoulder, hand, color, now);
    }
  }

  /** 1 体の姿勢 (位置・拡大・回転・表情・腕) を反応の時刻から決める */
  pose(s, now, layout, carrying, ringOn) {
    let x = s.x;
    let y = s.y;
    let sx = 1;
    let sy = 1;
    let rot = 0;
    let face = 'smile';
    let arms = 'down';

    const hop = now - s.hopAt - s.hopDelay;
    if (hop >= 0 && hop < HOP_MS) {
      const u = hop / HOP_MS;
      y -= 13 * Math.sin(Math.PI * u);
      sy = 1 + 0.08 * Math.sin(Math.PI * u);
      sx = 2 - sy;
      face = 'joy';
      arms = u < 0.6 ? 'up' : 'down';
    }
    const jump = now - s.jumpAt;
    if (jump >= 0 && jump < JUMP_MS) {
      y -= 15 * Math.abs(Math.sin((jump / JUMP_MS) * Math.PI * 4));
      face = 'joy';
      arms = 'up';
    }
    const dance = now - s.danceAt;
    if (dance >= 0 && dance < DANCE_MS) {
      rot = 0.4 * Math.sin((dance / DANCE_MS) * Math.PI * 6);
      x += 4 * Math.sin((dance / DANCE_MS) * Math.PI * 6);
      face = 'joy';
      arms = Math.sin((dance / DANCE_MS) * Math.PI * 12) > 0 ? 'up' : 'wave';
    }
    if (s.walker && now >= s.pauseUntil && !this.sulking) {
      y -= Math.abs(Math.sin(s.bob)) * 3;
      rot += Math.sin(s.bob) * 0.08;
    }
    if (ringOn && layout.pad !== null && !carrying) {
      // 筆記領域を囲む輪の上を回って踊る。入り・出は席からなめらかに寄せる
      const t = now - this.ringAt;
      const blend = ease(clamp01(Math.min(t, RING_MS - t) / RING_BLEND_MS));
      const index = this.sprites.indexOf(s);
      const p = ringPoint(layout.pad, (index / this.sprites.length + t / RING_MS * 0.5) % 1);
      x += (p.x - x) * blend;
      y += (p.y - y) * blend;
      rot += 0.3 * Math.sin(t / 90 + index);
      face = 'joy';
      arms = 'up';
    }
    if (this.lean && layout.pad !== null) {
      const cx = layout.pad.x + layout.pad.w / 2;
      rot += (cx >= x ? 1 : -1) * 0.14;
      sx *= 1.06;
      sy *= 1.06;
      if (face === 'smile') {
        face = 'surprised';
      }
    }
    const startle = now - s.startleAt;
    if (startle >= 0 && startle < STARTLE_MS) {
      const u = Math.sin((Math.PI * startle) / STARTLE_MS);
      sy *= 1 - 0.28 * u;
      sx *= 1 + 0.16 * u;
      face = 'surprised';
      arms = 'up';
    }
    if (carrying) {
      face = 'joy';
    }
    if (this.sulking) {
      // しょんぼり座る: つぶれて低くなり、少しうつむく
      sy *= 0.8;
      sx *= 1.1;
      rot = (s.id % 2 === 0 ? 1 : -1) * 0.06;
      face = 'sad';
      arms = 'down';
    }
    return { x, y, scale: s.scale, sx: sx * (s.walker ? s.dir : 1), sy, rot, face, arms };
  }

  /** スプライトを 1 体描く。原点は足の裏の中央 */
  drawSprite(ctx, color, { x, y, scale, sx, sy, rot, face, arms }) {
    const raster = this.rasters[color][face] ?? this.rasters[color].smile;
    if (!raster) {
      return;
    }
    const w = SPRITE_W * scale;
    const k = w / SPRITE_BOX.width;
    ctx.save();
    ctx.translate(x, y);
    ctx.rotate(rot);
    ctx.scale(sx, sy);
    drawSpriteArms(ctx, k, arms, CROWD_COLORS[color][1]);
    ctx.drawImage(raster, -w / 2, -SPRITE_BOX.feet * k, w, SPRITE_BOX.height * k);
    ctx.restore();
  }
}

/**
 * 歩く観客の道。筆記領域の左の余白を下から上へ → 帯の床を左から右へ → 右の余白を上から下へ、の
 * コの字 (足の位置)。余白の真ん中を通るので、筆記領域と問題文の上は横切らない。
 * 筆記領域が無い (プレイ画面でない) ときは null。
 */
export function walkPath(layout) {
  const { band, pad } = layout;
  if (band === null || pad === null) {
    return null;
  }
  const left = pad.x / 2;
  const right = (pad.x + pad.w + layout.w) / 2;
  const floor = band.y + band.h;
  const bottom = pad.y + pad.h;
  const column = Math.max(0, bottom - floor);
  const span = Math.max(0, right - left);
  return { left, right, floor, bottom, column, span, length: column * 2 + span };
}

/** 道の上の点 (pos は道の始まりからの長さ) */
export function pathPoint(path, pos) {
  if (pos <= path.column) {
    return { x: path.left, y: path.bottom - pos };
  }
  if (pos <= path.column + path.span) {
    return { x: path.left + (pos - path.column), y: path.floor };
  }
  return { x: path.right, y: path.floor + (pos - path.column - path.span) };
}

/** 筆記領域を 18 px 外側から囲む角丸四角の上の点 (u は 0〜1 で一周)。足の位置を返す */
function ringPoint(pad, u) {
  const m = 18;
  const x0 = pad.x - m;
  const y0 = pad.y - m + SPRITE_W;
  const w = pad.w + m * 2;
  const h = pad.h + m * 2;
  const per = 2 * (w + h);
  let d = u * per;
  if (d < w) {
    return { x: x0 + d, y: y0 };
  }
  d -= w;
  if (d < h) {
    return { x: x0 + w, y: y0 + d };
  }
  d -= h;
  if (d < w) {
    return { x: x0 + w - d, y: y0 + h };
  }
  d -= w;
  return { x: x0, y: y0 + h - d };
}

/**
 * 運ばれるカードの位置と大きさ。伸びる間は筆記領域の上で少し縮み、
 * 運ぶ間は山なりに枠へ向かって枠の大きさまで縮む。
 */
function carryCard(c, t) {
  const fx = c.from.x + c.from.w / 2;
  const fy = c.from.y + c.from.h / 2;
  const tx = c.to.x + c.to.w / 2;
  const ty = c.to.y + c.to.h / 2;
  const lifted = c.from.w * 0.62;
  let x;
  let y;
  let size;
  let paper;
  if (t < REACH_MS) {
    const u = ease(t / REACH_MS);
    size = c.from.w + (lifted - c.from.w) * u;
    // 掴む点 (墨の重心) の方へ寄せながら縮む
    x = fx + (c.grab.x - fx) * u * 0.4;
    y = fy + (c.grab.y - fy) * u * 0.4 - 10 * u;
    paper = 0;
  } else {
    const u = ease(clamp01((t - REACH_MS) / CARRY_MS));
    const sx = fx + (c.grab.x - fx) * 0.4;
    const sy = fy + (c.grab.y - fy) * 0.4 - 10;
    const cx = (sx + tx) / 2;
    const cy = Math.min(sy, ty) - 50;
    const v = 1 - u;
    x = v * v * sx + 2 * v * u * cx + u * u * tx;
    y = v * v * sy + 2 * v * u * cy + u * u * ty;
    size = lifted + (c.to.w - lifted) * u;
    paper = u;
  }
  return { x, y, size, top: y - size / 2 + 4, paper };
}

/** 運ばれるカード。筆記領域を離れるにつれて白い紙と枠が付く */
function drawCard(ctx, ink, card) {
  const { x, y, size, paper } = card;
  const left = x - size / 2;
  const top = y - size / 2;
  if (paper > 0) {
    ctx.save();
    ctx.globalAlpha = paper;
    ctx.fillStyle = '#ffffff';
    ctx.strokeStyle = NAVY;
    ctx.lineWidth = 2.5;
    ctx.beginPath();
    ctx.roundRect(left, top, size, size, Math.max(4, size * 0.12));
    ctx.fill();
    ctx.stroke();
    ctx.restore();
  }
  ctx.drawImage(ink, left, top, size, size);
}

/** ゴムのように伸びる腕。肩から手まで、たわんだ 2 次ベジェを太い線で */
function drawArm(ctx, from, to, color, now) {
  const mx = (from.x + to.x) / 2;
  const my = (from.y + to.y) / 2;
  const dx = to.x - from.x;
  const dy = to.y - from.y;
  const len = Math.hypot(dx, dy) || 1;
  const bend = Math.min(40, len * 0.18) * (1 + 0.25 * Math.sin(now / 70));
  const cx = mx + (-dy / len) * bend;
  const cy = my + (dx / len) * bend;
  ctx.lineCap = 'round';
  ctx.beginPath();
  ctx.moveTo(from.x, from.y);
  ctx.quadraticCurveTo(cx, cy, to.x, to.y);
  ctx.strokeStyle = NAVY;
  ctx.lineWidth = 7;
  ctx.stroke();
  ctx.strokeStyle = color;
  ctx.lineWidth = 4;
  ctx.stroke();
  ctx.beginPath();
  ctx.arc(to.x, to.y, 5.5, 0, Math.PI * 2);
  ctx.fillStyle = color;
  ctx.fill();
  ctx.lineWidth = 2.5;
  ctx.strokeStyle = NAVY;
  ctx.stroke();
}

/**
 * スプライトの腕 (体の後ろに描く)。k は viewBox 1 単位の px。
 * down = 下ろす / up = 上げる / wave = 片手を上げる
 */
function drawSpriteArms(ctx, k, arms, color) {
  const cx = SPRITE_BOX.width / 2;
  const feet = SPRITE_BOX.feet;
  SPRITE_BOX.shoulders.forEach(([sx, sy], side) => {
    const dir = side === 0 ? -1 : 1;
    const up = arms === 'up' || (arms === 'wave' && side === 1);
    const ex = sx + dir * (up ? 12 : 15);
    const ey = sy + (up ? -26 : 22);
    const qx = sx + dir * (up ? 16 : 13);
    const qy = sy + (up ? -6 : 7);
    ctx.beginPath();
    ctx.moveTo((sx - cx) * k, (sy - feet) * k);
    ctx.quadraticCurveTo((qx - cx) * k, (qy - feet) * k, (ex - cx) * k, (ey - feet) * k);
    ctx.lineCap = 'round';
    ctx.strokeStyle = NAVY;
    ctx.lineWidth = 12 * k;
    ctx.stroke();
    ctx.strokeStyle = color;
    ctx.lineWidth = 7 * k;
    ctx.stroke();
  });
}
