// 8 个场景 + 转场。renderFrame(ctx, t, assets) 是唯一入口，对任意 t 都是确定性的。

import { W, H, SC, SCENE_ORDER, S2, S3, S4_INTRO, S5, S6_CARDS, S8, SFX, s4Schedule } from './timeline.js';
import {
  C, PX, EN, clamp, lerp, seg, easeOutCubic, easeOutQuint, easeInOutCubic, easeOutBack, hash, mix, rgba,
  text, measure, rect, pxBox, pxBtn, pxTag, pxWindow, drawIcon, drawCore, drawPhone, drawPhoneUI, miniBtn,
  pixelCursor, pixelStar, drawScanlines, TASKS, STATE_COLOR,
} from './lib.js';

// ---------- 通用背景 ----------
function bgGrid(ctx, t, tint = null, tintA = 0.14) {
  rect(ctx, 0, 0, W, H, C.bg);
  if (tint) {
    const g = ctx.createRadialGradient(W / 2, H / 2, 40, W / 2, H / 2, 900);
    g.addColorStop(0, rgba(tint, tintA));
    g.addColorStop(1, rgba(tint, 0));
    ctx.fillStyle = g;
    ctx.fillRect(0, 0, W, H);
  }
  const off = (t * 10) % 80;
  ctx.fillStyle = 'rgba(232,237,245,0.055)';
  for (let y = -80; y < H + 80; y += 80) {
    for (let x = -80; x < W + 80; x += 80) {
      ctx.fillRect(Math.round(x + off), Math.round(y + off * 0.6), 4, 4);
    }
  }
}

// 弹入文字：缩放砸入 + 渐显
function slam(ctx, str, cx, cy, lt, t0, { font = PX(96), color = C.text, shadow = 6, dur = 0.14, from = 1.6 } = {}) {
  const p = seg(lt, t0, t0 + dur);
  if (p <= 0) return;
  const s = lerp(from, 1, easeOutCubic(p));
  ctx.save();
  ctx.translate(cx, cy);
  ctx.scale(s, s);
  text(ctx, str, 0, 0, { font, color, align: 'center', shadow, alpha: clamp(p * 2.5), base: 'middle' });
  ctx.restore();
}

function typed(str, lt, t0, cps = 22) {
  const n = Math.max(0, Math.floor((lt - t0) * cps));
  return str.slice(0, n);
}

const blink = (t, hz = 2) => Math.floor(t * hz * 2) % 2 === 0;

// ---------- 场景 1：钩子 ----------
const S1_TERM = [
  ['› 重构支付模块，并补全单元测试', C.text, 0.3],
  ['● 正在读取 src/payment/checkout.ts', C.cyan, 0.9],
  ['● 正在编辑 src/payment/refund.ts', C.indigo, 1.4],
  ['● 正在执行 npm test', C.orange, 1.9],
  ['● 思考中……', C.violet, 2.3],
];

const S1_CLUTTER = [
  { t: 2.3, from: [-700, 120], to: [120, 130, 760, 420], title: 'Slack — #general', hue: C.violet },
  { t: 2.8, from: [2600, 200], to: [1020, 160, 780, 460], title: 'Chrome — 文档', hue: C.blue },
  { t: 3.3, from: [400, 1300], to: [380, 420, 820, 440], title: 'VS Code — checkout.ts', hue: C.cyan },
  { t: 3.9, from: [1800, 1300], to: [820, 300, 700, 500], title: '邮件 — 收件箱 (128)', hue: C.orange },
  { t: 4.5, from: [-800, 500], to: [180, 520, 800, 420], title: '设计稿 — Figma', hue: C.green },
];

function scene1(ctx, t) {
  const lt = t - SC.s1;
  bgGrid(ctx, t);

  // 终端窗口
  const tw = { x: 560, y: 150, w: 800, h: 500 };
  const winA = lt < 2.3 ? 1 : 0.9;
  ctx.save();
  ctx.globalAlpha = winA * seg(lt, 0, 0.3);
  const body = pxWindow(ctx, tw.x, tw.y, tw.w, tw.h, 'codex — ~/payments', { accent: lt > 4.0 ? C.amber : C.divider });
  S1_TERM.forEach(([str, col, t0], i) => {
    const s = typed(str, lt, t0, 34);
    text(ctx, s, body.x + 32, body.y + 54 + i * 52, { font: PX(24), color: col, shadow: 0 });
  });
  if (lt > 2.8 && blink(lt, 1.5)) rect(ctx, body.x + 32, body.y + 54 + 5 * 52 - 22, 14, 26, C.text);
  ctx.restore();

  // 杂乱窗口陆续盖上来
  S1_CLUTTER.forEach((w) => {
    const p = easeOutCubic(seg(lt, w.t, w.t + 0.4));
    if (p <= 0) return;
    const x = lerp(w.from[0], w.to[0], p);
    const y = lerp(w.from[1], w.to[1], p);
    const body = pxWindow(ctx, x, y, w.to[2], w.to[3], w.title);
    for (let i = 0; i < 6; i++) {
      const bw = 160 + hash(i * 7 + w.t * 3) * (w.to[2] - 300);
      rect(ctx, body.x + 28, body.y + 30 + i * 44, bw, 14, rgba(w.hue, 0.28));
      rect(ctx, body.x + 28, body.y + 52 + i * 44, bw * 0.6, 10, 'rgba(127,138,154,0.25)');
    }
  });

  // 字幕
  const band = seg(lt, 2.2, 2.5) * (1 - seg(lt, 5.35, 5.5));
  if (band > 0) {
    ctx.fillStyle = `rgba(5,7,11,${0.82 * band})`;
    ctx.fillRect(0, 380, W, 300);
  }
  if (lt < 2.2) {
    const s = typed('你让 AI Agent 去干活了。', lt, 0.4, 14);
    ctx.save();
    ctx.globalAlpha = 1 - seg(lt, 2.0, 2.2);
    rect(ctx, 0, 836, W, 120, 'rgba(5,7,11,0.7)');
    text(ctx, s, W / 2, 915, { font: PX(60), align: 'center' });
    ctx.restore();
  }
  if (lt >= 2.2 && lt < 3.0) slam(ctx, '然后呢？', W / 2, 540, lt, 2.2, { font: PX(120) });
  if (lt >= 3.0 && lt < 3.8) slam(ctx, '做完了吗？', W / 2, 540, lt, 3.0, { font: PX(144), color: C.green });
  if (lt >= 3.8 && lt < 4.6) slam(ctx, '卡住了吗？', W / 2, 540, lt, 3.8, { font: PX(144), color: C.red });
  if (lt >= 4.6 && lt < 5.4) slam(ctx, '在等你批准吗？', W / 2, 540, lt, 4.6, { font: PX(144), color: C.amber });
  if (lt >= 5.4) {
    const g = lt < 5.9 ? (hash(Math.floor(lt * 30)) - 0.5) * 18 : 0;
    ctx.save();
    ctx.translate(g, 0);
    rect(ctx, 0, 440, W, 200, 'rgba(5,7,11,0.88)');
    slam(ctx, '你总不能一直盯着屏幕。', W / 2, 540, lt, 5.4, { font: PX(84), color: C.text, from: 1.25 });
    ctx.restore();
  }
}

