import { host } from '@hermes/plugin-sdk';
// AgentPager status exporter r4.2. Updated only as an installed, recognized integration.

const heartbeatMs = 5_000;
const expiryMs = 90_000;
const maximumSessions = 20;
const maximumTitle = 160;
// Replaced by the Windows Bridge installer with an independent local token.
const bridgeToken = 'AGENTPAGER_LOCAL_STATUS_TOKEN';
const text = value => typeof value === 'string' ? value.trim() : '';
function titleText(value, maximum = maximumTitle) {
  let title = text(value).replace(/[\u0000-\u001f\u007f-\u009f]/g, ' ').slice(0, maximum);
  if (/[\ud800-\udbff]$/.test(title)) title = title.slice(0, -1);
  return title.trim();
}
const priority = state => ({ running: 4, waiting: 3, succeeded: 2, interrupted: 2, idle: 1, offline: 0 })[state] ?? -1;
function bounded(rows) {
  const unique = new Map();
  for (const row of rows) {
    const prior = unique.get(row.id);
    if (!prior || row.updatedAt > prior.updatedAt || row.updatedAt === prior.updatedAt && priority(row.state) > priority(prior.state)) unique.set(row.id, row);
  }
  return [...unique.values()].sort((a, b) => priority(b.state) - priority(a.state)
    || b.updatedAt - a.updatedAt || a.id.localeCompare(b.id)).slice(0, maximumSessions);
}

// Only bounded, allowlisted SDK metadata leaves the renderer. Never export inventory rows.
const counter = value => Number.isSafeInteger(value) && value >= 0 && value <= 2_147_483_647;
const money = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1e9;
function pricePerMillion(value) {
  if (value === 'free') return 0;
  if (typeof value !== 'string' || !/^\$?\d+(?:\.\d+)?$/.test(value.trim())) return null;
  const result = Number(value.trim().replace(/^\$/, ''));
  return money(result) ? result : null;
}
// BroadcastChannel is same-origin but not a permission to forward arbitrary nested fields.
function safeModelUsage(value) {
  if (!value || !counter(value.inputTokens) || !counter(value.outputTokens) || !counter(value.totalTokens)) return undefined;
  const result = { inputTokens: value.inputTokens, outputTokens: value.outputTokens, totalTokens: value.totalTokens };
  for (const key of ['model', 'provider']) if (titleText(value[key])) result[key] = titleText(value[key], 64);
  if (money(value.estimatedCostUSD) && ['sdk_reported', 'current_model_pricing'].includes(value.costSource)) {
    result.estimatedCostUSD = value.estimatedCostUSD; result.costSource = value.costSource;
  }
  const quota = value.quota;
  if (quota && titleText(quota.label) && typeof quota.usedPercentage === 'number' && Number.isFinite(quota.usedPercentage)
      && quota.usedPercentage >= 0 && quota.usedPercentage <= 100 && ['session_plan_gauge', 'provider_cache'].includes(quota.source)
      && (quota.resetsAt == null || Number.isSafeInteger(quota.resetsAt) && quota.resetsAt > 0 && quota.resetsAt <= 253402300799999)) {
    result.quota = { label: titleText(quota.label, 32), usedPercentage: quota.usedPercentage, source: quota.source,
      ...(quota.resetsAt != null ? { resetsAt: quota.resetsAt } : {}) };
  }
  return result;
}

