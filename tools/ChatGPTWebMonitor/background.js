"use strict";

const STATE_URL = "http://127.0.0.1:49363/state";
const TOKEN = "apw_1119_8f6db7be5a2a45e2a82f4667240bc921";
const PAGE_KEY = "agentpagerChatGPTPage";
// Versioned buckets intentionally do not interpret legacy network/UI request records.
const CONVERSATIONS_KEY = "agentpagerConversationObservationsV2";
const TABS_KEY = "agentpagerTabObservationsV2";
const BROWSER_INSTANCE_KEY = "agentpagerBrowserInstanceId";
const HEARTBEAT_ALARM = "agentpagerChatGPTHeartbeat";
const UI_FINISH_CONFIRM_MS = 1800;
const OBSERVATION_MAX_AGE_MS = 60000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
let browserInstancePromise = null;
let eventQueue = Promise.resolve();
let lastDiagnosticAt = -Infinity;
let lastDiagnostic = null;
let lastDiagnosticShape = "";

function enqueue(work) {
  const pending = eventQueue.then(work);
  eventQueue = pending.catch(() => {});
  return pending;
}
function enqueueSilently(work) { void enqueue(work).catch(() => {}); }
async function readBucket(key) {
  const saved = await chrome.storage.session.get(key);
  return saved[key] && typeof saved[key] === "object" && !Array.isArray(saved[key]) ? saved[key] : {};
}
async function writeBucket(key, value) { await chrome.storage.session.set({ [key]: value }); }
async function browserInstanceId() {
  if (!browserInstancePromise) browserInstancePromise = (async () => {
    const saved = await chrome.storage.local.get(BROWSER_INSTANCE_KEY);
    if (saved[BROWSER_INSTANCE_KEY]) return saved[BROWSER_INSTANCE_KEY];
    const id = crypto.randomUUID();
    await chrome.storage.local.set({ [BROWSER_INSTANCE_KEY]: id });
    return id;
  })();
  return browserInstancePromise;
}
function normalizeMode(value) { return value === "Chat" || value === "Work" ? value : "ChatGPT"; }
function text(value, limit) { return typeof value === "string" ? value.replace(/\s+/g, " ").trim().slice(0, limit) : ""; }
function allowedUrl(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" && /^(chatgpt\.com|chat\.openai\.com)$/i.test(url.hostname) && !url.port ? url : null;
  } catch (_) { return null; }
}
function conversationIdFromUrl(value) {
  const url = allowedUrl(value);
  const match = url && url.pathname.match(/(?:^|\/)c\/([^/]+)\/?$/i);
  return match && UUID.test(match[1]) ? match[1].toLowerCase() : "";
}
async function hashConversationId(id) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(id));
  return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("");
}

function validObservation(message, sender) {
  if (!message || message.type !== PAGE_KEY || message.version !== 2 || !sender.tab ||
      !Number.isInteger(sender.tab.id) || sender.tab.id < 0 || sender.frameId !== 0 || !allowedUrl(sender.url)) return false;
  if (typeof message.documentId !== "string" || !/^[\w-]{1,100}$/.test(message.documentId) ||
      !Number.isSafeInteger(message.sequence) || message.sequence < 1 ||
      !Number.isSafeInteger(message.observedAt) || message.observedAt > Date.now() + 5000 ||
      Date.now() - message.observedAt > OBSERVATION_MAX_AGE_MS || !allowedUrl(message.pageUrl)) return false;
  if (typeof message.conversationId !== "string" ||
      message.conversationId !== conversationIdFromUrl(message.pageUrl)) return false;
  if (!Array.isArray(message.observations) || message.observations.length > 250) return false;
  const ids = new Set();
  for (const row of message.observations) {
    if (!row || typeof row.conversationId !== "string" || !UUID.test(row.conversationId) ||
        row.conversationId !== row.conversationId.toLowerCase() || ids.has(row.conversationId)) return false;
    ids.add(row.conversationId);
    if (row.activity === "thinking") {
      if (row.signal !== "sidebar-spinner" && row.signal !== "stop-control") return false;
    } else if (row.activity === "idle") {
      if (row.signal !== "sidebar-idle" && row.signal !== "composer-idle") return false;
    } else if (row.activity !== "unknown" || row.signal !== "none") return false;
    if ((row.signal === "stop-control" || row.signal === "composer-idle") && row.conversationId !== message.conversationId) return false;
  }
  return true;
}