// ---------- 场景 2：抽屉里的旧手机 ----------
function scene2(ctx, t) {
  const lt = t - SC.s2;
  const on = seg(lt, S2.on, S2.on + 0.25);
  bgGrid(ctx, t, on > 0 ? C.bBlue : null, 0.12 * on);

  const rot = easeInOutCubic(seg(lt, S2.rotate, S2.rotate + 0.9));
  const angle = lerp(Math.PI / 2, 0, rot);
  const sc = lerp(0.78, 1.12, rot);
  const bob = lt < S2.rotate ? Math.sin(lt * 2.2) * 8 : 0;
  const cy = 560 + bob + lerp(0, -20, rot);

  // 灰尘 / zZ
  if (lt < S2.rotate + 0.5) {
    for (let i = 0; i < 3; i++) {
      const p = ((lt * 0.5 + i * 0.33) % 1);
      ctx.globalAlpha = (1 - p) * 0.6 * (1 - seg(lt, S2.rotate, S2.rotate + 0.4));
      text(ctx, 'Z', 1010 + i * 40 + Math.sin(p * 6) * 12, 330 - p * 120, { font: EN(16 + i * 8), color: C.dimmed, shadow: 0 });
      ctx.globalAlpha = 1;
    }
  }

  const screen = (c, x, y, w, h) => {
    rect(c, x, y, w, h, '#090B10');
    const parts = [];
    for (let i = 0; i < 9; i++) parts.push(easeOutBack(seg(lt, S2.on + 0.1 + i * 0.06, S2.on + 0.4 + i * 0.06)));
    drawIcon(c, x + w / 2, y + h / 2 - 14, 200, { parts });
    const lab = typed('AGENTPAGER', lt, S2.on + 0.8, 18);
    text(c, lab, x + w / 2, y + h - 28, { font: EN(16), color: C.muted, align: 'center', shadow: 0 });
    // 开机闪光
    const flash = 1 - seg(lt, S2.on, S2.on + 0.35);
    if (flash > 0 && lt >= S2.on) rect(c, x, y, w, h, `rgba(232,237,245,${flash * 0.9})`);
  };
  drawPhone(ctx, W / 2, cy, 760, 360, { angle, scale: sc, screenFn: screen, screenOn: lt >= S2.on ? 1 : 0, glow: on });

  // 文案
  const a1 = 1 - seg(lt, S2.on - 0.25, S2.on - 0.05);
  if (a1 > 0) {
    ctx.save();
    ctx.globalAlpha = a1;
    text(ctx, typed('而你的抽屉里，', lt, 0.25, 16), W / 2, 140, { font: PX(72), align: 'center', color: C.muted });
    text(ctx, typed('还躺着一部旧手机。', lt, 1.0, 14), W / 2, 230, { font: PX(72), align: 'center' });
    ctx.restore();
  }
  const a2 = seg(lt, S2.on + 0.3, S2.on + 0.5);
  if (a2 > 0) {
    ctx.save();
    ctx.globalAlpha = a2;
    text(ctx, '现在，它有了新工作。', W / 2, 190, { font: PX(84), align: 'center', color: C.text });
    ctx.restore();
  }
}

// ---------- 场景 3：品牌揭晓 ----------
const PHONE_BIG = { w: 900, h: 420 };

function phoneScreen3(t) {
  return (c, x, y, w, h) => {
    drawPhoneUI(c, x, y, w, h, t, {
      rows: [
        { task: TASKS[0], expanded: true, state: 'editing', alpha: 1 },
        { task: TASKS[1], state: 'executing', alpha: 0.5 },
        { task: TASKS[2], state: 'succeeded', alpha: 0.5 },
        { task: TASKS[3], state: 'reading', alpha: 0.5 },
      ],
    });
  };
}

