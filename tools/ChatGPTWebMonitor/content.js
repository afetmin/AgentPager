(() => {
  "use strict";

  const PAGE_KEY = "agentpagerChatGPTPage";
  const REPORT_INTERVAL_MS = 1000;
  const SIDEBAR = 'nav,aside,#history,[data-testid="history"],[data-testid="sidebar"]';
  const SPINNERS = '[data-loading-indicator],[role="progressbar"],.animate-spin,' +
    '[data-testid="loading-indicator"],[data-testid="conversation-loading"],svg[class*="spin"]';
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  const documentId = crypto.randomUUID();
  let sequence = 0;
  let lastSignature = "";
  let lastSentAt = 0;

  // Identity is exclusively the server-issued /c/{uuid}, never title or prompt text.
  function conversationIdFromUrl(value) {
    try {
      const url = new URL(value, location.origin);
      if (url.protocol !== "https:" || !/^(chatgpt\.com|chat\.openai\.com)$/i.test(url.hostname)) return "";
      const match = url.pathname.match(/(?:^|\/)c\/([^/]+)\/?$/i);
      return match && UUID.test(match[1]) ? match[1].toLowerCase() : "";
    } catch (_) { return ""; }
  }

  function text(value, limit = 180) {
    return String(value || "").replace(/\s+/g, " ").trim().slice(0, limit);
  }

  function cleanTitle(value) {
    const title = text(value).replace(/\s*[|·–-]\s*ChatGPT\s*$/i, "").trim();
    return /^(chatgpt|new chat|home|新聊天|聊天)$/i.test(title) ? "" : title;
  }

  function visible(element) {
    if (!element || !element.getClientRects || !element.getClientRects().length) return false;
    for (let node = element; node && node.nodeType === 1; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (node.hidden || style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return false;
    }
    return true;
  }

  function titleElement(anchor) {
    return anchor.querySelector('[data-testid="conversation-title"],[data-sidebar-title],.truncate') || null;
  }

  function sidebarTitle(anchor) {
    const title = titleElement(anchor);
    if (title) return cleanTitle(title.textContent);
    const copy = anchor.cloneNode(true);
    copy.querySelectorAll('button,[role="button"],[role="status"],[role="progressbar"],svg,[data-loading-indicator],.sr-only')
      .forEach(node => node.remove());
    return cleanTitle(copy.textContent);
  }

  function rowFor(anchor, id) {
    // Some layouts put the trailing status next to the link, not inside it.
    // Never climb into a container containing another conversation's link.
    let row = anchor;
    for (let parent = anchor.parentElement, depth = 0;
      parent && depth < 3 && !parent.matches(SIDEBAR) && parent.closest(SIDEBAR);
      parent = parent.parentElement, depth++) {
      if (parent.matches('ul,ol,[role="list"],[role="group"],section')) break;
      const links = Array.from(parent.querySelectorAll("a[href]"))
        .filter(link => conversationIdFromUrl(link.href));
      if (links.length !== 1 || conversationIdFromUrl(links[0].href) !== id) break;
      row = parent;
      if (parent.matches('li,[role="listitem"],[data-testid^="history-item"]')) break;
    }
    return row;
  }

  function hasTrailingSpinner(anchor, row) {
    const title = titleElement(anchor);
    const indicators = Array.from(row.querySelectorAll(SPINNERS));
    // Some builds put layout/size on the processing wrapper, not the marker.
    for (const status of row.querySelectorAll('[role="status"][aria-label]')) {
      if (/(处理中|思考中|processing|thinking|generating|working)/i.test(status.getAttribute("aria-label")) &&
        status.querySelector('[data-loading-indicator]')) indicators.push(status);
    }
    // Also support CSS-keyframed SVG spinners without a stable generated class.
    for (const svg of row.querySelectorAll("svg")) {
      if (/spin|rotat/i.test(getComputedStyle(svg).animationName || "")) indicators.push(svg);
    }
    return indicators.some(indicator => {
      if (!visible(indicator)) return false;
      if (!title) return true;
      if (title.contains(indicator)) return false;
      const a = title.getBoundingClientRect();
      const b = indicator.getBoundingClientRect();
      // A trailing spinner may overlap a truncate box, so compare its left edge,
      // not the box's (potentially full-row) right edge.
      if (a.width > 0 && b.width > 0) return b.left >= a.left + Math.min(a.width / 2, 24);
      return Boolean(title.compareDocumentPosition(indicator) & Node.DOCUMENT_POSITION_FOLLOWING);
    });
  }

  function sidebarObservations() {
    const rows = new Map();
    for (const anchor of document.querySelectorAll("a[href]")) {
      if (!anchor.closest(SIDEBAR) || !visible(anchor)) continue;
      const conversationId = conversationIdFromUrl(anchor.href);
      if (!conversationId) continue;
      const row = rowFor(anchor, conversationId);
      const thinking = hasTrailingSpinner(anchor, row);
      const observation = {
        conversationId,
        title: sidebarTitle(anchor),
        activity: thinking ? "thinking" : "idle",
        signal: thinking ? "sidebar-spinner" : "sidebar-idle",
      };
      // Duplicate desktop/mobile links are one observation. A positive signal wins.
      if (!rows.has(conversationId) || thinking) rows.set(conversationId, observation);
    }
    return Array.from(rows.values()).slice(0, 250);
  }

  function isStopControl(element) {
    if (element.getAttribute("data-testid") === "stop-button") return true;
    return [element.getAttribute("aria-label"), element.getAttribute("title"), element.textContent]
      .some(value => {
        const label = text(value).toLowerCase();
        return /^(stop|cancel|停止|取消)$/.test(label) ||
          (/\b(stop|cancel)\b/.test(label) && /\b(generat|stream|response|task|answer|thinking)/.test(label)) ||
          /(停止|取消).*(生成|回答|任务|思考)/.test(label);
      });
  }

  function boundConversationRoot(id) {
    // A URL change alone does not bind the previous conversation's main pane.
    if (!id) return null;
    return Array.from(document.querySelectorAll('main[data-conversation-id],[role="main"][data-conversation-id]'))
      .find(root => root.getAttribute("data-conversation-id").toLowerCase() === id && visible(root)) || null;
  }

  function currentMode() {
    for (const control of document.querySelectorAll('button,[role="tab"],[role="radio"]')) {
      if (!visible(control)) continue;
      const selected = control.getAttribute("aria-selected") === "true" || control.getAttribute("aria-pressed") === "true" ||
        control.getAttribute("aria-checked") === "true" || control.getAttribute("data-state") === "active";
      if (!selected) continue;
      const labels = [control.getAttribute("aria-label"), control.getAttribute("title"), control.textContent].map(value => text(value).toLowerCase());
      if (labels.some(value => /^(work|work mode|工作|工作模式)$/.test(value))) return "Work";
      if (labels.some(value => /^(chat|chat mode|聊天|聊天模式)$/.test(value))) return "Chat";
    }
    return "ChatGPT";
  }

  function sendPageMetadata(force = false) {
    const conversationId = conversationIdFromUrl(location.href);
    const observations = sidebarObservations();
    const selected = observations.find(row => row.conversationId === conversationId);
    const root = boundConversationRoot(conversationId);
    // Sidebar is authoritative even when another chat's main pane is still mounted.
    // Stop controls are a fallback only inside an explicitly identity-bound pane.
    if (!selected && root) {
      const thinking = Array.from(root.querySelectorAll('button,[role="button"]')).some(control => visible(control) && isStopControl(control));
      const ready = Array.from(root.querySelectorAll('[data-testid="send-button"],button[aria-label="Send prompt"],button[aria-label="发送提示"]')).some(visible);
      if (thinking || ready) observations.push({ conversationId, title: "", activity: thinking ? "thinking" : "idle", signal: thinking ? "stop-control" : "composer-idle" });
    }
    // Status/title only: never inspect the conversation's user or assistant text.
    const prompt = ""; // Keep the legacy wire field empty for compatibility.
    const title = selected?.title || (root ? cleanTitle(document.title) : "");
    const mode = currentMode();
    const pageUrl = location.origin + location.pathname;
    const signature = JSON.stringify([pageUrl, conversationId, title, prompt, mode, observations]);
    const observedAt = Date.now();
    if (!force && signature === lastSignature && observedAt - lastSentAt < REPORT_INTERVAL_MS) return;
    lastSignature = signature;
    lastSentAt = observedAt;
    try {
      const pending = chrome.runtime.sendMessage({
        type: PAGE_KEY, version: 2, documentId, sequence: ++sequence, observedAt,
        pageUrl, conversationId, title, prompt, mode, observations,
        isThinking: observations.some(row => row.conversationId === conversationId && row.activity === "thinking"),
      });
      if (pending && typeof pending.catch === "function") pending.catch(() => {});
    } catch (_) { }
  }

  sendPageMetadata(true);
  setInterval(() => sendPageMetadata(), 500);
  let refreshTimer = null;
  const observer = new MutationObserver(() => {
    if (refreshTimer !== null) return;
    refreshTimer = setTimeout(() => { refreshTimer = null; sendPageMetadata(); }, 80);
  });
  const observe = () => {
    if (!document.documentElement) return;
    observer.observe(document.documentElement, {
      childList: true, subtree: true, characterData: true, attributes: true,
      attributeFilter: ["class", "style", "hidden", "href", "aria-label", "aria-current", "aria-selected", "data-loading-indicator", "data-conversation-id"],
    });
  };
  observe();
  document.addEventListener("DOMContentLoaded", observe, { once: true });
  addEventListener("popstate", () => sendPageMetadata(true));
  addEventListener("pageshow", () => sendPageMetadata(true));
})();
