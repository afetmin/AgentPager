# AgentPager 扩展版：Hermes Desktop 与 ChatGPT 网页状态监测

[English](RELEASE.en.md) · 上游：[`afetmin/AgentPager`](https://github.com/afetmin/AgentPager)

这是基于上游 `2651fd4a9fee61553ad3b59f52692e00385a5487` 的非官方修改版（2026-11-22），桌面新增功能仅支持 **Windows x64**。本版不提供 macOS Bridge，未修改上游 macOS 源码。项目按 GNU GPL v3 分发，保留原作者及第三方署名；见 `LICENSE`、`NOTICE.md`、`LICENSES/`。

## 功能和修复

- **Android 专用模式**：退出后按钮立即变为「进入专用模式」，无需重启即可再进入；配对页面的扫码和手动粘贴都用「电脑」作为提示。
- **Codex**：修复 Windows 上旧会话续聊漏检；5 小时和 7 天剩余额度取同一条最新本地事件，不按日志文件修改时间取快照。
- **Hermes Desktop**：按会话同步真实所属 Agent、工作状态和活动子代理数量；用量读取原生接口，按模型展示，不需要 NAS 统计插件。会话只读，不转发聊天正文。
- **ChatGPT 网页**：原生桌面客户端没有在此项目中验证到可靠的逐会话状态，因此 Chrome / Edge 扩展使用网页侧栏活动信号。只发状态、标题及脱敏会话标识，不发聊天正文、提示词、Cookie；切换会话或关闭标签页不等于生成完成。

## 安装与升级

1. **Windows**：下载 `AgentPager-Windows-Setup.exe`（推荐，可在系统设置卸载）或 `AgentPager-Windows-Portable.zip`（解压运行），二选一。切换前从托盘退出旧 Bridge。卸载仅移除安装器拥有的文件与快捷方式，不删除共享配对、设置、Hook 或自启动配置。Windows 安装包未做 Authenticode 签名。
2. **Android 8.0+**：只需 `AgentPager-Android.apk`。扩展版与上游原版可共存；不要先卸载原版。Windows 与 Android 均需升级后，使用「连接」页新二维码或配对文本**重新配对一次**。新版使用加密的 TCP `49365`；只允许受信任的专用局域网，不要把端口转发到互联网。不要共享配对码。细节见 [配对协议与兼容性](WINDOWS-PHONE-PAIRING.md)。
3. **Chrome / Edge**：解压 `AgentPager-ChatGPT-Web-Chrome-Edge.zip`，在浏览器扩展管理页打开开发者模式，加载含 `manifest.json` 的目录。打开 Bridge 的网页监测，刷新 ChatGPT 并展开侧栏。扩展未上架浏览器商店。
4. **Hermes 用量**：非本机地址使用密码、访问令牌或刷新令牌时，Hermes URL 必须是证书可验证的 HTTPS；原 HTTP 用户需换地址后重新登录。明确启用的匿名 HTTP 和本机回环 HTTP 不受影响。

对应源码 `AgentPager-Source.zip` 和 `SHA256SUMS.txt` 与发布文件同页提供。构建见 [扩展版打包](FORK-PACKAGING.md)。
