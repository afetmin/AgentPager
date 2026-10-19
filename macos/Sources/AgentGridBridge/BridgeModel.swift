import AgentGridCore
import Foundation
import Observation

@MainActor
@Observable
final class BridgeModel {
    private(set) var tasks: [TaskSnapshot] = []
    private(set) var usage: UsageSnapshot?
    private(set) var claudeUsage: UsageSnapshot?
    private(set) var focusedTaskID: String?
    private(set) var phoneCount = 0
    private(set) var serviceStatus = "正在启动"
    private(set) var hookInstalled = false
    private(set) var claudeHookInstalled = false
    /// Claude 订阅额度捕获（statusLine）是否已接管；旧版只装了 Hook 时为 false。
    private(set) var claudeStatusLineInstalled = false
    /// 是否允许用 Claude Code 登录凭据查询订阅额度（默认开启，可随时关闭）。
    private(set) var claudeOAuthQuotaEnabled = ClaudeOAuthUsage.isEnabled
    private(set) var lastError: String?
    /// Hook 安装/卸载错误单独保存：成功操作只清除自己的错误，不会误清服务启动错误。
    private(set) var codexHookError: String?
    private(set) var claudeHookError: String?
    private(set) var pairingText = ""
    private(set) var recentEvents: [String] = []
    /// 其他兼容客户端（ZCode、WorkBuddy 等）的 Hook 状态，按 `AgentIntegration.id` 索引。
    private(set) var integrationStatuses: [String: IntegrationStatus] = [:]

    struct IntegrationStatus: Equatable {
        var detected = false
        var installed = false
        /// 已写入但客户端的总开关被用户关闭，Hook 不会运行。
        var dormant = false
        var error: String?
    }

    private var catalog = PersistentTaskCatalog()
    private var replayGuard = ReplayGuard()
    private var pairingSecret = Data()
    private let hookConfiguration: CodexHookConfiguration
    private let claudeHookConfiguration: ClaudeHookConfiguration
    private let integrationHome: URL
    private var rolloutObservation = CodexRolloutObservation()
    private var claudeTranscriptObservation = ClaudeTranscriptObservation()
    private var hookServer: HookBridgeServer?
    private var webSocketServer: WebSocketServer?
    private var refreshTask: Task<Void, Never>?
    private var usageLoadTask: Task<Void, Never>?
    private var lastClaudeCaptureModifiedAt: Date?
    private var rolloutTask: Task<Void, Never>?
    private var sessionReconciliationTask: Task<Void, Never>?
    private var pairingTextBox = PairingTextBox("")
    private var pairingServiceID = ""
    private var nextPairingRefresh = Date.distantPast
    private var hasStarted = false
    private var nextSessionReconciliation = Date.distantPast

