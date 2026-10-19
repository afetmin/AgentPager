import Foundation

public enum AgentIntegrationError: LocalizedError, Equatable {
    case clientNotDetected(name: String, path: String)
    case unreadableConfig(path: String)
    case unparseableConfig(path: String)

    public var errorDescription: String? {
        switch self {
        case let .clientNotDetected(name, path):
            "未检测到 \(name)（\(path) 不存在），请先安装并启动一次该客户端"
        case let .unreadableConfig(path):
            "无法读取配置文件 \(path)"
        case let .unparseableConfig(path):
            "\(path) 不是标准 JSON（可能含注释或已损坏），为避免破坏你的配置，已拒绝修改"
        }
    }
}

/// 某个 `AgentIntegration` 在本机上的 Hook 安装入口。
///
/// 与 `ClaudeHookConfiguration` 同样的安全约束：改写前备份、保留用户既有配置、
/// 无法解析的配置一律拒绝改动；并且只在检测到客户端存在时才写，
/// 避免凭空创建目录让别的工具误判该客户端已安装。
public struct AgentIntegrationConfiguration: Sendable {
    public let integration: AgentIntegration
    public let home: URL

    public init(
        integration: AgentIntegration,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.integration = integration
        self.home = home
    }

    public var configURL: URL { integration.configURL(home: home) }

    public var displayConfigPath: String { "~/\(integration.configPath)" }

    /// 客户端的数据目录是否存在。
    public func isClientDetected() -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: integration.presenceURL(home: home).path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    public func isInstalled() -> Bool {
        let data = try? Data(contentsOf: configURL)
        switch integration.format {
        case .claudeSettings:
            return ClaudeHookInstaller.isInstalled(data: data, events: claudeEvents)
        case .zcodeConfig:
            return ZcodeHookInstaller.isInstalled(data: data, events: integration.events)
        }
    }

    /// ZCode 的 `hooks.enabled` 总开关被用户关闭：Hook 已写入但不会运行。
    public func isDormant() -> Bool {
        guard integration.format == .zcodeConfig, isInstalled() else { return false }
        return ZcodeHookInstaller.isMasterSwitchOff(data: try? Data(contentsOf: configURL))
    }

    public func install(
        binaryPath: String,
        now: Date = .now
    ) throws -> HookConfigurationChange {
        guard isClientDetected() else {
            throw AgentIntegrationError.clientNotDetected(
                name: integration.displayName,
                path: "~/\(integration.presencePath)"
            )
        }
        let existing = try readExisting()
        let command = integration.hookCommand(for: binaryPath)
        let mutation: HookFileMutation
        do {
            switch integration.format {
            case .claudeSettings:
                mutation = try ClaudeHookInstaller.install(
                    existingData: existing,
                    command: command,
                    statusLineBinaryPath: nil,
                    events: claudeEvents,
                    statusMessage: "Managed by AgentPager"
                )
            case .zcodeConfig:
                mutation = try ZcodeHookInstaller.install(
                    existingData: existing,
                    command: command,
                    events: integration.events
                )
            }
        } catch {
            throw AgentIntegrationError.unparseableConfig(path: displayConfigPath)
        }
        guard mutation.changed, let contents = mutation.contents else {
            return HookConfigurationChange(changed: false)
        }
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let backupURL = try backup(existing, now: now)
        try contents.write(to: configURL, options: .atomic)
        return HookConfigurationChange(changed: true, backupURL: backupURL)
    }

    public func uninstall(now: Date = .now) throws -> HookConfigurationChange {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return HookConfigurationChange(changed: false)
        }
        let existing = try readExisting()
        let mutation: HookFileMutation
        do {
            switch integration.format {
            case .claudeSettings:
                mutation = try ClaudeHookInstaller.uninstall(
                    existingData: existing,
                    events: claudeEvents
                )
            case .zcodeConfig:
                mutation = try ZcodeHookInstaller.uninstall(existingData: existing)
            }
        } catch {
            throw AgentIntegrationError.unparseableConfig(path: displayConfigPath)
        }
        guard mutation.changed else {
            return HookConfigurationChange(changed: false)
        }
        let backupURL = try backup(existing, now: now)
        if let contents = mutation.contents {
            try contents.write(to: configURL, options: .atomic)
        } else {
            try FileManager.default.removeItem(at: configURL)
        }
        return HookConfigurationChange(changed: true, backupURL: backupURL)
    }

    // MARK: - 内部

    private var claudeEvents: [ClaudeHookInstaller.EventSpec] {
        integration.events.map { ($0.name, $0.matcher, $0.timeout) }
    }

    private func readExisting() throws -> Data? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        guard let data = try? Data(contentsOf: configURL) else {
            throw AgentIntegrationError.unreadableConfig(path: displayConfigPath)
        }
        return data
    }

    private func backup(_ data: Data?, now: Date) throws -> URL? {
        guard let data else { return nil }
        let directory = configURL.deletingLastPathComponent()
        let name = "\(configURL.lastPathComponent).agentpager-\(integration.id)-backup-\(Int(now.timeIntervalSince1970))"
        var url = directory.appendingPathComponent(name)
        var suffix = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name)-\(suffix)")
            suffix += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}
