# Hermes 会话状态插件

`plugin.js` 使用 Hermes Desktop 公共 SDK 导出会话卡片；Windows 安装器继续将同一个文件内嵌进 Bridge，不需要额外模块或构建步骤。

## 真实 SDK 合同

已对照官方 Desktop Plugin SDK 文档，以及本机 `/opt/hermes/app` 提交 `3b42157858`：

- `apps/desktop/src/sdk/index.ts`：`busyBySession` 的键是 **runtime ID**，`focusedStoredSessionId` 是 **durable ID**；`gateway` 只表示连接状态，不等于忙碌。
- `tui_gateway/contracts/sessions.py`、`tui_gateway/session_registry.py`：`session.active_list` 返回 `id`（runtime）、`session_key`（stored）、`title`、`status`。标题来自 `_session_live_title`，不是聊天 preview。
- `session.list { limit: 100 }` 仅用于有限标题与 `_lineage_root_id` 元数据映射，不将历史列表转成卡片。Canonical gateway 回退仅接受显式 `scope: "live"` 的结果；旧网关回退仅导出能够正向匹配的焦点会话。
- `sessionRow` 槽在本机 SDK 的 props 只保证 stored `sessionId`，不假设它提供 runtime/title，亦不读取 DOM 或私有 store。

## 导出边界与身份

新协议 v2：`{version,state,updatedAt,sessions:[{id,title,state,updatedAt}]}`。安装器注入的本机令牌只用于已认证的 loopback 通道，不进入手机任务模型。

- 最多 20 张卡片、每个标题最多 160 个 UTF-16 单位、整包最多 32768 字节。
- 卡片 ID 为 `[connectionId, profile, durable lineage ID]` 的 SHA-256，不随焦点或窗口变化。
- 保留 SDK 真实标题；没有标题时明确显示“未命名会话”，不取用户消息/preview 代替。
- 不输出消息、提示词、工具参数、路径、transcript、preview。Bridge 卡片只读、无远程控制能力，仍使用现有 `hermesDesktop` Android wire 类型。
- 多窗口交换有界元数据，按每会话观测时间合并/去重；旧窗口的 running 不覆盖较新的 idle。心跳和每会话证据均在 90 秒后失效。其他会话的忙碌变更不会续租一个旧卡片。
- 已连接但没有会话时输出空列表，不制造“总状态”卡片。旧 v1 插件仍可用；健康 v2 心跳不会被遗留 v1 文件降级。
- `waiting` 只表示 SDK 报告的等待状态，映射为只读等待卡片，不推断具体审批类型或向手机暴露请求正文。
- 异步子代理通过原生 `subagent.roster` 按 durable 会话 ID 与路由/profile 归属读取，使用可选 `activeSubagents` 计数显示紫色“子代理工作中 · N 个”。主对话结束生成不等于子代理已结束；父卡片保持运行，阻止空闲轮播。只传计数，不读取/转发子任务目标、提示词或日志；读取失败不当成零，旧计数按租约过期为未知/离线。统计页仍通过原生 HTTP 直读，不依赖 NAS 插件。

## 手机模型用量与费用边界

- 每张实时卡片使用该路由自己的 `session.usage { session_id: runtimeID }`。不将 `focusedUsage` 或全局模型复制给其他会话，也不读取聊天历史、DOM、数据库正文或认证文件。
- 用量通过可选 `modelUsage`（并兼容现有 `tokenUsage`）传至 Windows/macOS catalog 和 Android。旧 v1/v2 无用量字段仍可解析；升级插件时应同时升级 Bridge 读取器。
- `model.options { session_id: runtimeID }` 只使用其精确 `provider` + `model` 的价格元数据；不猜 provider、别名、首个可用账户。USD 永远标为**估算**：优先 SDK `cost_usd`（未声明实付性质），否则按当前模型的每百万 token 标价粗估。输入有原生 `prompt` 时包含缓存输入但按完整输入标价；没有时只用原生 `input`。估算未复原缓存折扣、历史模型切换或实际账单；没有匹配价格就留空，而不是零美元。
- 可选额度仅来自会话 `plan_gauge`，或精确匹配 provider 的原生单账户 `usage.windows` 缓存；只取 account 范围中已用比例最高的一个窗口，并保留标签、来源和重置时间。有 `usage.accounts`、模型家族范围、过期/非法数值或来源不明时省略，不合并账户。`context_max/context_percent` **绝不是额度**。
- Android 卡片显示模型、原生 token 总量及 USD 估算；展开显示输入/输出/总量、估算依据，以及存在时的原生额度。离线或窗口已过重置时间时隐藏额度。不影响现有 Codex 全局用量面板。

## 验证

```sh
node --test hermes/*.test.mjs
# HERMES_SDK_SOURCE_ROOT 可覆盖真实 SDK 源码目录；源码不存在时仅跳过对应合同检查。

dotnet build windows/tests/HermesStatusSmoke/HermesStatusSmoke.csproj -p:EnableWindowsTargeting=true
dotnet windows/tests/HermesStatusSmoke/bin/Debug/net8.0-windows10.0.19041.0/HermesStatusSmoke.dll
dotnet build windows/src/AgentPager.Bridge/AgentPager.Bridge.csproj -p:EnableWindowsTargeting=true

cd macos && swift test --filter Hermes
```

Node 测试为隔离 SDK fixtures，C# smoke 运行真正的 loopback HTTP endpoint、解析器、catalog、安装器和持久化边界。这些结果不代表目标 Windows 电脑已安装、Hermes 插件已启用或手机已收到数据。Linux 已使用隔离 Swift 工具链执行 Foundation-only 的真实 Core 源码测试；不覆盖 macOS 原生 UI、网络、CryptoKit/Security。Android 单元测试及 debug APK 构建已执行；没有部署、提交或真机验收。