    init(
        hookConfiguration: CodexHookConfiguration = CodexHookConfiguration(),
        claudeHookConfiguration: ClaudeHookConfiguration = ClaudeHookConfiguration(),
        integrationHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.hookConfiguration = hookConfiguration
        self.claudeHookConfiguration = claudeHookConfiguration
        self.integrationHome = integrationHome
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        do {
            pairingSecret = try PairingSecretStore.loadOrCreate()
            pairingServiceID = "agentgrid-\(Host.current().localizedName ?? "mac")"
            pairingText = PairingText.make(
                serviceID: pairingServiceID,
                host: LocalNetworkAddress.preferredIPv4(),
                secret: pairingSecret
            )
            let pairingTextBox = PairingTextBox(pairingText)
            self.pairingTextBox = pairingTextBox

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
                    path == "/pairing" ? pairingTextBox.value : nil
                }
            )
            try webSocketServer.start(serviceID: pairingServiceID)
            self.webSocketServer = webSocketServer
            serviceStatus = "局域网服务运行中"
        } catch {
            serviceStatus = "服务启动失败"
            lastError = error.localizedDescription
        }

        refreshHookStatus()
        refreshClaudeHookStatus()
        refreshIntegrationStatuses()
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
                self.refreshClaudeQuotaIfNeeded()
                self.refreshPairingTextIfDue()
                if let commit = self.catalog.maintain() {
                    self.applyCatalogCommit(commit)
                }
            }
        }
    }

    /// 网络切换（Wi-Fi/有线/热点）后 IP 会变，二维码和 `/pairing` 必须跟随，否则手机扫到旧地址。
    func refreshPairingText() {
        guard !pairingSecret.isEmpty, !pairingServiceID.isEmpty else { return }
        let text = PairingText.make(
            serviceID: pairingServiceID,
            host: LocalNetworkAddress.preferredIPv4(),
            secret: pairingSecret
        )
        guard text != pairingText else { return }
        pairingText = text
        pairingTextBox.value = text
    }

    private func refreshPairingTextIfDue(now: Date = .now) {
        guard now >= nextPairingRefresh else { return }
        nextPairingRefresh = now.addingTimeInterval(10)
        refreshPairingText()
    }

    /// 界面出现时刷新：用户可能在 App 外手动改过 ~/.codex 或 ~/.claude 配置。
    func refreshHookStatuses() {
        refreshHookStatus()
        refreshClaudeHookStatus()
        refreshIntegrationStatuses()
    }

    func installIntegration(id: String) {
        guard let integration = AgentIntegrations.integration(id: id) else { return }
        let configuration = AgentIntegrationConfiguration(
            integration: integration,
            home: integrationHome
        )
        do {
            let change = try configuration.install(binaryPath: hookExecutableURL.path)
            addEvent(change.changed
                ? "\(integration.displayName) Hook 已安装"
                : "\(integration.displayName) Hook 已是最新")
            refreshIntegrationStatus(integration)
        } catch {
            refreshIntegrationStatus(integration)
            integrationStatuses[id, default: IntegrationStatus()].error =
                "安装 \(integration.displayName) Hook 失败：\(error.localizedDescription)"
        }
    }

    func uninstallIntegration(id: String) {
        guard let integration = AgentIntegrations.integration(id: id) else { return }
        let configuration = AgentIntegrationConfiguration(
            integration: integration,
            home: integrationHome
        )
        do {
            let change = try configuration.uninstall()
            if change.changed {
                addEvent("AgentPager \(integration.displayName) Hook 已移除")
            }
            refreshIntegrationStatus(integration)
        } catch {
            refreshIntegrationStatus(integration)
            integrationStatuses[id, default: IntegrationStatus()].error =
                "卸载 \(integration.displayName) Hook 失败：\(error.localizedDescription)"
        }
    }

    func refreshIntegrationStatuses() {
        for integration in AgentIntegrations.all {
            refreshIntegrationStatus(integration)
        }
    }

    private func refreshIntegrationStatus(_ integration: AgentIntegration) {
        let configuration = AgentIntegrationConfiguration(
            integration: integration,
            home: integrationHome
        )
        integrationStatuses[integration.id] = IntegrationStatus(
            detected: configuration.isClientDetected(),
            installed: configuration.isInstalled(),
            dormant: configuration.isDormant()
        )
    }

    func installHooks() {
        do {
            let change = try hookConfiguration.install(
                command: hookExecutableURL.path
            )
            addEvent(change.changed ? "Codex Hook 已安装" : "Codex Hook 已是最新")
            codexHookError = nil
            refreshHookStatus()
        } catch {
            codexHookError = "安装 Hook 失败：\(error.localizedDescription)"
            refreshHookStatus()
        }
    }

    func uninstallHooks() {
        do {
            let change = try hookConfiguration.uninstall()
            if change.changed {
                addEvent("AgentPager Codex Hook 已移除")
            }
            codexHookError = nil
            refreshHookStatus()
        } catch {
            codexHookError = "卸载 Hook 失败：\(error.localizedDescription)"
            refreshHookStatus()
        }
    }

    func installClaudeHooks() {
        do {
            let command = ClaudeHookInstaller.hookCommand(for: hookExecutableURL.path)
            let change = try claudeHookConfiguration.install(
                command: command,
                statusLineBinaryPath: hookExecutableURL.path
            )
            addEvent(change.changed ? "Claude Code Hook 已安装" : "Claude Code Hook 已是最新")
            claudeHookError = nil
            refreshClaudeHookStatus()
        } catch {
            claudeHookError = "安装 Claude Code Hook 失败：\(error.localizedDescription)"
            refreshClaudeHookStatus()
        }
    }

    func setClaudeOAuthQuotaEnabled(_ enabled: Bool) {
        ClaudeOAuthUsage.isEnabled = enabled
        claudeOAuthQuotaEnabled = enabled
        refreshUsage()
    }

    func uninstallClaudeHooks() {
        do {
            let change = try claudeHookConfiguration.uninstall()
            if change.changed {
                addEvent("AgentPager Claude Code Hook 已移除")
            }
            claudeHookError = nil
            refreshClaudeHookStatus()
        } catch {
            claudeHookError = "卸载 Claude Code Hook 失败：\(error.localizedDescription)"
            refreshClaudeHookStatus()
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
        codexHookError = nil
        claudeHookError = nil
        for id in integrationStatuses.keys {
            integrationStatuses[id]?.error = nil
        }
    }

    /// 菜单与诊断页展示的当前错误（Hook 操作错误优先，其次服务/持久化错误）。
    var displayedError: String? {
        codexHookError ?? claudeHookError ?? lastError
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
        case let .permissionExpired(sessionID):
            commit = catalog.expirePendingRequest(sessionID: sessionID)
            let task = catalog.projection().tasks.first { $0.id == sessionID }
            projectSummary = task?.projectName ?? "Agent"
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

        guard now >= nextSessionReconciliation, sessionReconciliationTask == nil else {
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
        let claudeCandidates = Set(
            catalog.projection().tasks.compactMap { task -> String? in
                guard task.source == .claudeCode,
                      task.agentName == nil,
                      task.lifecycle == .starting || task.lifecycle == .running else {
                    return nil
                }
                return task.id
            }
        )
        let codexObservation = rolloutObservation
        let claudeObservation = claudeTranscriptObservation
        sessionReconciliationTask = Task { [weak self] in
            // Directory scans and the bounded lsof probe must not block Hook
            // delivery, phone controls or UI updates on the main actor.
            let (existingSessionIDs, liveSessionIDs, claudeEvidence) = await Task.detached(
                priority: .utility
            ) {
                (
                    codexObservation.existingSessionIDs(matching: candidates),
                    codexObservation.liveSessionIDs(matching: candidates),
                    claudeObservation.evidence(matching: claudeCandidates)
                )
            }.value
            guard let self else { return }
            self.sessionReconciliationTask = nil
            if let commit = self.catalog.reconcileCodexSessions(
                existingSessionIDs: existingSessionIDs,
                liveSessionIDs: liveSessionIDs,
                now: .now
            ) {
                self.applyCatalogCommit(commit)
            }
            if let commit = self.catalog.reconcileClaudeSessions(
                evidenceBySessionID: claudeEvidence,
                now: .now
            ) {
                self.applyCatalogCommit(commit)
            }
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
            let (snapshot, claudeSnapshot) = await Task.detached(priority: .utility) {
                (
                    CodexUsageLoader.load(),
                    ClaudeUsageLoader.load(remoteCapture: { ClaudeOAuthUsage.currentCapture(now: $0) })
                )
            }.value
            guard let self else { return }
            self.usage = snapshot
            self.claudeUsage = claudeSnapshot
            self.usageLoadTask = nil
            self.broadcastSnapshot()
        }
    }

    /// statusLine 捕获文件更新、或已显示的额度窗口到期时，及时重算 Claude 额度。
    private func refreshClaudeQuotaIfNeeded() {
        let modifiedAt = (try? ClaudeRateLimitStore.defaultURL
            .resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let windowExpired = claudeUsage?.windows.contains {
            ($0.resetsAt ?? .distantFuture) <= .now
        } == true
        guard modifiedAt != lastClaudeCaptureModifiedAt || windowExpired else { return }
        lastClaudeCaptureModifiedAt = modifiedAt
        refreshUsage()
    }

    private func refreshHookStatus() {
        hookInstalled = hookConfiguration.isInstalled()
    }

    private func refreshClaudeHookStatus() {
        claudeHookInstalled = claudeHookConfiguration.isInstalled()
        claudeStatusLineInstalled = claudeHookConfiguration.isStatusLineInstalled()
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
            claudeUsage: claudeUsage,
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
