import Foundation

/// 解析 Claude Code 配置目录。
///
/// 优先级：`CLAUDE_CONFIG_DIR` 环境变量 > `~/.claude`。
/// AgentPager 仅依赖环境变量与默认路径，不提供其他自定义项。
public enum ClaudeConfigDirectory {
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let envPath = environment["CLAUDE_CONFIG_DIR"], !envPath.isEmpty {
            return URL(fileURLWithPath: (envPath as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }
}

/// 写入 Claude Code `settings.json` 的 Hook 配置入口。
///
/// 与 `CodexHookConfiguration` 结构对齐：保留用户既有配置、改写前备份、
/// 可恢复最近备份。差别仅在目标文件与安装器。
public struct ClaudeHookConfiguration: Sendable {
    public let settingsURL: URL

    public init(settingsURL: URL? = nil) {
        self.settingsURL = settingsURL ?? ClaudeConfigDirectory.resolved()
            .appendingPathComponent("settings.json")
    }

    public func isInstalled() -> Bool {
        ClaudeHookInstaller.isInstalled(
            data: try? Data(contentsOf: settingsURL)
        )
    }

    /// 额度捕获 statusLine 是否已安装（旧版本只装了 Hook，需重新安装才能获得 Claude 额度）。
    public func isStatusLineInstalled() -> Bool {
        ClaudeHookInstaller.isStatusLineInstalled(
            data: try? Data(contentsOf: settingsURL)
        )
    }

    public func install(
        command: String,
        statusLineBinaryPath: String? = nil,
        now: Date = .now
    ) throws -> HookConfigurationChange {
        let existing = try? Data(contentsOf: settingsURL)
        let mutation = try ClaudeHookInstaller.install(
            existingData: existing,
            command: command,
            statusLineBinaryPath: statusLineBinaryPath
        )
        guard mutation.changed, let contents = mutation.contents else {
            return HookConfigurationChange(changed: false)
        }

        try createParentDirectory()
        let backupURL = try backup(
            existing,
            prefix: "settings.json.agentpager-claude-backup",
            now: now
        )
        try contents.write(to: settingsURL, options: .atomic)
        return HookConfigurationChange(
            changed: true,
            backupURL: backupURL
        )
    }

    public func uninstall(
        now: Date = .now
    ) throws -> HookConfigurationChange {
        let existing = try? Data(contentsOf: settingsURL)
        let mutation = try ClaudeHookInstaller.uninstall(existingData: existing)
        guard mutation.changed else {
            return HookConfigurationChange(changed: false)
        }

        let backupURL = try backup(
            existing,
            prefix: "settings.json.agentpager-claude-backup",
            now: now
        )
        if let contents = mutation.contents {
            try createParentDirectory()
            try contents.write(to: settingsURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: settingsURL.path) {
            try FileManager.default.removeItem(at: settingsURL)
        }
        return HookConfigurationChange(
            changed: true,
            backupURL: backupURL
        )
    }

    public func restoreLatestBackup(
        now: Date = .now
    ) throws -> HookConfigurationChange {
        guard let backupURL = latestBackupURL() else {
            return HookConfigurationChange(changed: false)
        }
        let restored = try Data(contentsOf: backupURL)
        let existing = try? Data(contentsOf: settingsURL)
        guard restored != existing else {
            return HookConfigurationChange(changed: false)
        }

        try createParentDirectory()
        let recoveryURL = try backup(
            existing,
            prefix: "settings.json.agentpager-claude-before-restore",
            now: now
        )
        try restored.write(to: settingsURL, options: .atomic)
        return HookConfigurationChange(
            changed: true,
            backupURL: recoveryURL
        )
    }

    private func createParentDirectory() throws {
        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func backup(
        _ data: Data?,
        prefix: String,
        now: Date
    ) throws -> URL? {
        guard let data else { return nil }
        let baseURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("\(prefix)-\(Int(now.timeIntervalSince1970))")
        var url = baseURL
        var suffix = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = URL(fileURLWithPath: "\(baseURL.path)-\(suffix)")
            suffix += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private func latestBackupURL() -> URL? {
        let directory = settingsURL.deletingLastPathComponent()
        let prefix = "settings.json.agentpager-claude-backup-"
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .max { lhs, rhs in
                let lhsDate = try? lhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                let rhsDate = try? rhs.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                if lhsDate == rhsDate {
                    return lhs.lastPathComponent < rhs.lastPathComponent
                }
                return (lhsDate ?? .distantPast) < (rhsDate ?? .distantPast)
            }
    }
}
