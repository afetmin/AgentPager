"use strict";
const assert = require("node:assert/strict");
const { test } = require("node:test");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { webcrypto } = require("node:crypto");
const { JSDOM } = require("jsdom");
const ROOT = path.resolve(__dirname, "..");
const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";

// Synthetic DOM only: never attach to a user's browser or load real chat data.
function pageFixture({ id = A, mode = "Chat", spinner = true, sibling = false } = {}) {
  const dom = new JSDOM(`<!doctype html><html><head><title>ChatGPT</title></head><body>
    <nav id="history"><div data-row="a"><a href="/c/${A}" aria-current="page"><span class="truncate" data-left="10" data-right="100">Alpha title</span>${sibling ? "" : '<span data-spinner-slot></span>'}</a>${sibling ? '<span data-spinner-slot></span>' : ""}</div>
    <div data-row="b"><a href="/c/${B}"><span class="truncate" data-left="10" data-right="100">Beta title</span><span data-spinner-slot></span></a></div></nav>
    <main data-conversation-id="${id}"><div data-message-author-role="user">Synthetic prompt</div></main>
    <button role="tab" aria-selected="true">${mode}</button></body></html>`, {
      url: `https://chatgpt.com/c/${id}`, runScripts: "outside-only",
    });
  const w = dom.window;
  const messages = [];
  let now = 10000;
  const timers = [];
  w.Date.now = () => now;
  w.setInterval = callback => { timers.push(callback); return timers.length; };
  w.setTimeout = callback => { timers.push(callback); return timers.length; };
  w.chrome = { runtime: { sendMessage: message => { messages.push(JSON.parse(JSON.stringify(message))); return Promise.resolve(); } } };
  w.HTMLElement.prototype.getClientRects = function () {
    return this.closest('[hidden],[style*="display: none"]') ? [] : [this.getBoundingClientRect()];
  };
  w.Element.prototype.getBoundingClientRect = function () {
    const left = Number(this.getAttribute("data-left") || 0);
    const right = Number(this.getAttribute("data-right") || 200);
    return { left, right, top: 0, bottom: 24, width: right - left, height: 24 };
  };
  w.SVGElement.prototype.getClientRects = w.HTMLElement.prototype.getClientRects;
  const setSpinner = (row, on) => {
    w.document.querySelector(`[data-row="${row}"] [data-spinner-slot]`).innerHTML = on
      ? '<span role="status" aria-label="Processing"><svg class="animate-spin" data-loading-indicator data-left="120" data-right="140"></svg></span>' : "";
  };
  setSpinner("a", spinner);
  w.eval(fs.readFileSync(path.join(ROOT, "content.js"), "utf8"));
  return { w, messages, setSpinner, poll() { now += 1000; timers[0](); },
    async flushMutations() { await Promise.resolve(); for (const callback of timers.splice(1)) callback(); },
    close() { w.close(); } };
}

function event() {
  const listeners = [];
  return { listeners, addListener(fn) { listeners.push(fn); }, fire(...args) { for (const fn of listeners) fn(...args); } };
}
function backgroundFixture({ stores = { local: {}, session: {} } } = {}) {
  let now = 10000;
  const sent = [];
  const diagnostics = [];
  const storage = name => ({
    async get(key) { return structuredClone({ [key]: stores[name][key] }); },
    async set(values) { Object.assign(stores[name], structuredClone(values)); },
  });
  const chrome = {
    storage: { local: storage("local"), session: storage("session") },
    runtime: { onMessage: event(), onInstalled: event(), onStartup: event() },
    tabs: { onUpdated: event(), onRemoved: event() },
    webRequest: { onBeforeRequest: event(), onHeadersReceived: event(), onCompleted: event(), onErrorOccurred: event() },
    alarms: { create() {}, onAlarm: event() },
  };
  class Clock extends Date { static now() { return now; } }
  const context = vm.createContext({ chrome, crypto: webcrypto, TextEncoder, URL, AbortController, Date: Clock,
    setTimeout, clearTimeout, console,
    fetch: async (url, options) => {
      const body = JSON.parse(options.body);
      (body.type === "browser.heartbeat" ? diagnostics : sent).push(body);
      return { ok: true, json: async () => ({ enabled: true }) };
    },
  });
  vm.runInContext(fs.readFileSync(path.join(ROOT, "background.js"), "utf8"), context);
  const flush = () => vm.runInContext("enqueue(() => {})", context);
  return { sent, diagnostics, stores, chrome, context, advance(ms) { now += ms; }, flush,
    async send(message, { tab = 1, documentId = "document-a", url = "https://chatgpt.com/c/" + message.conversationId, frameId = 0 } = {}) {
      chrome.runtime.onMessage.fire(message, { tab: { id: tab }, documentId, frameId, url }, () => {});
      await flush();
    },
    async call(code) { await vm.runInContext(code, context); await flush(); },
  };
}

