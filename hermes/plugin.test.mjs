import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { test } from 'node:test';

const hooks = registerHooks({
  resolve(specifier, context, next) {
    if (specifier !== '@hermes/plugin-sdk') return next(specifier, context);
    return { url: 'data:text/javascript,export const host = globalThis.testHermesHost', shortCircuit: true };
  },
});

function atom(initial) {
  let value = initial;
  const listeners = new Set();
  return {
    get: () => value,
    listen(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    set(next) { value = next; for (const fn of listeners) fn(next); },
  };
}

const gateway = atom('open');
const busyBySession = atom({ 'private-session-id': false });
globalThis.testHermesHost = { state: { gateway, busyBySession }, notify() {} };
const { default: plugin, startStatusMonitor } = await import('./plugin.js');
hooks.deregister();
const tick = () => new Promise(resolve => setImmediate(resolve));

test('a legacy desktop without ctx.files can publish through an installed loopback transport', async t => {
  const sent = [];
  const disposers = [];

  t.mock.timers.enable({ apis: ['setInterval', 'Date'], now: 110_000 });
  // Enable this route only when the Windows bridge installed a private token.
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    sent.push([url, JSON.parse(options.body), options.credentials]);
    return { ok: true };
  });
  try {
    startStatusMonitor({ onDispose: fn => disposers.push(fn) }, '0'.repeat(64));
    await tick();
    assert.deepEqual(sent, [['http://127.0.0.1:49362/hermes-status',
      { version: 1, state: 'idle', updatedAt: 110_000, token: '0'.repeat(64) }, 'omit']]);

  } finally {
    disposers.forEach(fn => fn());
  }
});

test('publishes only aggregate state and heartbeat; stops when disabled', async t => {
  const emitted = [];
  const disposers = [];
  t.mock.timers.enable({ apis: ['setInterval', 'Date'], now: 100_000 });
  plugin.register({
    files: { writeText(folder, file, data) {
      assert.equal(folder, 'data');
      assert.equal(file, 'status.json');
      emitted.push(JSON.parse(data));
      return Promise.resolve({ ok: true });
    } },
    onDispose: fn => disposers.push(fn),
  });
  try {
    await tick();
    assert.deepEqual(emitted.at(-1), { version: 1, state: 'idle', updatedAt: 100_000 });
    busyBySession.set({ 'private-session-id': false, 'second-private-id': true });
    await tick();
    assert.deepEqual(emitted.at(-1), { version: 1, state: 'running', updatedAt: 100_000 });
    t.mock.timers.tick(5_000);
    await tick();
    assert.deepEqual(emitted.at(-1), { version: 1, state: 'running', updatedAt: 105_000 });
    gateway.set('closed');
    await tick();
    assert.deepEqual(emitted.at(-1), { version: 1, state: 'offline', updatedAt: 105_000 });
  } finally {
    disposers.forEach(fn => fn());
  }
  const count = emitted.length;
  gateway.set('open');
  t.mock.timers.tick(10_000);
  await tick();
  assert.equal(emitted.length, count);
});

test('an idle window preserves work reported by another window', async t => {
  const channels = new Set();
  t.mock.property(globalThis, 'BroadcastChannel', class {
    constructor() { channels.add(this); }
    postMessage(data) {
      for (const channel of channels) {
        if (channel !== this) queueMicrotask(() => channel.onmessage?.({ data }));
      }
    }
    close() { channels.delete(this); }
  });
  globalThis.window = {};
  const disposers = [];
  function openWindow(busy) {
    const emitted = [];
    const busyAtom = atom({ privateSession: busy });
    globalThis.testHermesHost.state = { gateway: atom('open'), busyBySession: busyAtom };
    plugin.register({
      files: { async writeText(_folder, _file, data) { emitted.push(JSON.parse(data).state); return { ok: true }; } },
      onDispose: fn => disposers.push(fn),
    });
    return emitted;
  }
  try {
    const active = openWindow(true);
    const idle = openWindow(false);
    await tick();
    assert.equal(active.at(-1), 'running');
    assert.equal(idle.at(-1), 'running');
    disposers.shift()();
    await tick();
    assert.equal(idle.at(-1), 'idle');
  } finally {
    disposers.forEach(fn => fn());
    delete globalThis.window;
    globalThis.testHermesHost.state = { gateway, busyBySession };
  }
});
