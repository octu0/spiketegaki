// 独自デザインのマスコット (SVG) と、その反応。
//
// 形は「墨のしずく」。上がとがった丸い体、白いおなか、丸い目、細い腕、小さな足。
// 輪郭線は太め (ポップな 2D 風)。表情は 3 つ (笑顔・驚き・喜び) を重ねて置き、
// どれを出すかは CSS のクラスで切り替える (style.css の .mascot--* / .mascot__face--*)。

const BODY = '#8fd8b5';
const BODY_DARK = '#4fb391';
const BELLY = '#fff4e1';
const CHEEK = '#f7a8c4';
const LINE = '#2b2e5a';

/**
 * マスコットの SVG。体の色だけを差し替えられるようにして、観客 (色違いの小さいマスコット) が
 * 同じ形を使えるようにする。
 *
 * @param {string} body 体の色
 * @param {string} bodyDark 手足の色 (体より濃い色)
 */
export function mascotSVG(body = BODY, bodyDark = BODY_DARK) {
  return SVG.replaceAll(BODY, body).replaceAll(BODY_DARK, bodyDark);
}

/** 観客の体の色 (パステル 6 種) と、その濃い色 */
export const CROWD_COLORS = [
  ['#f7a8c4', '#d9789c'],
  ['#f9d65c', '#d9a92f'],
  ['#7fb3f5', '#4d86cf'],
  ['#8fd8b5', '#4fb391'],
  ['#c7a6f0', '#9a72d1'],
  ['#ffb37a', '#d9834a']
];

const SVG = `
<svg viewBox="0 0 120 148" class="mascot__svg" aria-hidden="true">
  <g class="mascot__feet">
    <ellipse cx="45" cy="128" rx="14" ry="8" fill="${BODY_DARK}" stroke="${LINE}" stroke-width="4"/>
    <ellipse cx="75" cy="128" rx="14" ry="8" fill="${BODY_DARK}" stroke="${LINE}" stroke-width="4"/>
  </g>
  <g class="mascot__arms">
    <path d="M22 84 q-13 7 -15 22" stroke="${LINE}" stroke-width="12" stroke-linecap="round" fill="none"/>
    <path d="M98 84 q13 7 15 22" stroke="${LINE}" stroke-width="12" stroke-linecap="round" fill="none"/>
    <path d="M22 84 q-13 7 -15 22" stroke="${BODY_DARK}" stroke-width="7" stroke-linecap="round" fill="none"/>
    <path d="M98 84 q13 7 15 22" stroke="${BODY_DARK}" stroke-width="7" stroke-linecap="round" fill="none"/>
  </g>
  <!-- 体: 上がとがった しずく -->
  <path class="mascot__body" d="M60 6 C 78 40 104 58 104 84 C 104 110 84 126 60 126 C 36 126 16 110 16 84 C 16 58 42 40 60 6 Z"
        fill="${BODY}" stroke="${LINE}" stroke-width="5" stroke-linejoin="round"/>
  <ellipse cx="60" cy="96" rx="28" ry="23" fill="${BELLY}" stroke="${LINE}" stroke-width="3.5"/>
  <ellipse cx="32" cy="84" rx="7" ry="4.5" fill="${CHEEK}"/>
  <ellipse cx="88" cy="84" rx="7" ry="4.5" fill="${CHEEK}"/>

  <!-- 笑顔 (待機) -->
  <g class="mascot__face mascot__face--smile">
    <ellipse class="mascot__eye" cx="46" cy="72" rx="7.5" ry="8.5" fill="${LINE}"/>
    <ellipse class="mascot__eye" cx="74" cy="72" rx="7.5" ry="8.5" fill="${LINE}"/>
    <circle cx="48.5" cy="69" r="2.6" fill="#ffffff"/>
    <circle cx="76.5" cy="69" r="2.6" fill="#ffffff"/>
    <path d="M52 85 q8 8 16 0" stroke="${LINE}" stroke-width="4" stroke-linecap="round" fill="none"/>
  </g>

  <!-- 驚き (誤答) -->
  <g class="mascot__face mascot__face--surprised">
    <circle cx="46" cy="71" r="9" fill="#ffffff" stroke="${LINE}" stroke-width="3.5"/>
    <circle cx="74" cy="71" r="9" fill="#ffffff" stroke="${LINE}" stroke-width="3.5"/>
    <circle cx="46" cy="72" r="3.6" fill="${LINE}"/>
    <circle cx="74" cy="72" r="3.6" fill="${LINE}"/>
    <ellipse cx="60" cy="88" rx="6" ry="7" fill="${LINE}"/>
  </g>

  <!-- 喜び (正解) -->
  <g class="mascot__face mascot__face--joy">
    <path d="M38 74 q8 -12 16 0" stroke="${LINE}" stroke-width="5" stroke-linecap="round" fill="none"/>
    <path d="M66 74 q8 -12 16 0" stroke="${LINE}" stroke-width="5" stroke-linecap="round" fill="none"/>
    <path d="M49 84 q11 16 22 0 q-11 5 -22 0 Z" fill="${LINE}"/>
    <path d="M53 90 q7 5 14 0" stroke="${CHEEK}" stroke-width="3" stroke-linecap="round" fill="none"/>
  </g>
</svg>`;

