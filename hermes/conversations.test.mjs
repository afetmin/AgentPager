import assert from 'node:assert/strict';
import { registerHooks } from 'node:module';
import { test } from 'node:test';
const hooks = registerHooks({ resolve(name, context, next) {
  return name === '@hermes/plugin-sdk'
    ? { url: 'data:text/javascript,export const host = globalThis.conversationHost', shortCircuit: true }
    : next(name, context);
} });
globalThis.conversationHost = {};
const { startStatusMonitor, projectModelUsage } = await import('./plugin.js');
hooks.deregister();
function atom(value) {
  const listeners = new Set();
  return { get: () => value, listen(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    set(next) { value = next; listeners.forEach(fn => fn()); } };
}
// WebCrypto resolves on the worker pool; draining only microtasks is not a completion barrier.
const tick = () => new Promise(resolve => setImmediate(resolve));
async function waitFor(predicate) {
  for (let i = 0; i < 2000; i++) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 1));
  }
  assert.fail('SDK projection did not settle within the bounded test deadline');
}
function fixture(t, live, stored = [], usageByRuntime = {}, optionsByRuntime = {}, work = [], profiles = [], scopedMetadataOnly = false) {
  const emitted = [], calls = [], disposers = [];
  const state = { gateway: atom('open'), busyBySession: atom({}), connectionId: atom('local'), profile: atom('default'),
    focusedSessionId: atom(null), focusedStoredSessionId: atom(null) };
  const events = new Map();
  const sdk = { state, notify() {}, onEvent(type, handler) { events.set(type, handler); return () => events.delete(type); }, async request(method, params) {
    calls.push([method, params]);
    if (method === 'session.usage') return usageByRuntime[params.session_id];
    if (method === 'model.options') return optionsByRuntime[params.session_id];
    if (method === 'profiles.list') return { profiles };
    if (method === 'subagent.roster') return { sessions: work };
    // Default fixture models one profile: live rows also exist in session.list.
    // Cross-profile tests opt out explicitly to model a process-wide active_list.
    const metadata = scopedMetadataOnly ? stored : [...stored, ...[...live]
      .sort((a,b) => Number(b.status === 'working') - Number(a.status === 'working'))
      .filter(row => !stored.some(item => item.id === row.session_key || item.resolved_id === row.session_key))
      .map(row => ({id:row.session_key,title:row.title}))];
    return { sessions: method === 'session.active_list' ? live : metadata };
  } };
  Object.assign(globalThis.conversationHost, sdk);
  startStatusMonitor({ files: { async writeText(_area, _name, data) { emitted.push(JSON.parse(data)); return { ok: true }; } },
    onDispose: fn => disposers.push(fn) }, '', sdk);
  t.after(() => disposers.forEach(fn => fn()));
  return { emitted, calls, state, sdk, events, dispose: () => disposers.forEach(fn => fn()) };
}
test('exports real live titles and independent busy states, never previews/history', async t => {
  const f = fixture(t, [
    { id: 'runtime-a', session_key: 'stored-a', title: '修复支付 API', status: 'working', preview: 'SECRET BODY' },
    { id: 'runtime-b', session_key: 'stored-b', title: '整理文档', status: 'idle', messages: ['SECRET TRANSCRIPT'] },
  ], [{ id: 'historical', title: 'Must not become a card', preview: 'SECRET HISTORY' }]);
  await waitFor(() => f.emitted.at(-1)?.sessions?.length > 0);
  const packet = f.emitted.at(-1);
  assert.equal(packet.version, 2);
  assert.equal(packet.state, 'running', 'aggregate state must include gateway-reported live work');
  assert.deepEqual(packet.sessions.map(s => [s.title, s.state]).sort(), [['修复支付 API', 'running'], ['整理文档', 'idle']]);
  assert.equal(packet.sessions.length, 2);
  assert.ok(packet.sessions.every(s => /^[a-f0-9]{64}$/.test(s.id)));
  assert.equal(JSON.stringify(packet).includes('SECRET'), false);
  assert.deepEqual(Object.keys(packet.sessions[0]).sort(), ['agentName', 'id', 'state', 'title', 'updatedAt']);
  const before = packet.sessions.map(s => s.id).sort();
  f.state.focusedSessionId.set('runtime-b');
  f.state.focusedStoredSessionId.set('stored-b');
  f.state.busyBySession.set({ 'runtime-a': false, 'runtime-b': true });
  await tick();
  assert.deepEqual(f.emitted.at(-1).sessions.map(s => s.id).sort(), before);
  assert.deepEqual(f.emitted.at(-1).sessions.map(s => [s.title, s.state]).sort(), [['修复支付 API', 'idle'], ['整理文档', 'running']]);
});