function observation({ id = A, activity = "thinking", sequence = 1, title = "Alpha title", others = [], documentId = "fixture-document-a", time = 10000 } = {}) {
  return { type: "agentpagerChatGPTPage", version: 2, documentId, sequence, observedAt: time,
    pageUrl: `https://chatgpt.com/c/${id}`, conversationId: id, title, prompt: "Synthetic prompt", mode: "Chat",
    observations: [{ conversationId: id, title, activity, signal: activity === "thinking" ? "sidebar-spinner" : activity === "idle" ? "sidebar-idle" : "none" }, ...others] };
}

test("Chat and Work poll the spinner to the right of each sidebar title, including unselected conversations", () => {
  for (const mode of ["Chat", "Work"]) {
    for (const sibling of [false, true]) {
      const p = pageFixture({ mode, sibling });
      try {
        const message = p.messages.at(-1);
        assert.equal(message.version, 2);
        assert.equal(message.observations.find(row => row.conversationId === A).activity, "thinking");
        p.setSpinner("b", true);
        p.poll();
        assert.equal(p.messages.at(-1).observations.find(row => row.conversationId === B).activity, "thinking");
      } finally { p.close(); }
    }
  }
});

test("sidebar finds a processing indicator outside the link wrapper but in the same row", () => {
  const p = pageFixture({ spinner: false });
  try {
    const row = p.w.document.querySelector('[data-row="a"]');
    row.innerHTML = `<div><a href="/c/${A}"><span class="truncate" data-left="10" data-right="100">Alpha</span></a></div>
      <div role="status" aria-label="Processing" data-left="110" data-right="130"><span data-loading-indicator></span></div>`;
    p.poll();
    assert.equal(p.messages.at(-1).observations.find(row => row.conversationId === A).activity, "thinking");
    assert.equal(p.messages.at(-1).observations.find(row => row.conversationId === B).activity, "idle");
  } finally { p.close(); }
});

test("first stable ID starts once; automatic title changes update that same identity without another start", async () => {
  const b = backgroundFixture();
  const pending = observation({ id: "", title: "Temporary prompt", sequence: 1 });
  pending.pageUrl = "https://chatgpt.com/";
  pending.observations = [];
  await b.send(pending, { url: pending.pageUrl });
  assert.equal(b.sent.length, 0, "no title/prompt-derived provisional identity");
  await b.send(observation({ sequence: 2, title: "" }));
  await b.send(observation({ sequence: 3, title: "Auto-generated title" }));
  await b.send(observation({ sequence: 4, title: "Auto-generated title" }));
  assert.equal(b.sent.filter(item => item.action === "start").length, 1);
  assert.equal(new Set(b.sent.map(item => item.conversationHash)).size, 1);
  assert.equal(b.sent.filter(item => item.action === "finish").length, 0);
  assert.ok(b.sent.some(item => item.action === "metadata" && item.title === "Auto-generated title"));
});

test("diagnostics report observed tabs and sidebar counts without creating work or forwarding metadata", async () => {
  const b = backgroundFixture();
  await b.send(observation({ activity: "idle", title: "Private fixture title" }));
  assert.deepEqual(b.diagnostics.at(-1), { type: "browser.heartbeat", tabCount: 1, sidebarRows: 1, spinningRows: 0 });
  assert.equal(b.sent.length, 0);
  b.chrome.tabs.onRemoved.fire(1);
  await b.flush();
  await b.call('sendBrowserHeartbeat(true)');
  assert.deepEqual(b.diagnostics.at(-1), { type: "browser.heartbeat", tabCount: 0, sidebarRows: 0, spinningRows: 0 });
});

