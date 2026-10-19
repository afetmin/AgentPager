import Foundation

public struct TaskSnapshotPersistence: Sendable {
    private struct StoredTask: Codable {
        var id: String
        var source: AgentSource
        var agentName: String?
        var projectName: String
        var title: String
        var userPrompt: String?
        var tokenUsage: TokenUsage?
        var lifecycle: AgentLifecycle
        var activity: AgentActivity?
        var startedAt: Date
        var updatedAt: Date
        var completedAt: Date?
        var isUnread: Bool
        var isPinned: Bool
        var isMuted: Bool
        var capabilities: Set<TaskCapability>

        init(_ task: TaskSnapshot) {
            id = task.id
            source = task.source
            agentName = task.agentName
            projectName = task.projectName
            title = task.title
            userPrompt = task.userPrompt
            tokenUsage = task.tokenUsage
            lifecycle = task.lifecycle
            activity = task.activity
            startedAt = task.startedAt
            updatedAt = task.updatedAt
            completedAt = task.completedAt
            isUnread = task.isUnread
            isPinned = task.isPinned
            isMuted = task.isMuted
            capabilities = task.capabilities
        }

        var task: TaskSnapshot {
            TaskSnapshot(
                id: id,
                source: source,
                projectName: projectName,
                title: title,
                userPrompt: userPrompt,
                latestStep: nil,
                tokenUsage: tokenUsage,
                lifecycle: lifecycle,
                activity: activity,
                startedAt: startedAt,
                updatedAt: updatedAt,
                completedAt: completedAt,
                isUnread: isUnread,
                isPinned: isPinned,
                isMuted: isMuted,
                capabilities: capabilities,
                agentName: agentName
            )
        }
    }

    public let fileURL: URL

    public init(fileURL: URL = Self.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func load() -> [TaskSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode([StoredTask].self, from: data).map(\.task)) ?? []
    }

    public func save(_ tasks: [TaskSnapshot]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try encoder.encode(tasks.map(StoredTask.init)).write(to: fileURL, options: .atomic)
    }

    /// AgentPager 的 Application Support 目录（任务快照、额度捕获等共用）。
    public static var defaultDirectory: URL {
        let applicationSupport =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("AgentGrid", isDirectory: true)
    }

    public static var defaultFileURL: URL {
        defaultDirectory.appendingPathComponent("tasks.json")
    }
}