test('deduplicates concurrent runtime handles for the same durable lineage', async t => {
  const f = fixture(t, [
    { id: 'runtime-before', session_key: 'segment-before', title: 'Same chat', status: 'idle' },
    { id: 'runtime-after', session_key: 'segment-after', title: 'Same chat', status: 'working' },
  ], [
    { id: 'segment-before', _lineage_root_id: 'root', title: 'Same chat' },
    { id: 'segment-after', _lineage_root_id: 'root', title: 'Same chat' },
  ]);
  await waitFor(() => f.emitted.at(-1)?.sessions?.length === 1);
  assert.equal(f.emitted.at(-1).sessions.length, 1);
  assert.equal(f.emitted.at(-1).sessions[0].state, 'running');
  f.state.busyBySession.set({ 'runtime-before': true, 'runtime-after': true });
  await tick();
  f.state.busyBySession.set({ 'runtime-before': false, 'runtime-after': true });
  await tick();
  assert.equal(f.emitted.at(-1).sessions[0].state, 'running', 'one runtime completing must not stop another live runtime of the same conversation');
});
test('empty idle exports no invented card and never enumerates stored history as cards', async t => {
  const f = fixture(t, [], Array.from({ length: 5000 }, (_, i) => ({ id: `old-${i}`, title: `Historical ${i}` })));
  await tick();
  assert.deepEqual(f.emitted.at(-1).sessions, []);
  assert.ok(f.calls.some(([method, params]) => method === 'session.list' && params.limit === 100));
});

test('bounds card count and titles, prioritizes running cards, strips control characters', async t => {
  const f = fixture(t, Array.from({ length: 200 }, (_, i) => ({ id: `r-${i}`, session_key: `s-${i}`,
    title: i === 199 ? 'ACTIVE\n' + '文'.repeat(500) : `Card ${i}`, status: i === 199 ? 'working' : 'idle' })));
  await waitFor(() => f.emitted.at(-1)?.sessions?.length > 0);
  const packet = f.emitted.at(-1);
  assert.equal(packet.sessions.length, 20);
  assert.equal(packet.sessions[0].state, 'running');
  assert.ok(packet.sessions.every(row => row.title.length <= 160 && !/[\u0000-\u001f]/.test(row.title)));
  assert.ok(Buffer.byteLength(JSON.stringify(packet), 'utf8') <= 32768);
});

test('runtime restart and compression tip rotation retain lineage identity', async t => {
  t.mock.timers.enable({ apis: ['setInterval', 'Date'], now: 100_000 });
  const live = [{ id: 'runtime-1', session_key: 'tip-1', title: 'Original', status: 'working' }];
  const stored = [{ id: 'tip-1', _lineage_root_id: 'root-1', title: 'Original' }];
  const f = fixture(t, live, stored);
  await waitFor(() => f.emitted.at(-1)?.sessions?.length === 1);
  const id = f.emitted.at(-1).sessions[0].id;
  live[0] = { id: 'runtime-2', session_key: 'tip-2', title: 'Renamed', status: 'idle' };
  stored[0] = { id: 'tip-2', _lineage_root_id: 'root-1', title: 'Renamed' };
  t.mock.timers.tick(5000); await waitFor(() => f.emitted.at(-1)?.sessions?.[0]?.title === 'Renamed');
  assert.deepEqual(f.emitted.at(-1).sessions.map(row => [row.id, row.title, row.state]), [[id, 'Renamed', 'idle']]);
});