test("sidebar switching A to B never finishes A and never starts an idle B", async () => {
  const b = backgroundFixture();
  await b.send(observation());
  const aHash = b.sent.find(item => item.action === "start").conversationHash;
  await b.send(observation({ id: B, activity: "idle", sequence: 2, others: [
    { conversationId: A, title: "Alpha title", activity: "thinking", signal: "sidebar-spinner" },
  ] }));
  b.advance(5000);
  await b.send(observation({ id: B, activity: "idle", sequence: 3, time: 15000, others: [
    { conversationId: A, title: "Alpha title", activity: "thinking", signal: "sidebar-spinner" },
  ] }));
  b.chrome.webRequest.onCompleted.fire({ tabId: 1, requestId: "work-response-ended" });
  b.chrome.webRequest.onErrorOccurred.fire({ tabId: 1, requestId: "work-request-cancelled-on-navigation" });
  await b.flush();
  await b.call("sendHeartbeats()");
  assert.equal(b.sent.filter(item => item.action === "start").length, 1);
  assert.equal(b.sent.filter(item => item.action === "finish").length, 0);
  assert.ok(b.sent.some(item => item.action === "heartbeat" && item.conversationHash === aHash));
  await b.send(observation({ id: B, activity: "thinking", sequence: 4, time: 15000, others: [
    { conversationId: A, title: "Alpha title", activity: "thinking", signal: "sidebar-spinner" },
  ] }));
  assert.equal(b.sent.filter(item => item.action === "start").length, 2, "B starts immediately on B's own spinner");
});

test("only disappearance of A's own spinner, confirmed by consecutive observations, finishes A", async () => {
  const b = backgroundFixture();
  await b.send(observation());
  const active = b.sent.find(item => item.action === "start");
  await b.send(observation({ id: B, activity: "idle", sequence: 2, others: [
    { conversationId: A, title: "Alpha renamed", activity: "idle", signal: "sidebar-idle" },
  ] }));
  b.advance(2000);
  await b.send(observation({ id: B, activity: "idle", sequence: 3, time: 12000, others: [
    { conversationId: A, title: "Alpha renamed", activity: "idle", signal: "sidebar-idle" },
  ] }));
  const finished = b.sent.filter(item => item.action === "finish");
  assert.equal(finished.length, 1);
  assert.equal(finished[0].conversationHash, active.conversationHash);
  assert.equal(finished[0].requestId, active.requestId);
  assert.equal(finished[0].title, "Alpha renamed");
  await b.send(observation({ id: B, activity: "idle", sequence: 4, time: 12000 }));
  assert.equal(b.sent.filter(item => item.action === "finish").length, 1);
});

test("hidden or unmounted sidebar is unknown, not completion, and breaks idle confirmation", async () => {
  const b = backgroundFixture();
  await b.send(observation());
  await b.send(observation({ activity: "idle", sequence: 2 }));
  const missing = observation({ id: B, activity: "idle", sequence: 3 });
  await b.send(missing);
  b.advance(3000);
  await b.send(observation({ activity: "idle", sequence: 4, time: 13000 }));
  assert.equal(b.sent.filter(item => item.action === "finish").length, 0);
  b.advance(2000);
  await b.send(observation({ activity: "idle", sequence: 5, time: 15000 }));
  assert.equal(b.sent.filter(item => item.action === "finish").length, 1);
});

test("completed conversations reuse their hash, but new runs use fresh request IDs", async () => {
  const b = backgroundFixture();
  await b.send(observation());
  await b.send(observation({ activity: "idle", sequence: 2 }));
  b.advance(2000);
  await b.send(observation({ activity: "idle", sequence: 3, time: 12000 }));
  await b.send(observation({ activity: "thinking", sequence: 4, time: 12000, title: "New title" }));
  const starts = b.sent.filter(item => item.action === "start");
  assert.equal(starts.length, 2);
  assert.equal(starts[0].conversationHash, starts[1].conversationHash);
  assert.notEqual(starts[0].requestId, starts[1].requestId);
});

test("duplicate tabs merge into one run and a live spinner beats stale idle evidence", async () => {
  const b = backgroundFixture();
  await b.send(observation());
  await b.send(observation({ documentId: "fixture-document-b" }), { tab: 2, documentId: "document-b" });
  await b.send(observation({ activity: "idle", sequence: 2 }));
  b.advance(2000);
  await b.send(observation({ activity: "idle", sequence: 3, time: 12000 }));
  assert.equal(b.sent.filter(item => item.action === "start").length, 1);
  assert.equal(b.sent.filter(item => item.action === "finish").length, 0);
});

