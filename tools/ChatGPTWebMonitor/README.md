# ChatGPT 网页监测（Windows）

网页监测内置于 `AgentPagerBridge.exe`，不用运行第二个 EXE。项目未验证出原生 ChatGPT 桌面客户端可靠的逐会话工作信号，因此使用网页扩展观察侧栏。本候选只分发 Chrome / Edge 共用的扩展 ZIP；安装步骤见 [候选版说明](../../docs/RELEASE.zh-CN.md)。

## 安装或更新

1. 解压整合包。先从系统托盘退出旧 AgentPager。如果旧的 `AgentPagerChatGPTWebBridge.exe` 没有图标，在任务管理器的「详细信息」中结束这个确切名称的进程，避免它占用 `127.0.0.1:49363`。
2. 运行新的 `AgentPagerBridge.exe`，在 **CHATGPT WEB** 页确认监控已启用。该页和系统托盘菜单都可单独启停网页监测；托盘的「退出 AgentPager」结束整个应用。
3. 在 Chrome 的 `chrome://extensions` 或 Edge 的 `edge://extensions` 禁用旧网页扩展。打开开发者模式，选择「加载已解压的扩展程序」，选择新包里的 `ChatGPTWebMonitor` 文件夹；若原路径已替换为新版，则重新加载。刷新已打开的 ChatGPT 标签页并展开侧栏。
4. 用已配对的安卓端直接查看，无需重新安装支持 `hermesDesktop` 的 Android APK。原本就无法连到 Bridge 的情况需另查连接设置。

## 排查没有状态

- **监听失败**：查看 **CHATGPT WEB** 页的错误，确认没有旧网页桥占用 `49363`；释放后退出并重开新 Bridge。
- **等浏览器连接 / 心跳超时**：点浏览器工具栏里的 AgentPager 扩展图标，使用「重新检查」，确认扩展和 Windows 主程序版本匹配。
- **已连接但标签页为 0**：刷新 ChatGPT，确认扩展已启用且有权访问站点。
- **有标签页但侧栏条目为 0**：展开 ChatGPT 侧栏。若仍为 0，或正在生成时转圈计数始终为 0，请记录标签页、侧栏、转圈计数和「最近检测」。不需要提供聊天内容。

## 检测语义与隐私

- Chat 和 Work 由会话各自标题旁的侧栏转圈驱动。只有获得正式 `/c/{UUID}` 才创建卡片；会话重命名只更新同一卡片。切换会话、关闭标签页或丢失观测不会当作完成。
- 连续看到原会话的转圈消失才确认完成。最后一个观测租约约 100 秒未续约则标记离线。浏览器诊断心跳不创建任务、不延长生成租约。关闭监控只清除网页活动状态，不影响 Hermes、Codex 或 Claude。
- 扩展只上报哈希化的会话标识、标题、模式、状态及诊断计数，不读取或转发聊天正文、Cookie 或账号凭据。浏览器到 Bridge 的端点仅在本机可用；协议和限制参见 [BRIDGE-CONTRACT.md](BRIDGE-CONTRACT.md)。手机仍使用已有任务消息结构。
- 旧独立网页桥的源码仅保留作兼容测试，新流程不需要编译或运行它。旧 `AgentPagerChatGPTMonitor.exe` 若存在，是面向原生 ChatGPT 客户端的独立通道，不是此功能的依赖。

## 验证

```sh
npm ci --prefix tools/ChatGPTWebMonitor/tests
npm test --prefix tools/ChatGPTWebMonitor/tests
CHROME=/path/to/chromium node tools/ChatGPTWebMonitor/tests/chromium-smoke.cjs
dotnet run --project tools/ChatGPTWebMonitor/tests/WebMonitorTests.csproj
python3 tools/ChatGPTWebMonitor/tests/test_integrated_ui.py
```

Chromium 测试使用隔离的模拟页面；C# 测试执行真实的本机 HTTP 监听、状态归并和任务目录代码。在 Windows 上实际打开界面，以及在用户账号的 Chat 和 Work 页面上验证转圈识别，属于单独的验收步骤。

如需检验手机链路，在 Linux 上先编译 `WebMonitorTests.csproj`，再运行 Chromium 测试时设置 `BRIDGE_FIXTURE_DLL` 为 `tools/ChatGPTWebMonitor/tests/bin/Debug/net8.0/WebMonitorTests.dll` 的绝对路径。它会使用临时数据目录、本机端口 49361–49363 及真实 Bridge 的事件循环和手机 WebSocket，不需要 Windows GUI。可用 `PHONE_FIXTURE_OUT` 保存模拟页面产生的手机快照，供安卓解码与任务投影回归测试使用。
