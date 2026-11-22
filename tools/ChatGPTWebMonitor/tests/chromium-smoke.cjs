// Run with CHROME=/path/to/chrome node tests/chromium-smoke.cjs.
// The ChatGPT URL is intercepted inside a throwaway browser; no account or network data is used.
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { createHash } = require('node:crypto');
const { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } = require('node:fs');
const { createServer } = require('node:http');
const { resolve, join } = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const FixtureWebSocket = require('ws');

const idA = '11111111-1111-4111-8111-111111111111';
const idB = '22222222-2222-4222-8222-222222222222';
const pathA = `/c/${idA}`;
const pathB = `/c/${idB}`;
const ext = resolve(process.env.WEB_EXTENSION_DIR || resolve(__dirname, '..'));
const extId = createHash('sha256').update(ext).digest('hex').slice(0, 32)
  .replace(/./g, ch => String.fromCharCode(97 + Number.parseInt(ch, 16)));
const seen = [];
const spinner = '<span id="spinner" data-loading-indicator></span>';
const nestedRow = `<div class="row"><div><a href="${pathA}"><span class="truncate">Fixture Alpha</span></a></div>
<div role="status" aria-label="Processing">${spinner}</div></div>`;
const directRow = `<div class="row"><a href="${pathA}"><span class="truncate">Fixture Alpha</span></a>${spinner}</div>`;
const fixture = `<!doctype html><style>
  .row { display:flex; align-items:center; width:200px; height:32px; }
  .row a { width:154px; } [data-loading-indicator] { display:block; width:12px; height:12px; }
</style><nav id="history">
${process.env.DIRECT_SPINNER === '1' ? directRow : nestedRow}
<div class="row"><a href="${pathB}"><span class="truncate">Fixture Beta</span></a></div></nav>
<button role="tab" aria-selected="true">Work</button>`;

const shim = createServer((req, res) => {
  const origin = req.headers.origin || '';
  if (origin !== `chrome-extension://${extId}` || req.url !== '/state') { res.writeHead(403).end(); return; }
  const headers = { 'Access-Control-Allow-Origin': origin, 'Access-Control-Allow-Methods': 'POST,OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type,X-AgentPager-Token', 'Access-Control-Allow-Private-Network': 'true' };
  if (req.method === 'OPTIONS') { res.writeHead(204, headers).end(); return; }
  if (req.method !== 'POST' || !req.headers['x-agentpager-token']) { res.writeHead(403).end(); return; }
  let body = '';
  req.on('data', data => body += data);
  req.on('end', () => {
    seen.push(JSON.parse(body));
    res.writeHead(200, { ...headers, 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, enabled: true, status: 'connected' }));
  });
});

async function waitFor(find, label) {
  for (let i = 0; i < 100; i++) {
    const value = await find();
    if (value) return value;
    await delay(100);
  }
  throw new Error(`Timed out waiting for ${label}`);
}

async function connect(url) {
  const ws = new WebSocket(url);
  const pending = new Map();
  const events = new Map();
  let nextId = 0;
  ws.addEventListener('message', e => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) {
      const { resolve, reject, timer } = pending.get(m.id);
      pending.delete(m.id);
      clearTimeout(timer);
      if (m.error) reject(new Error(m.error.message)); else resolve(m.result);
    } else if (m.method) events.get(m.method)?.(m.params);
  });
  await new Promise((yes, no) => { ws.addEventListener('open', yes, { once: true }); ws.addEventListener('error', no, { once: true }); });
  return { close: () => ws.close(), on: (method, handle) => events.set(method, handle),
    send(method, params = {}) {
      const id = ++nextId;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 4000);
        pending.set(id, { resolve, reject, timer });
        ws.send(JSON.stringify({ id, method, params }));
      });
    } };
}

