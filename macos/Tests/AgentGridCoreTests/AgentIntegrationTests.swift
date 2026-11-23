import Foundation
import Testing
@testable import AgentGridCore

private func makeHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func integration(_ id: String) throws -> AgentIntegration {
    try #require(AgentIntegrations.integration(id: id))
}

private func parse(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func jsonObject(at url: URL) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

// MARK: - 注册表

@Test("Agent 注册表的标识唯一，且配置路径落在客户端数据目录内")
func registryIsConsistent() {
    let ids = AgentIntegrations.all.map(\.id)
    #expect(Set(ids).count == ids.count)
    for integration in AgentIntegrations.all {
        #expect(integration.configPath.hasPrefix(integration.presencePath + "/"))
        #expect(!integration.events.isEmpty)
        #expect(integration.hookCommand(for: "/Apps/AgentPagerHooks")
            == "'/Apps/AgentPagerHooks' --source claude --agent \(integration.id)")
    }
}

@Test("ZCode 只写入它严格白名单内的 7 个事件，且只有权限请求覆盖超时")
func zcodeEventsMatchStrictWhitelist() throws {
    let zcode = try integration("zcode")
    #expect(Set(zcode.events.map(\.name)) == [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PostToolUse", "PostToolUseFailure", "Stop",
    ])
    #expect(zcode.events.filter { $0.timeout != nil }.map(\.name) == ["PermissionRequest"])
    #expect(zcode.events.allSatisfy { $0.matcher == nil })
}

@Test("展示名只对已登记客户端有值，Claude Code 本身与未知来源为 nil")
func displayNameLookup() {
    #expect(AgentIntegrations.displayName(forAgentID: "zcode") == "ZCode")
    #expect(AgentIntegrations.displayName(forAgentID: "workbuddy") == "WorkBuddy")
    #expect(AgentIntegrations.displayName(forAgentID: nil) == nil)
    #expect(AgentIntegrations.displayName(forAgentID: "unknown") == nil)
}

// MARK: - ZCode 安装器

@Test("ZCode 全新安装写入 enabled 与 7 个事件，权限请求带长超时")
func zcodeFreshInstall() throws {
    let zcode = try integration("zcode")
    let mutation = try ZcodeHookInstaller.install(
        existingData: nil,
        command: "'/x/AgentPagerHooks' --source claude --agent zcode",
        events: zcode.events
    )
    let root = try parse(mutation.contents)
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect(hooks["enabled"] as? Bool == true)
    let events = try #require(hooks["events"] as? [String: Any])
    #expect(Set(events.keys) == Set(zcode.events.map(\.name)))

    let permission = try #require(events["PermissionRequest"] as? [[String: Any]])
    let permissionHook = try #require((permission[0]["hooks"] as? [[String: Any]])?.first)
    #expect(permissionHook["timeout"] as? Int == 86_400)
    let stop = try #require(events["Stop"] as? [[String: Any]])
    let stopHook = try #require((stop[0]["hooks"] as? [[String: Any]])?.first)
    #expect(stopHook["timeout"] == nil)
    #expect(mutation.changed)
}

@Test("ZCode 安装保留用户 Hook 与其他配置，重复安装幂等")
func zcodeInstallPreservesUserDataAndIsIdempotent() throws {
    let zcode = try integration("zcode")
    let original = Data(
        """
        {
          "theme": "dark",
          "hooks": {
            "enabled": true,
            "events": {
              "Stop": [{"hooks": [{"type": "command", "command": "user-stop"}]}]
            }
          }
        }
        """.utf8
    )
    let command = "'/x/AgentPagerHooks' --source claude --agent zcode"
    let first = try ZcodeHookInstaller.install(
        existingData: original, command: command, events: zcode.events
    )
    let second = try ZcodeHookInstaller.install(
        existingData: first.contents, command: command, events: zcode.events
    )
    #expect(second.changed == false)
    #expect(second.contents == first.contents)

    let root = try parse(first.contents)
    #expect(root["theme"] as? String == "dark")
    let events = try #require((root["hooks"] as? [String: Any])?["events"] as? [String: Any])
    let stop = try #require(events["Stop"] as? [[String: Any]])
    #expect(stop.count == 2)
    #expect(((stop[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String) == "user-stop")
}

@Test("用户把 hooks.enabled 设为 false 时安装不会改回 true，并被识别为休眠")
func zcodeInstallRespectsDisabledMasterSwitch() throws {
    let zcode = try integration("zcode")
    let original = Data(#"{"hooks": {"enabled": false}}"#.utf8)
    let mutation = try ZcodeHookInstaller.install(
        existingData: original, command: "AgentPagerHooks", events: zcode.events
    )
    let root = try parse(mutation.contents)
    #expect((root["hooks"] as? [String: Any])?["enabled"] as? Bool == false)
    #expect(ZcodeHookInstaller.isMasterSwitchOff(data: mutation.contents))
}

@Test("ZCode 卸载只移除管理项；只剩脚手架时整体移除 hooks")
func zcodeUninstall() throws {
    let zcode = try integration("zcode")
    let command = "'/x/AgentPagerHooks' --source claude --agent zcode"

    let fresh = try ZcodeHookInstaller.install(existingData: nil, command: command, events: zcode.events)
    #expect(ZcodeHookInstaller.isInstalled(data: fresh.contents, events: zcode.events))
    let removed = try ZcodeHookInstaller.uninstall(existingData: fresh.contents)
    #expect(removed.changed)
    #expect(removed.contents == nil)

    let withUser = try ZcodeHookInstaller.install(
        existingData: Data(
            #"{"hooks":{"enabled":true,"events":{"Stop":[{"hooks":[{"type":"command","command":"user-stop"}]}]}}}"#.utf8
        ),
        command: command,
        events: zcode.events
    )
    let cleaned = try ZcodeHookInstaller.uninstall(existingData: withUser.contents)
    let root = try parse(cleaned.contents)
    let events = try #require((root["hooks"] as? [String: Any])?["events"] as? [String: Any])
    #expect(Set(events.keys) == ["Stop"])
    #expect(!ZcodeHookInstaller.isInstalled(data: cleaned.contents, events: zcode.events))
}

@Test("ZCode 配置结构异常时拒绝改写，避免覆盖用户数据")
func zcodeInstallRefusesMalformedConfig() throws {
    let zcode = try integration("zcode")
    for bad in [#"["not","an","object"]"#, #"{"hooks": "oops"}"#, #"{"hooks": {"events": []}}"#, "{ // 注释\n}"] {
        #expect(throws: (any Error).self) {
            try ZcodeHookInstaller.install(
                existingData: Data(bad.utf8), command: "AgentPagerHooks", events: zcode.events
            )
        }
    }
}

