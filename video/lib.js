// 绘制原语：配色、缓动、像素风窗口/按钮、3×3 像素核心、手机外壳与手机端 UI。

export const C = {
  bg: '#05070B',
  surface: '#0B1018',
  raised: '#101824',
  divider: '#18212E',
  text: '#E8EDF5',
  muted: '#7F8A9A',
  dimmed: '#4F5968',
  blue: '#60A5FA',
  cyan: '#5EEAD4',
  violet: '#A78BFA',
  indigo: '#818CF8',
  orange: '#FB923C',
  amber: '#FDBA4A',
  yellow: '#FACC15',
  green: '#4ADE80',
  red: '#FB7185',
  bBlue: '#4E8CFF',
  bOrg: '#FF744F',
  bTeal: '#35BDAA',
};

export const PX = (s) => `${s}px "Fusion Pixel"`;
export const EN = (s) => `${s}px "Press Start 2P"`;

// ---------- 数学 ----------
export const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
export const lerp = (a, b, t) => a + (b - a) * t;
export const seg = (t, a, b) => clamp((t - a) / (b - a));
export const easeOutCubic = (t) => 1 - Math.pow(1 - t, 3);
export const easeOutQuint = (t) => 1 - Math.pow(1 - t, 5);
export const easeInOutCubic = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
export const easeOutBack = (t) => {
  const c1 = 1.70158;
  const c3 = c1 + 1;
  return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
};
export const hash = (n) => {
  const s = Math.sin(n * 127.1 + 311.7) * 43758.5453;
  return s - Math.floor(s);
};

