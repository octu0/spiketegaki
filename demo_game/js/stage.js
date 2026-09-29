// 筆記領域まわりの飾り: 電飾・はなまる・消去のワイプ・「あつめた字」の帯。
//
// どれも DOM の数を先に作っておき、再生のたびにクラスと transform を付け替えるだけにする
// (毎回の生成でごみが増えないようにするため)。形は SVG、動きは CSS と Web Animations。

import { flowerPath } from './fx.js';
import { collectedSlots } from './scoring.js';

/** 枠のまわりに並べる電球の数 (辺ごとに 4 つ) */
const BULBS = 16;
/** 電球の色 (4 種。i % 4 で割り当てる) */
const BULB_COLORS = ['#f7a8c4', '#f9d65c', '#7fb3f5', '#8fd8b5'];
/** 拍ごとに点く電球の間隔 (4 つに 1 つ) */
const BULB_STRIDE = 4;

/** はなまるを描く時間 (ms) と、消えるまでの時間 (ms)。
    判定バーストが縮んでいく間に描き上がり、次の問題を書き始めるころには消えている */
const HANAMARU_DRAW_MS = 250;
const HANAMARU_TOTAL_MS = 520;

/** 書いた字が帯へ飛ぶ時間 (ms) */
export const FLY_MS = 300;

/**
 * 枠の外側に電球を並べる位置 (百分率)。i を辺の長さで割って四辺に配る。
 * @returns {{left: number, top: number}}
 */
export function bulbPosition(i, count = BULBS) {
  const t = ((i % count) / count) * 4;
  const side = Math.floor(t);
  const f = t - side;
  if (side === 0) {
    return { left: f * 100, top: 0 };
  }
  if (side === 1) {
    return { left: 100, top: f * 100 };
  }
  if (side === 2) {
    return { left: (1 - f) * 100, top: 100 };
  }
  return { left: 0, top: (1 - f) * 100 };
}

/** 筆記領域の枠の外側で点滅する電飾。拍ごとに順送りし、MAX コンボで全点灯する */
export class Lights {
  /** @param {HTMLElement} host 電球を並べる要素 (筆記領域と同じ大きさ) */
  constructor(host) {
    this.host = host;
    this.bulbs = [];
    for (let i = 0; i < BULBS; i += 1) {
      const node = document.createElement('span');
      node.className = 'bulb';
      const { left, top } = bulbPosition(i);
      node.style.left = `${left}%`;
      node.style.top = `${top}%`;
      node.style.setProperty('--bulb-color', BULB_COLORS[i % BULB_COLORS.length]);
      host.append(node);
      this.bulbs.push(node);
    }
    this.on = false;
    this.rainbow = false;
    this.apply();
  }

  /** 電飾そのものを点けるか (強度が低いあいだは消しておく) */
  setOn(on) {
    this.on = on;
    this.apply();
  }

  /** MAX コンボ: 順送りをやめて虹色に全点灯する。強度が低くてもこのときは点ける */
  setRainbow(on) {
    this.rainbow = on;
    if (on) {
      for (const bulb of this.bulbs) {
        bulb.classList.add('bulb--on');
      }
    }
    this.apply();
  }

  apply() {
    this.host.classList.toggle('lights--on', this.on || this.rainbow);
    this.host.classList.toggle('lights--rainbow', this.rainbow);
  }

  /** 1 拍ぶん送る。4 つに 1 つが点く */
  tick(beat) {
    if (this.rainbow) {
      return;
    }
    this.bulbs.forEach((bulb, i) => {
      bulb.classList.toggle('bulb--on', (i + beat) % BULB_STRIDE === 0);
    });
  }
}

/** 正解の瞬間、筆記領域の上に赤い「はなまる」(花の輪郭 + 二重丸) を筆で描く */
export class Hanamaru {
  /** @param {HTMLElement} host 筆記領域に重ねる要素 */
  constructor(host) {
    this.host = host;
    host.innerHTML =
      `<svg viewBox="0 0 100 100" aria-hidden="true">`
      + `<path class="hanamaru__flower" d="${flowerPath(8, 44, 31)}"/>`
      + `<circle class="hanamaru__ring" cx="50" cy="50" r="27"/>`
      + `<circle class="hanamaru__ring" cx="50" cy="50" r="20"/>`
      + `</svg>`;
    this.flower = host.querySelector('.hanamaru__flower');
    this.rings = [...host.querySelectorAll('.hanamaru__ring')];
    this.fade = null;
  }

  /** 1 回描く。花の輪郭 → 二重丸 の順に筆を走らせ、書き取りの丸付けらしく見せる */
  play() {
    if (typeof this.host.animate !== 'function') {
      return;
    }
    this.host.classList.add('hanamaru--on');
    this.draw(this.flower, 0, HANAMARU_DRAW_MS * 0.64);
    this.rings.forEach((ring, i) => {
      this.draw(ring, HANAMARU_DRAW_MS * (0.44 + i * 0.16), HANAMARU_DRAW_MS * 0.4);
    });
    if (this.fade !== null) {
      this.fade.cancel();
    }
    this.fade = this.host.animate(
      [{ opacity: 1, offset: 0 }, { opacity: 1, offset: 0.7 }, { opacity: 0, offset: 1 }],
      { duration: HANAMARU_TOTAL_MS, easing: 'linear' }
    );
    this.fade.onfinish = () => this.host.classList.remove('hanamaru--on');
  }