function scene3(ctx, t, A) {
  const lt = t - SC.s3;
  bgGrid(ctx, t, C.bOrg, 0.07);

  // 左侧标题
  const x0 = 110;
  const tagA = seg(lt, 0.1, 0.3);
  if (tagA > 0) {
    ctx.save();
    ctx.globalAlpha = tagA;
    pxTag(ctx, x0, 210, 'LAN · PIXEL · 8-BIT', { color: C.bOrg });
    ctx.restore();
  }
  const title = 'AGENTPAGER';
  let cx = x0;
  ctx.font = EN(72);
  for (let i = 0; i < title.length; i++) {
    const ch = title[i];
    const w = measure(ctx, ch, EN(72));
    const p = seg(lt, S3.title + i * S3.letter, S3.title + i * S3.letter + 0.18);
    if (p > 0) {
      const s = easeOutBack(p);
      ctx.save();
      ctx.translate(cx + w / 2, 390 - 30 * (1 - s));
      ctx.scale(s, s);
      text(ctx, ch, -w / 2, 0, { font: EN(72), color: i < 5 ? C.bBlue : C.bOrg, shadow: 5, alpha: clamp(p * 3) });
      ctx.restore();
    }
    cx += w;
  }
  if (lt > S3.title + 0.9 && blink(lt, 1.5)) rect(ctx, cx + 6, 350, 36, 12, C.text);

  const sl = lt - S3.slogan;
  if (sl > 0) {
    text(ctx, typed('让闲置 Android 手机，', sl, 0, 24), x0, 490, { font: PX(48), color: C.text });
    text(ctx, typed('成为 AI Agent 的专属状态终端。', sl, 0.5, 24), x0, 556, { font: PX(48), color: C.text });
  }
  const sb = seg(lt, 3.0, 3.4);
  if (sb > 0) {
    ctx.save();
    ctx.globalAlpha = sb;
    text(ctx, 'Codex Desktop  ·  Codex CLI  ·  Claude Code', x0, 626, { font: PX(24), color: C.muted, shadow: 0 });
    ctx.restore();
  }

  // 真实运行画面（来自 artifacts/converted.gif）
  const ia = seg(lt, 3.2, 3.6);
  if (ia > 0 && A.footage.length) {
    const fr = A.footage[Math.floor((lt * 12) % A.footage.length)];
    ctx.save();
    ctx.globalAlpha = ia;
    pxBox(ctx, x0, 700, 520, 300, { border: C.divider });
    ctx.imageSmoothingEnabled = false;
    ctx.drawImage(fr, x0 + 3, 703, 514, 294);
    ctx.restore();
    ctx.save();
    ctx.globalAlpha = ia;
    text(ctx, '▲ 真实运行画面', x0 + 560, 780, { font: PX(36), color: C.cyan });
    text(ctx, '一部闲置的旧手机，', x0 + 560, 840, { font: PX(28), color: C.muted, shadow: 0 });
    text(ctx, '正在实时同步 Agent 状态', x0 + 560, 880, { font: PX(28), color: C.muted, shadow: 0 });
    ctx.restore();
  }

  // 右侧手机
  const pe = easeOutCubic(seg(lt, 0.2, 1.0));
  drawPhone(ctx, 1390, 470 + (1 - pe) * 500, PHONE_BIG.w, PHONE_BIG.h, {
    screenFn: phoneScreen3(t),
    glow: 0.6,
  });
}

// ---------- 场景 4：状态图鉴 ----------
const S4_COPY = {
  starting: ['正在启动', 'STARTING', '任务已下发，Agent 正在初始化环境'],
  reading: ['读取 · 搜索 · 浏览', 'READING · SEARCHING', 'Agent 正在理解代码库与上下文'],
  editing: ['正在编辑', 'EDITING', '代码正在被改写，文件逐行更新'],
  executing: ['正在执行', 'EXECUTING', '命令与脚本正在终端里狂奔'],
  testing: ['正在测试', 'TESTING', '测试套件运行中，验证改动是否正确'],
  approval: ['等待批准', 'WAITING_APPROVAL', '需要你点头！手机上直接批准或拒绝'],
  succeeded: ['任务完成', 'SUCCEEDED', '8-bit 音效响起，收工'],
};
const S4_CHIP = { starting: '启动', reading: '读取', editing: '编辑', executing: '执行', testing: '测试', approval: '批准', succeeded: '完成' };

