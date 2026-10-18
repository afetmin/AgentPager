// 用本机 Chrome 逐帧截图，并行多个页面。用法：node render.mjs [起始秒] [结束秒] [输出目录]
import puppeteer from 'puppeteer-core';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FPS, SC, W, H } from './timeline.js';

const root = path.dirname(fileURLToPath(import.meta.url));
const t0 = Number(process.argv[2] ?? 0);
const t1 = Number(process.argv[3] ?? SC.end);
const outDir = path.resolve(process.argv[4] ?? path.join(root, 'out/frames'));
const WORKERS = Number(process.env.WORKERS ?? 4);
const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const MIME = { '.html': 'text/html', '.js': 'text/javascript', '.png': 'image/png', '.ttf': 'font/ttf', '.woff2': 'font/woff2' };
const server = http.createServer((req, res) => {
  const f = path.join(root, decodeURIComponent(req.url.split('?')[0]).replace(/^\/$/, '/index.html'));
  if (!f.startsWith(root) || !fs.existsSync(f)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': MIME[path.extname(f)] ?? 'application/octet-stream' });
  fs.createReadStream(f).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const url = `http://127.0.0.1:${server.address().port}/`;

fs.mkdirSync(outDir, { recursive: true });
const first = Math.round(t0 * FPS);
const last = Math.round(t1 * FPS);
const frames = process.env.TIMES
  ? process.env.TIMES.split(',').map((x) => Math.round(Number(x) * FPS))
  : Array.from({ length: last - first }, (_, i) => first + i);

const launch = () => puppeteer.launch({ executablePath: CHROME, headless: 'new', protocolTimeout: 120000, args: ['--hide-scrollbars', '--force-device-scale-factor=1'] });
let done = 0;
const started = Date.now();

async function worker(id) {
  const browser = await launch(); // 每个 worker 独立浏览器，避免后台页被节流导致截图超时
  const page = await browser.newPage();
  await page.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
  page.on('pageerror', (e) => console.error('pageerror', e.message));
  page.on('console', (m) => { if (m.type() === 'error') console.error('console', m.text()); });
  await page.goto(url);
  await page.waitForFunction('window.__ready === true', { timeout: 60000 });
  for (let i = id; i < frames.length; i += WORKERS) {
    const n = frames[i];
    const file = path.join(outDir, `f${String(n).padStart(5, '0')}.png`);
    if (fs.existsSync(file)) { done++; continue; }
    await page.evaluate((t) => window.renderAt(t), n / FPS);
    await page.screenshot({ path: file, type: 'png', clip: { x: 0, y: 0, width: W, height: H } });
    done++;
    if (done % 60 === 0) {
      const el = (Date.now() - started) / 1000;
      process.stdout.write(`\r${done}/${frames.length}  ${(done / el).toFixed(1)} fps  eta ${Math.round((frames.length - done) / (done / el))}s   `);
    }
  }
  await browser.close();
}
await Promise.all(Array.from({ length: WORKERS }, (_, i) => worker(i)));
console.log(`\n完成 ${frames.length} 帧 → ${outDir}`);
server.close();
