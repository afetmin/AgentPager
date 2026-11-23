import AgentGridCore
import Foundation
import Testing
@testable import AgentGridBridge

@MainActor
@Suite struct BridgeModelHookTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpager-bridge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeModel(in directory: URL) -> BridgeModel {
        BridgeModel(
            hookConfiguration: CodexHookConfiguration(
                hooksURL: directory.appendingPathComponent("codex/hooks.json")
            ),
            claudeHookConfiguration: ClaudeHookConfiguration(
                settingsURL: directory.appendingPathComponent("claude/settings.json")
            ),
            integrationHome: directory.appendingPathComponent("home")
        )
    }

    @Test func installAndUninstallTogglesStatusAndEvents() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(in: directory)

        model.refreshHookStatuses()
        #expect(!model.hookInstalled)
        #expect(!model.claudeHookInstalled)

        model.installHooks()
        model.installClaudeHooks()
        #expect(model.hookInstalled)
        #expect(model.claudeHookInstalled)
        #expect(model.displayedError == nil)

        // 重复点击“安装或修复”也要给出反馈，而不是静默无事发生。
        model.installHooks()
        #expect(model.recentEvents.first == "Codex Hook 已是最新")

        model.uninstallHooks()
        model.uninstallClaudeHooks()
        #expect(!model.hookInstalled)
        #expect(!model.claudeHookInstalled)
    }

    @Test func integrationInstallRequiresDetectedClientAndReportsStatus() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(in: directory)
        let home = directory.appendingPathComponent("home")

        model.refreshHookStatuses()
        #expect(model.integrationStatuses["zcode"]?.detected == false)

        // 未检测到客户端：给出错误，且不凭空创建目录。
        model.installIntegration(id: "zcode")
        #expect(model.integrationStatuses["zcode"]?.installed == false)
        #expect(model.integrationStatuses["zcode"]?.error?.contains("未检测到") == true)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".zcode").path))

        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".zcode"),
            withIntermediateDirectories: true
        )
        model.installIntegration(id: "zcode")
        #expect(model.integrationStatuses["zcode"]?.installed == true)
        #expect(model.integrationStatuses["zcode"]?.error == nil)
        #expect(model.recentEvents.first == "ZCode Hook 已安装")

        model.uninstallIntegration(id: "zcode")
        #expect(model.integrationStatuses["zcode"]?.installed == false)
    }

    @Test func refreshPicksUpExternalConfigurationChanges() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = makeModel(in: directory)
        model.installHooks()
        #expect(model.hookInstalled)

        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("codex/hooks.json")
        )
        #expect(model.hookInstalled)  // 外部删除后状态尚未刷新
        model.refreshHookStatuses()
        #expect(!model.hookInstalled)
    }

    @Test func hookErrorIsShownThenClearedOnSuccess() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 把父目录位置占成普通文件，使写入必然失败。
        let blocker = directory.appendingPathComponent("claude")
        try Data("x".utf8).write(to: blocker)
        let model = makeModel(in: directory)

        model.installClaudeHooks()
        #expect(model.claudeHookError?.hasPrefix("安装 Claude Code Hook 失败") == true)
        #expect(model.displayedError == model.claudeHookError)
        #expect(!model.claudeHookInstalled)

        // Codex 操作成功不应清掉 Claude 的错误。
        model.installHooks()
        #expect(model.codexHookError == nil)
        #expect(model.claudeHookError != nil)

        // 手动关闭后清除；问题修复后重试成功同样清除。
        model.clearError()
        #expect(model.displayedError == nil)

        model.installClaudeHooks()
        #expect(model.claudeHookError != nil)
        try FileManager.default.removeItem(at: blocker)
        model.installClaudeHooks()
        #expect(model.claudeHookError == nil)
        #expect(model.claudeHookInstalled)
    }
}

@Suite struct PairingTextTests {
    @Test func payloadContainsCurrentHostPortAndSecret() throws {
        let secret = Data([1, 2, 3, 4])
        let text = PairingText.make(serviceID: "agentgrid-mac", host: "192.168.1.8", secret: secret)
        let payload = try JSONDecoder().decode(PairingPayload.self, from: Data(text.utf8))
        #expect(payload.host == "192.168.1.8")
        #expect(payload.port == PairingText.port)
        #expect(payload.secret == secret.base64EncodedString())
        #expect(payload.serviceID == "agentgrid-mac")
    }

    @Test func changedHostProducesDifferentText() {
        let secret = Data([9])
        let first = PairingText.make(serviceID: "a", host: "192.168.1.8", secret: secret)
        let second = PairingText.make(serviceID: "a", host: "10.0.0.5", secret: secret)
        #expect(first != second)
        #expect(first == PairingText.make(serviceID: "a", host: "192.168.1.8", secret: secret))
    }

    @Test func boxReturnsLatestValue() {
        let box = PairingTextBox("old")
        box.value = "new"
        #expect(box.value == "new")
    }
}
