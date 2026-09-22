import Foundation

public struct CodexRolloutSignal: Equatable, Sendable {
    public var sessionID: String
    public var cwd: String
    public var lifecycle: AgentLifecycle?
    public var activity: AgentActivity?
    public var requestKind: PendingRequestKind?
    public var summary: String?
    public var userPrompt: String?
    public var latestStep: String?
    public var tokenUsage: TokenUsage?
    public var subagentID: String?
    public var subagentPath: String?
    public var timestamp: Date

    public init(
        sessionID: String,
        cwd: String,
        lifecycle: AgentLifecycle?,
        activity: AgentActivity?,
        requestKind: PendingRequestKind? = nil,
        summary: String? = nil,
        userPrompt: String? = nil,
        latestStep: String? = nil,
        tokenUsage: TokenUsage? = nil,
        subagentID: String? = nil,
        subagentPath: String? = nil,
        timestamp: Date = .now
    ) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.lifecycle = lifecycle
        self.activity = activity
        self.requestKind = requestKind
        self.summary = summary
        self.userPrompt = userPrompt
        self.latestStep = latestStep
        self.tokenUsage = tokenUsage
        self.subagentID = subagentID
        self.subagentPath = subagentPath
        self.timestamp = timestamp
    }
}

public struct CodexRolloutReader: Sendable {
    private struct PendingSubagent: Sendable {
        var id: String
        var path: String
        var parentSessionID: String
        var parentCWD: String
        var nearbyDirectory: URL
    }

    private struct TrackedFile: Sendable {
        var url: URL
        var sessionID: String
        var cwd: String
        var subagentID: String?
        var subagentPath: String?
        var offset: UInt64
        var partialLine = Data()
    }

    private var trackedFiles: [String: TrackedFile] = [:]
    private var pendingSubagents: [String: PendingSubagent] = [:]

    public init() {}

    public var hasTrackedFiles: Bool {
        !trackedFiles.isEmpty
    }

    public mutating func track(
        filePath: String?,
        sessionID: String,
        cwd: String,
        subagentID: String? = nil,
        subagentPath: String? = nil,
        readExisting: Bool = false,
        maximumReplayBytes: UInt64? = nil
    ) {
        guard let filePath, !filePath.isEmpty else {
            return
        }

        let url = URL(fileURLWithPath: filePath)
        let key = url.standardizedFileURL.path
        let size = Self.fileSize(at: url)
        if var existing = trackedFiles[key] {
            existing.sessionID = sessionID
            existing.cwd = cwd
            existing.subagentID = subagentID
            existing.subagentPath = subagentPath
            trackedFiles[key] = existing
        } else {
            let replayOffset: UInt64
            if readExisting, let maximumReplayBytes {
                replayOffset = size > maximumReplayBytes ? size - maximumReplayBytes : 0
            } else {
                replayOffset = readExisting ? 0 : size
            }
            trackedFiles[key] = TrackedFile(
                url: url,
                sessionID: sessionID,
                cwd: cwd,
                subagentID: subagentID,
                subagentPath: subagentPath,
                offset: replayOffset
            )
        }
    }