export function hexToRgb(h) {
  const n = parseInt(h.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}
export function mix(a, b, t) {
  const A = hexToRgb(a);
  const B = hexToRgb(b);
  const r = A.map((v, i) => Math.round(lerp(v, B[i], clamp(t))));
  return `rgb(${r[0]},${r[1]},${r[2]})`;
}
export function rgba(hex, a) {
  const [r, g, b] = hexToRgb(hex);
  return `rgba(${r},${g},${b},${a})`;
}

// ---------- 文字 ----------
// 带像素硬阴影的文字，和官网 text-shadow: 4px 4px 0 #000 一致。
export function text(ctx, str, x, y, { font = PX(48), color = C.text, align = 'left', shadow = 4, alpha = 1, base = 'alphabetic' } = {}) {
  ctx.save();
  ctx.font = font;
  ctx.textAlign = align;
  ctx.textBaseline = base;
  ctx.globalAlpha *= alpha;
  if (shadow) {
    ctx.fillStyle = '#000';
    ctx.fillText(str, Math.round(x + shadow), Math.round(y + shadow));
  }
  ctx.fillStyle = color;
  ctx.fillText(str, Math.round(x), Math.round(y));
  ctx.restore();
}

export function measure(ctx, str, font) {
  ctx.save();
  ctx.font = font;
  const w = ctx.measureText(str).width;
  ctx.restore();
  return w;
}

// ---------- 像素风形状 ----------
export function rect(ctx, x, y, w, h, fill) {
  ctx.fillStyle = fill;
  ctx.fillRect(Math.round(x), Math.round(y), Math.round(w), Math.round(h));
}

// px-box：表面色 + 3px 描边 + 6px 硬阴影
export function pxBox(ctx, x, y, w, h, { fill = C.surface, border = C.divider, bw = 3, shadow = 6 } = {}) {
  x = Math.round(x);
  y = Math.round(y);
  w = Math.round(w);
  h = Math.round(h);
  if (shadow) rect(ctx, x + shadow, y + shadow, w, h, '#000');
  rect(ctx, x, y, w, h, border);
  rect(ctx, x + bw, y + bw, w - bw * 2, h - bw * 2, fill);
}

// px-btn：带高光/暗边的立体按钮
export function pxBtn(ctx, x, y, w, h, label, { fill = C.bOrg, color = '#05070B', font = PX(36), pressed = 0 } = {}) {
  const off = Math.round(5 * (1 - pressed));
  const dx = Math.round(5 * pressed);
  x = Math.round(x + dx);
  y = Math.round(y + dx);
  w = Math.round(w);
  h = Math.round(h);
  if (off) rect(ctx, x + off, y + off, w, h, '#000');
  rect(ctx, x, y, w, h, '#000');
  rect(ctx, x + 3, y + 3, w - 6, h - 6, fill);
  rect(ctx, x + 3, y + 3, w - 6, 4, 'rgba(255,255,255,0.22)');
  rect(ctx, x + 3, y + 3, 4, h - 6, 'rgba(255,255,255,0.22)');
  rect(ctx, x + 3, y + h - 7, w - 6, 4, 'rgba(0,0,0,0.28)');
  rect(ctx, x + w - 7, y + 3, 4, h - 6, 'rgba(0,0,0,0.28)');
  ctx.save();
  ctx.font = font;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillStyle = color;
  ctx.fillText(label, Math.round(x + w / 2), Math.round(y + h / 2 + 2));
  ctx.restore();
}

// 像素 tag：2px 描边，无填充
export function pxTag(ctx, x, y, label, { color = C.bOrg, font = EN(16), pad = 14, align = 'left' } = {}) {
  const w = measure(ctx, label, font) + pad * 2;
  const h = 44;
  const left = align === 'center' ? x - w / 2 : x;
  rect(ctx, left, y, w, 2, color);
  rect(ctx, left, y + h - 2, w, 2, color);
  rect(ctx, left, y, 2, h, color);
  rect(ctx, left + w - 2, y, 2, h, color);
  text(ctx, label, left + pad, y + 29, { font, color, shadow: 0 });
  return w;
}

// 窗口：标题栏 + 三个像素圆点
export function pxWindow(ctx, x, y, w, h, title, { accent = C.divider } = {}) {
  pxBox(ctx, x, y, w, h, { fill: C.surface, border: accent, shadow: 8 });
  rect(ctx, x + 3, y + 3, w - 6, 44, C.raised);
  rect(ctx, x + 3, y + 47, w - 6, 3, C.divider);
  rect(ctx, x + 22, y + 19, 12, 12, C.red);
  rect(ctx, x + 44, y + 19, 12, 12, C.amber);
  rect(ctx, x + 66, y + 19, 12, 12, C.green);
  text(ctx, title, x + w / 2, y + 33, { font: PX(24), color: C.muted, align: 'center', shadow: 0 });
  return { x: x + 3, y: y + 50, w: w - 6, h: h - 53 };
}

// 品牌图标（与 assets/brand/agentpager-icon.svg 一致）
export function drawIcon(ctx, cx, cy, size, { parts = 1, glow = 0 } = {}) {
  const s = size / 1024;
  ctx.save();
  ctx.translate(cx - size / 2, cy - size / 2);
  ctx.scale(s, s);
  if (glow) {
    ctx.shadowColor = rgba(C.bOrg, 0.7 * glow);
    ctx.shadowBlur = 90;
  }
  ctx.fillStyle = '#090B10';
  ctx.beginPath();
  ctx.roundRect(64, 64, 896, 896, 196);
  ctx.fill();
  ctx.shadowBlur = 0;
  const cells = [
    [164, 348, C.bBlue],
    [348, 348, C.bBlue],
    [532, 348, C.bOrg],
    [164, 532, C.bBlue],
    [532, 532, C.bBlue],
    [164, 716, C.bTeal],
    [348, 716, C.bBlue],
    [532, 716, C.bBlue],
  ];
  cells.forEach(([x, y, col], i) => {
    const p = Array.isArray(parts) ? parts[i] : parts;
    if (p <= 0) return;
    ctx.globalAlpha = clamp(p * 2);
    ctx.fillStyle = col;
    const k = lerp(0.4, 1, clamp(p));
    ctx.fillRect(x + 72 * (1 - k), y + 72 * (1 - k), 144 * k, 144 * k);
  });
  ctx.globalAlpha = 1;
  const arrow = Array.isArray(parts) ? parts[8] : parts;
  if (arrow > 0) {
    ctx.globalAlpha = clamp(arrow * 2);
    ctx.fillStyle = C.bOrg;
    ctx.fill(new Path2D('M532 256H768V492H716V308H532Z'));
    ctx.fill(new Path2D('M532 164H860V492H808V216H532Z'));
    ctx.globalAlpha = 1;
  }
  ctx.restore();
}

// ---------- 3×3 像素核心 ----------
// 动画预设取自 site/pixel-grid/pixel-grid.js；颜色取自 PixelPalette。
const PRESET = {
  starting: { delays: [0, 80, 160, 560, 640, 240, 480, 400, 320], dur: 180, color: C.violet },
  reading: { delays: [0, 120, 240, 0, 120, 240, 0, 120, 240], dur: 200, color: C.cyan },
  editing: { delays: [0, 80, 160, 400, 320, 240, 480, 560, 640], dur: 160, color: C.indigo },
  executing: { delays: [0, 160, 480, 320, 640, 160, 480, 320, 0], dur: 150, color: C.orange },
  testing: { delays: [0, 250, 0, 250, 0, 250, 0, 250, 0], dur: 220, color: C.blue },
  approval: { delays: [0, 200, 0, 200, 400, 200, 0, 200, 0], dur: 200, color: C.amber },
  answer: { delays: [240, 120, 240, 120, 0, 120, 240, 120, 240], dur: 200, color: C.yellow },
};
export const STATE_COLOR = {
  starting: C.violet,
  reading: C.cyan,
  editing: C.indigo,
  executing: C.orange,
  testing: C.blue,
  approval: C.amber,
  answer: C.yellow,
  succeeded: C.green,
  offline: C.muted,
};
const CHECK_CELLS = [6, 7, 5, 2];

function cellIntensity(state, i, t) {
  const p = PRESET[state];
  if (!p) return 0.2;
  const maxD = Math.max(...p.delays) / 1000;
  const period = maxD + (p.dur / 1000) * 3.2 + 0.35;
  const ph = ((t % period) + period) % period;
  const d = p.delays[i] / 1000;
  const hold = (p.dur / 1000) * 2.4;
  const up = seg(ph, d, d + 0.07);
  const down = 1 - seg(ph, d + hold, d + hold + 0.22);
  return 0.16 + 0.84 * Math.min(up, down);
}

// state 可以是字符串，或 {from,to,k} 做颜色过渡
export function drawCore(ctx, cx, cy, size, state, t, { glow = 1, bursts = 0 } = {}) {
  const gap = size * 0.14;
  const cell = (size - gap * 2) / 3;
  const color = STATE_COLOR[state] || C.cyan;
  for (let i = 0; i < 9; i++) {
    const r = Math.floor(i / 3);
    const c = i % 3;
    let inten;
    let scale = 1;
    if (state === 'succeeded') {
      const pathIdx = CHECK_CELLS.indexOf(i);
      const burstP = Math.min(1, t / 0.3);
      const resolve = easeOutQuint(clamp((t - 0.16) / 0.48));
      if (pathIdx >= 0) {
        const draw = easeOutQuint(clamp((t - 0.32 - pathIdx * 0.055) / 0.18));
        inten = 0.2 + 0.8 * draw;
        scale = 0.82 + 0.18 * draw;
      } else {
        inten = 0.82 * (1 - resolve) + 0.05;
        scale = 0.7;
      }
      const ex = Math.sin(burstP * Math.PI) * 0.58 * (1 - resolve);
      var ox = (c - 1) * ex * cell * 0.9;
      var oy = (r - 1) * ex * cell * 0.9;
    } else if (state === 'offline') {
      inten = Math.abs(r - 1) === Math.abs(c - 1) ? 0.28 : 0.05;
      scale = 0.8;
      var ox = 0;
      var oy = 0;
    } else {
      inten = cellIntensity(state, i, t);
      scale = 0.78 + 0.22 * inten;
      var ox = 0;
      var oy = 0;
    }
    const w = cell * scale;
    const px = cx - size / 2 + c * (cell + gap) + (cell - w) / 2 + (ox || 0);
    const py = cy - size / 2 + r * (cell + gap) + (cell - w) / 2 + (oy || 0);
    ctx.save();
    if (inten > 0.5 && glow) {
      ctx.shadowColor = rgba(color, 0.9 * glow * inten);
      ctx.shadowBlur = size * 0.2 * inten;
    }
    ctx.fillStyle = mix('#05070B', color, 0.12 + 0.88 * inten * inten);
    ctx.fillRect(Math.round(px), Math.round(py), Math.round(w), Math.round(w));
    ctx.restore();
  }
}

// ---------- 手机外壳 ----------
// 以横屏形态绘制（w > h）；angle=π/2 即竖屏。screenFn(ctx, sx, sy, sw, sh) 在屏幕区域内绘制内容。
export function drawPhone(ctx, cx, cy, w, h, { angle = 0, scale = 1, screenFn = null, screenOn = 1, glow = 0, shake = 0, t = 0 } = {}) {
  ctx.save();
  const jx = shake ? Math.sin(t * 90) * shake : 0;
  const jy = shake ? Math.cos(t * 77) * shake * 0.6 : 0;
  ctx.translate(Math.round(cx + jx), Math.round(cy + jy));
  ctx.rotate(angle);
  ctx.scale(scale, scale);
  if (glow) {
    ctx.shadowColor = rgba(C.bBlue, 0.45 * glow);
    ctx.shadowBlur = 80;
  }
  // 机身
  ctx.fillStyle = '#2B3548';
  ctx.beginPath();
  ctx.roundRect(-w / 2, -h / 2, w, h, 40);
  ctx.fill();
  ctx.shadowBlur = 0;
  ctx.fillStyle = '#0A0D14';
  ctx.beginPath();
  ctx.roundRect(-w / 2 + 6, -h / 2 + 6, w - 12, h - 12, 34);
  ctx.fill();
  // 屏幕
  const m = 20;
  const sx = -w / 2 + m + 18;
  const sy = -h / 2 + m;
  const sw = w - m * 2 - 18;
  const sh = h - m * 2;
  ctx.fillStyle = '#000';
  ctx.beginPath();
  ctx.roundRect(sx, sy, sw, sh, 18);
  ctx.fill();
  if (screenFn && screenOn > 0) {
    ctx.save();
    ctx.beginPath();
    ctx.roundRect(sx, sy, sw, sh, 18);
    ctx.clip();
    ctx.globalAlpha = screenOn;
    screenFn(ctx, sx, sy, sw, sh);
    ctx.restore();
  }
  // 前置摄像头（横屏时在左侧）
  ctx.fillStyle = '#05070B';
  ctx.beginPath();
  ctx.arc(-w / 2 + m + 6, 0, 7, 0, Math.PI * 2);
  ctx.fill();
  // 反光
  ctx.fillStyle = 'rgba(255,255,255,0.035)';
  ctx.beginPath();
  ctx.moveTo(sx + sw * 0.55, sy);
  ctx.lineTo(sx + sw * 0.8, sy);
  ctx.lineTo(sx + sw * 0.5, sy + sh);
  ctx.lineTo(sx + sw * 0.25, sy + sh);
  ctx.closePath();
  if (screenOn > 0) ctx.fill();
  ctx.restore();
}

// ---------- 手机端 UI（任务列表）----------
export const TASKS = [
  { title: 'AgentPager · 像素任务列表联调', sub: '你: 检查任务行、逐像素 Bloom 和状态动效', state: 'editing', label: '正在编辑', agent: 'Codex', time: '08:43', tok: '14.7k tok' },
  { title: '支付模块 · 重构并补全测试', sub: '你: 把 checkout 流程拆成独立模块', state: 'executing', label: '正在执行', agent: 'Codex', time: '03:12', tok: '8.2k tok' },
  { title: '官网 · 修复移动端导航', sub: '你: 汉堡菜单在小屏幕上点不开', state: 'succeeded', label: '任务完成', agent: 'Claude', time: '12:05', tok: '21.3k tok' },
  { title: '数据库 · 合并迁移脚本', sub: '你: 把旧的迁移合并成一个版本', state: 'reading', label: '正在读取', agent: 'Claude', time: '01:27', tok: '5.6k tok' },
];

// rows: [{task, y, alpha, expanded, approval, core}]
export function drawPhoneUI(ctx, x, y, w, h, t, { rows = TASKS, focus = 0, approval = null, titleAlpha = 1 } = {}) {
  rect(ctx, x, y, w, h, '#05070B');
  // 状态栏
  rect(ctx, x, y, w, 30, '#05070B');
  text(ctx, '7d 5%', x + w - 150, y + 21, { font: EN(10), color: C.dimmed, shadow: 0 });
  rect(ctx, x + w - 82, y + 12, 28, 8, C.dimmed);
  text(ctx, '19:42', x + 18, y + 21, { font: EN(10), color: C.muted, shadow: 0 });
  let cy = y + 36;
  rows.forEach((r, i) => {
    const task = r.task || r;
    const exp = r.expanded;
    const rowH = exp ? (approval ? 170 : 140) : 78;
    const a = r.alpha === undefined ? (i === focus ? 1 : 0.5) : r.alpha;
    const col = STATE_COLOR[r.state || task.state];
    ctx.save();
    ctx.globalAlpha = a;
    const ry = r.y === undefined ? cy : r.y;
    rect(ctx, x + 10, ry, w - 20, rowH - 8, exp ? '#0B1018' : '#080C13');
    if (exp) {
      rect(ctx, x + 10, ry, 4, rowH - 8, col);
    }
    drawCore(ctx, x + 56, ry + 40, 52, r.state || task.state, t + i * 0.37, { glow: 0.8 });
    text(ctx, task.title, x + 100, ry + 32, { font: PX(24), color: C.text, shadow: 0 });
    text(ctx, task.sub, x + 100, ry + 60, { font: PX(16), color: C.muted, shadow: 0 });
    // 右侧状态
    const lab = r.label || task.label;
    text(ctx, lab, x + w - 34, ry + 32, { font: PX(16), color: col, align: 'right', shadow: 0 });
    pxMini(ctx, x + w - 190, ry + 12, task.agent);
    if (exp) {
      text(ctx, `IN 12.5k tok  ·  CACHE 9.2k tok  ·  OUT 2.2k tok  ·  TOTAL ${task.tok}`, x + 100, ry + 96, { font: PX(16), color: C.cyan, shadow: 0 });
      if (approval) {
        text(ctx, approval.text, x + 100, ry + 124, { font: PX(16), color: C.amber, shadow: 0 });
        const b1 = approval.pressed || 0;
        miniBtn(ctx, x + w - 250, ry + 108, 100, 40, '批准', C.green, b1);
        miniBtn(ctx, x + w - 140, ry + 108, 100, 40, '拒绝', C.red, 0);
      }
    }
    ctx.restore();
    cy += rowH;
  });
}

function pxMini(ctx, x, y, label) {
  const w = 74;
  rect(ctx, x, y, w, 24, '#101824');
  text(ctx, label, x + w / 2, y + 17, { font: EN(8), color: C.blue, align: 'center', shadow: 0 });
}

export function miniBtn(ctx, x, y, w, h, label, fill, pressed = 0) {
  const o = Math.round(4 * pressed);
  rect(ctx, x + 4 - o, y + 4 - o, w, h, '#000');
  rect(ctx, x + o, y + o, w, h, fill);
  rect(ctx, x + o, y + o, w, 3, 'rgba(255,255,255,0.3)');
  rect(ctx, x + o, y + h - 3 + o, w, 3, 'rgba(0,0,0,0.3)');
  text(ctx, label, x + o + w / 2, y + o + h / 2 + 7, { font: PX(24), color: '#05070B', align: 'center', shadow: 0 });
}

// ---------- 图标小件 ----------
export function pixelCheck(ctx, x, y, s, color) {
  const g = s / 5;
  [[0, 3], [1, 4], [2, 3], [3, 2], [4, 1], [5, 0]].forEach(([cx, cy]) => rect(ctx, x + cx * g * 0.8, y + cy * g, g, g, color));
}

export function pixelCursor(ctx, x, y, s = 4) {
  const rows = [
    '1000000000',
    '1100000000',
    '1210000000',
    '1221000000',
    '1222100000',
    '1222210000',
    '1222221000',
    '1222222100',
    '1222211110',
    '1221210000',
    '1210121000',
    '1100121000',
    '1000012100',
    '0000012100',
    '0000001100',
  ];
  rows.forEach((row, j) => {
    [...row].forEach((ch, i) => {
      if (ch === '0') return;
      rect(ctx, x + i * s, y + j * s, s, s, ch === '1' ? '#000' : '#fff');
    });
  });
}

export function pixelStar(ctx, cx, cy, s, color) {
  const g = s / 5;
  const grid = ['00100', '00100', '11111', '01110', '11011'];
  grid.forEach((row, j) => [...row].forEach((ch, i) => ch === '1' && rect(ctx, cx - s / 2 + i * g, cy - s / 2 + j * g, g, g, color)));
}

// 屏幕扫描线 + 暗角（预渲染，整段复用）
let scan = null;
export function drawScanlines(ctx, W, H) {
  if (!scan) {
    scan = document.createElement('canvas');
    scan.width = W;
    scan.height = H;
    const s = scan.getContext('2d');
    s.fillStyle = 'rgba(0,0,0,0.16)';
    for (let y = 0; y < H; y += 3) s.fillRect(0, y, W, 1);
    const g = s.createRadialGradient(W / 2, H / 2, H * 0.45, W / 2, H / 2, H * 0.95);
    g.addColorStop(0, 'rgba(0,0,0,0)');
    g.addColorStop(1, 'rgba(0,0,0,0.55)');
    s.fillStyle = g;
    s.fillRect(0, 0, W, H);
  }
  ctx.drawImage(scan, 0, 0);
}
