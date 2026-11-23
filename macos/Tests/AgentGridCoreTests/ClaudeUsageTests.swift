import Foundation
import Testing
@testable import AgentGridCore

private let statusLineInput = Data(
    """
    {"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1785067200},"seven_day":{"used_percentage":41.2,"resets_at":1785672000}}}
    """.utf8
)

@Test("statusLine 载荷解析 5 小时与 7 天额度")
func claudeRateLimitParsesBothWindows() throws {
    let now = Date(timeIntervalSince1970: 1_785_000_000)
    let capture = try #require(
        ClaudeRateLimitCapture.parse(statusLineInput: statusLineInput, now: now)
    )
    #expect(capture.fiveHour?.usedPercentage == 23.5)
    #expect(capture.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_785_067_200))
    #expect(capture.sevenDay?.usedPercentage == 41.2)
}

@Test("没有 rate_limits 的载荷不产生捕获，也不覆盖已有文件")
func claudeRateLimitIgnoresPayloadWithoutLimits() throws {
    #expect(ClaudeRateLimitCapture.parse(statusLineInput: Data("{}".utf8)) == nil)

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("claude-rate-limits.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    #expect(ClaudeRateLimitStore.record(statusLineInput: statusLineInput, to: url))
    #expect(!ClaudeRateLimitStore.record(statusLineInput: Data("{\"a\":1}".utf8), to: url))
    #expect(ClaudeRateLimitStore.load(from: url)?.fiveHour?.usedPercentage == 23.5)
}

@Test("已过重置时间的额度窗口不再展示")
func claudeUsageDropsExpiredWindows() {
    let reset = Date(timeIntervalSince1970: 1_785_067_200)
    let capture = ClaudeRateLimitCapture(
        capturedAt: reset.addingTimeInterval(-600),
        fiveHour: .init(usedPercentage: 90, resetsAt: reset),
        sevenDay: .init(usedPercentage: 10, resetsAt: reset.addingTimeInterval(86_400))
    )
    let before = ClaudeUsageLoader.windows(from: capture, now: reset.addingTimeInterval(-60))
    #expect(before.map(\.key) == ["primary", "secondary"])
    #expect(before[0].remainingPercentage == 10)
    #expect(before.map(\.label) == ["5h", "7d"])

    let after = ClaudeUsageLoader.windows(from: capture, now: reset.addingTimeInterval(60))
    #expect(after.map(\.key) == ["secondary"])
}

@Test("Claude 对话日志按消息去重并按日聚合 Token")
func claudeTranscriptScannerDeduplicatesStreamedMessages() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let project = root.appendingPathComponent("-Users-me-demo", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let lines = [
        #"{"type":"user","timestamp":"2026-07-26T09:00:00.000Z","message":{"role":"user","content":"hi"}}"#,
        // 同一条消息被流式写成两行，只应计一次（取后一行）。
        #"{"type":"assistant","timestamp":"2026-07-26T10:00:00.000Z","message":{"id":"msg_1","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":400,"output_tokens":10}}}"#,
        #"{"type":"assistant","timestamp":"2026-07-26T10:00:01.000Z","message":{"id":"msg_1","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":400,"output_tokens":50}}}"#,
        #"{"type":"assistant","timestamp":"2026-07-25T10:00:00.000Z","message":{"id":"msg_2","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":9}}}"#,
    ]
    try Data(lines.joined(separator: "\n").utf8)
        .write(to: project.appendingPathComponent("session.jsonl"))

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-26T12:00:00Z"))
    let captureURL = root.appendingPathComponent("missing.json")

    let snapshot = try #require(
        ClaudeUsageLoader.load(
            projectsURL: root,
            captureURL: captureURL,
            now: now,
            calendar: calendar
        )
    )
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.dailyUsage.count == ClaudeUsageLoader.historyDayCount)
    let today = try #require(snapshot.dailyUsage.last)
    #expect(today.date == "2026-07-26")
    #expect(today.totalTokens == 2 + 100 + 400 + 50)
    #expect(today.cachedInputTokens == 400)
    #expect(today.inputTokens == 502)
    #expect(today.outputTokens == 50)
    #expect(snapshot.dailyUsage[snapshot.dailyUsage.count - 2].totalTokens == 10)
}