async function postBridge(body) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2500);
  try {
    const response = await fetch(STATE_URL, {
      method: "POST", mode: "cors", credentials: "omit", redirect: "error",
      headers: { "Content-Type": "application/json", "X-AgentPager-Token": TOKEN },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    if (!response.ok) return { ok: false, httpStatus: response.status };
    const data = typeof response.json === "function" ? await response.json() : {};
    return { ok: data?.ok !== false, enabled: data?.enabled, status: data?.status };
  } catch (_) {
    return { ok: false, httpStatus: null };
  } finally { clearTimeout(timeout); }
}

async function postStatus(action, record, evidence) {
  if (lastDiagnostic?.enabled === false) return false;
  const response = await postBridge({
    action, conversationHash: record.conversationHash, title: record.title || "",
    mode: normalizeMode(record.mode), requestId: record.requestId,
    observationId: evidence ? evidence.documentId + ":" + evidence.sequence : "",
    observedAt: evidence ? evidence.observedAt : record.lastThinkingAt,
    signal: evidence ? evidence.signal : "sidebar-spinner",
  });
  if (response.enabled === false) lastDiagnostic = response;
  return response.ok && response.enabled !== false;
}

async function sendBrowserHeartbeat(force = false, tabs) {
  const now = Date.now();
  const observed = Object.values(tabs || await readBucket(TABS_KEY))
    .filter(tab => now - tab.observedAt <= OBSERVATION_MAX_AGE_MS)
    .sort((a, b) => b.observedAt - a.observedAt);
  const body = {
    type: "browser.heartbeat", tabCount: Math.min(10000, observed.length),
    sidebarRows: observed[0]?.sidebarRows || 0, spinningRows: observed[0]?.spinningRows || 0,
  };
  const shape = `${body.tabCount}:${body.sidebarRows}:${body.spinningRows}`;
  if (!force && now - lastDiagnosticAt < (shape === lastDiagnosticShape ? 10000 : 750)) return lastDiagnostic;
  lastDiagnosticAt = now;
  lastDiagnosticShape = shape;
  const result = { ...await postBridge(body), ...body };
  if (lastDiagnosticAt === now) lastDiagnostic = result;
  return result;
}

async function refreshTabMetadata(tabId, message, senderDocumentId = "") {
  const tabs = await readBucket(TABS_KEY);
  const previous = tabs[String(tabId)];
  const streamId = senderDocumentId + ":" + message.documentId;
  const retired = previous ? previous.retired || [] : [];
  if (previous && previous.streamId === streamId &&
      (message.sequence <= previous.sequence || message.observedAt < previous.observedAt)) return;
  if (retired.includes(streamId)) return;
  if (previous && previous.streamId !== streamId) retired.push(previous.streamId);
  tabs[String(tabId)] = {
    streamId, documentId: message.documentId, sequence: message.sequence, observedAt: message.observedAt,
    conversationId: message.conversationId, retired: retired.slice(-16),
    sidebarRows: message.observations.filter(row => row.signal.startsWith("sidebar-")).length,
    spinningRows: message.observations.filter(row => row.signal === "sidebar-spinner").length,
  };
  await writeBucket(TABS_KEY, tabs);
  // Start transport without blocking the observation/send queue behind a diagnostic.
  void sendBrowserHeartbeat(false, tabs).catch(() => {});

  const records = await readBucket(CONVERSATIONS_KEY);
  const seen = new Set();
  for (const row of message.observations) {
    const hash = await hashConversationId(row.conversationId);
    seen.add(hash);
    let record = records[hash];
    const wasKnown = Boolean(record);
    // Opening an idle conversation or changing its title is never a new run.
    if (!record && row.activity !== "thinking") continue;
    if (!record) record = records[hash] = { conversationHash: hash, title: "", mode: "ChatGPT", active: false, observers: {} };
    const selected = row.conversationId === message.conversationId;
    record.title = text(row.title, 180) || (selected ? text(message.title, 180) : "") || record.title;
    if (selected && normalizeMode(message.mode) !== "ChatGPT") record.mode = normalizeMode(message.mode);
    const before = record.observers[String(tabId)];
    const sameDocument = before && before.streamId === streamId;
    const evidence = {
      streamId, documentId: message.documentId, sequence: message.sequence, observedAt: message.observedAt,
      activity: row.activity, signal: row.signal,
      hasSeenThinking: row.activity === "thinking" || Boolean(sameDocument && before.hasSeenThinking),
      idleSince: row.activity === "idle" && sameDocument && before.activity === "idle" ? before.idleSince : message.observedAt,
    };
    record.observers[String(tabId)] = evidence;
    if (row.activity === "thinking") {
      record.lastThinkingAt = message.observedAt;
      if (!record.active || record.finishObserved) {
        record.requestId = (await browserInstanceId()) + ":ui:" + hash + ":" + crypto.randomUUID();
        record.active = true;
        record.finishObserved = false;
        record.startAccepted = false;
        // Prior-run idle/positive samples cannot terminate or keep alive a later run.
        record.observers = { [String(tabId)]: evidence };
      }
      if (!record.startAccepted) {
        // Persist the idempotency key before any external side effect. Retrying
        // after an interrupted worker uses this exact run, never a new request ID.
        await writeBucket(CONVERSATIONS_KEY, records);
        record.startAccepted = await postStatus("start", record, evidence);
        if (record.startAccepted) record.publishedTitle = record.title;
      }
    }
    // Late titles (even after completion) update only the original conversation.
    // Retain publication acknowledgement separately so a failed update is retried.
    if (wasKnown && record.title && record.title !== record.publishedTitle) {
      if (await postStatus("metadata", record, evidence)) record.publishedTitle = record.title;
    }
    records[hash] = record;
  }
  // A disappeared/sidebar-collapsed row is unknown, never an idle/terminal sample.
  for (const [hash, record] of Object.entries(records)) {
    const observer = record.observers[String(tabId)];
    if (observer && !seen.has(hash)) {
      observer.activity = "unknown";
      observer.signal = "none";
      observer.idleSince = 0;
    }
  }
  for (const record of Object.values(records)) {
    if (!record.active) continue;
    const observers = Object.values(record.observers);
    const thinking = observers.some(observer => observer.activity === "thinking" &&
      message.observedAt - observer.observedAt <= OBSERVATION_MAX_AGE_MS);
    const terminal = observers.find(observer => observer.streamId === streamId && observer.sequence === message.sequence &&
      observer.activity === "idle" && observer.hasSeenThinking &&
      observer.idleSince > 0 && observer.observedAt - observer.idleSince >= UI_FINISH_CONFIRM_MS &&
      message.observedAt - observer.observedAt <= OBSERVATION_MAX_AGE_MS);
    if (!thinking && terminal) {
      record.finishObserved = true;
      await writeBucket(CONVERSATIONS_KEY, records);
      // A missing HTTP acknowledgement does not mean start was not accepted.
      // The exact run ID makes repeated finish signals safe at the bridge.
      if (await postStatus("finish", record, terminal)) {
        record.active = false;
        record.startAccepted = false;
      }
    }
  }
  await writeBucket(CONVERSATIONS_KEY, records);
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === "agentpagerCheckBridge" && sender.url === chrome.runtime.getURL("popup.html")) {
    void sendBrowserHeartbeat(true).then(sendResponse, () => sendResponse({ ok: false }));
    return true;
  }
  if (!validObservation(message, sender)) return false;
  void enqueue(() => refreshTabMetadata(sender.tab.id, message, sender.documentId || ""))
    .then(() => sendResponse({ ok: true })).catch(() => sendResponse({ ok: false }));
  return true;
});

