// 画面与音轨共用的时间线：场景起点、状态秀节奏、音效触发点都只在这里定义一次。

export const W = 1920;
export const H = 1080;
export const FPS = 30;

export const SC = {
  s1: 0, // 钩子：你不能一直盯着屏幕
  s2: 6.5, // 抽屉里的旧手机
  s3: 11.5, // 品牌揭晓
  s4: 18.0, // 状态图鉴
  s5: 28.6, // 手机上批准
  s6: 36.0, // 功能速览
  s7: 42.4, // 纯本地
  s8: 46.4, // 号召行动
  end: 52.5,
};

export const SCENE_ORDER = ['s1', 's2', 's3', 's4', 's5', 's6', 's7', 's8'];

// 状态图鉴的节奏（秒）；每项是 [状态, 时长]。
export const S4_INTRO = 0.7;
export const S4_STATES = [
  ['starting', 1.2],
  ['reading', 1.2],
  ['editing', 1.2],
  ['executing', 1.2],
  ['testing', 1.2],
  ['approval', 1.9],
  ['succeeded', 2.0],
];

export function s4Schedule() {
  let t = SC.s4 + S4_INTRO;
  return S4_STATES.map(([state, dur]) => {
    const row = { state, start: t, end: t + dur };
    t += dur;
    return row;
  });
}

// 场景 5：手机批准的关键时刻（相对场景起点）
export const S5 = {
  type: 0.7,
  request: 2.0,
  cursor: 3.5,
  tap: 4.4,
  approved: 4.6,
  done: 6.2,
};

// 场景 6：卡片弹出时刻（相对场景起点）
export const S6_CARDS = [0.55, 1.1, 1.65, 2.2];

// 场景 2：旧手机
export const S2 = { rotate: 1.8, on: 3.0 };

// 场景 3：标题逐字出现
export const S3 = { title: 0.5, letter: 0.07, slogan: 1.5 };

// 场景 8：落版
export const S8 = { logo: 0.35, title: 1.1, badges: 2.4, link: 3.2 };

// 音效触发表。kind 对应 audio.mjs 里的合成器。
export const SFX = (() => {
  const L = [];
  const at = (t, kind, vel = 1) => L.push({ t, kind, vel });

  // S1
  at(SC.s1 + 2.2, 'hit', 0.9);
  at(SC.s1 + 3.0, 'slam', 1);
  at(SC.s1 + 3.8, 'slam', 1);
  at(SC.s1 + 4.6, 'slam', 1);
  at(SC.s1 + 5.5, 'glitch', 0.8);

  // S2
  at(SC.s2 + S2.rotate, 'whoosh', 0.8);
  at(SC.s2 + S2.on, 'ack', 1);
  for (let i = 0; i < 8; i++) at(SC.s2 + S2.on + 0.1 + i * 0.06, 'blip', 0.5 + i * 0.05);

  // S3
  for (let i = 0; i < 10; i++) at(SC.s3 + S3.title + i * S3.letter, 'blip', 0.7);
  at(SC.s3 + S3.slogan, 'ack', 0.8);

  // S4
  const sched = s4Schedule();
  sched.forEach((row, i) => {
    if (row.state === 'approval') at(row.start, 'input', 1);
    else if (row.state === 'succeeded') at(row.start, 'complete', 1);
    else at(row.start, 'tick', 0.8 + i * 0.03);
  });

  // S5
  at(SC.s5 + S5.request, 'input', 1);
  at(SC.s5 + S5.tap, 'ack', 1);
  at(SC.s5 + S5.done, 'complete', 1);

  // S6
  S6_CARDS.forEach((c) => at(SC.s6 + c, 'pop', 1));

  // S7
  at(SC.s7 + 0.2, 'whoosh', 0.6);
  for (let i = 0; i < 6; i++) at(SC.s7 + 1.2 + i * 0.25, 'blip', 0.55);
  at(SC.s7 + 2.9, 'slam', 0.8);

  // S8
  at(SC.s8 + S8.logo, 'ack', 1);
  at(SC.s8 + S8.title, 'complete', 1);
  at(SC.s8 + S8.badges, 'pop', 0.8);
  at(SC.s8 + S8.badges + 0.15, 'pop', 0.8);
  at(SC.s8 + S8.badges + 0.3, 'pop', 0.8);
  at(SC.s8 + S8.link, 'ack', 0.8);

  // 场景切换的像素转场
  SCENE_ORDER.slice(1).forEach((k) => at(SC[k] - 0.1, 'wipe', 0.6));

  return L.sort((a, b) => a.t - b.t);
})();
