# AgentPager r4.2 验证记录

## 已通过

- Android：18 个测试类，85 个单元测试，0 失败、0 错误、0 跳过；应用 APK 与 instrumentation APK 构建成功。应用版本 0.4.2 / code 6，最低 Android API 26。
- APK：ZIP 内容完整，apksigner 验证通过；应用签名 SHA256 与此前交付 r4 的 APK 一致，可在同签名版本上覆盖升级并保留配对。
- Desktop 状态脚本：26 个 Node 测试通过，名称清空/异步刷新回归还连续重跑三轮通过。覆盖所属 Agent 显示名称、共享 Gateway 的 profile 归属、子代理父状态、压缩身份、隐私白名单、多窗口基本合并、Unicode 和 32KiB 传输上限。
- Windows：HermesStatusSmoke、WindowsSettingsSmoke、CodexPricingSmoke 全部通过；9 项静态 WPF 接线契约通过；真实 WPF win-x64 self-contained single-file publish 成功。
- 跨组件：真实执行生产 plugin.js（SDK 为受控 fixture），通过带认证的 `/hermes-status` HTTP → 生产 BridgeRuntime → 手机 WebSocket，核验子代理 2 个 → 父生成结束仍 2 个 → 子代理归零后成功，所属 Agent 前缀正确，另一会话独立空闲。
- 自动来源：生产运行时 → 手机 WebSocket 验证显式空来源、Hook 安装/卸载、外部禁用配置、日志目录探测、Hermes 已安装但离线、HTTP 来源，以及旧协议 null 兼容。
- 用户 Windows PC 上的隔离原生探针：真实生产文件升级逻辑完成已知旧模板升级、备份、相同内容不重写、保留自改和禁用状态；真实当前用户 DPAPI 完成随机 fixture 凭据保存、读回、来源绑定、删除。未修改用户真实启动项、账号、配置或正在运行的应用。探针 EXE 的传输 SHA256 已核对；首次删除遇到暂时文件锁，重试后确认删除且无对应进程。

## 真实根因证据

用户 PC 安装的状态脚本没有 `subagent.roster` / `activeSubagents`。仅规范化本机令牌后，其源码 SHA256 与历史 r2/r3 发布模板逐字节一致；因此先前只替换 Bridge，没有升级已安装的 Desktop 导出脚本。r4.2 为已知模板增加安全升级路径，不把自定义文件当作官方文件覆盖。

## 尚未执行的现场验收

- 未连接实际安卓设备：instrumentation 只编译，未在手机/模拟器执行；不能将单元测试或 APK 构建当成手机 UI 真机验收。
- 未替换用户正在运行的 Bridge 或真实已安装 Desktop 状态脚本；真实热重载及最终手机显示待用户安装新版组合后现场确认。
- 未用用户真实账号密码登录 NAS；现有 PKCE/账号续期测试使用真实 HTTP fixture。
- 来源列表基于安装/配置证据，不宣称能读取 renderer 的插件开关、Hook 信任状态或订阅账号历史归属。
