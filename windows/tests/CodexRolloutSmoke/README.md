# Windows Codex rollout regression tests

This contribution modifies Windows Codex quota and lifecycle collection from upstream AgentPager on 2026-11-22. The existing GPL-3.0 license and attribution are unchanged.

```sh
dotnet run --project windows/tests/CodexRolloutSmoke -p:EnableWindowsTargeting=true
```

The fixtures use synthetic JSONL in temporary directories. They do not read account data, modify runtime settings, or start a Bridge process.