test('older gateway falls back only to matched focused metadata, not its stored list', async t => {
  t.mock.timers.enable({ apis: ['setInterval', 'Date'], now: 100_000 });
  const f = fixture(t, []);
  f.state.focusedSessionId.set('runtime-focused');
  f.state.focusedStoredSessionId.set('stored-focused');
  f.state.busyBySession.set({ 'runtime-focused': true });
  await tick();
  f.sdk.request = async method => {
    if (method === 'session.active_list') throw new Error('Method not found');
    return { sessions: [{ id: 'stored-focused', title: '真实焦点标题' }, { id: 'history', title: 'Do not export' }] };
  };
  t.mock.timers.tick(5000); await waitFor(() => f.emitted.at(-1)?.sessions?.[0]?.title === '真实焦点标题');
  assert.deepEqual(f.emitted.at(-1).sessions.map(row => [row.title, row.state]), [['真实焦点标题', 'running']]);
});

test('canonical list is accepted only with explicit live scope', async t => {
  t.mock.timers.enable({ apis: ['setInterval', 'Date'], now: 100_000 });
  const f = fixture(t, []); await tick();
  f.sdk.request = async method => {
    if (method === 'session.active_list') throw new Error('Method not found');
    return { scope: 'live', sessions: [{ session_id: 'canonical-runtime', id: 'canonical-stored', title: 'Canonical chat', running: true }] };
  };
  t.mock.timers.tick(5000); await waitFor(() => f.emitted.at(-1)?.sessions?.[0]?.title === 'Canonical chat');
  assert.deepEqual(f.emitted.at(-1).sessions.map(row => [row.title, row.state]), [['Canonical chat', 'running']]);
});

test('metadata RPC failure expires cached work despite ongoing transport heartbeats', async t => {
  t.mock.timers.enable({ apis: ['setInterval', 'Date'], now: 100_000 });
  const f = fixture(t, [{ id: 'runtime', session_key: 'stored', title: 'Old working card', status: 'working' }]);
  await waitFor(() => f.emitted.at(-1)?.sessions?.length === 1);
  f.sdk.request = async () => { throw new Error('gateway unavailable'); };
  t.mock.timers.tick(90_000); await tick();
  assert.equal(f.emitted.at(-1).sessions[0].state, 'offline');
});

test('multi-window union deduplicates identity and newer idle beats stale running', async t => {
  t.mock.timers.enable({ apis: ['setInterval', 'Date'], now: 100_000 });
  const channels = new Set();
  t.mock.property(globalThis, 'BroadcastChannel', class {
    constructor() { channels.add(this); }
    postMessage(data) { for (const peer of channels) if (peer !== this) queueMicrotask(() => peer.onmessage?.({ data })); }
    close() { channels.delete(this); }
  });
  globalThis.window = {};
  t.after(() => { delete globalThis.window; });
  const first = fixture(t, [{ id: 'r1', session_key: 'same', title: 'Shared chat', status: 'working' }]);
  const second = fixture(t, [{ id: 'r2', session_key: 'same', title: 'Shared chat', status: 'working' },
    { id: 'r3', session_key: 'other', title: 'Other chat', status: 'idle' }]);
  await waitFor(() => first.emitted.at(-1)?.sessions?.length === 2 && second.emitted.at(-1)?.sessions?.length === 2);
  assert.equal(first.emitted.at(-1).sessions.length, 2);
  assert.equal(second.emitted.at(-1).sessions.length, 2);
  second.sdk.request = async () => { throw new Error('stale renderer'); };
  t.mock.timers.tick(1000);
  first.state.busyBySession.set({ r1: false });
  await tick();
  assert.equal(second.emitted.at(-1).sessions.find(row => row.title === 'Shared chat').state, 'idle');
  first.dispose(); second.dispose();
});

test('a different conversation changing busy state cannot renew stale work forever', async t => {
  t.mock.timers.enable({ apis: ['setInterval', 'Date'], now: 100_000 });
  const f = fixture(t, [{ id: 'r1', session_key: 's1', title: 'Stale', status: 'working' },
    { id: 'r2', session_key: 's2', title: 'Fresh', status: 'working' }]);
  await waitFor(() => f.emitted.at(-1)?.sessions?.length === 2);
  f.state.busyBySession.set({ r1: true, r2: true });
  await tick();
  f.sdk.request = async () => { throw new Error('no fresh metadata'); };
  t.mock.timers.tick(80_000); await tick();
  f.state.busyBySession.set({ r1: true, r2: false });
  await tick();
  t.mock.timers.tick(10_000); await tick();
  assert.equal(f.emitted.at(-1).sessions.find(row => row.title === 'Stale').state, 'offline');
  assert.equal(f.emitted.at(-1).sessions.find(row => row.title === 'Fresh').state, 'idle');
});