test("sequence, document identity, sender origin, URL identity and observation signal are validated", async () => {
  const b = backgroundFixture();
  await b.send(observation());
  const originalCount = b.sent.length;
  await b.send(observation({ sequence: 1, title: "replayed" }));
  await b.send(observation({ sequence: 2, title: "iframe" }), { frameId: 3 });
  await b.send(observation({ sequence: 2, title: "evil origin" }), { url: "https://example.com/" });
  await b.send({ ...observation({ sequence: 2 }), conversationId: "Synthetic prompt" });
  await b.send({ ...observation({ sequence: 2 }), observedAt: 90000 });
  const malformed = observation({ sequence: 2 });
  malformed.observations[0].signal = "request-completed";
  await b.send(malformed);
  const duplicate = observation({ sequence: 2 });
  duplicate.observations.push(duplicate.observations[0]);
  await b.send(duplicate);
  assert.equal(b.sent.length, originalCount);
  await b.send(observation({ sequence: 1, documentId: "new-document", title: "New document title" }), { documentId: "new-document" });
  const newCount = b.sent.length;
  await b.send(observation({ sequence: 999, title: "old document replay" }));
  assert.equal(b.sent.length, newCount);
});

test("tab close, navigation, extension reload and startup cannot manufacture finish", async () => {
  const b = backgroundFixture();
  await b.send(observation());
  b.chrome.tabs.onUpdated.fire(1, { url: "https://chatgpt.com/" });
  b.chrome.runtime.onInstalled.fire({ reason: "update" });
  b.chrome.runtime.onStartup.fire();
  b.chrome.tabs.onRemoved.fire(1);
  await b.flush();
  assert.equal(b.sent.filter(item => item.action === "finish").length, 0);
  b.advance(70000);
  await b.call("sendHeartbeats()");
  assert.equal(b.sent.filter(item => item.action === "heartbeat").length, 0, "unknown work is not falsely kept live forever");
});

test("an unrelated tab's later timestamp cannot confirm a single idle sample", async () => {
  const b = backgroundFixture();
  await b.send(observation());
  await b.send(observation({ activity: "idle", sequence: 2 }));
  b.advance(5000);
  await b.send(observation({ id: B, activity: "idle", documentId: "other-tab", time: 15000 }), { tab: 2, documentId: "other-tab" });
  assert.equal(b.sent.filter(item => item.action === "finish").length, 0);
});

test("idle evidence from an earlier run cannot finish a new run", async () => {
  const b = backgroundFixture();
  await b.send(observation());
  await b.send(observation({ documentId: "tab-two" }), { tab: 2, documentId: "tab-two" });
  await b.send(observation({ activity: "idle", sequence: 2 }));
  await b.send(observation({ activity: "idle", sequence: 2, documentId: "tab-two" }), { tab: 2, documentId: "tab-two" });
  b.advance(2000);
  await b.send(observation({ activity: "idle", sequence: 3, time: 12000 }));
  assert.equal(b.sent.filter(item => item.action === "finish").length, 1);
  await b.send(observation({ activity: "thinking", sequence: 4, time: 12000 }));
  const hidden = observation({ sequence: 5, time: 12000 });
  hidden.observations = [];
  await b.send(hidden);
  b.advance(2000);
  await b.send(observation({ activity: "idle", sequence: 3, documentId: "tab-two", time: 14000 }), { tab: 2, documentId: "tab-two" });
  assert.equal(b.sent.filter(item => item.action === "finish").length, 1);
});

test("manifest removes network observation permission and declares the 30-second-alarm runtime baseline", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, "manifest.json"), "utf8"));
  assert.match(manifest.version, /^\d+\.\d+\.\d+$/);
  assert.equal(manifest.action.default_popup, "popup.html");
  assert.ok(fs.existsSync(path.join(ROOT, manifest.action.default_icon)));
  assert.equal(manifest.minimum_chrome_version, "120");
  assert.deepEqual(manifest.permissions, ["storage", "alarms"]);
  assert.deepEqual(manifest.content_scripts[0].js, ["content.js"]);
});

test("global/hidden/leading indicators and stale main-pane controls cannot mark another row busy", () => {
  const p = pageFixture({ spinner: false });
  try {
    p.w.document.body.insertAdjacentHTML("beforeend", '<div role="status" aria-label="Thinking"><svg data-loading-indicator></svg></div><button data-testid="stop-button">Stop</button>');
    p.w.document.querySelector('[data-row="a"] a').insertAdjacentHTML("afterbegin", '<svg class="animate-spin" data-left="0" data-right="5"></svg>');
    p.w.document.querySelector('[data-row="b"] [data-spinner-slot]').innerHTML = '<span hidden><svg class="animate-spin" data-left="120" data-right="140"></svg></span>';
    p.poll();
    assert.ok(p.messages.at(-1).observations.every(row => row.activity === "idle"));
    p.w.history.pushState({}, "", "/c/" + B);
    p.poll();
    const message = p.messages.at(-1);
    assert.equal(message.conversationId, B);
    assert.equal(message.isThinking, false);
    assert.equal(message.prompt, "", "old main-pane prompt must not be attributed to B");
    assert.equal(message.title, "Beta title");
  } finally { p.close(); }
});