function scene4(ctx, t) {
  const lt = t - SC.s4;
  const sched = s4Schedule();
  let cur = null;
  let prev = null;
  sched.forEach((r, i) => {
    if (t >= r.start && t < r.end) {
      cur = r;
      prev = sched[i - 1] || null;
    }
  });
  if (!cur && t >= sched[sched.length - 1].end) cur = sched[sched.length - 1];
  const state = cur ? cur.state : 'starting';
  const k = cur ? clamp((t - cur.start) / 0.3) : 1;
  const tint = prev ? mix(STATE_COLOR[prev.state], STATE_COLOR[state], k) : STATE_COLOR.starting;
  const tintHex = state ? STATE_COLOR[state] : C.violet;
  bgGrid(ctx, t, tintHex, 0.16);

  // 标题
  const ta = easeOutCubic(seg(lt, 0, 0.5));
  ctx.save();
  ctx.globalAlpha = ta;
  const head = '颜色即语言';
  text(ctx, head, W / 2, 150 - (1 - ta) * 30, { font: PX(84), align: 'center' });
  text(ctx, '余光一扫，就知道 Agent 此刻在做什么', W / 2, 205, { font: PX(28), color: C.muted, align: 'center', shadow: 0 });
  ctx.restore();

  if (!cur || t < sched[0].start) return;
  const st = t - cur.start;
  const col = STATE_COLOR[state];

  // 提醒态：屏幕边缘脉冲
  let shake = 0;
  if (state === 'approval') {
    const beat = Math.abs(Math.sin(st * 4.2));
    ctx.save();
    ctx.strokeStyle = rgba(C.amber, 0.25 + 0.45 * beat);
    ctx.lineWidth = 14;
    ctx.strokeRect(7, 7, W - 14, H - 14);
    ctx.restore();
    shake = st < 0.5 ? (1 - st / 0.5) * 8 : 0;
  }
  ctx.save();
  if (shake) ctx.translate(Math.sin(st * 120) * shake, Math.cos(st * 99) * shake * 0.6);
  drawCore(ctx, W / 2, 470, 380, state, st, { glow: 1 });
  ctx.restore();

  // 完成：像素烟花
  if (state === 'succeeded' && st > 0.25 && st < 1.9) {
    const age = st - 0.25;
    for (let i = 0; i < 46; i++) {
      const ang = hash(i * 3.1) * Math.PI * 2;
      const sp = 220 + hash(i * 7.7) * 520;
      const x = W / 2 + Math.cos(ang) * sp * age;
      const y = 470 + Math.sin(ang) * sp * age + 520 * age * age;
      const a = 1 - age / 1.65;
      const cs = [C.green, C.cyan, C.amber, C.bBlue, C.bOrg][i % 5];
      ctx.globalAlpha = Math.max(0, a);
      rect(ctx, x, y, 10 + (i % 3) * 4, 10 + (i % 3) * 4, cs);
      ctx.globalAlpha = 1;
    }
  }

  // 标签
  const [name, en, desc] = S4_COPY[state];
  const pop = easeOutCubic(seg(st, 0, 0.18));
  ctx.save();
  ctx.translate(W / 2, 770);
  ctx.scale(lerp(1.25, 1, pop), lerp(1.25, 1, pop));
  text(ctx, name, 0, 0, { font: PX(72), color: col, align: 'center', alpha: clamp(pop * 3), base: 'middle' });
  ctx.restore();
  text(ctx, en, W / 2, 840, { font: EN(20), color: C.dimmed, align: 'center', shadow: 0, alpha: pop });
  text(ctx, desc, W / 2, 898, { font: PX(32), color: C.muted, align: 'center', shadow: 0, alpha: pop });

  // 底部状态条
  const cw = 160;
  const gap = 16;
  const total = sched.length * cw + (sched.length - 1) * gap;
  sched.forEach((r, i) => {
    const x = W / 2 - total / 2 + i * (cw + gap);
    const y = 968;
    const active = r.state === state;
    const reached = t >= r.start;
    const cc = STATE_COLOR[r.state];
    rect(ctx, x, y, cw, 52, reached ? (active ? cc : C.raised) : C.surface);
    if (!active) rect(ctx, x, y + 49, cw, 3, reached ? cc : C.divider);
    rect(ctx, x + 14, y + 18, 16, 16, reached ? (active ? '#05070B' : cc) : C.dimmed);
    text(ctx, S4_CHIP[r.state], x + 44, y + 36, { font: PX(24), color: active ? '#05070B' : reached ? C.text : C.dimmed, shadow: 0 });
  });
}

// ---------- 场景 5：手机上批准 ----------
function phoneScreenRect(cx, cy, w, h) {
  const m = 20;
  return { x: cx - w / 2 + m + 18, y: cy - h / 2 + m, w: w - m * 2 - 18, h: h - m * 2 };
}