test('each card reads its runtime usage and estimates USD from exact session provider/model pricing', async t => {
  const f = fixture(t, [
    { id: 'runtime-a', session_key: 'stored-a', title: 'A', status: 'working' },
    { id: 'runtime-b', session_key: 'stored-b', title: 'B', status: 'idle' },
  ], [], {
    'runtime-a': { model: 'model-a', input: 1000000, output: 200000, total: 1200000, calls: 2, context_max: 200000 },
    'runtime-b': { model: 'model-b', input: 20, output: 5, total: 25, calls: 1 },
  }, {
    'runtime-a': { model: 'model-a', provider: 'provider-a', providers: [
      { slug: 'wrong', pricing: { 'model-a': { input: '$999', output: '$999' } } },
      { slug: 'provider-a', pricing: { 'model-a': { input: '$2.00', output: '$10.00', free: false } } },
    ] },
  });
  await waitFor(() => f.emitted.at(-1)?.sessions?.length === 2);
  const a = f.emitted.at(-1).sessions.find(row => row.title === 'A');
  const b = f.emitted.at(-1).sessions.find(row => row.title === 'B');
  assert.equal(a.modelUsage?.estimatedCostUSD, 4);
  assert.deepEqual([a.modelUsage.model, a.modelUsage.provider, a.modelUsage.inputTokens, a.modelUsage.outputTokens, a.modelUsage.totalTokens],
    ['model-a', 'provider-a', 1000000, 200000, 1200000]);
  assert.equal(a.modelUsage.costSource, 'current_model_pricing');
  assert.equal(b.modelUsage?.totalTokens, 25);
  assert.equal(b.modelUsage?.estimatedCostUSD, undefined, 'unknown price is not free');
  assert.equal(a.modelUsage.quota, undefined, 'context window is never quota');
  assert.ok(f.calls.some(([method, params]) => method === 'session.usage' && params.session_id === 'runtime-a'));
  assert.ok(f.calls.every(([method]) => !/history|auth|credential/.test(method)));
});

test('quota is only native session gauge or exact single-account provider metadata; context is not quota', () => {
  const usage = { model: 'm', input: 10, output: 5, total: 15, context_percent: 80, context_max: 200000 };
  const options = { model: 'm', provider: 'p', providers: [{ slug: 'p', usage: {
    windows: [{ label: '5 hours', used_percent: 30, scope: 'account', resets_at: '2099-01-01T00:00:00Z' },
      { label: 'Other model family', used_percent: 99, scope: 'model' }],
  } }] };
  assert.equal(projectModelUsage(usage, options).quota?.usedPercentage, 30);
  assert.equal(projectModelUsage(usage, options).quota?.source, 'provider_cache');
  options.providers[0].usage.accounts = [{ id: 'a', state: 'ready' }, { id: 'b', state: 'ready' }];
  assert.equal(projectModelUsage(usage, options).quota, undefined, 'pool cannot be attributed to the session');
  assert.equal(projectModelUsage(usage).quota, undefined);
  const native = projectModelUsage({ ...usage, plan_gauge: { id: 'day', label: 'Today', used_bp: 1234, resets_at_ms: 4070908800000 } }, options);
  assert.equal(native.quota?.usedPercentage, 12.34);
  assert.equal(native.quota?.source, 'session_plan_gauge');
  assert.equal(projectModelUsage({ ...usage, plan_gauge: { id: 'day', label: 'Expired', used_bp: 5000, resets_at_ms: 1 } }, options).quota, undefined);
});

test('unknown, malformed and mismatched pricing never invents a zero bill or quota', () => {
  const base = { model: 'm', input: 1, output: 2, total: 3 };
  assert.equal(projectModelUsage({ ...base, input: -1 }), undefined);
  assert.equal(projectModelUsage({ ...base, total: Infinity }), undefined);
  assert.equal(projectModelUsage({ ...base, cost_usd: NaN }).estimatedCostUSD, undefined);
  const options = { model: 'another', provider: 'p', providers: [{ slug: 'p', pricing: { m: { input: '$1', output: '$2' } } }] };
  assert.equal(projectModelUsage(base, options).estimatedCostUSD, undefined);
  options.model = 'm'; options.providers[0].pricing.m.input = 'unknown';
  assert.equal(projectModelUsage(base, options).estimatedCostUSD, undefined);
  const direct = projectModelUsage({ ...base, cost_usd: 0.125 }, options);
  assert.equal(direct.estimatedCostUSD, 0.125);
  assert.equal(direct.costSource, 'sdk_reported');
});