@Test("statusLine 安装保留用户原命令并可无损卸载")
func claudeStatusLineChainsAndRestoresOriginal() throws {
    let existing = Data(
        #"{"statusLine":{"type":"command","command":"~/.claude/my-line.sh","padding":2}}"#.utf8
    )
    let binary = "/Applications/AgentPager Bridge.app/Contents/MacOS/AgentPagerHooks"
    let installed = try ClaudeHookInstaller.install(
        existingData: existing,
        command: ClaudeHookInstaller.hookCommand(for: binary),
        statusLineBinaryPath: binary
    )
    #expect(ClaudeHookInstaller.isStatusLineInstalled(data: installed.contents))
    let installedData = try #require(installed.contents)
    let root = try #require(
        JSONSerialization.jsonObject(with: installedData) as? [String: Any]
    )
    let statusLine = try #require(root["statusLine"] as? [String: Any])
    #expect(statusLine["padding"] as? Int == 2)
    let command = try #require(statusLine["command"] as? String)
    #expect(command.contains("--claude-statusline"))
    #expect(
        ClaudeStatusLineInstaller.original(fromCommand: command)?["command"] as? String
            == "~/.claude/my-line.sh"
    )

    // 重复安装不叠加链路，原命令保持不变。
    let again = try ClaudeHookInstaller.install(
        existingData: installed.contents,
        command: ClaudeHookInstaller.hookCommand(for: binary),
        statusLineBinaryPath: binary
    )
    #expect(again.contents == installed.contents)

    let removed = try ClaudeHookInstaller.uninstall(existingData: installed.contents)
    let removedData = try #require(removed.contents)
    let restoredRoot = try #require(
        JSONSerialization.jsonObject(with: removedData) as? [String: Any]
    )
    let restored = try #require(restoredRoot["statusLine"] as? [String: Any])
    #expect(restored["command"] as? String == "~/.claude/my-line.sh")
    #expect(restored["padding"] as? Int == 2)
}

@Test("没有原 statusLine 时卸载会移除 AgentPager 的 statusLine")
func claudeStatusLineUninstallRemovesManagedEntry() throws {
    let binary = "/tmp/AgentPagerHooks"
    let installed = try ClaudeHookInstaller.install(
        existingData: nil,
        command: ClaudeHookInstaller.hookCommand(for: binary),
        statusLineBinaryPath: binary
    )
    #expect(ClaudeHookInstaller.isStatusLineInstalled(data: installed.contents))
    let removed = try ClaudeHookInstaller.uninstall(existingData: installed.contents)
    #expect(removed.contents == nil)
}

@Test("快照协议兼容缺失 claudeUsage 的旧载荷")
func stateSnapshotEncodesClaudeUsageOnlyWhenPresent() throws {
    let usage = UsageSnapshot(
        capturedAt: nil,
        planType: nil,
        limitID: "claude",
        windows: []
    )
    let with = try ProtocolCodec.encode(
        StateSnapshotPayload(tasks: [], usage: nil, claudeUsage: usage, focusedTaskID: nil)
    )
    let without = try ProtocolCodec.encode(
        StateSnapshotPayload(tasks: [], usage: nil, focusedTaskID: nil)
    )
    #expect(String(decoding: with, as: UTF8.self).contains("\"claudeUsage\""))
    #expect(!String(decoding: without, as: UTF8.self).contains("claudeUsage"))
}

@Test("OAuth 用量响应解析 utilization 与 ISO 重置时间")
func claudeOAuthUsageParsesResponse() throws {
    let data = Data(
        #"{"five_hour":{"utilization":37.0,"resets_at":"2026-07-26T15:00:00.123456+00:00"},"seven_day":{"utilization":8,"resets_at":"2026-07-30T00:00:00Z"},"seven_day_opus":null}"#.utf8
    )
    let capture = try #require(ClaudeOAuthUsage.parseUsage(data))
    #expect(capture.fiveHour?.usedPercentage == 37)
    #expect(capture.sevenDay?.usedPercentage == 8)
    #expect(capture.fiveHour?.resetsAt != nil)
    #expect(capture.sevenDay?.resetsAt == ISO8601DateFormatter().date(from: "2026-07-30T00:00:00Z"))
    #expect(ClaudeOAuthUsage.parseUsage(Data("{}".utf8)) == nil)
}

@Test("OAuth 凭据解析取访问令牌并忽略过期令牌")
func claudeOAuthCredentialsParsing() {
    let now = Date(timeIntervalSince1970: 1_785_000_000)
    let valid = Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1785003600000}}"#.utf8)
    let expired = Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1784990000000}}"#.utf8)
    #expect(ClaudeOAuthUsage.accessToken(fromCredentials: valid, now: now) == "tok")
    #expect(ClaudeOAuthUsage.accessToken(fromCredentials: expired, now: now) == nil)
    #expect(ClaudeOAuthUsage.accessToken(fromCredentials: Data("x".utf8), now: now) == nil)
}
