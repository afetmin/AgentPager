import Foundation

/// Claude Code statusLine 载荷里的订阅额度窗口（`rate_limits`）。
///
/// Claude Code 只在 statusLine 命令的 stdin 里提供额度百分比，不写入会话日志；
/// AgentPager 的 `--claude-statusline` 命令把它落盘到这里，Bridge 再读取。
public struct ClaudeRateLimitCapture: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var usedPercentage: Double
        public var resetsAt: Date?

        public init(usedPercentage: Double, resetsAt: Date?) {
            self.usedPercentage = usedPercentage
            self.resetsAt = resetsAt
        }
    }

    public var capturedAt: Date
    public var fiveHour: Window?
    public var sevenDay: Window?

    public init(capturedAt: Date, fiveHour: Window?, sevenDay: Window?) {
        self.capturedAt = capturedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// 从 statusLine stdin JSON 提取额度；没有 `rate_limits`（API 计费或首次响应前）返回 nil。
    public static func parse(statusLineInput: Data, now: Date = .now) -> ClaudeRateLimitCapture? {
        guard let root = (try? JSONSerialization.jsonObject(with: statusLineInput))
                as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else {
            return nil
        }
        let fiveHour = window(limits["five_hour"])
        let sevenDay = window(limits["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return ClaudeRateLimitCapture(capturedAt: now, fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func window(_ value: Any?) -> Window? {
        guard let payload = value as? [String: Any],
              let used = (payload["used_percentage"] as? NSNumber)?.doubleValue
                ?? (payload["used_percentage"] as? String).flatMap(Double.init),
              used.isFinite else {
            return nil
        }
        let resets = (payload["resets_at"] as? NSNumber)?.doubleValue
            ?? (payload["resets_at"] as? String).flatMap(Double.init)
        return Window(
            usedPercentage: min(max(used, 0), 100),
            resetsAt: resets.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

/// 额度捕获文件的读写（`Application Support/AgentGrid/claude-rate-limits.json`）。
public enum ClaudeRateLimitStore {
    public static var defaultURL: URL {
        // 允许用环境变量改写落盘位置，便于端到端验证而不污染真实数据。
        if let override = ProcessInfo.processInfo.environment["AGENTPAGER_CLAUDE_RATE_LIMIT_FILE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return TaskSnapshotPersistence.defaultDirectory
            .appendingPathComponent("claude-rate-limits.json")
    }

    /// 记录一次 statusLine 载荷。载荷没有额度字段时保留旧文件，避免用空值覆盖。
    @discardableResult
    public static func record(
        statusLineInput: Data,
        now: Date = .now,
        to url: URL = defaultURL
    ) -> Bool {
        guard let capture = ClaudeRateLimitCapture.parse(statusLineInput: statusLineInput, now: now) else {
            return false
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(capture) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public static func load(from url: URL = defaultURL) -> ClaudeRateLimitCapture? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ClaudeRateLimitCapture.self, from: data)
    }
}

/// 汇总 Claude Code 的额度窗口与近期 Token 用量，输出与 Codex 相同的 `UsageSnapshot`。
public enum ClaudeUsageLoader {
    public static let historyDayCount = CodexUsageLoader.historyDayCount

    private static let fiveHourMinutes = 300
    private static let sevenDayMinutes = 10_080

    public static func load(
        projectsURL: URL = ClaudeConfigDirectory.resolved()
            .appendingPathComponent("projects", isDirectory: true),
        captureURL: URL = ClaudeRateLimitStore.defaultURL,
        fileManager: FileManager = .default,
        now: Date = .now,
        calendar: Calendar = .current,
        remoteCapture: (@Sendable (Date) -> ClaudeRateLimitCapture?)? = nil
    ) -> UsageSnapshot? {
        // statusLine 与 OAuth 查询取较新的一份。
        let capture = [
            ClaudeRateLimitStore.load(from: captureURL),
            remoteCapture?(now),
        ].compactMap { $0 }.max { $0.capturedAt < $1.capturedAt }
        let windows = windows(from: capture, now: now)
        let dailyUsage = ClaudeTranscriptUsageScanner.shared.dailyUsage(
            projectsURL: projectsURL,
            fileManager: fileManager,
            now: now,
            calendar: calendar
        )
        let hasUsage = dailyUsage.contains { $0.totalTokens > 0 }
        guard !windows.isEmpty || hasUsage else { return nil }

        return UsageSnapshot(
            capturedAt: capture?.capturedAt ?? now,
            planType: nil,
            limitID: "claude",
            windows: windows,
            dailyUsage: hasUsage ? dailyUsage : []
        )
    }

    /// 已过 `resets_at` 的窗口不再可信（额度已刷新但还没有新载荷），直接丢弃而不是显示旧百分比。
    static func windows(from capture: ClaudeRateLimitCapture?, now: Date) -> [UsageWindow] {
        guard let capture else { return [] }
        func make(
            key: String,
            label: String,
            minutes: Int,
            window: ClaudeRateLimitCapture.Window?
        ) -> UsageWindow? {
            guard let window else { return nil }
            if let resetsAt = window.resetsAt, resetsAt <= now { return nil }
            return UsageWindow(
                key: key,
                label: label,
                usedPercentage: window.usedPercentage,
                remainingPercentage: max(0, 100 - window.usedPercentage),
                windowMinutes: minutes,
                resetsAt: window.resetsAt
            )
        }
        return [
            make(key: "primary", label: "5h", minutes: fiveHourMinutes, window: capture.fiveHour),
            make(key: "secondary", label: "7d", minutes: sevenDayMinutes, window: capture.sevenDay),
        ].compactMap { $0 }
    }
}

/// 扫描 `~/.claude/projects/**/*.jsonl` 的 assistant 用量并按本地日期聚合。
///
/// 同一条 assistant 消息会被流式写成多行（相同 `message.id`），只取每个消息的最后一条。
/// 按文件的 (修改时间, 大小) 缓存每日桶，周期刷新时只重解析变化的文件。
final class ClaudeTranscriptUsageScanner: @unchecked Sendable {
    static let shared = ClaudeTranscriptUsageScanner()

    private struct Bucket {
        var input: Int64 = 0
        var cacheCreation: Int64 = 0
        var cacheRead: Int64 = 0
        var output: Int64 = 0

        var total: Int64 { input + cacheCreation + cacheRead + output }

        static func + (lhs: Bucket, rhs: Bucket) -> Bucket {
            Bucket(
                input: lhs.input + rhs.input,
                cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
                cacheRead: lhs.cacheRead + rhs.cacheRead,
                output: lhs.output + rhs.output
            )
        }
    }

    private struct FileEntry {
        var modifiedAt: Date
        var size: Int
        var timeZoneID: String
        var days: [String: Bucket]
    }

    private let lock = NSLock()
    private var cache: [String: FileEntry] = [:]

    func dailyUsage(
        projectsURL: URL,
        fileManager: FileManager,
        now: Date,
        calendar: Calendar
    ) -> [DailyUsagePoint] {
        let startOfToday = calendar.startOfDay(for: now)
        let days = ClaudeUsageLoader.historyDayCount
        guard let historyStart = calendar.date(
            byAdding: .day,
            value: -(days - 1),
            to: startOfToday
        ) else {
            return []
        }
        let formatter = Self.dayFormatter(calendar: calendar)

        var totals: [String: Bucket] = [:]
        var seenPaths = Set<String>()
        for fileURL in transcriptFiles(under: projectsURL, fileManager: fileManager) {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            ),
            let modifiedAt = values.contentModificationDate,
            modifiedAt >= historyStart else {
                continue
            }
            let size = values.fileSize ?? 0
            let path = fileURL.standardizedFileURL.path
            seenPaths.insert(path)

            let entry = cachedEntry(
                path: path,
                modifiedAt: modifiedAt,
                size: size,
                timeZoneID: calendar.timeZone.identifier
            ) ?? {
                let parsed = FileEntry(
                    modifiedAt: modifiedAt,
                    size: size,
                    timeZoneID: calendar.timeZone.identifier,
                    days: parse(fileURL, historyStart: historyStart, calendar: calendar, formatter: formatter)
                )
                store(parsed, for: path)
                return parsed
            }()
            for (day, bucket) in entry.days {
                totals[day] = (totals[day] ?? Bucket()) + bucket
            }
        }
        prune(keeping: seenPaths)

        return (0..<days).compactMap { offset in
            guard let day = calendar.date(
                byAdding: .day,
                value: offset - (days - 1),
                to: startOfToday
            ) else {
                return nil
            }
            let key = formatter.string(from: day)
            let bucket = totals[key] ?? Bucket()
            return DailyUsagePoint(
                date: key,
                inputTokens: bucket.input + bucket.cacheCreation + bucket.cacheRead,
                cachedInputTokens: bucket.cacheRead,
                outputTokens: bucket.output,
                totalTokens: bucket.total
            )
        }
    }

    private func cachedEntry(
        path: String,
        modifiedAt: Date,
        size: Int,
        timeZoneID: String
    ) -> FileEntry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[path],
              entry.modifiedAt == modifiedAt,
              entry.size == size,
              entry.timeZoneID == timeZoneID else {
            return nil
        }
        return entry
    }

    private func store(_ entry: FileEntry, for path: String) {
        lock.lock()
        cache[path] = entry
        lock.unlock()
    }

    private func prune(keeping paths: Set<String>) {
        lock.lock()
        cache = cache.filter { paths.contains($0.key) }
        lock.unlock()
    }

    private func transcriptFiles(under root: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            result.append(url)
        }
        return result
    }

    private func parse(
        _ fileURL: URL,
        historyStart: Date,
        calendar: Calendar,
        formatter: DateFormatter
    ) -> [String: Bucket] {
        // 同一 message.id 的多行快照取最后一条（流式输出里 usage 单调递增）。
        var latestByMessage: [String: (timestamp: Date, usage: Bucket)] = [:]
        var anonymous: [(timestamp: Date, usage: Bucket)] = []

        Self.forEachLine(in: fileURL) { line in
            guard line.contains("\"usage\""),
                  line.contains("\"assistant\""),
                  let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let timestamp = Self.parseTimestamp(object["timestamp"]) else {
                return
            }
            let bucket = Bucket(
                input: Self.int64(usage["input_tokens"]),
                cacheCreation: Self.int64(usage["cache_creation_input_tokens"]),
                cacheRead: Self.int64(usage["cache_read_input_tokens"]),
                output: Self.int64(usage["output_tokens"])
            )
            guard bucket.total > 0 else { return }
            if let id = message["id"] as? String {
                latestByMessage[id] = (timestamp, bucket)
            } else {
                anonymous.append((timestamp, bucket))
            }
        }

        var days: [String: Bucket] = [:]
        for entry in Array(latestByMessage.values) + anonymous where entry.timestamp >= historyStart {
            let key = formatter.string(from: calendar.startOfDay(for: entry.timestamp))
            days[key] = (days[key] ?? Bucket()) + entry.usage
        }
        return days
    }

    private static func forEachLine(in fileURL: URL, body: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }

        var pending = Data()
        while let chunk = try? handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
            pending.append(chunk)
            var lineStart = pending.startIndex
            while let lineEnd = pending[lineStart...].firstIndex(of: 0x0A) {
                if let line = String(data: pending[lineStart..<lineEnd], encoding: .utf8) {
                    body(line)
                }
                lineStart = pending.index(after: lineEnd)
            }
            if lineStart > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<lineStart)
            }
        }
        if !pending.isEmpty, let line = String(data: pending, encoding: .utf8) {
            body(line)
        }
    }

    private static func dayFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return max(0, number.int64Value) }
        return 0
    }
}
