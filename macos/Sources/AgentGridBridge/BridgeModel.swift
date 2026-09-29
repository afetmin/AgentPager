import AgentGridCore
import Foundation
import Observation

@MainActor
@Observable
final class BridgeModel {
    private(set) var tasks: [TaskSnapshot] = []
    private(set) var usage: UsageSnapshot?
    private(set) var focusedTaskID: String?
    private(set) var phoneCount = 0
    private(set) var serviceStatus = "正在启动"
    private(set) var hookInstalled = false
    private(set) var claudeHookInstalled = false
    private(set) var lastError: String?
    private(set) var pairingText = ""
    private(set) var recentEvents: [String] = []

    private var catalog = PersistentTaskCatalog()
    private var replayGuard = ReplayGuard()
    private var pairingSecret = Data()
    private let hookConfiguration = CodexHookConfiguration()
    private let claudeHookConfiguration = ClaudeHookConfiguration()
    private var rolloutObservation = CodexRolloutObservation()
    private var hookServer: HookBridgeServer?
    private var webSocketServer: WebSocketServer?
    private var refreshTask: Task<Void, Never>?
    private var usageLoadTask: Task<Void, Never>?
    private var rolloutTask: Task<Void, Never>?
    private var hasStarted = false
    private var nextSessionReconciliation = Date.distantPast

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        do {
            pairingSecret = try PairingSecretStore.loadOrCreate()
            let payload = PairingPayload(
                serviceID: "agentgrid-\(Host.current().localizedName ?? "mac")",
                host: LocalNetworkAddress.preferredIPv4(),
                port: 49_362,
                secret: pairingSecret.base64EncodedString()
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let pairingPayloadText =
                String(data: try encoder.encode(payload), encoding: .utf8) ?? ""
            pairingText = pairingPayloadText

            let hookServer = HookBridgeServer { [weak self] envelope in
                Task { @MainActor in
                    self?.handle(envelope)
                }
            }
            try hookServer.start()
            self.hookServer = hookServer

            let webSocketServer = WebSocketServer(
                messageHandler: { [weak self] text in
                    Task { @MainActor in
                        self?.handleControl(text)
                    }
                },
                countHandler: { [weak self] count in
                    Task { @MainActor in
                        guard let self else { return }
                        let phoneConnected = count > self.phoneCount
                        self.phoneCount = count
                        if phoneConnected {
                            self.refreshUsage()
                        } else {
                            self.broadcastSnapshot()
                        }
                    }
                },
                localHTTPHandler: { path in
                    path == "/pairing" ? pairingPayloadText : nil
                }
            )
            try webSocketServer.start()
            self.webSocketServer = webSocketServer
            serviceStatus = "局域网服务运行中"
        } catch {
            serviceStatus = "服务启动失败"
            lastError = error.localizedDescription
        }

        refreshHookStatus()
        refreshClaudeHookStatus()
        refreshUsage()
        handleRolloutObservation()
        publishCatalog()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard let self else { return }
                self.refreshUsage()
                if let commit = self.catalog.maintain() {
                    self.applyCatalogCommit(commit)
                }
            }
        }
        rolloutTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard let self else { return }
                self.handleRolloutObservation()
                if let commit = self.catalog.maintain() {
                    self.applyCatalogCommit(commit)
                }
            }
        }
    }

    func installHooks() {
        do {
            let change = try hookConfiguration.install(
                command: hookExecutableURL.path
            )
            if change.changed {
                addEvent("Codex Hook 已安装")
            }
            refreshHookStatus()
        } catch {
            lastError = "安装 Hook 失败：\(error.localizedDescription)"
        }
    }

    func uninstallHooks() {
        do {
            let change = try hookConfiguration.uninstall()
            if change.changed {
                addEvent("AgentPager Codex Hook 已移除")
            }
            refreshHookStatus()
        } catch {
            lastError = "卸载 Hook 失败：\(error.localizedDescription)"
        }
    }

    func installClaudeHooks() {
        do {
            let command = ClaudeHookInstaller.hookCommand(for: hookExecutableURL.path)
            let change = try claudeHookConfiguration.install(command: command)
            if change.changed {
                addEvent("Claude Code Hook 已安装")
            }
            refreshClaudeHookStatus()
        } catch {
            lastError = "安装 Claude Code Hook 失败：\(error.localizedDescription)"
        }
    }

    func uninstallClaudeHooks() {
        do {
            let change = try claudeHookConfiguration.uninstall()
            if change.changed {
                addEvent("AgentPager Claude Code Hook 已移除")
            }
            refreshClaudeHookStatus()
        } catch {
            lastError = "卸载 Claude Code Hook 失败：\(error.localizedDescription)"
        }
    }

    func simulate(_ lifecycle: AgentLifecycle) {
        let now = Date()
        let task = TaskSnapshot(
            id: "agentgrid-simulator",
            source: .codexDesktop,
            projectName: "AgentPager 模拟器",
            title: "AgentPager · 像素任务列表联调",
            userPrompt: "检查任务行、逐像素 Bloom 和状态动效",
            latestStep: lifecycle == .running ? "apply_patch android/AgentPagerScreen.kt" : nil,
            tokenUsage: TokenUsage(input: 12_480, cachedInput: 9_200, output: 2_180, total: 14_660),
            subagents: [
                SubagentSnapshot(
                    id: "simulator-protocol",
                    path: "/root/protocol_v2",
                    lifecycle: lifecycle == .interrupted ? .interrupted : .running,
                    activity: .editing,
                    latestStep: "apply_patch protocol/fixtures/task-snapshot.json",
                    tokenUsage: TokenUsage(input: 3_200, output: 680, total: 3_880),
                    startedAt: now.addingTimeInterval(-31),
                    updatedAt: now
                ),
                SubagentSnapshot(
                    id: "simulator-animation",
                    path: "/root/pixel_motion",
                    lifecycle: .succeeded,
                    activity: nil,
                    latestStep: "swift test PixelMotionTests",
                    tokenUsage: TokenUsage(input: 2_440, output: 390, total: 2_830),
                    startedAt: now.addingTimeInterval(-27),
                    updatedAt: now.addingTimeInterval(-4)
                ),
            ],
            lifecycle: lifecycle,
            activity: lifecycle == .running ? .editing : nil,
            startedAt: now.addingTimeInterval(-42),
            updatedAt: now,
            completedAt: [.succeeded, .interrupted].contains(lifecycle) ? now : nil,
            isUnread: lifecycle == .succeeded,
            capabilities: lifecycle == .waitingApproval ? [.approve, .deny] : []
        )
        let commit = catalog.accept(
            .synthetic(task),
            focusedTaskIDOverride: task.id
        )
        addEvent("模拟状态：\(lifecycle.rawValue)")
        if let commit {
            applyCatalogCommit(commit)
        }
    }

    func clearError() {
        lastError = nil
    }

    private func handle(_ envelope: HookEnvelope) {
        let commit: TaskCatalogCommit?
        let projectSummary: String
        let lifecycleSummary: String
        switch envelope {
        case let .codex(hook):
            rolloutObservation.include(hook)
            commit = catalog.accept(.hook(hook))
            let task = catalog.projection().tasks.first { $0.id == hook.sessionID }
            projectSummary = task?.projectName ?? "Codex"
            lifecycleSummary = task?.lifecycle.rawValue ?? ""
        case let .claude(hook):
            commit = catalog.accept(.claudeHook(hook))
            let task = catalog.projection().tasks.first { $0.id == hook.sessionID }
            projectSummary = task?.projectName ?? "Claude Code"
            lifecycleSummary = task?.lifecycle.rawValue ?? ""
        }
        addEvent("\(projectSummary) · \(lifecycleSummary)")
        if let commit {
            applyCatalogCommit(commit)
        }
    }

    private func handleRolloutObservation() {
        let now = Date()
        let signals = rolloutObservation.observe(now: now)
        if !signals.isEmpty,
           let commit = catalog.accept(.rollout(signals)) {
            applyCatalogCommit(commit)
        }

        guard now >= nextSessionReconciliation else {
            return
        }
        nextSessionReconciliation = now.addingTimeInterval(60)
        let candidates = Set(
            catalog.projection().tasks.compactMap { task -> String? in
                guard task.source == .codexDesktop || task.source == .codexCLI,
                      task.lifecycle == .starting || task.lifecycle == .running else {
                    return nil
                }
                return task.id
            }
        )
        let existingSessionIDs = rolloutObservation.existingSessionIDs(
            matching: candidates
        )
        if let commit = catalog.reconcileCodexSessions(
            existingSessionIDs: existingSessionIDs,
            now: now
        ) {
            applyCatalogCommit(commit)
        }
    }

    private func handleControl(_ text: String) {
        guard let data = text.data(using: .utf8),
              var request = try? JSONDecoder().decode(SignedControlEnvelope.self, from: data) else {
            return
        }

        do {
            try replayGuard.validate(request, secret: pairingSecret)
        } catch {
            sendAck(requestID: request.messageId, result: .rejected, reason: "签名或序号无效")
            return
        }

        guard let hookServer else {
            sendAck(
                requestID: request.messageId,
                result: .rejected,
                reason: "Hook 通道尚未就绪"
            )
            return
        }
        let result = catalog.perform(
            AuthorizedTaskControl(
                requestID: request.messageId,
                taskID: request.payload.taskID,
                action: request.payload.action,
                value: request.payload.value
            ),
            permissionResolver: hookServer
        )
        request.signature = ""
        if let commit = result.commit {
            applyCatalogCommit(commit)
        }
        sendAck(
            requestID: result.receipt.requestID,
            result: result.receipt.result,
            reason: result.receipt.reason
        )
    }

    private func sendAck(requestID: UUID, result: ControlResult, reason: String? = nil) {
        let envelope = MessageEnvelope(
            type: "control.ack",
            payload: ControlAckPayload(requestID: requestID, result: result, reason: reason)
        )
        guard let text = encode(envelope) else { return }
        webSocketServer?.broadcast(text)
    }

    private func refreshUsage() {
        guard usageLoadTask == nil else { return }
        usageLoadTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                CodexUsageLoader.load()
            }.value
            guard let self else { return }
            self.usage = snapshot
            self.usageLoadTask = nil
            self.broadcastSnapshot()
        }
    }

    private func refreshHookStatus() {
        hookInstalled = hookConfiguration.isInstalled()
    }

    private func refreshClaudeHookStatus() {
        claudeHookInstalled = claudeHookConfiguration.isInstalled()
    }

    private func publishCatalog(focusedTaskIDOverride: String? = nil) {
        applyCatalogCommit(
            catalog.synchronize(
                focusedTaskIDOverride: focusedTaskIDOverride
            )
        )
    }

    private func applyCatalogCommit(_ commit: TaskCatalogCommit) {
        tasks = commit.projection.tasks
        focusedTaskID = commit.projection.focusedTaskID
        if let persistenceError = commit.persistenceError {
            lastError = persistenceError
        }
        broadcastSnapshot()
    }

    private func broadcastSnapshot() {
        let payload = StateSnapshotPayload(
            tasks: tasks,
            usage: usage,
            focusedTaskID: focusedTaskID,
            pendingRequests: catalog.projection().pendingRequests
        )
        let envelope = MessageEnvelope(type: "state.snapshot", payload: payload)
        guard let text = encode(envelope) else { return }
        webSocketServer?.broadcast(text)
    }

    private func encode<T: Codable & Sendable>(_ value: T) -> String? {
        guard let data = try? ProtocolCodec.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func addEvent(_ text: String) {
        recentEvents.insert(text, at: 0)
        recentEvents = Array(recentEvents.prefix(20))
    }

    private var hookExecutableURL: URL {
        let executableDirectory = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS")
        let currentSibling = executableDirectory
            .appendingPathComponent("AgentPagerHooks")
        if FileManager.default.isExecutableFile(atPath: currentSibling.path) {
            return currentSibling
        }
        let legacySibling = executableDirectory
            .appendingPathComponent("AgentGridHooks")
        if FileManager.default.isExecutableFile(atPath: legacySibling.path) {
            return legacySibling
        }

        let commandDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        let currentExecutable = commandDirectory
            .appendingPathComponent("AgentPagerHooks")
        if FileManager.default.isExecutableFile(atPath: currentExecutable.path) {
            return currentExecutable
        }
        return commandDirectory.appendingPathComponent("AgentGridHooks")
    }
}
