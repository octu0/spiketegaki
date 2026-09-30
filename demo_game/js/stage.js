// 筆記領域まわりの飾り: 電飾・はなまる・消去のワイプ・「あつめた字」の帯。
//
// どれも DOM の数を先に作っておき、再生のたびにクラスと transform を付け替えるだけにする
// (毎回の生成でごみが増えないようにするため)。形は SVG、動きは CSS と Web Animations。

import { flowerPath, spiralPaths } from './fx.js';
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

/** 虹色の渦巻きの色 (内側から) */
const RAINBOW = ['#e24b4b', '#f08a24', '#f2c200', '#3fae5a', '#3d7fe0', '#6a4fd6', '#c04fc7'];

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

/**
 * 正解の瞬間、筆記領域の上に赤い「はなまる」(花の輪郭 + 二重丸) を筆で描く。
 * コンボが乗っているときは虹色の渦巻きに格上げする。
 */
export class Hanamaru {
  /** @param {HTMLElement} host 筆記領域に重ねる要素 */
  constructor(host) {
    this.host = host;
    host.innerHTML =
      `<svg viewBox="0 0 100 100" aria-hidden="true">`
      + `<g class="hanamaru__maru">`
      + `<path class="hanamaru__flower" d="${flowerPath(8, 44, 31)}"/>`
      + `<circle class="hanamaru__ring" cx="50" cy="50" r="27"/>`
      + `<circle class="hanamaru__ring" cx="50" cy="50" r="20"/>`
      + `</g><g class="hanamaru__swirl">`
      + spiralPaths(3, RAINBOW.length, 44)
        .map((d, i) => `<path class="hanamaru__arc" d="${d}" style="stroke:${RAINBOW[i]}"/>`).join('')
      + `</g></svg>`;
    this.flower = host.querySelector('.hanamaru__flower');
    this.rings = [...host.querySelectorAll('.hanamaru__ring')];
    this.arcs = [...host.querySelectorAll('.hanamaru__arc')];
    this.fade = null;
  }

  /**
   * 1 回描く。はなまるは花の輪郭 → 二重丸、渦巻きは内側から外へ、の順に筆を走らせる。
   * @param {boolean} rainbow 虹色の渦巻きにするか
   */
  play(rainbow = false) {
    if (typeof this.host.animate !== 'function') {
      return;
    }
    this.host.classList.add('hanamaru--on');
    this.host.classList.toggle('hanamaru--rainbow', rainbow);
    if (rainbow) {
      const step = HANAMARU_DRAW_MS / this.arcs.length;
      this.arcs.forEach((arc, i) => this.draw(arc, step * i, step));
    } else {
      this.draw(this.flower, 0, HANAMARU_DRAW_MS * 0.64);
      this.rings.forEach((ring, i) => {
        this.draw(ring, HANAMARU_DRAW_MS * (0.44 + i * 0.16), HANAMARU_DRAW_MS * 0.4);
      });
    }
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
 * 書いた字がそのままカードになって埋まる。ステージをまたいで 10 を越えると枠が増えて横に伸びる。
 * 字を帯まで運ぶのは観客の腕 (crowd.js の carry)。ここは枠の予約と、着いたときの表示だけを持つ。
 */
export class Collected {
  /** @param {HTMLElement} host 帯の中身を入れる要素 */
  constructor(host) {
    this.host = host;
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

  /**
   * 次に埋まる枠を押さえる。伸びた帯は、その枠が見えるところまで先に寄せておく
   * (運ぶ先の位置がずれないように)。
   * @returns {HTMLElement}
   */
  reserve() {
    this.grow(collectedSlots(this.count + 1));
    const slot = this.slots[this.count];
    this.count += 1;
    this.host.scrollLeft = Math.max(0, slot.offsetLeft - this.host.clientWidth + slot.offsetWidth + 8);
    return slot;
  }

  /**
   * つづきから: 保存してあった字 (画像は保存しないので活字) で枠を埋め直す。
   * @param {string[]} chars あつめた字
   */
  restore(chars) {
    this.reset();
    this.grow(collectedSlots(chars.length));
    chars.forEach((ch, i) => {
      const slot = this.slots[i];
      slot.classList.add('slot--filled');
      const span = document.createElement('span');
      span.className = 'slot__char';
      span.textContent = ch;
      slot.replaceChildren(span);
    });
    this.count = chars.length;
    const last = this.slots[Math.max(0, this.count - 1)];
    this.host.scrollLeft = Math.max(0, last.offsetLeft - this.host.clientWidth + last.offsetWidth + 8);
  }

  /**
   * 運ばれてきた字を枠に収める。
   * @param {HTMLElement} slot reserve() で押さえた枠
   * @param {string} dataUrl 筆記領域を写した画像
   */
  land(slot, dataUrl) {
    if (!slot.isConnected) {
      return;
    }
    slot.classList.add('slot--filled');
    slot.replaceChildren(makeCard(dataUrl));
    slot.classList.remove('slot--pop');
    void slot.offsetWidth;
    slot.classList.add('slot--pop');
  }
}

function makeCard(dataUrl) {
  const img = document.createElement('img');
  img.src = dataUrl;
  img.alt = '';
  return img;
}
