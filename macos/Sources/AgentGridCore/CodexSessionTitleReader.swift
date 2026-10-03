import Foundation

public struct CodexSessionTitleRevision: Equatable, Sendable {
    public var modificationDate: Date
    public var fileSize: UInt64

    public init(modificationDate: Date, fileSize: UInt64) {
        self.modificationDate = modificationDate
        self.fileSize = fileSize
    }
}

public struct CodexSessionTitleReader: Sendable {
    private struct Entry: Decodable {
        let id: String
        let threadName: String
        let updatedAt: String

        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
            case updatedAt = "updated_at"
        }
    }

    public var indexURL: URL
    private var fallbackIndexURL: URL?

    public init(indexURL: URL? = nil) {
        if let indexURL {
            self.indexURL = indexURL
            fallbackIndexURL = nil
            return
        }

        let homeIndexURL = Self.homeIndexURL()
        if let configuredIndexURL = Self.configuredIndexURL(),
           configuredIndexURL.standardizedFileURL != homeIndexURL.standardizedFileURL {
            self.indexURL = configuredIndexURL
            fallbackIndexURL = homeIndexURL
        } else {
            self.indexURL = homeIndexURL
            fallbackIndexURL = nil
        }
    }

    init(primaryIndexURL: URL, fallbackIndexURL: URL?) {
        indexURL = primaryIndexURL
        self.fallbackIndexURL = fallbackIndexURL
    }

    public func loadTitles() -> [String: String] {
        guard let data = try? Data(contentsOf: activeIndexURL) else {
            return [:]
        }
        return Self.titles(from: data)
    }

    public func revision() -> CodexSessionTitleRevision? {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: activeIndexURL.path
        ),
        let modificationDate = attributes[.modificationDate] as? Date,
        let fileSize = attributes[.size] as? NSNumber else {
            return nil
        }
        return CodexSessionTitleRevision(
            modificationDate: modificationDate,
            fileSize: fileSize.uint64Value
        )
    }

    public static func titles(from data: Data) -> [String: String] {
        let decoder = JSONDecoder()
        var latestEntries: [String: Entry] = [:]

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
                  let id = normalized(entry.id),
                  let title = normalized(entry.threadName) else {
                continue
            }

            let normalizedEntry = Entry(
                id: id,
                threadName: title,
                updatedAt: entry.updatedAt
            )
            if let current = latestEntries[id],
               current.updatedAt > normalizedEntry.updatedAt {
                continue
            }
            latestEntries[id] = normalizedEntry
        }

        return latestEntries.mapValues(\.threadName)
    }

    private static func configuredIndexURL() -> URL? {
        if let configuredHome = normalized(
            ProcessInfo.processInfo.environment["CODEX_HOME"]
        ) {
            return URL(fileURLWithPath: configuredHome, isDirectory: true)
                .appendingPathComponent("session_index.jsonl")
        }
        return nil
    }

    private static func homeIndexURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
    }

    private var activeIndexURL: URL {
        guard !FileManager.default.fileExists(atPath: indexURL.path),
              let fallbackIndexURL else {
            return indexURL
        }
        return fallbackIndexURL
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

public struct CodexSessionTitleSynchronizer: Sendable {
    private var synchronizedTitles: [String: String] = [:]
    private var synchronizedRevision: CodexSessionTitleRevision?

    public init() {}

    public func needsRefresh(
        for tasks: [TaskSnapshot],
        revision: CodexSessionTitleRevision?
    ) -> Bool {
        // 标题源是 Codex 的 session_index.jsonl，只对 Codex 会话有意义；
        // Claude 会话的标题来自 UserPromptSubmit，无需进入该同步流程。
        let codexTasks = tasks.filter { task in
            task.source == .codexCLI || task.source == .codexDesktop
        }
        guard !codexTasks.isEmpty else { return false }
        return revision != synchronizedRevision
            || codexTasks.contains { task in
                guard let codexTitle = synchronizedTitles[task.id] else {
                    return true
                }
                return task.title != TaskStore.displayTitle(
                    projectName: task.projectName,
                    codexTitle: codexTitle
                )
            }
    }

    @discardableResult
    public mutating func applyAvailableTitles(
        _ availableTitles: [String: String],
        revision: CodexSessionTitleRevision?,
        to catalog: inout TaskCatalog
    ) -> Bool {
        let taskIDs = catalog.projection().tasks.compactMap { task in
            (task.source == .codexCLI || task.source == .codexDesktop)
                ? task.id
                : nil
        }
        for taskID in taskIDs {
            guard let title = availableTitles[taskID] else {
                continue
            }
            synchronizedTitles[taskID] = title
        }
        synchronizedRevision = revision
        return catalog.applyAvailableTitles(synchronizedTitles)
    }
}
