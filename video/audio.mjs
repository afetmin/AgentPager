// 8-bit 音轨：背景音乐 + 音效，全部用方波/三角波/噪声合成。音效沿用 App 的 ArcadeSounds 参数。
import fs from 'node:fs';
import { SC, SFX } from './timeline.js';

const SR = 44100;
const DUR = SC.end + 0.5;
const N = Math.floor(DUR * SR);
const L = new Float32Array(N);
const R = new Float32Array(N);

const hz = (m) => 440 * Math.pow(2, (m - 69) / 12);
const sq = (ph, duty = 0.5) => (ph % 1 < duty ? 1 : -1);
const tri = (ph) => 2 * Math.abs(2 * (ph % 1) - 1) - 1;

function add(start, dur, fn, amp, pan = 0) {
  const s0 = Math.floor(start * SR);
  const n = Math.floor(dur * SR);
  const gl = amp * (1 - Math.max(0, pan));
  const gr = amp * (1 + Math.min(0, pan));
  for (let i = 0; i < n; i++) {
    const idx = s0 + i;
    if (idx < 0 || idx >= N) continue;
    const v = fn(i / SR, i / n);
    L[idx] += v * gl;
    R[idx] += v * gr;
  }
}
function env(e, dur, a = 0.004, r = 0.02) {
  return Math.min(1, e / a, (dur - e) / r);
}
function pulse(start, f, dur, amp, { duty = 0.5, a = 0.004, r = 0.02, pan = 0, slide = 0 } = {}) {
  add(start, dur, (e) => sq(f * e + (slide * e * e) / 2, duty) * env(e, dur, a, r), amp, pan);
}
function triangle(start, f, dur, amp, { a = 0.005, r = 0.05, pan = 0 } = {}) {
  add(start, dur, (e) => tri(f * e) * env(e, dur, a, r), amp, pan);
}
function noise(start, dur, amp, { decay = 20, lp = 1, pan = 0 } = {}) {
  let last = 0;
  add(start, dur, (e) => {
    last += (Math.random() * 2 - 1 - last) * lp;
    return last * Math.exp(-e * decay);
  }, amp, pan);
}

// ---------- 音效 ----------
const FX = {
  ack: (t, v) => { // TASK_ACKNOWLEDGE
    pulse(t, 987.76, 0.055, 0.2 * v);
    pulse(t + 0.06, 1318.51, 0.12, 0.24 * v, { a: 0.008, r: 0.018 });
  },
  input: (t, v) => { // INPUT_REQUIRED
    pulse(t, 523.25, 0.1, 0.2 * v);
    pulse(t + 0.1, 698.46, 0.1, 0.22 * v);
    pulse(t + 0.28, 698.46, 0.1, 0.2 * v);
    pulse(t + 0.38, 880, 0.16, 0.21 * v, { r: 0.03 });
    triangle(t, 174.61, 0.5, 0.05 * v, { r: 0.1 });
  },
  complete: (t, v) => { // TASK_COMPLETE
    pulse(t, 659.25, 0.07, 0.2 * v);
    pulse(t + 0.08, 783.99, 0.07, 0.2 * v);
    pulse(t + 0.16, 1046.5, 0.55, 0.22 * v, { r: 0.25 });
    triangle(t + 0.16, 523.25, 0.55, 0.1 * v, { r: 0.2 });
    triangle(t + 0.5, 1046.5, 0.5, 0.04 * v, { r: 0.2 });
  },
  interrupt: (t, v) => {
    [261.63, 220, 174.61].forEach((f, i) => { pulse(t + i * 0.13, f, 0.12, 0.2 * v); pulse(t + i * 0.13, f * 1.015, 0.12, 0.12 * v); });
  },
  blip: (t, v) => pulse(t, 1568 + v * 400, 0.035, 0.12 * v, { r: 0.01 }),
  tick: (t, v) => { pulse(t, 880, 0.04, 0.12 * v, { r: 0.01 }); pulse(t + 0.05, 1174.66, 0.06, 0.12 * v, { r: 0.02 }); },
  pop: (t, v) => { pulse(t, 440, 0.12, 0.2 * v, { slide: 9000, r: 0.03 }); noise(t, 0.05, 0.05 * v, { decay: 60 }); },
  hit: (t, v) => { pulse(t, 140, 0.25, 0.3 * v, { slide: -240, duty: 0.25, r: 0.1 }); noise(t, 0.12, 0.18 * v, { decay: 25, lp: 0.4 }); },
  slam: (t, v) => { pulse(t, 110, 0.3, 0.32 * v, { slide: -200, duty: 0.25, r: 0.12 }); pulse(t, 55, 0.3, 0.25 * v, { slide: -60, r: 0.12 }); noise(t, 0.2, 0.25 * v, { decay: 18, lp: 0.5 }); },
  glitch: (t, v) => { for (let i = 0; i < 7; i++) pulse(t + i * 0.035, 200 + Math.random() * 1800, 0.03, 0.14 * v, { r: 0.005 }); noise(t, 0.25, 0.1 * v, { decay: 8 }); },
  whoosh: (t, v) => { noise(t, 0.6, 0.35 * v, { decay: 4, lp: 0.12 }); pulse(t, 220, 0.5, 0.06 * v, { slide: 1800, r: 0.2 }); },
  wipe: (t, v) => { for (let i = 0; i < 8; i++) pulse(t + i * 0.04, 400 + i * 120, 0.05, 0.07 * v, { duty: 0.25, r: 0.01, pan: (i % 2 ? 0.3 : -0.3) }); },
};
SFX.forEach((e) => FX[e.kind]?.(e.t, e.vel));