async function run() {
  assert.ok(process.env.CHROME && process.env.TMPDIR, 'Set CHROME and TMPDIR');
  const profile = mkdtempSync(join(process.env.TMPDIR, 'agentpager-smoke-'));
  let chrome;
  let bridge;
  let legacy;
  let phone;
  const snapshots = [];
  const useBridge = Boolean(process.env.BRIDGE_FIXTURE_DLL);
  const legacyDll = process.env.LEGACY_WEB_BRIDGE_DLL;
  assert.ok(!legacyDll || useBridge, 'Legacy helper requires the bridge fixture');
  const clients = [];
  try {
    if (useBridge) {
      bridge = spawn(process.env.DOTNET || 'dotnet', [process.env.BRIDGE_FIXTURE_DLL,
        legacyDll ? '--serve-legacy-mobile-fixture' : '--serve-mobile-fixture'], {
        env: { ...process.env, HOME: profile, XDG_DATA_HOME: profile, CODEX_HOME: join(profile, 'codex'),
          HERMES_HOME: join(profile, 'hermes'), HERMES_DESKTOP_USER_DATA_DIR: join(profile, 'hermes-desktop') },
        stdio: ['pipe', 'pipe', 'inherit'],
      });
      let output = '';
      bridge.stdout.on('data', data => { output += data; });
      let failure;
      bridge.on('error', error => { failure = error; });
      const phoneFixture = await waitFor(() => {
        if (failure) throw failure;
        if (bridge.exitCode !== null) throw new Error(`Bridge fixture exited: ${bridge.exitCode}`);
        const ready = /^MOBILE_FIXTURE_READY (.+)\r?\n/m.exec(output);
        return ready && JSON.parse(ready[1]);
      }, 'production bridge fixture');
      if (legacyDll) {
        legacy = spawn(process.env.DOTNET || 'dotnet', [legacyDll], { stdio: 'ignore' });
        await waitFor(async () => {
          if (legacy.exitCode !== null) throw new Error(`Legacy bridge exited: ${legacy.exitCode}`);
          try { return (await fetch('http://127.0.0.1:49363/state')).status === 403; }
          catch (_) { return false; }
        }, 'legacy HTTP listener');
      }
      const { pairing, certificate } = phoneFixture;
      if (pairing.version !== 2 || pairing.host !== '127.0.0.1') throw new Error('Expected isolated secure pairing');
      phone = new FixtureWebSocket(`wss://${pairing.host}:${pairing.port}/agentgrid`, {
        ca: certificate,
        followRedirects: false,
        headers: { Authorization: `Bearer ${pairing.secret}` },
        checkServerIdentity: (_, cert) => createHash('sha256').update(cert.raw).digest('hex') === pairing.certificateSha256
          ? undefined : new Error('Unexpected phone fixture TLS certificate'),
      });
      phone.on('error', () => { failure = new Error('Secure phone fixture connection failed'); });
      phone.on('message', text => snapshots.push(JSON.parse(text.toString())));
      await waitFor(() => {
        if (failure) throw failure;
        return snapshots.find(row => row.type === 'state.snapshot');
      }, 'first phone snapshot');
    } else {
      await new Promise((yes, no) => shim.listen(49363, '127.0.0.1', yes).once('error', no));
    }
    chrome = spawn(process.env.CHROME, ['--headless=new', '--no-first-run', '--disable-background-networking',
      `--user-data-dir=${profile}`, '--remote-debugging-port=0', `--disable-extensions-except=${ext}`, `--load-extension=${ext}`,
      ...(process.env.CHROME_NO_SANDBOX === '1' ? ['--no-sandbox'] : []), 'about:blank'], { stdio: 'ignore' });
    chrome.on('error', error => console.error(error.message));
    const file = join(profile, 'DevToolsActivePort');
    const port = await waitFor(() => existsSync(file) && readFileSync(file, 'utf8').split('\n')[0], 'Chrome');
    const base = `http://127.0.0.1:${port}`;
    const target = await waitFor(async () => (await (await fetch(`${base}/json/list`)).json()).find(t => t.type === 'page' && t.url === 'about:blank'), 'test tab');
    const page = await connect(target.webSocketDebuggerUrl);
    clients.push(page);
    page.on('Fetch.requestPaused', args => {
      void page.send('Fetch.fulfillRequest', { requestId: args.requestId, responseCode: 200,
        responseHeaders: [{ name: 'Content-Type', value: 'text/html' }], body: Buffer.from(fixture).toString('base64') });
    });
    await page.send('Fetch.enable', { patterns: [{ urlPattern: 'https://chatgpt.com/*' }] });
    await page.send('Page.navigate', { url: `https://chatgpt.com${pathA}` });
    const hash = createHash('sha256').update(idA).digest('hex');
    const id = 'agentpager-chatgpt-web-' + hash;
    const phoneTask = (id, lifecycle) => snapshots.flatMap(s => s.payload.tasks)
      .find(t => t.id === id && t.lifecycle === lifecycle);
    const start = await waitFor(() => useBridge
      ? phoneTask(id, 'running') : seen.find(row => row.action === 'start'), 'real extension start');
    assert.equal(start.title, useBridge ? 'chatgpt网页 · Fixture Alpha' : 'Fixture Alpha');
    if (useBridge) {
      assert.equal(start.source, 'codexDesktop');
      assert.equal(start.activity, 'thinking');
      assert.equal(start.projectName, 'ChatGPT Work');
    } else {
      assert.equal(start.mode, 'Work');
      assert.equal(start.conversationHash, hash);
    }
    await page.send('Runtime.evaluate', { expression: `history.pushState({}, '', '${pathB}')` });
    await delay(2200);
    if (useBridge) {
      assert.equal(phoneTask(id, 'succeeded'), undefined);
      assert.equal(snapshots.at(-1).payload.tasks.filter(t => t.id.startsWith('agentpager-chatgpt-web-')).length, 1);
    } else {
      assert.equal(seen.filter(row => row.action === 'start').length, 1);
      assert.equal(seen.filter(row => row.action === 'finish').length, 0);
    }
    await page.send('Runtime.evaluate', { expression: `document.getElementById('spinner').remove()` });
    const finish = await waitFor(() => useBridge
      ? phoneTask(id, 'succeeded') : seen.find(row => row.action === 'finish'), 'same-row disappearance');
    if (useBridge) {
      assert.equal(finish.title, start.title);
      const chatHash = createHash('sha256').update(idB).digest('hex');
      await page.send('Runtime.evaluate', { expression: `document.querySelector('[role=tab]').textContent = 'Chat';
        document.querySelector('a[href="${pathB}"]').insertAdjacentHTML('afterend',
          '<span id="chat-spinner" data-loading-indicator></span>');` });
      const chat = await waitFor(() => phoneTask('agentpager-chatgpt-web-' + chatHash, 'running'), 'Chat phone snapshot');
      assert.equal(chat.projectName, 'ChatGPT Chat');
      assert.equal(chat.title, 'chatgpt网页 · Fixture Beta');
      assert.equal(chat.activity, 'thinking');
      if (process.env.PHONE_FIXTURE_OUT) {
        const frame = snapshots.find(s => s.payload.tasks.some(t => t.id === chat.id && t.lifecycle === 'running'));
        writeFileSync(process.env.PHONE_FIXTURE_OUT, JSON.stringify(frame, null, 2) + '\n');
      }
    } else {
      assert.equal(finish.requestId, start.requestId);
      assert.ok(seen.some(row => row.type === 'browser.heartbeat' && row.tabCount === 1 && row.sidebarRows === 2));
    }

    if (!legacyDll && process.env.SKIP_POPUP !== '1') {
      const popupUrl = `chrome-extension://${extId}/popup.html`;
      const popupTarget = await (await fetch(`${base}/json/new?${popupUrl}`, { method: 'PUT' })).json();
      const popup = await connect(popupTarget.webSocketDebuggerUrl);
      clients.push(popup);
      const text = await waitFor(async () => {
        const r = await popup.send('Runtime.evaluate', { expression: 'document.getElementById("status")?.textContent', returnByValue: true });
        return r.result.value?.includes('已连接') && r.result.value;
      }, 'extension popup connection status');
      assert.match(text, /1 个 ChatGPT 标签页/);
    }
    console.log(useBridge
      ? `Chromium → ${legacyDll ? 'legacy HTTP/TCP helper → ' : ''}production Bridge/event loop/catalog → phone WebSocket: Chat and Work received`
      : 'Chromium extension: isolated fixture → browser worker → loopback → popup; switch and same-row finish passed');
  } finally {
    phone?.close();
    for (const client of clients) client.close();
    if (chrome) {
      chrome.kill();
      await Promise.race([new Promise(yes => chrome.once('exit', yes)), delay(1500)]);
    }
    shim.close();
    if (legacy && legacy.exitCode === null) {
      const exit = new Promise(yes => legacy.once('exit', yes));
      legacy.kill();
      await Promise.race([exit, delay(1500)]);
    }
    if (bridge) {
      bridge.stdin.end();
      await Promise.race([new Promise(yes => bridge.once('exit', yes)), delay(2500)]);
      if (bridge.exitCode === null) bridge.kill();
    }
    rmSync(profile, { recursive: true, force: true, maxRetries: 4, retryDelay: 100 });
  }
}

run().catch(error => { console.error(error); process.exitCode = 1; });