test("new-chat route never derives identity from a prompt, title, or malformed /c token", () => {
  const p = pageFixture();
  try {
    p.w.document.querySelector("nav").remove();
    p.w.document.title = "Title identical to a private prompt";
    for (const pathname of ["/", "/c/Synthetic-prompt", "/c/not-a-uuid", "/c/" + A + "/extra"]) {
      p.w.history.pushState({}, "", pathname);
      p.poll();
      const message = p.messages.at(-1);
      assert.equal(message.conversationId, "");
      assert.equal(message.observations.length, 0);
      assert.equal(message.prompt, "");
    }
    p.w.history.pushState({}, "", "/g/g-project/c/" + A);
    p.w.document.querySelector("main").insertAdjacentHTML("beforeend", '<button data-testid="stop-button">Stop generating</button>');
    p.poll();
    assert.equal(p.messages.at(-1).conversationId, A);
    assert.equal(p.messages.at(-1).observations[0].signal, "stop-control");
  } finally { p.close(); }
});

test("spinner class/style mutations are observed and a duplicate sidebar link cannot override a positive signal", () => {
  const p = pageFixture();
  try {
    const anchor = p.w.document.querySelector('[data-row="a"] a');
    const duplicate = anchor.cloneNode(true);
    duplicate.querySelector("[data-spinner-slot]").innerHTML = "";
    p.w.document.querySelector("nav").append(duplicate);
    p.poll();
    const matches = p.messages.at(-1).observations.filter(row => row.conversationId === A);
    assert.equal(matches.length, 1);
    assert.equal(matches[0].activity, "thinking");
    p.w.document.querySelector('[data-row="a"]').hidden = true;
    p.poll();
    assert.equal(p.messages.at(-1).observations.find(row => row.conversationId === A).activity, "idle");
  } finally { p.close(); }
});

test("the run ID is persisted before sending start so a worker interruption cannot invent another run", async () => {
  const b = backgroundFixture();
  let snapshot;
  b.context.fetch = async () => {
    snapshot = structuredClone(b.stores.session.agentpagerConversationObservationsV2);
    return { ok: true };
  };
  await b.send(observation());
  assert.ok(snapshot, "run must be saved before the first external write");
  assert.ok(Object.values(snapshot)[0].requestId);
});

test("a lost start acknowledgement still gets its own matching terminal signal", async () => {
  const b = backgroundFixture();
  const calls = [];
  b.context.fetch = async (url, options) => {
    calls.push(JSON.parse(options.body));
    return { ok: calls.at(-1).action !== "start" };
  };
  await b.send(observation());
  await b.send(observation({ activity: "idle", sequence: 2 }));
  b.advance(2000);
  await b.send(observation({ activity: "idle", sequence: 3, time: 12000 }));
  assert.equal(calls.filter(item => item.action === "finish").length, 1);
  assert.equal(calls.find(item => item.action === "finish").requestId, calls.find(item => item.action === "start").requestId);
});

test("a new spinner after an unacknowledged terminal observation uses a fresh run ID", async () => {
  const b = backgroundFixture();
  const calls = [];
  b.context.fetch = async (url, options) => {
    calls.push(JSON.parse(options.body));
    return { ok: calls.at(-1).action !== "finish" };
  };
  await b.send(observation());
  await b.send(observation({ activity: "idle", sequence: 2 }));
  b.advance(2000);
  await b.send(observation({ activity: "idle", sequence: 3, time: 12000 }));
  await b.send(observation({ activity: "thinking", sequence: 4, time: 12000 }));
  const starts = calls.filter(item => item.action === "start");
  assert.equal(starts.length, 2);
  assert.notEqual(starts[0].requestId, starts[1].requestId);
});

