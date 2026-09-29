// 観客とパレード。筆記領域の下に色違いの小さなマスコットを並べ、正解・誤答・節目に反応させる。
//
// DOM の数は固定 (観客 6 体、パレード 6 体) で、増減は display の出し入れだけで行う。
// 動きはすべて CSS の transform (style.css の .fan--* / .parade--*)。

import { mascotSVG, CROWD_COLORS } from './mascot.js';

/** 観客の最大人数 (DOM をこの数だけ作って display で出し入れする) */
const SEATS = CROWD_COLORS.length;
/** 正解の波。左から 1 体ずつずらす間隔 (ms) */
const WAVE_STEP_MS = 60;
/** パレードが画面を横切る時間 (ms) */
export const PARADE_MS = 2500;
/** パレード中に紙吹雪の尾を出す間隔 (ms) */
const TRAIL_MS = 130;

/** 反応ごとのアニメの長さ (ms) */
const DURATIONS = { hop: 520, startle: 520, jump: 1200 };

export class Crowd {
  /**
   * @param {HTMLElement} host 観客を並べる要素
   * @param {HTMLElement} paradeHost パレードを入れる要素 (画面下に固定)
   * @param {(x: number, y: number) => void} onTrail パレードの尾を出す
   */
  constructor(host, paradeHost, onTrail = () => {}) {
    this.host = host;
    this.paradeHost = paradeHost;
    this.onTrail = onTrail;
    this.timers = [];
    this.paradeTimer = 0;
    this.trailTimer = 0;

    this.seats = CROWD_COLORS.map(([body, dark]) => {
      const node = document.createElement('div');
      node.className = 'fan';
      node.innerHTML = mascotSVG(body, dark);
      host.append(node);
      return node;
    });

    this.marchers = CROWD_COLORS.map(([body, dark], i) => {
      const node = document.createElement('div');
      node.className = 'parade__member';
      node.innerHTML = mascotSVG(body, dark);
      node.style.setProperty('--march-delay', `${i * 90}ms`);
      paradeHost.append(node);
      return node;
    });
    this.setCount(SEATS);
  }

  /** 見せる人数 (2〜6)。余りは display: none で隠す */
  setCount(count) {
    const n = Math.min(SEATS, Math.max(0, count));
    this.seats.forEach((node, i) => {
      node.style.display = i < n ? '' : 'none';
    });
  }

  /** 反応を 1 つ再生する。左から WAVE_STEP_MS ずつ遅らせると波になる */
  play(name, stagger) {
    for (const timer of this.timers) {
      window.clearTimeout(timer);
    }
    this.timers = [];
    for (const node of this.seats) {
      node.classList.remove('fan--hop', 'fan--startle', 'fan--jump');
    }
    // クラスを付け直す前にレイアウトを確定させて、同じ反応でもアニメを頭から流す
    void this.host.offsetWidth;
    this.seats.forEach((node, i) => {
      node.style.animationDelay = stagger ? `${i * WAVE_STEP_MS}ms` : '0ms';
      node.classList.add(`fan--${name}`);
    });
    const total = DURATIONS[name] + (stagger ? (SEATS - 1) * WAVE_STEP_MS : 0);
    this.timers.push(window.setTimeout(() => {
      for (const node of this.seats) {
        node.classList.remove(`fan--${name}`);
      }
    }, total));
  }

  /** 正解: 左から順に跳ねる (波) */
  wave() {
    this.play('hop', true);
  }

  /** 誤答: 驚いて縮む */
  startle() {
    this.play('startle', false);
  }

  /** 節目: 全員が両手を上げて連続ジャンプ */
  jump() {
    this.play('jump', false);
  }

  /** リーチ: 前のめりになる */
  setLean(on) {
    this.host.classList.toggle('fans--lean', on);
  }

  /** 完走・大きな節目: 画面の下を横切って行進する (紙吹雪の尾つき) */
  parade() {
    window.clearTimeout(this.paradeTimer);
    window.clearInterval(this.trailTimer);
    this.paradeHost.classList.remove('parade--on');
    void this.paradeHost.offsetWidth;
    this.paradeHost.classList.add('parade--on');
    const started = performance.now();
    this.trailTimer = window.setInterval(() => {
      const t = (performance.now() - started) / PARADE_MS;
      if (t >= 1) {
        window.clearInterval(this.trailTimer);
        return;
      }
      // 行進の先頭あたりに尾を落とす (CSS の translateX と同じ道すじ)
      const rect = this.paradeHost.getBoundingClientRect();
      this.onTrail(rect.x + rect.width * (t * 1.2 - 0.1), rect.y + rect.height * 0.4);
    }, TRAIL_MS);
    this.paradeTimer = window.setTimeout(() => {
      this.paradeHost.classList.remove('parade--on');
    }, PARADE_MS);
  }

  /** 画面を離れるときに動きを止める */
  stop() {
    window.clearTimeout(this.paradeTimer);
    window.clearInterval(this.trailTimer);
    for (const timer of this.timers) {
      window.clearTimeout(timer);
    }
    this.timers = [];
    this.paradeHost.classList.remove('parade--on');
    this.setLean(false);
  }
}