test('multi-window usage remains allowlisted and bounded when broadcast to another renderer', async t => {
  const channels = new Set();
  t.mock.property(globalThis, 'BroadcastChannel', class {
    constructor() { channels.add(this); }
    postMessage(data) { for (const peer of channels) if (peer !== this) queueMicrotask(() => peer.onmessage?.({ data })); }
    close() { channels.delete(this); }
  });
  globalThis.window = {}; t.after(() => { delete globalThis.window; });
  const first = fixture(t, [{ id: 'r1', session_key: 's1', title: 'Usage owner', status: 'working' }], [],
    { r1: { model: 'native-model', input: 50, output: 10, total: 60, cost_usd: 0.1, secret: 'DO NOT EXPORT' } });
  const second = fixture(t, []);
  await waitFor(() => second.emitted.at(-1)?.sessions?.length === 1);
  assert.equal(second.emitted.at(-1).sessions[0].modelUsage?.totalTokens, 60);
  assert.equal(JSON.stringify(second.emitted.at(-1)).includes('DO NOT EXPORT'), false);
  first.dispose(); second.dispose();
});

test('twenty cards with Unicode usage metadata still fit the transport byte budget', async t => {
  const model = '模'.repeat(160), provider = '商'.repeat(160);
  const live = Array.from({ length: 20 }, (_, i) => ({ id: `r${i}`, session_key: `s${i}`, title: '文'.repeat(160), status: 'working' }));
  const usages = Object.fromEntries(live.map(row => [row.id, { model, input: 2147483647, output: 2147483647, total: 2147483647,
    cost_usd: 1000000000, plan_gauge: { id: 'day', label: '额'.repeat(160), used_bp: 10000, resets_at_ms: 253402300799999 } }]));
  const options = Object.fromEntries(live.map(row => [row.id, { model, provider, providers: [{ slug: provider }] }]));
  const work=live.map(row=>({session_id:row.session_key,subagents:1024}));
  const f = fixture(t, live, [], usages, options, work, [{name:'default',display_name:'助'.repeat(160)}]);
  await waitFor(() => f.emitted.at(-1)?.sessions?.length === 20);
  const bytes=Buffer.byteLength(JSON.stringify({ ...f.emitted.at(-1), token: 'a'.repeat(64) }), 'utf8');
  assert.ok(bytes <= 32768, `20 Unicode cards exceed the 32KiB endpoint budget: ${bytes} bytes`);
  assert.ok(f.emitted.at(-1).sessions.every(row => row.modelUsage?.model?.length <= 64));
});

test('title bounds do not split an emoji surrogate pair', async t => {
  const f = fixture(t, [{ id: 'runtime', session_key: 'stored', title: 'x'.repeat(159) + '😀', status: 'idle' }]);
  await waitFor(() => f.emitted.at(-1)?.sessions?.length === 1);
  const title = f.emitted.at(-1).sessions[0].title;
  assert.equal(title.length, 159);
  assert.equal(title, 'x'.repeat(159));
});


test('explicit successful completion is green terminal, not idle, and survives roster polling', async t => {
  t.mock.timers.enable({ apis: ['setInterval'] });
  const live = [{id:'run-a',session_key:'store-a',title:'Task',status:'working'}];
  const f = fixture(t,live);
  await waitFor(()=>f.emitted.at(-1)?.sessions?.length === 1);
  f.state.busyBySession.set({'run-a':true});
  assert.equal(typeof f.events.get('message.complete'), 'function');
  f.events.get('message.complete')({session_id:'run-a',connectionId:'local',profile:'default',payload:{status:'complete',text:'PRIVATE'}});
  f.state.busyBySession.set({'run-a':false});
  await waitFor(()=>f.emitted.at(-1)?.sessions?.[0]?.state === 'succeeded');
  live[0].status='idle';t.mock.timers.tick(5000);
  await tick();await tick();
  assert.equal(f.emitted.at(-1).sessions[0].state,'succeeded');
  assert.equal(JSON.stringify(f.emitted.at(-1)).includes('PRIVATE'), false);
  live[0].status='working'; t.mock.timers.tick(5000);
  await waitFor(()=>f.emitted.at(-1)?.sessions?.[0]?.state === 'running');
  f.state.busyBySession.set({'run-a':true});await tick();
  assert.equal(f.emitted.at(-1).sessions[0].state,'running');
  f.events.get('message.complete')({session_id:'run-a',payload:{status:'error'}});
  f.state.busyBySession.set({'run-a':false});await tick();
  assert.equal(f.emitted.at(-1).sessions[0].state,'interrupted');
});