async function sendHeartbeats() {
  const records = await readBucket(CONVERSATIONS_KEY);
  for (const record of Object.values(records)) {
    if (!record.active || !record.startAccepted) continue;
    const evidence = Object.values(record.observers).find(observer => observer.activity === "thinking" &&
      Date.now() - observer.observedAt <= OBSERVATION_MAX_AGE_MS);
    if (evidence) await postStatus("heartbeat", record, evidence);
  }
}
chrome.alarms.create(HEARTBEAT_ALARM, { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name !== HEARTBEAT_ALARM) return;
  void sendBrowserHeartbeat(true).catch(() => {});
  enqueueSilently(sendHeartbeats);
});

// A tab closing, navigation, reload, browser startup, or service-worker restart is
// not evidence that any server-side Chat/Work run completed. Never synthesize Stop.
chrome.tabs.onRemoved.addListener(tabId => {
  enqueueSilently(async () => {
    const tabs = await readBucket(TABS_KEY);
    delete tabs[String(tabId)];
    await writeBucket(TABS_KEY, tabs);
    const records = await readBucket(CONVERSATIONS_KEY);
    for (const record of Object.values(records)) delete record.observers[String(tabId)];
    await writeBucket(CONVERSATIONS_KEY, records);
  });
});
// Network response completion is deliberately not a lifecycle signal: Work's
// response stream can close while its task and sidebar spinner are still active.
