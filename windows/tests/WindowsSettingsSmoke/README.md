# Windows settings production smoke checks

Run from the repository root with .NET 8:

```sh
dotnet run --project windows/tests/WindowsSettingsSmoke -c Release -p:EnableWindowsTargeting=true
python3 windows/tests/WindowsSettingsSmoke/test_ui_wiring.py
dotnet build windows/src/AgentPager.Bridge/AgentPager.Bridge.csproj -c Release -p:EnableWindowsTargeting=true
```

The smoke executable compiles the real `WindowsIntegration.cs` and `BridgeRuntime.cs`, not a copy of their behavior. It exercises live log switching, old-file preservation (including old dates), path validation, failed persistence rollback, unavailable destinations, both destinations unavailable, recovery, reset, custom-path JSON round-trip/default omission, corrupt JSON, and nonblocking UI status reads during slow I/O. Startup checks exercise the production command/state/read-back/error paths using an injected registry boundary; they never change the developer's real login configuration.

On Linux it starts an isolated child process with existing temporary HOME/XDG data folders before CLR startup (special-folder paths can be cached). This also allows production runtime initialization/save/reset checks without writing to the real user profile. Those runtime/profile checks are skipped on Windows; filesystem/state checks still run there. A Linux cross-target WPF build does not prove the native folder picker, Explorer launch, registry changes, Task Manager interaction, or an actual next-login launch. Verify those on Windows before release.

The UI contract check verifies XAML placement/unique controls and handler wiring, including that regular launch never rewrites the startup entry and programmatic checkbox refresh is not consent. To switch the registered exe, exit the old Bridge, open the intended exe, and explicitly check login startup in Settings. This check is not a rendered-WPF or next-login test.

For an isolated Hermes HTTP probe, append `-- --hermes-transport-probe` to the `dotnet run` command above. It checks that nonloopback cleartext refuses password login before discovery, refresh, and bearer analytics without sending requests; confirms anonymous HTTP and authenticated loopback still work; and checks unsafe URL/response handling. The full auth smoke also checks pre-existing insecure manual/account credentials without downgrading them to anonymous.

## r4.2 数据源、标题和 Desktop 状态脚本

- Linux smoke 还会通过真实 `BridgeRuntime` 和 `/agentgrid` WebSocket 验证 `enabledSources`：旧字段缺失仍为 null，新 Windows 显式发送 `[]`；Claude 按当前管理 Hook 且 `disableAllHooks != true`，Codex 按 Hook 或自动观察的 `sessions` / `archived_sessions` 目录，Hermes 按已安装 Desktop 状态集成或已配置 HTTP 来源。旧任务、仅 CLI 存在、网页监控开关不启用这些数据源。外部文件变化由约 3 秒维护周期发现，显式安装/卸载操作会入队刷新。
- `HermesStatusSmoke` 验证每会话 `agentName` 的 160 字符白名单，生成 `Agent名称 · 对话标题`；缺失时用 `Hermes`。严格网页哈希身份生成小写 `chatgpt网页 · 对话标题`，涵盖元数据重命名、prompt、恢复和标题读入。普通 Codex / Claude 标题不变。
- 启动仅更新已安装的已知官方脚本；只规范化 `const bridgeToken`，用完整 UTF-8 SHA256 匹配 r2/r3、r4/r4.1 模板或当前内置模板。自定义/未知脚本保留并明确提示。先唯一备份、同目录原子替换、读回校验，相同内容不重写；从不修改 Hermes 启用/禁用配置。显式手动安装允许修复自定义文件，但也保留既有备份。
- `HermesProducerInteropTests` 要求 Node 支持 `node:module.registerHooks`（本轮执行版本 v26.12.1），真实执行仓库 `hermes/plugin.js`（模拟 SDK），由 `hermes/producer-trace.test.mjs` 生成三段状态，经真实 `/hermes-status` 认证 HTTP → runtime → phone WebSocket 验证子代理 2 / 父完成仍 2 / 子归零父成功、Agent 前缀和另一会话独立 idle。只重置测试重放时间戳并注入随机测试令牌，不合成状态结果。纯心跳无变更不会广播，测试通过重新连接读取权威快照。

以上不是实际 PC Hermes SDK、插件热重载、渲染 WPF 或真实手机 UI 验收；source inventory 表示本地配置/安装证据，不能证明 Codex/Claude 已审核信任 Hook，也不读取 Hermes renderer 的用户插件开关。未能判定的 CLI 执行/连接状态不伪装成已验证。

可选 Windows 原生文件升级探针（仅隔离临时 HERMES_HOME；不更改真实安装、启用状态、账号、启动项或运行进程）：

```sh
dotnet publish windows/tests/WindowsSettingsSmoke -c Release -r win-x64 --self-contained true -p:EnableWindowsTargeting=true -p:PublishSingleFile=true -p:DebugType=none -o "$TMPDIR/windows-r42-native-probe"
# 在用户授权的 Windows 测试环境执行：WindowsSettingsSmoke.exe --native-windows-probe
```

探针复用真实 `HermesPluginSetup` 及旧官方模板，检查升级、备份、幂等、自定义保留和已有 .bak 不碰撞，再执行原有随机 fixture DPAPI/只读启动检查；Linux 上只能构建，不能声称已执行原生探针。