function scene5(ctx, t) {
  const lt = t - SC.s5;
  const reqd = lt >= S5.request;
  const appr = lt >= S5.approved;
  const done = lt >= S5.done;
  bgGrid(ctx, t, done ? C.green : appr ? C.indigo : reqd ? C.amber : null, 0.12);

  // 标题
  const ta = easeOutCubic(seg(lt, 0, 0.4));
  ctx.save();
  ctx.globalAlpha = ta;
  text(ctx, '权限请求，手机上直接批准', W / 2, 130 - (1 - ta) * 24, { font: PX(72), align: 'center' });
  ctx.restore();

  // 电脑端终端
  const mw = { x: 90, y: 230, w: 840, h: 560 };
  const body = pxWindow(ctx, mw.x, mw.y, mw.w, mw.h, 'codex — ~/payments', { accent: reqd && !appr ? C.amber : done ? C.green : C.divider });
  const L = (i) => body.y + 56 + i * 48;
  const lx = body.x + 32;
  text(ctx, typed('› 把改动推送到远端', lt, 0.3, 30), lx, L(0), { font: PX(28), shadow: 0 });
  text(ctx, typed('● 正在执行 git add -A', lt, 0.55, 30), lx, L(1), { font: PX(28), color: C.orange, shadow: 0 });
  text(ctx, typed('● 正在执行 git push origin main', lt, 0.9, 30), lx, L(2), { font: PX(28), color: C.orange, shadow: 0 });
  if (reqd) {
    text(ctx, '[!] 需要权限：git push origin main', lx, L(4), { font: PX(28), color: C.amber, shadow: 0 });
    if (!appr) {
      text(ctx, '等待批准' + '.'.repeat(1 + (Math.floor(lt * 3) % 3)), lx, L(5), { font: PX(28), color: C.amber, shadow: 0 });
      text(ctx, '(电脑旁没人也没关系)', lx, L(6), { font: PX(24), color: C.dimmed, shadow: 0 });
    }
  }
  if (appr) {
    text(ctx, '[OK] 已在手机上批准', lx, L(5), { font: PX(28), color: C.green, shadow: 0 });
    text(ctx, typed('● 正在推送 main -> origin', lt, S5.approved + 0.2, 28), lx, L(6), { font: PX(28), color: C.orange, shadow: 0 });
  }
  if (done) {
    const p = easeOutBack(seg(lt, S5.done, S5.done + 0.25));
    ctx.save();
    ctx.translate(lx, L(8) + 8);
    ctx.scale(p, p);
    text(ctx, '[OK] 任务完成', 0, 0, { font: PX(36), color: C.green, shadow: 0 });
    ctx.restore();
  }

  // 手机
  const pcx = 1390;
  const pcy = 510;
  const pw = 900;
  const ph = 440;
  const since = lt - S5.request;
  const shakeAmp = since >= 0 && since < 0.6 ? (1 - since / 0.6) * 9 : 0;
  const state = done ? 'succeeded' : appr ? 'executing' : reqd ? 'approval' : 'executing';
  const label = done ? '任务完成' : appr ? '正在执行' : reqd ? '等待批准' : '正在执行';
  const pressed = lt >= S5.tap && lt < S5.tap + 0.18 ? 1 : 0;
  const screen = (c, x, y, w, h) => {
    drawPhoneUI(c, x, y, w, h, lt, {
      rows: [
        { task: TASKS[0], expanded: true, state, label, alpha: 1 },
        { task: TASKS[1], state: 'executing', alpha: 0.4 },
        { task: TASKS[2], state: 'succeeded', alpha: 0.4 },
        { task: TASKS[3], state: 'reading', alpha: 0.4 },
      ],
      approval: reqd && !appr ? { text: '请求执行: git push origin main', pressed } : null,
    });
  };
  // 提示光圈
  if (since >= 0 && since < 1.2) {
    for (let i = 0; i < 3; i++) {
      const p = clamp((since - i * 0.2) / 0.9);
      if (p <= 0 || p >= 1) continue;
      ctx.strokeStyle = rgba(C.amber, 0.6 * (1 - p));
      ctx.lineWidth = 8;
      const gx = 40 + p * 120;
      ctx.strokeRect(pcx - pw / 2 - gx, pcy - ph / 2 - gx, pw + gx * 2, ph + gx * 2);
    }
  }
  drawPhone(ctx, pcx, pcy, pw, ph, {
    screenFn: screen,
    glow: reqd && !appr ? 1.2 : 0.5,
    shake: shakeAmp,
    t: lt,
  });

  // 光标：移动到「批准」并点击
  const sr = phoneScreenRect(pcx, pcy, pw, ph);
  const btn = { x: sr.x + sr.w - 250 + 50, y: sr.y + 36 + 108 + 20 };
  if (lt >= S5.cursor - 0.9 && lt < S5.approved + 0.5) {
    const p = easeInOutCubic(seg(lt, S5.cursor - 0.9, S5.tap));
    const cx = lerp(pcx + 380, btn.x, p);
    const cy = lerp(pcy + 380, btn.y, p);
    const press = lt >= S5.tap && lt < S5.tap + 0.18 ? 3 : 0;
    pixelCursor(ctx, cx + press, cy + press, 5);
    if (lt >= S5.tap && lt < S5.tap + 0.5) {
      const rp = seg(lt, S5.tap, S5.tap + 0.5);
      ctx.strokeStyle = rgba(C.green, 1 - rp);
      ctx.lineWidth = 6;
      ctx.strokeRect(btn.x - 20 - rp * 50, btn.y - 20 - rp * 50, 40 + rp * 100, 40 + rp * 100);
    }
  }

  // 底部字幕
  const sa = seg(lt, 0.8, 1.2);
  const cap = done ? '任务完成，全程没碰电脑。' : appr ? '点一下，继续干活。' : reqd ? '不用切回电脑。' : 'Agent 想推送代码……';
  ctx.save();
  ctx.globalAlpha = sa;
  text(ctx, cap, W / 2, 960, { font: PX(48), align: 'center', color: done ? C.green : reqd && !appr ? C.amber : C.text });
  ctx.restore();
}

// ---------- 场景 6：功能卡片 ----------
function card(ctx, x, y, w, h, t0, lt, color, title, desc, drawBody) {
  const p = seg(lt, t0, t0 + 0.28);
  if (p <= 0) return;
  const s = easeOutBack(p);
  ctx.save();
  ctx.translate(x + w / 2, y + h / 2);
  ctx.scale(s, s);
  ctx.translate(-w / 2, -h / 2);
  ctx.globalAlpha = clamp(p * 3);
  pxBox(ctx, 0, 0, w, h, { border: C.divider });
  rect(ctx, 3, 3, w - 6, 8, color);
  text(ctx, title, 40, 76, { font: PX(44), color, shadow: 0 });
  text(ctx, desc, 40, 122, { font: PX(24), color: C.muted, shadow: 0 });
  ctx.save();
  ctx.translate(40, 150);
  drawBody(ctx, lt - t0, w - 80, h - 180);
  ctx.restore();
  ctx.restore();
}