test("class-only visibility and title text-node changes trigger MutationObserver reporting without polling", async () => {
  const p = pageFixture();
  try {
    p.w.document.head.insertAdjacentHTML("beforeend", '<style>.fixture-hidden { display: none }</style>');
    await p.flushMutations();
    const before = p.messages.length;
    p.w.document.querySelector('[data-row="a"] [data-spinner-slot]').classList.add("fixture-hidden");
    await p.flushMutations();
    assert.ok(p.messages.length > before);
    assert.equal(p.messages.at(-1).observations.find(row => row.conversationId === A).activity, "idle");
    p.w.document.querySelector('[data-row="a"] .truncate').firstChild.data = "Automatic title";
    await p.flushMutations();
    assert.equal(p.messages.at(-1).title, "Automatic title");
    assert.equal(p.messages.at(-1).conversationId, A);
  } finally { p.close(); }
});

test("DOM-to-worker integration keeps A active across rename and A→B navigation, then finishes only A", async () => {
  const p = pageFixture({ mode: "Work", sibling: true });
  const b = backgroundFixture();
  const deliver = async () => b.send(p.messages.at(-1), { url: p.messages.at(-1).pageUrl });
  try {
    await deliver();
    const start = b.sent.find(item => item.action === "start");
    assert.equal(start.mode, "Work");
    p.w.document.querySelector('[data-row="a"] .truncate').textContent = "Automatic title";
    p.poll(); b.advance(1000); await deliver();
    p.w.history.pushState({}, "", "/c/" + B);
    p.poll(); b.advance(1000); await deliver();
    assert.equal(b.sent.filter(item => item.action === "start").length, 1);
    assert.equal(b.sent.filter(item => item.action === "finish").length, 0);
    p.setSpinner("a", false);
    for (let i = 0; i < 3; i++) { p.poll(); b.advance(1000); await deliver(); }
    const finish = b.sent.filter(item => item.action === "finish");
    assert.equal(finish.length, 1);
    assert.equal(finish[0].conversationHash, start.conversationHash);
    assert.equal(finish[0].title, "Automatic title");
    assert.equal(finish[0].mode, "Work");
    assert.equal(b.sent.filter(item => item.action === "start").length, 1);
  } finally { p.close(); }
});

test("status-only observations never read or forward user/assistant message text", async () => {
  const p = pageFixture();
  const b = backgroundFixture();
  try {
    assert.ok(p.messages.every(message => message.prompt === ""));
    await b.send(observation());
    assert.ok(b.sent.every(message => !message.prompt));
  } finally { p.close(); }
});

test("a title arriving after completion updates the existing conversation without opening another run", async () => {
  const b = backgroundFixture();
  await b.send(observation({ title: "" }));
  await b.send(observation({ activity: "idle", title: "", sequence: 2 }));
  b.advance(2000);
  await b.send(observation({ activity: "idle", title: "", sequence: 3, time: 12000 }));
  await b.send(observation({ activity: "idle", title: "Late automatic title", sequence: 4, time: 12000 }));
  assert.equal(b.sent.filter(item => item.action === "start").length, 1);
  assert.equal(b.sent.filter(item => item.action === "finish").length, 1);
  assert.equal(b.sent.filter(item => item.action === "metadata" && item.title === "Late automatic title").length, 1);
  assert.equal(new Set(b.sent.map(item => item.conversationHash)).size, 1);
});

test("a service-worker restart preserves the run and deduplicates replayed observation sequences", async () => {
  const first = backgroundFixture();
  await first.send(observation());
  const id = first.sent.find(item => item.action === "start").requestId;
  const restarted = backgroundFixture({ stores: first.stores });
  await restarted.send(observation());
  await restarted.send(observation({ sequence: 2 }));
  await restarted.call("sendHeartbeats()");
  assert.equal(restarted.sent.filter(item => item.action === "start").length, 0);
  assert.equal(restarted.sent.find(item => item.action === "heartbeat").requestId, id);
});

test("a failed late-title metadata publication is retried without another start", async () => {
  const b = backgroundFixture();
  const calls = [];
  b.context.fetch = async (url, options) => {
    calls.push(JSON.parse(options.body));
    return { ok: calls.at(-1).action !== "metadata" || calls.filter(item => item.action === "metadata").length > 1 };
  };
  await b.send(observation());
  await b.send(observation({ title: "Renamed", sequence: 2 }));
  await b.send(observation({ title: "Renamed", sequence: 3 }));
  assert.equal(calls.filter(item => item.action === "metadata").length, 2);
  assert.equal(calls.filter(item => item.action === "start").length, 1);
});

module.exports = { pageFixture, backgroundFixture, observation, A, B };