export function projectModelUsage(usage, options) {
  if (!usage || !counter(usage.input) || !counter(usage.output) || !counter(usage.total)) return undefined;
  const result = { inputTokens: usage.input, outputTokens: usage.output, totalTokens: usage.total };
  const model = titleText(usage.model);
  if (model) result.model = model;
  // model.options is session-scoped. Exact IDs only; aliases/current-global/provider order are not identity.
  const provider = options?.model === model && text(options?.provider);
  const matches = provider && Array.isArray(options?.providers) ? options.providers.filter(row => row && row.slug === provider) : [];
  const row = matches.length === 1 ? matches[0] : null;
  if (row && provider.length <= maximumTitle) result.provider = provider;
  if (money(usage.cost_usd)) {
    result.estimatedCostUSD = usage.cost_usd;
    result.costSource = 'sdk_reported'; // SDK does not declare actual-vs-estimated; never claim invoice cost.
  } else if (row) {
    const pricing = row.pricing?.[model];
    const inputRate = pricePerMillion(pricing?.input), outputRate = pricePerMillion(pricing?.output);
    if (inputRate !== null && outputRate !== null) {
      // Prompt includes cache when supplied. Full input list price intentionally ignores discounts/cache tiers.
      const input = counter(usage.prompt) && usage.prompt >= usage.input ? usage.prompt : usage.input;
      const estimate = (input * inputRate + usage.output * outputRate) / 1_000_000;
      if (money(estimate)) {
        result.estimatedCostUSD = estimate;
        result.costSource = 'current_model_pricing';
      }
    }
  }
  const gauge = usage.plan_gauge;
  if (gauge && counter(gauge.used_bp) && gauge.used_bp <= 10000 && titleText(gauge.label)
      && (gauge.resets_at_ms == null || Number.isSafeInteger(gauge.resets_at_ms) && gauge.resets_at_ms > Date.now())) {
    result.quota = { label: titleText(gauge.label), usedPercentage: gauge.used_bp / 100, source: 'session_plan_gauge',
      ...(gauge.resets_at_ms != null ? { resetsAt: gauge.resets_at_ms } : {}) };
  } else if (row?.usage && row.usage.accounts == null && Array.isArray(row.usage.windows)) {
    // Native contract: legacy windows mean a single login. Never pick a sibling from a credential pool.
    const windows = row.usage.windows.slice(0, 8).filter(window => window.scope === 'account'
      && titleText(window.label) && typeof window.used_percent === 'number' && Number.isFinite(window.used_percent)
      && window.used_percent >= 0 && window.used_percent <= 100
      && (window.resets_at == null || Number.isFinite(Date.parse(window.resets_at)) && Date.parse(window.resets_at) > Date.now()));
    const binding = windows.sort((a, b) => b.used_percent - a.used_percent)[0];
    if (binding) result.quota = { label: titleText(binding.label), usedPercentage: binding.used_percent, source: 'provider_cache',
      ...(binding.resets_at != null ? { resetsAt: Date.parse(binding.resets_at) } : {}) };
  }
  return safeModelUsage(result);
}

export default {
  id: 'agentpager-status',
  name: 'AgentPager 会话状态同步',
  defaultEnabled: false,
  register(ctx) { startStatusMonitor(ctx, bridgeToken); },
};

