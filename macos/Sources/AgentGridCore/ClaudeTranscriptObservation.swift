import Foundation

/// Claude 会话文件中足以判断当前轮次是否仍然存活的最小证据。
public struct ClaudeTranscriptEvidence: Equatable, Sendable {
    public var sessionID: String
    public var modificationDate: Date
    public var lastActivityAt: Date?
    public var completedAt: Date?
    public var hasOpenTurn: Bool

    public init(
        sessionID: String,
        modificationDate: Date,
        lastActivityAt: Date?,
        completedAt: Date?,
        hasOpenTurn: Bool
    ) {
        self.sessionID = sessionID
        self.modificationDate = modificationDate
        self.lastActivityAt = lastActivityAt
        self.completedAt = completedAt
        self.hasOpenTurn = hasOpenTurn
    }
}

/// 读取 Claude Code / Claude Desktop 共用的 `~/.claude/projects/**/*.jsonl`。
///
/// Hook 是实时主通道；会话文件只用于每分钟一次的纠偏：补上丢失的 Stop、
/// 识别漏掉 UserPromptSubmit 的活跃轮次，以及清理由 Desktop 重放事件造成的
/// 僵尸任务。只读每个候选文件的尾部，避免加载大型历史会话。
public struct ClaudeTranscriptObservation: Sendable {
    private let projectsRoots: [URL]
    private let maximumTailBytes: UInt64

    public init() {
        let homeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let configuredRoot = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .flatMap(Self.normalized)
            .map {
                URL(fileURLWithPath: $0, isDirectory: true)
                    .appendingPathComponent("projects", isDirectory: true)
            }
        self.init(projectsRoot: homeRoot, additionalProjectsRoot: configuredRoot)
    }

    init(
        projectsRoot: URL,
        additionalProjectsRoot: URL? = nil,
        maximumTailBytes: UInt64 = 512 * 1_024
    ) {
        var roots = [projectsRoot]
        if let additionalProjectsRoot,
           additionalProjectsRoot.standardizedFileURL != projectsRoot.standardizedFileURL {
            roots.append(additionalProjectsRoot)
        }
        projectsRoots = roots
        self.maximumTailBytes = maximumTailBytes
    }

    public func evidence(
        matching sessionIDs: Set<String>
    ) -> [String: ClaudeTranscriptEvidence] {
        guard !sessionIDs.isEmpty else { return [:] }
        var result: [String: ClaudeTranscriptEvidence] = [:]

        for root in projectsRoots where !sessionIDs.isSubset(of: Set(result.keys)) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl" else { continue }
                let sessionID = url.deletingPathExtension().lastPathComponent
                guard sessionIDs.contains(sessionID),
                      let candidate = Self.readEvidence(
                          at: url,
                          sessionID: sessionID,
                          maximumTailBytes: maximumTailBytes
                      ) else {
                    continue
                }
                if let current = result[sessionID],
                   current.modificationDate >= candidate.modificationDate {
                    continue
                }
                result[sessionID] = candidate
            }
        }
        return result
    }

    static func evidence(
        from data: Data,
        sessionID: String,
        modificationDate: Date
    ) -> ClaudeTranscriptEvidence {
        var lastActivityAt: Date?
        var lastTurnActivityIndex: Int?
        var lastStopIndex: Int?
        var lastStopAt: Date?

        for (index, line) in data.split(separator: UInt8(ascii: "\n")).enumerated() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else {
                continue
            }
            let timestamp = Self.date(from: object["timestamp"] as? String)
            if let timestamp {
                lastActivityAt = max(lastActivityAt ?? timestamp, timestamp)
            }

            let type = object["type"] as? String
            let subtype = object["subtype"] as? String
            if type == "user" || type == "assistant" {
                lastTurnActivityIndex = index
            }
            if type == "assistant",
               let message = object["message"] as? [String: Any],
               let stopReason = message["stop_reason"] as? String,
               ["end_turn", "stop_sequence"].contains(stopReason) {
                // A final assistant response is also completion evidence when
                // a Desktop run does not emit a Stop hook summary.
                lastStopIndex = index
                lastStopAt = timestamp ?? modificationDate
            }
            if type == "system", subtype == "stop_hook_summary" {
                lastStopIndex = index
                lastStopAt = timestamp ?? modificationDate
            }
        }

        let hasOpenTurn: Bool
        if let lastTurnActivityIndex {
            hasOpenTurn = lastTurnActivityIndex > (lastStopIndex ?? -1)
        } else {
            hasOpenTurn = false
        }
        return ClaudeTranscriptEvidence(
            sessionID: sessionID,
            modificationDate: modificationDate,
            lastActivityAt: lastActivityAt,
            completedAt: hasOpenTurn ? nil : lastStopAt,
            hasOpenTurn: hasOpenTurn
        )
    }

    private static func readEvidence(
        at url: URL,
        sessionID: String,
        maximumTailBytes: UInt64
    ) -> ClaudeTranscriptEvidence? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey,
            .contentModificationDateKey,
        ]),
        values.isRegularFile == true,
        let modificationDate = values.contentModificationDate,
        let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > maximumTailBytes ? end - maximumTailBytes : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // 尾读可能从 JSON 行中间开始，丢弃不完整首行。
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data.removeSubrange(data.startIndex...newline)
        }
        return evidence(
            from: data,
            sessionID: sessionID,
            modificationDate: modificationDate
        )
    }

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func normalized(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
