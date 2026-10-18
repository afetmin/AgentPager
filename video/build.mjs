// 一键出片：准备素材 → 渲染帧 → 合成音轨 → ffmpeg 编码。用法：node build.mjs
import { execSync } from 'node:child_process';
import fs from 'node:fs';

const run = (c) => execSync(c, { stdio: 'inherit', cwd: new URL('.', import.meta.url).pathname });

// 素材全部来自仓库内已有文件，不重复提交
fs.mkdirSync('assets/footage', { recursive: true });
fs.copyFileSync('../assets/fonts/fusion_pixel_12px_zh_hans.ttf', 'assets/fusion_pixel_12px_zh_hans.ttf');
fs.copyFileSync('node_modules/@fontsource/press-start-2p/files/press-start-2p-latin-400-normal.woff2', 'assets/press-start-2p-latin-400-normal.woff2');
if (!fs.existsSync('assets/footage/f001.png')) {
  // 从真实运行录屏里裁出手机区域
  run('ffmpeg -y -v error -i ../artifacts/converted.gif -vf "crop=480:270:0:288" -fps_mode passthrough assets/footage/f%03d.png');
}

run('WORKERS=6 node render.mjs');
run('node audio.mjs');
run('ffmpeg -y -v error -framerate 30 -i out/frames/f%05d.png -i out/audio.wav -t 52.5 -c:v libx264 -preset slow -crf 22 -pix_fmt yuv420p -movflags +faststart -c:a aac -b:a 160k out/agentpager-intro.mp4');