function scene6(ctx, t) {
  const lt = t - SC.s6;
  bgGrid(ctx, t, C.bBlue, 0.06);
  const ta = easeOutCubic(seg(lt, 0, 0.4));
  ctx.save();
  ctx.globalAlpha = ta;
  text(ctx, '不止好看，还很能打', W / 2, 135 - (1 - ta) * 24, { font: PX(72), align: 'center' });
  ctx.restore();

  const cw = 800;
  const ch = 360;
  const pos = [[110, 190], [1010, 190], [110, 590], [1010, 590]];

  // 1 自动置顶
  card(ctx, pos[0][0], pos[0][1], cw, ch, S6_CARDS[0], lt, C.amber, '重点任务，自动置顶', '需要你处理的会排到最前，其余自动变暗', (c, l, w) => {
    const rows = [
      { label: '官网 · 修复移动端导航', st: 'succeeded', tag: '完成' },
      { label: '支付模块 · 重构并补全测试', st: 'executing', tag: '执行' },
      { label: 'AgentPager · 权限请求', st: 'approval', tag: '等待批准' },
    ];
    const move = easeInOutCubic(seg(l, 0.9, 1.6));
    rows.forEach((r, i) => {
      // 最后一项移到最前，其余顺延
      const target = i === 2 ? 0 : i + 1;
      const yi = lerp(i, target, move);
      const y = yi * 56;
      const hot = i === 2;
      const a = hot ? 1 : lerp(0.9, 0.4, move);
      c.globalAlpha = a;
      rect(c, 0, y, w, 48, hot ? C.raised : '#080C13');
      if (hot) rect(c, 0, y, 6, 48, C.amber);
      drawCore(c, 28, y + 24, 30, r.st, l + i * 0.3, { glow: hot ? 0.8 : 0.3 });
      text(c, r.label, 58, y + 33, { font: PX(24), color: hot ? C.text : C.muted, shadow: 0 });
      text(c, r.tag, w - 14, y + 33, { font: PX(24), color: STATE_COLOR[r.st], align: 'right', shadow: 0 });
      c.globalAlpha = 1;
    });
  });

  // 2 子代理
  card(ctx, pos[1][0], pos[1][1], cw, ch, S6_CARDS[1], lt, C.violet, '子代理，同屏可见', '耗时、最新步骤、Token 用量一目了然', (c, l, w) => {
    const rows = [
      { n: '主任务 · 重构支付模块', st: 'executing', ind: 0, t0: 154, tok: 14.7 },
      { n: 'explore-api', st: 'reading', ind: 1, t0: 74, tok: 3.9 },
      { n: 'write-tests', st: 'editing', ind: 1, t0: 48, tok: 5.2 },
      { n: 'review', st: 'testing', ind: 1, t0: 35, tok: 1.8 },
    ];
    rows.forEach((r, i) => {
      const p = seg(l, 0.1 + i * 0.12, 0.3 + i * 0.12);
      if (p <= 0) return;
      const y = i * 46;
      c.globalAlpha = p;
      const ix = r.ind * 36;
      rect(c, ix, y, w - ix, 40, r.ind ? '#080C13' : C.raised);
      if (r.ind) {
        rect(c, 16, y - 6, 3, 28, C.divider);
        rect(c, 16, y + 22, 18, 3, C.divider);
      }
      drawCore(c, ix + 24, y + 20, 26, r.st, l + i * 0.4, { glow: 0.6 });
      text(c, r.n, ix + 52, y + 28, { font: PX(24), color: r.ind ? C.muted : C.text, shadow: 0 });
      const sec = r.t0 + Math.floor(l);
      const mm = String(Math.floor(sec / 60)).padStart(2, '0');
      const ss = String(sec % 60).padStart(2, '0');
      text(c, `${mm}:${ss}   ${r.tok.toFixed(1)}k tok`, w - 12, y + 28, { font: PX(24), color: STATE_COLOR[r.st], align: 'right', shadow: 0 });
      c.globalAlpha = 1;
    });
  });

  // 3 额度
  card(ctx, pos[2][0], pos[2][1], cw, ch, S6_CARDS[2], lt, C.blue, '额度余量，随时可查', 'Codex 5 小时与每周窗口，不等触顶才发现', (c, l, w) => {
    const bars = [
      { n: '5 小时窗口', used: 62, col: C.amber },
      { n: '每周窗口', used: 38, col: C.green },
    ];
    bars.forEach((b, i) => {
      const y = i * 84;
      text(c, b.n, 0, y + 22, { font: PX(24), color: C.text, shadow: 0 });
      const prog = easeOutCubic(seg(l, 0.2 + i * 0.2, 1.2 + i * 0.2));
      const val = Math.round(b.used * prog);
      text(c, `已用 ${val}%`, w, y + 22, { font: PX(24), color: b.col, align: 'right', shadow: 0 });
      const n = 25;
      const sw = (w - (n - 1) * 4) / n;
      for (let k = 0; k < n; k++) {
        const on = (k + 1) / n <= (b.used / 100) * prog + 0.0001;
        rect(c, k * (sw + 4), y + 34, sw, 28, on ? b.col : C.divider);
      }
    });
  });

  // 4 音效振动
  card(ctx, pos[3][0], pos[3][1], cw, ch, S6_CARDS[3], lt, C.orange, '8-bit 音效 + 振动', '完成、等待、中断，不再悄无声息', (c, l, w) => {
    // 方波示波器
    const wh = 90;
    c.strokeStyle = C.orange;
    c.lineWidth = 6;
    c.shadowColor = rgba(C.orange, 0.8);
    c.shadowBlur = 12;
    c.beginPath();
    const period = 64;
    const sp = l * 220;
    let lastY = null;
    for (let x = 0; x <= w; x += 4) {
      const ph = (((x + sp) % (period * 2)) + period * 2) % (period * 2);
      const amp = 1 - Math.abs((x / w) * 2 - 1) * 0.6;
      const y = wh / 2 + (ph < period ? -1 : 1) * 34 * amp;
      if (lastY === null) c.moveTo(x, y);
      else {
        c.lineTo(x, lastY);
        c.lineTo(x, y);
      }
      lastY = y;
    }
    c.stroke();
    c.shadowBlur = 0;
    // 提示音胶囊
    const chips = [['确认', C.cyan], ['提醒', C.amber], ['完成', C.green], ['中断', C.muted]];
    chips.forEach(([n, col], i) => {
      const x = i * 170;
      const hit = Math.floor(l * 1.6) % 4 === i;
      rect(c, x, 110, 150, 52, hit ? col : C.raised);
      rect(c, x, 159, 150, 3, col);
      text(c, n, x + 75, 146, { font: PX(28), color: hit ? '#05070B' : col, align: 'center', shadow: 0 });
    });
  });
}

