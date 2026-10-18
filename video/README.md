# AgentPager 介绍视频

52 秒 · 1920×1080 · 30fps · 带 8-bit 音轨。画面是 Canvas 逐帧渲染，音轨由 `audio.mjs` 合成（提示音沿用 App 里的 ArcadeSounds 参数）。

```bash
npm install
node build.mjs        # 准备素材 → 渲染帧 → 合成音轨 → 输出 out/agentpager-intro.mp4
```

需要本机安装 Chrome 和 ffmpeg（Chrome 路径可用 `CHROME` 环境变量指定）。成片放在仓库的 `artifacts/agentpager-intro.mp4`。

- `timeline.js`：场景起点和音效触发点（画面与音轨共用）
- `scenes.js` / `lib.js`：8 个场景与绘制原语
- `render.mjs`：用本机 Chrome 逐帧截图（`TIMES=1.5,3 node render.mjs` 可只出指定时刻用于预览）
- `assets/`：构建时自动生成（字体取自仓库 `assets/fonts`，真实运行画面从 `artifacts/converted.gif` 裁出），不提交