// MARK: - 配置入口（临时主目录）

@Test("未检测到客户端时拒绝安装，且不会凭空创建目录")
func installRefusedWhenClientMissing() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let configuration = AgentIntegrationConfiguration(integration: try integration("zcode"), home: home)

    #expect(!configuration.isClientDetected())
    #expect(throws: AgentIntegrationError.self) {
        try configuration.install(binaryPath: "/x/AgentPagerHooks")
    }
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".zcode").path))
}

@Test("Claude 系客户端安装：保留配置、创建备份、写入各自事件，卸载后还原")
func claudeFamilyInstallAndUninstall() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let workbuddy = try integration("workbuddy")
    let configuration = AgentIntegrationConfiguration(integration: workbuddy, home: home)

    let directory = home.appendingPathComponent(".workbuddy")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let original = Data(
        #"{"model":"x","hooks":{"Stop":[{"hooks":[{"type":"command","command":"user-stop"}]}]}}"#.utf8
    )
    try original.write(to: configuration.configURL)

    let change = try configuration.install(
        binaryPath: "/x/AgentPagerHooks", now: Date(timeIntervalSince1970: 5_000)
    )
    #expect(change.changed)
    #expect(try Data(contentsOf: #require(change.backupURL)) == original)
    #expect(configuration.isInstalled())

    let root = try jsonObject(at: configuration.configURL)
    #expect(root["model"] as? String == "x")
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect(Set(hooks.keys) == Set(workbuddy.events.map(\.name)))
    let permission = try #require(hooks["PermissionRequest"] as? [[String: Any]])
    let hook = try #require((permission[0]["hooks"] as? [[String: Any]])?.first)
    #expect((hook["command"] as? String)?.contains("--agent workbuddy") == true)
    #expect(hook["timeout"] as? Int == 86_400)

    let again = try configuration.install(binaryPath: "/x/AgentPagerHooks")
    #expect(!again.changed)

    let removed = try configuration.uninstall()
    #expect(removed.changed)
    #expect(!configuration.isInstalled())
    let afterRoot = try jsonObject(at: configuration.configURL)
    let remaining = try #require(afterRoot["hooks"] as? [String: Any])
    #expect(Set(remaining.keys) == ["Stop"])
}

@Test("配置文件无法解析时安装被拒绝，原文件保持不变")
func unparseableConfigIsNeverTouched() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let configuration = AgentIntegrationConfiguration(integration: try integration("zcode"), home: home)
    let directory = home.appendingPathComponent(".zcode/cli", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let broken = Data("{ // 用户注释\n \"hooks\": {} }".utf8)
    try broken.write(to: configuration.configURL)

    #expect(throws: AgentIntegrationError.unparseableConfig(path: "~/.zcode/cli/config.json")) {
        try configuration.install(binaryPath: "/x/AgentPagerHooks")
    }
    #expect(try Data(contentsOf: configuration.configURL) == broken)
}

@Test("ZCode 经配置入口安装后可被检测，总开关关闭时标记为休眠")
func zcodeConfigurationDetectsDormant() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let configuration = AgentIntegrationConfiguration(integration: try integration("zcode"), home: home)
    try FileManager.default.createDirectory(
        at: home.appendingPathComponent(".zcode/cli", isDirectory: true),
        withIntermediateDirectories: true
    )
    try Data(#"{"hooks":{"enabled":false}}"#.utf8).write(to: configuration.configURL)

    _ = try configuration.install(binaryPath: "/x/AgentPagerHooks")
    #expect(configuration.isInstalled())
    #expect(configuration.isDormant())
}

// MARK: - 载荷键名归一化

@Test("camelCase 键补齐为 snake_case，且不覆盖已有 snake_case、不改写嵌套对象")
func keyNormalizerAddsSnakeCaseOnly() {
    let normalized = HookPayloadKeyNormalizer.snakeCasedKeys([
        "sessionId": "camel",
        "hook_event_name": "Stop",
        "hookEventName": "ignored",
        "toolInput": ["filePath": "/a"],
    ])
    #expect(normalized["session_id"] as? String == "camel")
    #expect(normalized["hook_event_name"] as? String == "Stop")
    let toolInput = normalized["tool_input"] as? [String: Any]
    #expect(toolInput?["filePath"] as? String == "/a")
    #expect(toolInput?["file_path"] == nil)
}
