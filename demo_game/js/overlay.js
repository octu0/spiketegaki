// 画面の中身に重なる 2 枚の canvas。観客 (crowd.js) と飾り (props.js) をここに描く。
//   back  HUD・問題・あつめた字・ボタンのカードより下 (カードが観客の手前に来る = 文字が隠れない):
//         ガーランド、帯の観客、歩き回る観客、風船
//   front カードより上: ストリーマー、硬貨、キャンディ、紙吹雪、飛び越える観客、パレード、運搬
//
// 筆記領域の枠の内側には、書いている最中に見える常時の飾りを描かない: 両方とも毎フレーム
// 「画面全体 − 枠」の形で切り抜いてから描く。判定のあとの一瞬だけの運搬 (腕と字のカード) は
// 切り抜かずに描く。認識は筆記領域の canvas の墨だけを読むので、ここに何を描いても影響しない。
//
// canvas は #shake の中に置き、画面の揺れと一緒に動く。座標は #shake の左上を原点にした CSS px。

/** 枠の外側に少し余白をとって切り抜く (枠線の太さと影のぶん) */
const PAD_MARGIN = 4;

export class Overlay {
  /**
   * @param {HTMLCanvasElement} back カードより下の canvas
   * @param {HTMLCanvasElement} front カードより上の canvas
   * @param {object} parts
   * @param {import('./crowd.js').Crowd} parts.crowd
   * @param {import('./props.js').Props} parts.props
   * @param {() => object} parts.anchors 測る要素 { pad, band } (無いものは null)
   */
  constructor(back, front, { crowd, props, anchors }) {
    this.canvases = [back, front];
    this.back = back.getContext('2d');
    this.front = front.getContext('2d');
    this.crowd = crowd;
    this.props = props;
    this.anchors = anchors;
    this.layout = { w: 0, h: 0, pad: null, band: null };
    this.last = 0;
    this.running = false;
    this.resize();
    window.addEventListener('resize', () => {
      this.resize();
      this.measure();
    });
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) {
        this.start();
      }
    });
    this.start();
  }

  resize() {
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    this.dpr = dpr;
    const w = this.canvases[0].clientWidth || window.innerWidth;
    const h = this.canvases[0].clientHeight || window.innerHeight;
    for (const canvas of this.canvases) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
    }
    this.layout.w = w;
    this.layout.h = h;
  }
  /**
   * 筆記領域・帯などの位置を測り直す。画面の切り替え・次の問題・大きさの変更のたびに呼ぶ
   * (枠は揺れ以外では動かないので毎フレームは測らない)。
   */
  measure() {
    const origin = this.canvases[0].getBoundingClientRect();
    const local = (node) => {
      if (!node) {
        return null;
      }
      const r = node.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) {
        return null;
      }
      return { x: r.x - origin.x, y: r.y - origin.y, w: r.width, h: r.height };
    };
    const { pad, band } = this.anchors();
    this.layout.pad = local(pad);
    this.layout.band = local(band);
    return this.layout;
  }

  /** 要素の位置を overlay の座標で返す */
  toLocal(rect) {
    const origin = this.canvases[0].getBoundingClientRect();
    return { x: rect.x - origin.x, y: rect.y - origin.y, w: rect.width, h: rect.height };
  }

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
      this.running = false;
      return;
    }
    this.crowd.update(dt, time, this.layout);
    this.props.update(dt, this.layout);
    this.draw(time);
    window.requestAnimationFrame((t) => this.frame(t));
  }

  draw(time) {
    const { w, h } = this.layout;
    for (const ctx of [this.back, this.front]) {
      ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
      ctx.clearRect(0, 0, w, h);
    }

    this.clipPad(this.back);
    this.props.drawGarlands(this.back, this.layout, time);
    this.crowd.drawCrowd(this.back, this.layout, time);
    this.props.drawBack(this.back);
    this.back.restore();

    this.clipPad(this.front);
    this.props.drawFront(this.front);
    this.crowd.drawVisitors(this.front, this.layout, time);
    this.front.restore();
    this.crowd.drawCarries(this.front, this.layout, time);
  }

  /** 画面全体から枠を抜いた形 (evenodd) で切り抜く。呼んだ側が restore する */
  clipPad(ctx) {
    ctx.save();
    const { w, h, pad } = this.layout;
    if (pad === null) {
      return;
    }
    ctx.beginPath();
    ctx.rect(0, 0, w, h);
    ctx.rect(pad.x - PAD_MARGIN, pad.y - PAD_MARGIN, pad.w + PAD_MARGIN * 2, pad.h + PAD_MARGIN * 2);
    ctx.clip('evenodd');
  }

  /** 観客 + 飾りの数 (上限の確認用) */
  get spriteCount() {
    return this.crowd.spriteCount + this.props.count;
  }
}