// ---------- 场景 7：纯本地 ----------
function scene7(ctx, t) {
  const lt = t - SC.s7;
  bgGrid(ctx, t, C.cyan, 0.06);

  const pop = (t0) => easeOutBack(seg(lt, t0, t0 + 0.3));
  const cy = 430;

  // 电脑
  const pc = pop(0.1);
  if (pc > 0) {
    ctx.save();
    ctx.translate(430, cy);
    ctx.scale(pc, pc);
    pxBox(ctx, -150, -100, 300, 190, { fill: C.surface, border: C.dimmed });
    for (let i = 0; i < 5; i++) rect(ctx, -120, -70 + i * 28, 60 + hash(i * 3) * 150, 10, i === 4 ? C.cyan : rgba(C.text, 0.2));
    rect(ctx, -30, 90, 60, 36, C.dimmed);
    rect(ctx, -80, 126, 160, 12, C.dimmed);
    ctx.restore();
    text(ctx, 'Mac / Windows', 430, 250, { font: PX(32), align: 'center', color: C.text, alpha: pc });
  }
  // 手机
  const pp = pop(0.3);
  if (pp > 0) {
    ctx.save();
    ctx.globalAlpha = clamp(pp * 2);
    drawPhone(ctx, 1490, cy, 360 * pp, 180 * pp, {
      screenFn: (c, x, y, w, h) => {
        rect(c, x, y, w, h, '#05070B');
        drawCore(c, x + w / 2, y + h / 2, h * 0.6, 'reading', lt);
      },
    });
    ctx.restore();
    text(ctx, '旧 Android 手机', 1490, 250, { font: PX(32), align: 'center', color: C.text, alpha: pp });
  }

  // 局域网链路 + 数据包
  const lp = easeOutCubic(seg(lt, 0.8, 1.6));
  const x1 = 620;
  const x2 = 1300;
  if (lp > 0) {
    ctx.fillStyle = C.divider;
    for (let x = x1; x < x1 + (x2 - x1) * lp; x += 24) ctx.fillRect(x, cy - 4, 14, 8);
    for (let i = 0; i < 3; i++) {
      const r = 26 + i * 22;
      ctx.strokeStyle = rgba(C.cyan, 0.9 - i * 0.28);
      ctx.lineWidth = 6;
      ctx.beginPath();
      ctx.arc((x1 + x2) / 2, cy - 70, r, Math.PI * 1.25, Math.PI * 1.75);
      ctx.stroke();
    }
    rect(ctx, (x1 + x2) / 2 - 6, cy - 78, 12, 12, C.cyan);
    text(ctx, 'LAN · 局域网', (x1 + x2) / 2, cy + 52, { font: EN(14), color: C.cyan, align: 'center', shadow: 0 });
  }
  if (lt > 1.2) {
    for (let i = 0; i < 5; i++) {
      const p = (((lt - 1.2) * 0.6 + i * 0.2) % 1);
      const dir = i % 2 ? 1 : -1;
      const x = dir > 0 ? lerp(x1, x2, p) : lerp(x2, x1, p);
      rect(ctx, x - 9, cy - 9 + (dir > 0 ? -14 : 14) * 0, 18, 18, [C.amber, C.bBlue, C.green, C.violet, C.bOrg][i]);
    }
  }

  // 云：被划掉
  const cp = pop(1.9);
  if (cp > 0) {
    ctx.save();
    ctx.translate(960, 190);
    ctx.scale(cp, cp);
    ctx.globalAlpha = 0.55;
    const cloud = [[-60, 20, 120, 40], [-90, 0, 60, 40], [-30, -30, 80, 60], [30, -10, 70, 40], [60, 10, 40, 30]];
    cloud.forEach(([x, y, w, h]) => rect(ctx, x, y, w, h, C.dimmed));
    ctx.globalAlpha = 1;
    const xp = easeOutCubic(seg(lt, 2.8, 3.0));
    if (xp > 0) {
      ctx.strokeStyle = C.red;
      ctx.lineWidth = 16;
      ctx.lineCap = 'square';
      ctx.beginPath();
      ctx.moveTo(-90, -70);
      ctx.lineTo(-90 + 180 * xp, -70 + 140 * xp);
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(90, -70);
      ctx.lineTo(90 - 180 * xp, -70 + 140 * xp);
      ctx.stroke();
    }
    ctx.restore();
  }

  // 文案
  const ha = easeOutCubic(seg(lt, 0.6, 1.0));
  ctx.save();
  ctx.globalAlpha = ha;
  text(ctx, '纯本地 · 数据不出局域网', W / 2, 760 + (1 - ha) * 20, { font: PX(84), align: 'center' });
  ctx.restore();
  const hb = seg(lt, 2.2, 2.6);
  ctx.save();
  ctx.globalAlpha = hb;
  text(ctx, '没有账号  ·  没有云服务  ·  GPL-3.0 开源', W / 2, 860, { font: PX(36), align: 'center', color: C.muted, shadow: 0 });
  ctx.restore();
}