// Only public SDK doors. active_list.id is RUNTIME, session_key is STORED;
// busyBySession is keyed by RUNTIME. Neither list previews nor transcripts leave this function.
function sessionRoster(sdk, changed) {
  const routes = new Map();
  let refreshing = false;
  let generation = 0;
  let stopped = false;
  const value = name => sdk.state[name]?.get?.();
  const activeRoute = () => ({ connectionId: text(value('connectionId')) || 'local', profile: text(value('profile')) || 'default' });
  const keyOf = route => JSON.stringify([route.connectionId, route.profile]);
  const remember = route => {
    const key = keyOf(route);
    if (!routes.has(key)) {
      if (routes.size >= 8) routes.delete(routes.keys().next().value);
      routes.set(key, { route, rows: [], runtime: new Map(), outcomes: new Map(), work: new Map(), workAt: 0 });
    }
    return routes.get(key);
  };
  async function stableID(route, storedID) {
    const bytes = new TextEncoder().encode(JSON.stringify([route.connectionId, route.profile, storedID]));
    const digest = await crypto.subtle.digest('SHA-256', bytes);
    return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
  }
  let previousBusy = { ...(value('busyBySession') || {}) };
  function busyChanged() {
    const busy = value('busyBySession') || {};
    const changes = Object.entries(busy).filter(([runtime, working]) => typeof working === 'boolean' && previousBusy[runtime] !== working);
    previousBusy = { ...busy };
    if (!changes.length) return;
    generation++;
    for (const [runtime, working] of changes) {
      // Ambiguous runtime IDs from separate gateways must not cross-update.
      const owners = [...routes.values()].filter(route => route.runtime.has(runtime));
      if (owners.length !== 1 || typeof working !== 'boolean') continue;
      const owner = owners[0], id = owner.runtime.get(runtime);
      if (working) owner.outcomes.delete(runtime);
      const anyWorking = [...owner.runtime].some(([handle, mapped]) => mapped === id && busy[handle] === true);
      owner.rows = owner.rows.map(row => row.id === id
        ? { ...row, state: anyWorking || row.activeSubagents > 0 ? 'running' : owner.outcomes.get(runtime) || 'idle', updatedAt: Date.now() } : row);
    }
    changed();
  }
  async function refresh() {
    if (stopped || refreshing || value('gateway') !== 'open' || typeof sdk.request !== 'function') return;
    refreshing = true;
    const active = activeRoute();
    remember(active);
    const focusedOwner = value('focusedSessionOwner');
    if (focusedOwner?.connectionId && focusedOwner?.profile) remember(focusedOwner);
    const started = generation;
    try {
      await Promise.all([...routes.values()].map(async entry => {
        const route = entry.route;
        const isActive = keyOf(route) === keyOf(active);
        if (!isActive && typeof sdk.requestProfile !== 'function') return;
        const request = (method, params) => isActive ? sdk.request(method, params, 2_500)
          : sdk.requestProfile({ ...route, mode: route.connectionId === 'local' ? 'local' : 'remote', targetProfile: route.profile }, method, params, 2_500);
        // Bound stored metadata. It resolves compression roots/titles, NEVER creates historical cards.
        const requestedAt = Date.now();
        const [liveResult, storedResult, workResult, profilesResult] = await Promise.allSettled([
          request('session.active_list', {}), request('session.list', { limit: 100, profile: route.profile }),
          request('subagent.roster', { profile: route.profile }), request('profiles.list', { include_sessions: false }),
        ]);
        const profiles = profilesResult.status === 'fulfilled' && Array.isArray(profilesResult.value?.profiles)
          ? profilesResult.value.profiles.slice(0, 500) : [];
        const ownerProfile = profiles.find(row => row?.name === route.profile);
        const agentName = ownerProfile
          ? titleText(ownerProfile.display_name, 64) || titleText(route.profile, 64)
          : entry.agentName || titleText(route.profile, 64);
        const stored = storedResult.status === 'fulfilled' && Array.isArray(storedResult.value?.sessions)
          ? storedResult.value.sessions.slice(0, 100) : [];
        const rootFor = id => text(stored.find(item => item.id === id || item.resolved_id === id)?._lineage_root_id) || id;
        const validWork = workResult.status === 'fulfilled' && Array.isArray(workResult.value?.sessions)
          && workResult.value.sessions.length <= 2000 && workResult.value.sessions.every(row => row
            && typeof row.session_id === 'string' && row.session_id.length > 0 && row.session_id.length <= 256
            && Number.isSafeInteger(row.subagents) && row.subagents >= 0 && row.subagents <= 1024);
        const work = validWork ? new Map() : entry.work;
        if (validWork) for (const row of workResult.value.sessions) {
          const root = rootFor(row.session_id);
          work.set(root, Math.min(1024, (work.get(root) || 0) + row.subagents));
        }
        const workAt = validWork ? requestedAt : entry.workAt;
        let live;
        if (liveResult.status === 'fulfilled' && Array.isArray(liveResult.value?.sessions)) {
          // active_list is PROCESS-wide on a shared Gateway, not profile-scoped.
          // Only the owning profile's stored metadata, fresh child-work roster,
          // or explicit focused owner may qualify a card. Never relabel foreign runtimes.
          if (storedResult.status !== 'fulfilled' || !Array.isArray(storedResult.value?.sessions)) return;
          const owner = focusedOwner || active;
          live = liveResult.value.sessions.filter(row => stored.some(item => item.id === row.session_key || item.resolved_id === row.session_key)
            || Date.now() - workAt < expiryMs && work.has(rootFor(text(row.session_key)))
            || keyOf(owner) === keyOf(route) && value('focusedSessionId') === row.id && value('focusedStoredSessionId') === row.session_key);
        } else if (storedResult.status === 'fulfilled' && storedResult.value?.scope === 'live') {
          // Canonical gateway list has session_id/id + running; an explicit scope is mandatory.
          live = stored.map(row => ({ id: row.session_id, session_key: row.id, title: row.root_title || row.title,
            status: row.running === true ? 'working' : 'idle' }));
        } else {
          // Older SDK/gateway: export ONLY the positively identified focused conversation.
          const owner = focusedOwner || active;
          const focused = value('focusedStoredSessionId');
          const runtime = value('focusedSessionId') || value('activeSessionId');
          const row = keyOf(owner) === keyOf(route) && stored.find(row => row.id === focused || row._lineage_root_id === focused);
          if (!row || !runtime) return; // failure is not an authoritative empty roster
          live = [{ id: runtime, session_key: focused, title: row.title,
            status: value('busyBySession')?.[runtime] === true ? 'working' : 'idle' }];
        }
        const now = Date.now();
        live = [...live];
        const represented = new Set(live.map(row => rootFor(text(row.session_key))));
        // Only a positive native roster may create a background parent card; never enumerate history.
        for (const [storedID, count] of work) if (count > 0 && now - workAt < expiryMs && !represented.has(storedID)) {
          live.push({ id: 'delegation:' + storedID, session_key: storedID, status: 'idle', title: '子代理工作中的会话' });
        }
        const runtimeMap = new Map();
        const activeRuntimes = new Set();
        const rows = await Promise.all(live.slice(0, 200).map(async row => {
          const runtime = text(row.id), storedID = text(row.session_key);
          if (!runtime || !storedID || runtime.length > 256 || storedID.length > 256) return null;
          const metadata = stored.find(item => item.id === storedID || item.resolved_id === storedID);
          const root = text(metadata?._lineage_root_id) || storedID;
          const id = await stableID(route, root);
          runtimeMap.set(runtime, id);
          const active = ['working', 'streaming', 'starting', 'resuming'].includes(row.status);
          if (active || row.status === 'waiting') activeRuntimes.add(runtime);
          const count = work.get(root) || 0;
          const activeSubagents = now - workAt < expiryMs ? count : 0;
          const state = count > 0 && !activeSubagents ? 'offline' : row.status === 'waiting' ? 'waiting' : active || activeSubagents > 0 ? 'running'
            : row.status === 'idle' ? entry.outcomes.get(runtime) || 'idle' : 'offline';
          return { id, runtime, agentName, title: titleText(metadata?.title) || titleText(row.title) || '未命名会话', state,
            updatedAt: activeSubagents > 0 && !active ? workAt : now,
            ...(activeSubagents > 0 ? { activeSubagents } : {}) };
        }));
        const cards = await Promise.all(bounded(rows.filter(Boolean)).map(async ({ runtime, ...card }) => {
          // Bounded to visible live cards, routed to their owner, never to the global focused model.
          const usage = runtime.startsWith('delegation:') ? undefined : await request('session.usage', { session_id: runtime }).catch(() => undefined);
          if (!usage || !counter(usage.input) || !counter(usage.output) || !counter(usage.total)) return card;
          const options = await request('model.options', { session_id: runtime }).catch(() => undefined);
          const modelUsage = projectModelUsage(usage, options);
          return modelUsage ? { ...card, modelUsage } : card;
        }));
        // Focus/profile/busy changed while the RPC was pending: never overwrite newer local evidence.
        if (stopped || generation !== started || keyOf(activeRoute()) !== keyOf(active)) return;
        entry.rows = cards;
        entry.agentName = agentName;
        entry.runtime = runtimeMap;
        entry.work = work; entry.workAt = workAt;
        for (const runtime of activeRuntimes) entry.outcomes.delete(runtime);
        for (const runtime of entry.outcomes.keys()) if (!runtimeMap.has(runtime)) entry.outcomes.delete(runtime);
      }));
    } catch { /* Optional SDK/gateway features must never break Hermes. */ }
    finally { refreshing = false; if (!stopped) changed(); }
  }
  const stopComplete = sdk.onEvent?.('message.complete', event => {
    const runtime = text(event.session_id);
    const outcome = event.payload?.status;
    if (!runtime || !['complete', 'error', 'interrupted'].includes(outcome)) return;
    const owners = [...routes.values()].filter(entry => entry.runtime.has(runtime)
      && (!event.connectionId || event.connectionId === entry.route.connectionId)
      && (!event.profile || event.profile === entry.route.profile));
    if (owners.length !== 1) return;
    generation++;
    const owner = owners[0], id = owner.runtime.get(runtime);
    const terminal = outcome === 'complete' ? 'succeeded' : 'interrupted';
    owner.outcomes.set(runtime, terminal);
    const anotherWorking = [...owner.runtime].some(([handle, mapped]) => handle !== runtime && mapped === id
      && value('busyBySession')?.[handle] === true);
    owner.rows = owner.rows.map(row => row.id === id ? { ...row,
      state: anotherWorking || row.activeSubagents > 0 ? 'running' : terminal, updatedAt: Date.now() } : row);
    changed();
  });
  return {
    supported: typeof sdk.request === 'function', refresh, busyChanged,
    stop() { stopped = true; stopComplete?.(); },
    rows() { return bounded([...routes.values()].flatMap(entry => entry.rows).map(row => ({ ...row,
      state: value('gateway') !== 'open' || Date.now() - row.updatedAt >= expiryMs ? 'offline' : row.state }))); },
  };
}

