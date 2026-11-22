import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';

// This is a source-contract check, not evidence of a running/installed target PC.
const root = process.env.HERMES_SDK_SOURCE_ROOT || '/opt/hermes/app';
const sdkPath = join(root, 'apps/desktop/src/sdk/index.ts');
test('local real Hermes SDK exposes the runtime-keyed busy atoms and public RPC contract used by the exporter',
  { skip: !existsSync(sdkPath) }, () => {
    const sdk = readFileSync(sdkPath, 'utf8');
    assert.match(sdk, /busyBySession:\s*readonlyAtom<Record<string, boolean>>\(\$busyBySession\)/);
    assert.match(sdk, /focusedSessionId:\s*readonlyAtom/);
    assert.match(sdk, /focusedStoredSessionId:\s*readonlyAtom/);
    assert.match(sdk, /request: async <T>\(method: string, params: Record<string, unknown> = \{\}, timeoutMs\?: number\)/);
    const contracts = readFileSync(join(root, 'tui_gateway/contracts/sessions.py'), 'utf8');
    const active = contracts.split('class SessionActiveItem(Result):')[1].split('class SessionActiveListResult')[0];
    for (const field of ['id: str', 'session_key: str', 'status: LiveSessionStatus', 'title: str']) assert.ok(active.includes(field), field);
    const registry = readFileSync(join(root, 'tui_gateway/session_registry.py'), 'utf8');
    assert.match(registry, /"session_key": key/);
    assert.match(registry, /"title": _session_live_title\(session, key\)/);
    const common = readFileSync(join(root, 'tui_gateway/contracts/common.py'), 'utf8');
    assert.match(contracts, /method\("session\.usage", params=SessionUsageParams, result=SessionUsageResult/);
    for (const field of ['model: str', 'input: int', 'output: int', 'total: int', 'cost_usd: float | None', 'plan_gauge: PlanGauge | None']) assert.ok(common.includes(field), field);
    const inventory = readFileSync(join(root, 'tui_gateway/contracts/config_free_tier_control.py'), 'utf8');
    assert.match(inventory, /class ModelOptionsParams\(ProfileParams\):\s+session_id:/);
    assert.match(inventory, /class ModelPricing\(Result\):[\s\S]*?input: str[\s\S]*?output: str/);
    assert.match(inventory, /Multi-entry credential pools carry ``accounts``/);
    assert.match(contracts, /lineage_root_id: str \| None.*alias="_lineage_root_id"/);
    const profiles = readFileSync(join(root, 'tui_gateway/contracts/profiles_vault_complete_foreign_subagents.py'), 'utf8');
    assert.match(profiles, /method\("profiles\.list", params=ProfilesListParams, result=ProfilesListResult/);
    assert.match(profiles, /class ProfileRow\(Result\):[\s\S]*?display_name: str/);
    const work = readFileSync(join(root, 'tui_gateway/methods_subagents.py'), 'utf8');
    assert.match(work, /@method\("subagent\.roster"\)/);
    assert.match(work, /"session_id": sid/);
    assert.match(work, /"subagents": 0, "background": 0/);
  });