  /** 1 本の線を dash で「書いていく」 */
  draw(node, delay, duration) {
    const length = node.getTotalLength();
    node.style.strokeDasharray = String(length);
    node.animate(
      [{ strokeDashoffset: length, offset: 0 }, { strokeDashoffset: length, offset: 0.0001 },
       { strokeDashoffset: 0, offset: 1 }],
      { duration: duration + delay, easing: 'cubic-bezier(.35,.85,.45,1)' }
    );
  }
}

/** 消去のワイプ (ms)。白い帯が左から右へ走り、その裏で墨が消えていく */
export const WIPE_MS = 150;

/**
 * 筆記領域を消すときのワイプ。消す直前に写した墨を帯の下に置き、帯が通ったところから
 * 順に切り落としていく。canvas 自体はもう空なので、書き足しはこの間も邪魔されない。
 */
export class Wipe {
  /** @param {HTMLElement} node 筆記領域に重ねる要素 */
  constructor(node) {
    this.node = node;
    node.innerHTML = '<img class="wipe__ink" alt=""><span class="wipe__band"></span>';
    this.ink = node.querySelector('.wipe__ink');
    this.timer = 0;
  }

  /** @param {string|null} dataUrl 消す直前の墨。無ければ帯だけ走らせる */
  play(dataUrl = null) {
    this.ink.style.display = dataUrl === null ? 'none' : '';
    if (dataUrl !== null) {
      this.ink.src = dataUrl;
    }
    window.clearTimeout(this.timer);
    this.node.classList.remove('wipe--on');
    void this.node.offsetWidth;
    this.node.classList.add('wipe--on');
    this.timer = window.setTimeout(() => this.node.classList.remove('wipe--on'), WIPE_MS);
  }
}

/**
 * 「あつめた字」の帯。ラウンドの 10 枠を空カードで見せ、正解するたびに
 * 書いた字がそのままカードになって埋まる。エクストラでは枠が増えて横に伸びる。
 */
export class Collected {
  /** @param {HTMLElement} host 帯の中身を入れる要素 */
  constructor(host, flightHost) {
    this.host = host;
    this.flightHost = flightHost;
    this.slots = [];
    this.count = 0;
    this.reset();
  }

  reset() {
    this.count = 0;
    this.slots = [];
    this.host.replaceChildren();
    this.grow(collectedSlots(0));
    this.host.scrollLeft = 0;
  }

  /** 枠を total 個まで増やす */
  grow(total) {
    while (this.slots.length < total) {
      const slot = document.createElement('div');
      slot.className = 'slot';
      this.host.append(slot);
      this.slots.push(slot);
    }
  }

  /** 次に埋まる枠 */
  nextSlot() {
    this.grow(collectedSlots(this.count + 1));
    return this.slots[this.count];
  }

  /**
   * 書いた字を帯へ飛ばして収める。
   * @param {string} dataUrl 筆記領域を写した画像
   * @param {DOMRect} from 飛び立つ位置 (筆記領域)
   */
  collect(dataUrl, from) {
    const slot = this.nextSlot();
    this.count += 1;
    const to = slot.getBoundingClientRect();
    const flyer = document.createElement('img');
    flyer.className = 'flyer';
    flyer.src = dataUrl;
    flyer.alt = '';
    flyer.style.width = `${from.width}px`;
    flyer.style.height = `${from.height}px`;
    this.flightHost.append(flyer);

    const x0 = from.x + from.width / 2;
    const y0 = from.y + from.height / 2;
    const x1 = to.x + to.width / 2;
    const y1 = to.y + to.height / 2;
    // 山なりに飛ばす (2 次ベジェ。制御点は中点の少し上)
    const cx = (x0 + x1) / 2;
    const cy = Math.min(y0, y1) - Math.abs(y1 - y0) * 0.35 - 40;
    const scale0 = from.width > 0 ? Math.min(1, to.width / from.width) : 0.2;
    const started = performance.now();
    const step = (now) => {
      const t = Math.min(1, (now - started) / FLY_MS);
      const u = 1 - t;
      const x = u * u * x0 + 2 * u * t * cx + t * t * x1;
      const y = u * u * y0 + 2 * u * t * cy + t * t * y1;
      const s = 1 + (scale0 - 1) * t;
      flyer.style.transform = `translate(${x}px, ${y}px) translate(-50%, -50%) scale(${s.toFixed(3)})`;
      if (t < 1) {
        window.requestAnimationFrame(step);
        return;
      }
      flyer.remove();
      slot.classList.add('slot--filled');
      slot.replaceChildren(makeCard(dataUrl));
      slot.classList.remove('slot--pop');
      void slot.offsetWidth;
      slot.classList.add('slot--pop');
      // エクストラで伸びた帯は、いま埋めたカードが見えるところまで寄せる
      this.host.scrollLeft = Math.max(0, slot.offsetLeft - this.host.clientWidth + slot.offsetWidth + 8);
    };
    flyer.style.transform = `translate(${x0}px, ${y0}px) translate(-50%, -50%)`;
    window.requestAnimationFrame(step);
  }
}

function makeCard(dataUrl) {
  const img = document.createElement('img');
  img.src = dataUrl;
  img.alt = '';
  return img;
}