    @discardableResult
    public mutating func discoverSessions(
        in sessionsRoot: URL,
        modifiedAfter: Date,
        maximumReplayBytes: UInt64 = 2 * 1_024 * 1_024
    ) -> Int {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [
            .contentModificationDateKey,
            .isRegularFileKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return 0
        }

        var discovered = 0
        for case let fileURL as URL in enumerator
        where fileURL.pathExtension == "jsonl" {
            let key = fileURL.standardizedFileURL.path
            guard trackedFiles[key] == nil,
                  let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys)),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt >= modifiedAfter,
                  let metadata = Self.sessionMetadata(at: fileURL) else {
                continue
            }
            track(
                filePath: fileURL.path,
                sessionID: metadata.sessionID,
                cwd: metadata.cwd,
                readExisting: true,
                maximumReplayBytes: maximumReplayBytes
            )
            discovered += 1
        }
        return discovered
    }

    public mutating func poll() -> [CodexRolloutSignal] {
        resolvePendingSubagents()
        var signals: [CodexRolloutSignal] = []

        for key in Array(trackedFiles.keys) {
            guard var tracked = trackedFiles[key] else {
                continue
            }
            let size = Self.fileSize(at: tracked.url)
            guard size >= tracked.offset else {
                tracked.offset = size
                tracked.partialLine.removeAll(keepingCapacity: false)
                trackedFiles[key] = tracked
                continue
            }
            guard size > tracked.offset,
                  let handle = try? FileHandle(forReadingFrom: tracked.url) else {
                continue
            }
            defer { try? handle.close() }

            do {
                try handle.seek(toOffset: tracked.offset)
                let appended = try handle.readToEnd() ?? Data()
                tracked.offset = size
                tracked.partialLine.append(appended)

                while let newline = tracked.partialLine.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = tracked.partialLine[..<newline]
                    tracked.partialLine.removeSubrange(
                        tracked.partialLine.startIndex...newline
                    )
                    if let signal = Self.signal(
                        from: Data(line),
                        sessionID: tracked.sessionID,
                        cwd: tracked.cwd,
                        trackedSubagentID: tracked.subagentID,
                        trackedSubagentPath: tracked.subagentPath
                    ) {
                        signals.append(signal)
                        if tracked.subagentID == nil,
                           let subagentID = signal.subagentID,
                           let subagentPath = signal.subagentPath {
                            trackSubagent(
                                id: subagentID,
                                path: subagentPath,
                                parent: tracked
                            )
                        }
                    }
                }
            } catch {
                tracked.offset = size
                tracked.partialLine.removeAll(keepingCapacity: false)
            }
            trackedFiles[key] = tracked
        }

        // 同一任务可能存在多个续接记录，必须按事件时间合并，避免旧消息覆盖最新输入。
        return signals.enumerated()
            .sorted { left, right in
                if left.element.timestamp == right.element.timestamp {
                    return left.offset < right.offset
                }
                return left.element.timestamp < right.element.timestamp
            }
            .map(\.element)
    }

    private mutating func trackSubagent(
        id: String,
        path: String,
        parent: TrackedFile
    ) {
        guard !trackedFiles.values.contains(where: { $0.subagentID == id }) else {
            pendingSubagents.removeValue(forKey: id)
            return
        }
        guard let fileURL = Self.findRolloutFile(
                sessionID: id,
                near: parent.url.deletingLastPathComponent()
              ) else {
            pendingSubagents[id] = PendingSubagent(
                id: id,
                path: path,
                parentSessionID: parent.sessionID,
                parentCWD: parent.cwd,
                nearbyDirectory: parent.url.deletingLastPathComponent()
            )
            return
        }
        track(
            filePath: fileURL.path,
            sessionID: parent.sessionID,
            cwd: parent.cwd,
            subagentID: id,
            subagentPath: path,
            readExisting: true
        )
        pendingSubagents.removeValue(forKey: id)
    }

    private mutating func resolvePendingSubagents() {
        for pending in Array(pendingSubagents.values) {
            guard !trackedFiles.values.contains(where: { $0.subagentID == pending.id }),
                  let fileURL = Self.findRolloutFile(
                    sessionID: pending.id,
                    near: pending.nearbyDirectory
                  ) else {
                continue
            }
            track(
                filePath: fileURL.path,
                sessionID: pending.parentSessionID,
                cwd: pending.parentCWD,
                subagentID: pending.id,
                subagentPath: pending.path,
                readExisting: true
            )
            pendingSubagents.removeValue(forKey: pending.id)
        }
    }

    public static func signal(
        from line: Data,
        sessionID: String,
        cwd: String,
        trackedSubagentID: String? = nil,
        trackedSubagentPath: String? = nil,
        now: Date = .now
    ) -> CodexRolloutSignal? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let rootType = root["type"] as? String,
              let payload = root["payload"] as? [String: Any],
              let type = payload["type"] as? String else {
            return nil
        }

        let timestamp = parseTimestamp(root["timestamp"] as? String) ?? now

        if rootType == "response_item" {
            return responseItemSignal(
                type: type,
                payload: payload,
                sessionID: sessionID,
                cwd: cwd,
                subagentID: trackedSubagentID,
                subagentPath: trackedSubagentPath,
                timestamp: timestamp
            )
        }
        guard rootType == "event_msg" else { return nil }

        switch type {
        case "task_started", "turn_started":
            return signal(.running, .thinking, timestamp: timestamp)
        case "task_complete", "turn_complete":
            return signal(.succeeded, nil, timestamp: timestamp)
        case "turn_aborted":
            return signal(.interrupted, nil, timestamp: timestamp)
        case "agent_reasoning", "agent_reasoning_raw_content",
             "agent_reasoning_section_break", "context_compacted":
            return signal(.running, .thinking, timestamp: timestamp)
        case "user_message":
            let prompt = clipped(payload["message"] as? String, limit: 240)
            return signal(
                .running,
                .thinking,
                userPrompt: prompt,
                timestamp: timestamp
            )
        case "token_count":
            guard let usage = tokenUsage(from: payload) else { return nil }
            return signal(nil, nil, tokenUsage: usage, timestamp: timestamp)
        case "sub_agent_activity":
            guard trackedSubagentID == nil,
                  let childID = payload["agent_thread_id"] as? String,
                  let childPath = payload["agent_path"] as? String else {
                return nil
            }
            return CodexRolloutSignal(
                sessionID: sessionID,
                cwd: cwd,
                lifecycle: .running,
                activity: .thinking,
                subagentID: childID,
                subagentPath: childPath,
                timestamp: Self.millisecondDate(payload["occurred_at_ms"]) ?? timestamp
            )
        case "exec_command_begin", "terminal_interaction":
            return signal(
                .running,
                .executing,
                latestStep: commandSummary(payload),
                timestamp: timestamp
            )
        case "patch_apply_begin", "patch_apply_updated":
            return signal(.running, .editing, latestStep: "apply_patch", timestamp: timestamp)
        case "mcp_tool_call_begin", "dynamic_tool_call_request":
            return signal(
                .running,
                .executing,
                latestStep: toolSummary(payload),
                timestamp: timestamp
            )
        case "web_search_begin", "web_search_end":
            return signal(
                .running,
                .browsing,
                latestStep: prefixed("Web", clipped(payload["query"] as? String)),
                timestamp: timestamp
            )
        case "image_generation_begin", "image_generation_end",
             "view_image_tool_call":
            return signal(.running, .reading, latestStep: "Image", timestamp: timestamp)
        case "plan_update":
            return signal(.running, .thinking, latestStep: "更新计划", timestamp: timestamp)
        case "exec_command_end", "patch_apply_end", "mcp_tool_call_end",
             "dynamic_tool_call_response":
            return signal(.running, .thinking, timestamp: timestamp)
        case "request_user_input", "elicitation_request":
            return signal(
                .waitingAnswer,
                .thinking,
                kind: .question,
                summary: clipped(payload["prompt"] as? String)
                    ?? clipped(payload["message"] as? String),
                timestamp: timestamp
            )
        case "exec_approval_request", "apply_patch_approval_request",
             "request_permissions":
            return signal(
                .waitingApproval,
                .executing,
                kind: .approval,
                summary: clipped(payload["reason"] as? String)
                    ?? clipped(payload["message"] as? String),
                timestamp: timestamp
            )
        default:
            return nil
        }

        func signal(
            _ lifecycle: AgentLifecycle?,
            _ activity: AgentActivity?,
            kind: PendingRequestKind? = nil,
            summary: String? = nil,
            userPrompt: String? = nil,
            latestStep: String? = nil,
            tokenUsage: TokenUsage? = nil,
            timestamp: Date
        ) -> CodexRolloutSignal {
            CodexRolloutSignal(
                sessionID: sessionID,
                cwd: cwd,
                lifecycle: lifecycle,
                activity: activity,
                requestKind: kind,
                summary: summary,
                userPrompt: userPrompt,
                latestStep: latestStep,
                tokenUsage: tokenUsage,
                subagentID: trackedSubagentID,
                subagentPath: trackedSubagentPath,
                timestamp: timestamp
            )
        }
    }

    private static func responseItemSignal(
        type: String,
        payload: [String: Any],
        sessionID: String,
        cwd: String,
        subagentID: String?,
        subagentPath: String?,
        timestamp: Date
    ) -> CodexRolloutSignal? {
        guard ["function_call", "custom_tool_call", "tool_search_call"].contains(type) else {
            return nil
        }
        let name = payload["name"] as? String
            ?? (type == "tool_search_call" ? "tool_search" : nil)
        let rawArguments = payload["arguments"] as? String
            ?? payload["input"] as? String
        let nestedNames = ToolStepSanitizer.isExecScriptTool(name)
            ? ToolStepSanitizer.nestedToolNames(in: rawArguments ?? "")
            : []
        let effectiveNames = nestedNames.isEmpty ? [name].compactMap { $0 } : nestedNames
        let detail = argumentSummary(rawArguments, toolName: name)

        if effectiveNames.contains(where: { toolLeaf($0) == "request_user_input" }) {
            return CodexRolloutSignal(
                sessionID: sessionID,
                cwd: cwd,
                lifecycle: .waitingAnswer,
                activity: .thinking,
                requestKind: .question,
                summary: requestSummary(rawArguments) ?? detail,
                subagentID: subagentID,
                subagentPath: subagentPath,
                timestamp: timestamp
            )
        }
        let requestsSandboxApproval = effectiveNames.contains(where: {
            CodexEventReducer.isCommandTool($0)
        }) && ToolStepSanitizer.javascriptStringArgument(
            named: "sandbox_permissions",
            in: rawArguments ?? ""
        )?.lowercased() == "require_escalated"
        if effectiveNames.contains(where: { toolLeaf($0) == "request_permissions" })
            || requestsSandboxApproval {
            return CodexRolloutSignal(
                sessionID: sessionID,
                cwd: cwd,
                lifecycle: .waitingApproval,
                activity: .executing,
                requestKind: .approval,
                summary: requestSummary(rawArguments) ?? detail,
                subagentID: subagentID,
                subagentPath: subagentPath,
                timestamp: timestamp
            )
        }

        let effectiveName = preferredToolName(effectiveNames) ?? name
        let step = CodexEventReducer.latestStep(toolName: effectiveName, summary: detail)
        let activity = activity(
            toolNames: effectiveNames,
            summary: detail
        )
        return CodexRolloutSignal(
            sessionID: sessionID,
            cwd: cwd,
            lifecycle: .running,
            activity: activity,
            latestStep: step,
            subagentID: subagentID,
            subagentPath: subagentPath,
            timestamp: timestamp
        )
    }

    private static func argumentSummary(_ raw: String?, toolName: String?) -> String? {
        guard let raw else {
            return nil
        }
        if ToolStepSanitizer.isApplyPatchTool(toolName) {
            // 补丁协议头和具体差异不适合作为状态摘要，只展示首个修改目标。
            return ToolStepSanitizer.patchTargetSummary(raw)
        }
        if ToolStepSanitizer.isExecScriptTool(toolName) {
            // exec 的输入是 JavaScript 包装代码，展示时只保留内部工具真正收到的参数。
            let nestedNames = ToolStepSanitizer.nestedToolNames(in: raw)
            if nestedNames.contains(where: ToolStepSanitizer.isApplyPatchTool) {
                return ToolStepSanitizer.patchTargetSummary(raw)
            }
            for key in ["cmd", "command", "query", "q", "path", "ref_id", "step"] {
                if let value = ToolStepSanitizer.javascriptStringArgument(
                    named: key,
                    in: raw
                ) {
                    return clipped(value)
                }
            }
        }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return clipped(raw)
        }
        if let dictionary = object as? [String: Any] {
            for key in ["cmd", "command", "query", "path", "ref_id", "step"] {
                if let value = displayValue(dictionary[key]) {
                    return clipped(value)
                }
            }
            if toolName?.contains("apply_patch") == true {
                return nil
            }
            return dictionary
                .sorted { $0.key < $1.key }
                .compactMap { displayValue($0.value) }
                .first
                .flatMap { clipped($0) }
        }
        return displayValue(object).flatMap { clipped($0) }
    }

    private static func preferredToolName(_ names: [String]) -> String? {
        names.first { CodexEventReducer.activity(for: $0) == .testing }
            ?? names.first { CodexEventReducer.activity(for: $0) == .editing }
            ?? names.first {
                [.reading, .searching, .browsing].contains(
                    CodexEventReducer.activity(for: $0)
                )
            }
            ?? names.first
    }

    private static func activity(
        toolNames: [String],
        summary: String?
    ) -> AgentActivity {
        if toolNames.contains(where: { CodexEventReducer.activity(for: $0) == .testing })
            || toolNames.contains(where: CodexEventReducer.isCommandTool)
                && ToolStepSanitizer.isTestCommand(summary) {
            return .testing
        }
        let effectiveName = preferredToolName(toolNames)
        return CodexEventReducer.activity(for: effectiveName)
    }

    private static func toolLeaf(_ name: String) -> String {
        name.split(separator: ".").last.map(String.init)?.lowercased()
            ?? name.lowercased()
    }

    private static func requestSummary(_ raw: String?) -> String? {
        guard let raw else { return nil }
        for key in ["question", "prompt", "message", "reason", "justification"] {
            if let value = ToolStepSanitizer.javascriptStringArgument(named: key, in: raw) {
                return clipped(value)
            }
        }
        guard let data = raw.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return nil
        }
        for key in ["question", "prompt", "message", "reason", "justification"] {
            if let value = displayValue(dictionary[key]) {
                return clipped(value)
            }
        }
        if let questions = dictionary["questions"] as? [[String: Any]],
           let first = questions.first,
           let value = displayValue(first["question"]) {
            return clipped(value)
        }
        return nil
    }

    private static func commandSummary(_ payload: [String: Any]) -> String? {
        let command = displayValue(payload["command"])
            ?? displayValue(payload["cmd"])
        return clipped(command)
    }

    private static func toolSummary(_ payload: [String: Any]) -> String? {
        let name = payload["tool_name"] as? String
            ?? payload["name"] as? String
            ?? payload["app_name"] as? String
        let detail = clipped(payload["reason"] as? String)
            ?? clipped(payload["message"] as? String)
        return CodexEventReducer.latestStep(toolName: name, summary: detail)
    }

    private static func tokenUsage(from payload: [String: Any]) -> TokenUsage? {
        guard let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any] else {
            return nil
        }
        return TokenUsage(
            input: integer(total["input_tokens"]),
            cachedInput: integer(total["cached_input_tokens"]),
            output: integer(total["output_tokens"]),
            reasoningOutput: integer(total["reasoning_output_tokens"]),
            total: integer(total["total_tokens"])
        )
    }

    private static func integer(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }

    private static func displayValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let strings as [String]:
            return strings.joined(separator: " ")
        case let values as [Any]:
            return values.compactMap(displayValue).joined(separator: " ")
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func prefixed(_ prefix: String?, _ detail: String?) -> String? {
        switch (clipped(prefix, limit: 60), clipped(detail)) {
        case let (prefix?, detail?): return "\(prefix) \(detail)"
        case let (prefix?, nil): return prefix
        case let (nil, detail?): return detail
        case (nil, nil): return nil
        }
    }

    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func millisecondDate(_ value: Any?) -> Date? {
        guard let milliseconds = value as? NSNumber else {
            return nil
        }
        return Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
    }

    private static func sessionMetadata(
        at fileURL: URL
    ) -> (sessionID: String, cwd: String)? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        guard let prefix = try? handle.read(upToCount: 1_024 * 1_024),
              let newline = prefix.firstIndex(of: UInt8(ascii: "\n")),
              let root = try? JSONSerialization.jsonObject(
                  with: Data(prefix[..<newline])
              ) as? [String: Any],
              root["type"] as? String == "session_meta",
              let payload = root["payload"] as? [String: Any],
              (payload["source"] as? [String: Any])?["subagent"] == nil,
              let sessionID = payload["id"] as? String
                  ?? payload["session_id"] as? String,
              !sessionID.isEmpty,
              let cwd = payload["cwd"] as? String,
              !cwd.isEmpty else {
            return nil
        }
        return (sessionID, cwd)
    }

    private static func findRolloutFile(
        sessionID: String,
        near directory: URL
    ) -> URL? {
        let fileManager = FileManager.default
        if let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ), let match = files.first(where: {
            $0.lastPathComponent.contains(sessionID) && $0.pathExtension == "jsonl"
        }) {
            return match
        }

        let root = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let fileURL as URL in enumerator
        where fileURL.lastPathComponent.contains(sessionID)
            && fileURL.pathExtension == "jsonl" {
            return fileURL
        }
        return nil
    }

    private static func fileSize(at url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func clipped(_ value: String?, limit: Int = 220) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(limit))
    }
}