const REACTIONS = ['happy', 'cheer', 'sad', 'wobble', 'dance', 'spin', 'giant', 'clap', 'lean'];
/** 反応ごとのアニメの長さ (ms)。終わったらクラスを外す */
const DURATIONS = {
  happy: 700, cheer: 1400, sad: 700, wobble: 700, dance: 1250,
  spin: 1050, giant: 2250, clap: 700, lean: 900
};

export class Mascot {
  /** @param {HTMLElement} host マスコットを入れる要素 */
  constructor(host) {
    this.host = host;
    this.host.innerHTML = SVG;
    this.host.classList.add('mascot');
    this.timer = 0;
    this.blinkTimer = 0;
    this.scheduleBlink();
  }

  /** 待機中のまばたき (2〜6 秒おき) */
  scheduleBlink() {
    window.clearTimeout(this.blinkTimer);
    this.blinkTimer = window.setTimeout(() => {
      this.host.classList.add('mascot--blink');
      window.setTimeout(() => this.host.classList.remove('mascot--blink'), 160);
      this.scheduleBlink();
    }, 2000 + Math.random() * 4000);
  }

  /** 反応を 1 つ再生する。intensity が高いほど大きく動く */
  react(name, intensity = 1) {
    if (!REACTIONS.includes(name)) {
      return;
    }
    for (const r of REACTIONS) {
      this.host.classList.remove(`mascot--${r}`);
    }
    // クラスを付け直す前に一度レイアウトを確定させて、同じ反応でもアニメを頭から流す
    void this.host.offsetWidth;
    this.host.style.setProperty('--mascot-amp', Math.min(1.5, Math.max(0.3, intensity)).toFixed(2));
    this.host.classList.add(`mascot--${name}`);
    window.clearTimeout(this.timer);
    this.timer = window.setTimeout(() => {
      this.host.classList.remove(`mascot--${name}`);
    }, DURATIONS[name]);
  }

  /** 正解: 腕を上げて跳ねる。節目では大きく跳ねる */
  correct(intensity, big = false) {
    this.react(big ? 'cheer' : 'happy', intensity);
  }

  /** 5 コンボごと: 左右に揺れて回るダンス */
  dance() {
    this.react('dance', 1);
  }

  /** ドパの節目: 回転ジャンプ */
  spin() {
    this.react('spin', 1.5);
  }

  /** フィナーレ: 巨大化 */
  giant() {
    this.react('giant', 1.5);
  }

  /** おしい: 少し揺れる */
  close() {
    this.react('wobble', 0.8);
  }

  /** もういちど: 崩れてから戻る */
  wrong() {
    this.react('sad', 1);
  }

  /** はなまるを見て拍手する */
  clap() {
    this.react('clap', 1);
  }

  /** リーチ: 身を乗り出す */
  lean() {
    this.react('lean', 1);
  }
}