export function startStatusMonitor(ctx, token, sdk = host) {
  const { gateway, busyBySession } = sdk.state;
  const canUseLoopback = /^[a-fA-F0-9]{64}$/.test(token);
  if ((!canUseLoopback && !ctx.files?.writeText) || !gateway?.listen || !busyBySession?.listen) {
    sdk.notify({ kind: 'error', message: 'AgentPager 未配置可用的状态通道，请从 Bridge 的 HERMES 页面安装插件。' });
    return;
  }
  let disposed = false, writing = false, requested = false, lastState, warned = false;
  const localState = () => gateway.get() !== 'open' ? 'offline'
    : Object.values(busyBySession.get()).some(busy => busy === true) ? 'running' : 'idle';
  const channel = typeof window !== 'undefined' && typeof BroadcastChannel === 'function'
    ? new BroadcastChannel('agentpager-status-v2') : null;
  const windowID = channel ? crypto.randomUUID() : null;
  const peers = new Map();
  const roster = sessionRoster(sdk, () => { announce(); reconcile(); });
  function current() {
    let state = localState();
    const own = roster.supported ? roster.rows() : null;
    const sessions = new Map((own || []).map(row => [row.id, row]));
    let hasRoster = own !== null;
    const now = Date.now();
    for (const [id, peer] of peers) {
      if (now - peer.at >= expiryMs) { peers.delete(id); continue; }
      if (peer.state === 'running') state = 'running';
      else if (peer.state === 'idle' && state === 'offline') state = 'idle';
      if (peer.sessions) {
        hasRoster = true;
        for (const row of peer.sessions) {
          const prior = sessions.get(row.id);
          if (!prior || row.updatedAt > prior.updatedAt || row.updatedAt === prior.updatedAt && priority(row.state) > priority(prior.state)) sessions.set(row.id, row);
        }
      }
    }
    const cards = bounded([...sessions.values()].map(row => ({ ...row,
      state: now - row.updatedAt >= expiryMs ? 'offline' : row.state })));
    if (cards.some(row => row.state !== 'offline' && (row.state === 'running' || row.activeSubagents > 0))) state = 'running';
    return hasRoster ? { version: 2, state, sessions: cards } : { version: 1, state };
  }
  async function publish() {
    if (disposed) return;
    requested = true;
    if (writing) return;
    writing = true;
    try {
      while (requested && !disposed) {
        requested = false;
        const snapshot = current();
        const payload = { ...snapshot, updatedAt: Date.now() };
        let sent = false;
        try {
          if (canUseLoopback) {
            const response = await fetch('http://127.0.0.1:49362/hermes-status', {
              method: 'POST', credentials: 'omit', redirect: 'error',
              body: JSON.stringify({ ...payload, token }), signal: AbortSignal.timeout(2500),
            });
            sent = response.ok;
          } else sent = (await ctx.files.writeText('data', 'status.json', JSON.stringify(payload))).ok;
        } catch { /* Retain heartbeat after transient failures. */ }
        if (sent) { lastState = JSON.stringify(snapshot); warned = false; }
        else if (!warned && !disposed) {
          warned = true;
          sdk.notify({ kind: 'error', message: 'AgentPager 暂未收到状态，请检查 Bridge 的 HERMES 页面。' });
        }
      }
    } finally { writing = false; }
  }
  function reconcile() { if (writing || JSON.stringify(current()) !== lastState) void publish(); }
  function announce() { channel?.postMessage({ id: windowID, state: localState(), sessions: roster.supported ? roster.rows() : null }); }
  if (channel) channel.onmessage = ({ data }) => {
    if (!data || typeof data.id !== 'string' || data.id.length > 64) return;
    if (data.state === 'leaving') peers.delete(data.id);
    else if (['idle', 'running', 'offline'].includes(data.state)) {
      const known = peers.has(data.id);
      if (!known && peers.size >= 32) return;
      const sessions = Array.isArray(data.sessions) ? data.sessions.slice(0, maximumSessions).filter(row => row
        && /^[a-f0-9]{64}$/.test(row.id) && typeof row.title === 'string' && row.title.length <= maximumTitle
        && priority(row.state) >= 0 && Number.isSafeInteger(row.updatedAt) && row.updatedAt <= Date.now() + 5_000)
        .map(row => ({ id: row.id, title: titleText(row.title), state: row.state, updatedAt: row.updatedAt,
          ...(titleText(row.agentName, 64) ? { agentName: titleText(row.agentName, 64) } : {}),
          ...(Number.isSafeInteger(row.activeSubagents) && row.activeSubagents > 0 && row.activeSubagents <= 1024 ? { activeSubagents: row.activeSubagents } : {}),
          ...(safeModelUsage(row.modelUsage) ? { modelUsage: safeModelUsage(row.modelUsage) } : {}) })) : null;
      peers.set(data.id, { state: data.state, sessions, at: Date.now() });
      if (!known) announce();
    } else return;
    reconcile();
  };
  const stopGateway = gateway.listen(() => { announce(); reconcile(); void roster.refresh(); });
  const stopBusy = busyBySession.listen(() => roster.busyChanged());
  const stopAtoms = ['focusedSessionId', 'focusedStoredSessionId', 'focusedSessionOwner', 'profile', 'connectionId']
    .map(name => sdk.state[name]?.listen?.(() => { void roster.refresh(); })).filter(Boolean);
  const heartbeat = setInterval(() => { announce(); void publish(); void roster.refresh(); }, heartbeatMs);
  ctx.onDispose(() => {
    disposed = true;
    roster.stop(); clearInterval(heartbeat); stopGateway(); stopBusy(); stopAtoms.forEach(stop => stop());
    channel?.postMessage({ id: windowID, state: 'leaving' }); channel?.close();
  });
  announce(); void publish(); void roster.refresh();
}