// ---------- 背景音乐 ----------
const BPM = 128;
const beat = 60 / BPM;
const step = beat / 4;
const prog = [ // 每小节：[低音, 和弦音(arp)]
  [45, [57, 60, 64]], // Am
  [41, [53, 57, 60]], // F
  [48, [60, 64, 67]], // C
  [43, [55, 59, 62]], // G
];
// 各段强度：[起, 止, 低音, 琶音, 鼓, 旋律]
const SECT = [
  [SC.s1, SC.s2, 0.5, 0, 0, 0],
  [SC.s2, SC.s3, 0.6, 0.5, 0, 0],
  [SC.s3, SC.s4, 1, 1, 1, 0],
  [SC.s4, SC.s5, 1, 1, 1, 1],
  [SC.s5, SC.s6, 1, 0.8, 0.8, 0.6],
  [SC.s6, SC.s7, 1, 1, 1, 1],
  [SC.s7, SC.s8, 0.8, 0.8, 0.6, 0],
  [SC.s8, SC.end + 1, 1, 1, 1, 1],
];
const sect = (t) => SECT.find((s) => t >= s[0] && t < s[1]) ?? SECT[SECT.length - 1];

const lead = [0, -1, 7, -1, 4, -1, 7, -1, 9, -1, 7, -1, 4, -1, 2, -1]; // 相对和弦根音的旋律（半音，-1 休止）
const total = Math.floor(DUR / step);
for (let i = 0; i < total; i++) {
  const t = i * step;
  const [, , bassG, arpG, drumG, leadG] = sect(t);
  const bar = Math.floor(i / 16) % 4;
  const s16 = i % 16;
  const [root, chord] = prog[bar];

  if (bassG > 0 && s16 % 2 === 0) {
    const f = hz(root + (s16 % 8 === 6 ? 12 : 0));
    triangle(t, f, step * 1.8, 0.16 * bassG, { r: 0.03 });
  }
  if (arpG > 0) {
    const note = chord[s16 % 3] + (Math.floor(s16 / 3) % 2 ? 12 : 0);
    pulse(t, hz(note + 12), step * 0.9, 0.05 * arpG, { duty: 0.25, r: 0.02, pan: s16 % 2 ? 0.35 : -0.35 });
  }
  if (drumG > 0) {
    if (s16 % 4 === 0) { // kick
      add(t, 0.13, (e) => Math.sin(2 * Math.PI * (130 * e - 520 * e * e)) * Math.exp(-e * 22), 0.35 * drumG);
    }
    if (s16 % 8 === 4) noise(t, 0.12, 0.2 * drumG, { decay: 22, lp: 0.5 }); // snare
    if (s16 % 2 === 1) noise(t, 0.03, 0.06 * drumG, { decay: 90, lp: 0.9 }); // hat
  }
  if (leadG > 0 && lead[s16] >= 0) {
    pulse(t, hz(root + 24 + lead[s16]), step * 1.6, 0.075 * leadG, { duty: 0.125, r: 0.04, pan: 0.1 });
  }
}
// 片尾：和弦收束
const endT = SC.end - 1.8;
[57, 60, 64, 69].forEach((m, i) => pulse(endT, hz(m), 1.5, 0.07, { r: 0.8, pan: (i - 1.5) * 0.2 }));
triangle(endT, hz(45), 1.5, 0.2, { r: 0.8 });

// ---------- 母带：限幅 + 末尾淡出 ----------
let peak = 0;
for (let i = 0; i < N; i++) {
  const fade = Math.min(1, Math.max(0, (SC.end + 0.4 - i / SR) / 0.9));
  L[i] = Math.tanh(L[i] * 1.2) * fade;
  R[i] = Math.tanh(R[i] * 1.2) * fade;
  peak = Math.max(peak, Math.abs(L[i]), Math.abs(R[i]));
}
const gain = 0.89 / peak;
const buf = Buffer.alloc(44 + N * 4);
buf.write('RIFF', 0); buf.writeUInt32LE(36 + N * 4, 4); buf.write('WAVEfmt ', 8);
buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(2, 22);
buf.writeUInt32LE(SR, 24); buf.writeUInt32LE(SR * 4, 28); buf.writeUInt16LE(4, 32); buf.writeUInt16LE(16, 34);
buf.write('data', 36); buf.writeUInt32LE(N * 4, 40);
for (let i = 0; i < N; i++) {
  buf.writeInt16LE(Math.round(L[i] * gain * 32767), 44 + i * 4);
  buf.writeInt16LE(Math.round(R[i] * gain * 32767), 46 + i * 4);
}
fs.mkdirSync('out', { recursive: true });
fs.writeFileSync('out/audio.wav', buf);
console.log(`audio.wav ${DUR.toFixed(1)}s, peak ${peak.toFixed(2)}`);