// ---------- 场景 8：号召行动 ----------
function scene8(ctx, t) {
  const lt = t - SC.s8;
  bgGrid(ctx, t, C.bOrg, 0.1);

  // 图标
  const ip = easeOutBack(seg(lt, S8.logo, S8.logo + 0.4));
  if (ip > 0) {
    const bob = lt > 1.2 ? Math.sin((lt - 1.2) * 2.4) * 6 : 0;
    drawIcon(ctx, W / 2, 300 + bob, 300 * ip, { glow: 0.6 });
  }

  // 标题
  const title = 'AGENTPAGER';
  ctx.font = EN(80);
  const widths = [...title].map((c) => measure(ctx, c, EN(80)));
  const total = widths.reduce((a, b) => a + b, 0);
  let cx = W / 2 - total / 2;
  [...title].forEach((ch, i) => {
    const p = easeOutBack(seg(lt, S8.title + i * 0.05, S8.title + i * 0.05 + 0.2));
    if (p > 0) {
      ctx.save();
      ctx.translate(cx + widths[i] / 2, 560 - 30 * (1 - p));
      ctx.scale(p, p);
      text(ctx, ch, -widths[i] / 2, 0, { font: EN(80), color: i < 5 ? C.bBlue : C.bOrg, shadow: 5, alpha: clamp(p * 3) });
      ctx.restore();
    }
    cx += widths[i];
  });
  const sa = seg(lt, S8.title + 0.7, S8.title + 1.0);
  ctx.save();
  ctx.globalAlpha = sa;
  text(ctx, '让旧手机，重新上岗。', W / 2, 650, { font: PX(56), align: 'center' });
  ctx.restore();

  // 平台
  const badges = [['ANDROID', C.green], ['MACOS', C.blue], ['WINDOWS', C.amber]];
  badges.forEach(([n, col], i) => {
    const p = easeOutBack(seg(lt, S8.badges + i * 0.15, S8.badges + i * 0.15 + 0.25));
    if (p <= 0) return;
    const bw = 300;
    const x = W / 2 - (bw * 3 + 80) / 2 + i * (bw + 40);
    ctx.save();
    ctx.translate(x + bw / 2, 760);
    ctx.scale(p, p);
    pxBtn(ctx, -bw / 2, -36, bw, 72, n, { fill: col, font: EN(20) });
    ctx.restore();
  });

  // 链接 + Star
  const la = seg(lt, S8.link, S8.link + 0.3);
  if (la > 0) {
    ctx.save();
    ctx.globalAlpha = la;
    text(ctx, 'github.com/afetmin/AgentPager', W / 2, 890, { font: PX(52), align: 'center', color: C.cyan });
    const star = blink(lt, 1.6) ? C.yellow : C.amber;
    pixelStar(ctx, W / 2 - 250, 970, 40, star);
    text(ctx, '觉得有用的话，点个 Star 吧', W / 2 + 10, 982, { font: PX(32), align: 'center', color: C.muted, shadow: 0 });
    pixelStar(ctx, W / 2 + 270, 970, 40, star);
    ctx.restore();
  }
  if (lt > 4.2 && blink(lt, 1.5)) {
    text(ctx, 'INSERT COIN', W / 2, 1040, { font: EN(16), color: C.bOrg, align: 'center', shadow: 0 });
  }
}

// ---------- 转场：像素方格 ----------
const GC = 60;
const GX = Math.ceil(W / GC);
const GY = Math.ceil(H / GC);
const WIPE_COLORS = [C.bBlue, C.bOrg, C.bTeal, '#090B10', C.bBlue, C.bOrg];

function wipe(ctx, t) {
  for (const k of SCENE_ORDER.slice(1)) {
    const tb = SC[k];
    if (t < tb - 0.45 || t > tb + 0.45) continue;
    for (let gy = 0; gy < GY; gy++) {
      for (let gx = 0; gx < GX; gx++) {
        const d = (gx / GX) * 0.5 + (gy / GY) * 0.2 + hash(gx * 13 + gy * 7) * 0.3;
        const inP = easeOutCubic(clamp((t - (tb - 0.4) - d * 0.22) / 0.16));
        const outP = clamp((t - tb - d * 0.22) / 0.16);
        const s = inP * (1 - outP);
        if (s <= 0) continue;
        const size = GC * s;
        ctx.fillStyle = WIPE_COLORS[(gx + gy) % WIPE_COLORS.length];
        ctx.fillRect(Math.round(gx * GC + (GC - size) / 2), Math.round(gy * GC + (GC - size) / 2), Math.ceil(size), Math.ceil(size));
      }
    }
  }
}

// 随音效触发的画面抖动
const SHAKERS = SFX.filter((e) => e.kind === 'slam' || e.kind === 'hit');
function cameraShake(t) {
  let amp = 0;
  for (const e of SHAKERS) {
    const dt = t - e.t;
    if (dt >= 0 && dt < 0.5) amp += 14 * Math.exp(-dt * 12) * e.vel;
  }
  return amp;
}

const SCENES = { s1: scene1, s2: scene2, s3: scene3, s4: scene4, s5: scene5, s6: scene6, s7: scene7, s8: scene8 };

export function renderFrame(ctx, t, assets) {
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.imageSmoothingEnabled = true;
  let key = 's1';
  for (const k of SCENE_ORDER) if (t >= SC[k]) key = k;
  const amp = cameraShake(t);
  ctx.save();
  if (amp > 0.3) ctx.translate(Math.round(Math.sin(t * 143) * amp), Math.round(Math.cos(t * 117) * amp * 0.7));
  SCENES[key](ctx, t, assets);
  ctx.restore();
  wipe(ctx, t);
  drawScanlines(ctx, W, H);
  // 片尾淡出
  const fade = seg(t, SC.end - 0.5, SC.end);
  if (fade > 0) {
    ctx.fillStyle = `rgba(0,0,0,${fade})`;
    ctx.fillRect(0, 0, W, H);
  }
}