test('native roster keeps the owning parent working while async children run', async t => {
  t.mock.timers.enable({apis:['setInterval']});
  const work=[{session_id:'stored-parent',subagents:2,background:9,goal:'PRIVATE'}];
  const f=fixture(t,[{id:'runtime-parent',session_key:'stored-parent',title:'Parent',status:'idle'},
    {id:'runtime-other',session_key:'stored-other',title:'Other',status:'idle'}],[],{},{},work);
  await waitFor(()=>f.emitted.at(-1)?.sessions?.length===2);
  const parent=()=>f.emitted.at(-1).sessions.find(row=>row.title==='Parent');
  assert.equal(parent().activeSubagents,2);
  assert.equal(parent().state,'running');
  assert.equal(f.emitted.at(-1).sessions.find(row=>row.title==='Other').state,'idle');
  f.events.get('message.complete')({session_id:'runtime-parent',payload:{status:'complete'}});
  await tick(); assert.equal(parent().state,'running','parent yielding must not mark delegated work complete');
  assert.equal(JSON.stringify(f.emitted.at(-1)).includes('PRIVATE'),false);
  work.length=0; t.mock.timers.tick(5000);
  await waitFor(()=>parent()?.state==='succeeded');
  assert.equal(parent().activeSubagents ?? 0,0);
});

test('Agent labels belong to the routed stored profile, not every globally live runtime', async t => {
  const f = fixture(t, [
    {id:'runtime-own',session_key:'stored-own',title:'Own chat',status:'idle'},
    {id:'runtime-foreign',session_key:'stored-foreign',title:'Foreign chat',status:'working'},
  ], [{id:'stored-own',title:'Own chat'}], {}, {}, [], [
    {name:'other',display_name:'Other Agent',preview:'PRIVATE PREVIEW'},
    {name:'default',display_name:'我的助手',path:'PRIVATE PATH'},
  ], true);
  await waitFor(() => f.emitted.at(-1)?.sessions?.length > 0);
  assert.equal(f.emitted.at(-1).sessions.length, 1, 'process-wide active_list must be matched to the routed profile metadata');
  assert.equal(f.emitted.at(-1).sessions[0].agentName, '我的助手');
  assert.equal(JSON.stringify(f.emitted.at(-1)).includes('PRIVATE'),false);
  assert.ok(f.calls.some(([method,p]) => method==='profiles.list' && p.include_sessions===false));
});

test('clearing an Agent display name falls back to its canonical profile name', async t => {
  t.mock.timers.enable({apis:['setInterval']});
  const profiles=[{name:'default',display_name:'旧名称'}];
  const f=fixture(t,[{id:'runtime',session_key:'stored',title:'Chat',status:'idle'}],[],{},{},[],profiles);
  await waitFor(()=>f.emitted.at(-1)?.sessions?.[0]?.agentName==='旧名称');
  profiles[0].display_name='';t.mock.timers.tick(5000);
  await waitFor(()=>f.emitted.at(-1)?.sessions?.[0]?.agentName==='default');
  assert.equal(f.emitted.at(-1).sessions[0].agentName,'default');
});

test('a positive profile-scoped child roster owns an active parent outside the bounded metadata page', async t => {
  const f=fixture(t,[{id:'runtime-parent',session_key:'stored-old',title:'真实父会话标题',status:'idle'}],
    [{id:'unrelated-history',title:'Not a card'}],{},{},[{session_id:'stored-old',subagents:1}],[],true);
  await waitFor(()=>f.emitted.at(-1)?.sessions?.length===1);
  assert.equal(f.emitted.at(-1).sessions[0].title,'真实父会话标题');
  assert.equal(f.emitted.at(-1).sessions[0].activeSubagents,1);
  assert.equal(f.emitted.at(-1).sessions[0].state,'running');
});
