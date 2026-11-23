import Foundation

/// 通过 Claude Code 自己的登录凭据查询订阅额度（供没有 statusLine 的场景使用，例如 Claude Desktop）。
///
/// 风险与约束：
/// - 凭据取自钥匙串项 `Claude Code-credentials`（或 `~/.claude/.credentials.json`），
///   首次读取时 macOS 会弹出钥匙串授权；令牌只留在内存，不写盘、不记录日志、不发往手机。
/// - 令牌只发送到 `https://api.anthropic.com/api/oauth/usage` 这一个固定地址，只读额度。
/// - 这是 Claude Code 的非公开接口，可能随版本变化；任何失败都静默回退到 statusLine 捕获。
/// - 最短 120 秒查询一次；遇到 401/403/429 会退避，避免打扰账号。
public enum ClaudeOAuthUsage {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let enabledDefaultsKey = "AgentPager.ClaudeOAuthQuotaEnabled"
    static let minimumInterval: TimeInterval = 120
    static let backoffInterval: TimeInterval = 900

    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledDefaultsKey) }
    }

    // MARK: 解析（纯函数，便于测试）

    /// 从钥匙串/凭据文件的 JSON 中取 OAuth 访问令牌，并忽略已过期的令牌。
    public static func accessToken(fromCredentials data: Data, now: Date = .now) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let oauth = root["claudeAiOauth"] as? [String: Any] ?? root
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            // Claude Code 以毫秒保存过期时间。
            let seconds = expiresAt > 1e12 ? expiresAt / 1_000 : expiresAt
            if Date(timeIntervalSince1970: seconds) <= now { return nil }
        }
        return token
    }

    /// 解析 `/api/oauth/usage` 响应：`five_hour` / `seven_day` 的 `utilization`（0–100）与 `resets_at`（ISO 8601）。
    public static func parseUsage(_ data: Data, now: Date = .now) -> ClaudeRateLimitCapture? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let fiveHour = window(root["five_hour"])
        let sevenDay = window(root["seven_day"])
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return ClaudeRateLimitCapture(capturedAt: now, fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func window(_ value: Any?) -> ClaudeRateLimitCapture.Window? {
        guard let payload = value as? [String: Any],
              let used = (payload["utilization"] as? NSNumber)?.doubleValue
                ?? (payload["utilization"] as? String).flatMap(Double.init),
              used.isFinite else {
            return nil
        }
        var resetsAt: Date?
        if let string = payload["resets_at"] as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetsAt = fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        } else if let seconds = (payload["resets_at"] as? NSNumber)?.doubleValue {
            resetsAt = Date(timeIntervalSince1970: seconds)
        }
        return .init(usedPercentage: min(max(used, 0), 100), resetsAt: resetsAt)
    }

    // MARK: 查询（带缓存与退避）

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var token: String?
        var lastAttempt = Date.distantPast
        var nextAllowed = Date.distantPast
        var lastCapture: ClaudeRateLimitCapture?
    }
    private static let state = State()

    /// 返回最近一次成功的额度；节流期内直接返回缓存。阻塞调用，应在后台线程使用。
    public static func currentCapture(now: Date = .now) -> ClaudeRateLimitCapture? {
        guard isEnabled else { return nil }
        let state = Self.state
        state.lock.lock()
        if now < state.nextAllowed {
            let cached = state.lastCapture
            state.lock.unlock()
            return cached
        }
        state.nextAllowed = now.addingTimeInterval(minimumInterval)
        var token = state.token
        state.lock.unlock()

        if token == nil { token = readToken(now: now) }
        guard let token else {
            // 没有凭据：长时间不再尝试，避免反复触发钥匙串弹窗。
            state.lock.lock()
            state.nextAllowed = now.addingTimeInterval(backoffInterval)
            state.lock.unlock()
            return nil
        }

        let (data, status) = request(token: token)
        state.lock.lock()
        defer { state.lock.unlock() }
        switch status {
        case 200:
            state.token = token
            if let data, let capture = parseUsage(data, now: now) {
                state.lastCapture = capture
            }
        case 401, 403:
            state.token = nil
            state.nextAllowed = now.addingTimeInterval(backoffInterval)
        case 429:
            state.nextAllowed = now.addingTimeInterval(backoffInterval)
        default:
            break
        }
        return state.lastCapture
    }

    private static func readToken(now: Date) -> String? {
        if let data = runSecurity(), let token = accessToken(fromCredentials: data, now: now) {
            return token
        }
        let file = ClaudeConfigDirectory.resolved().appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file) {
            return accessToken(fromCredentials: data, now: now)
        }
        return nil
    }

    /// 读取钥匙串里的 Claude Code 凭据；等待用户授权弹窗最多 20 秒。
    private static func runSecurity() -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func request(token: String) -> (Data?, Int) {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Data?, Int) = (nil, 0)
        let task = URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            result = (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 15) == .timedOut {
            task.cancel()
            return (nil, 0)
        }
        return result
    }
}
