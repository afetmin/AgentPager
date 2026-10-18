import Foundation
import Network

/// 桥接服务器收到并已分类的 Hook 事件。
public enum HookEnvelope: Sendable {
    case codex(CodexHookPayload)
    case claude(ClaudeHookPayload)
    case permissionExpired(sessionID: String)
}

public final class HookBridgeServer: CodexPermissionResolving, @unchecked Sendable {
    public typealias EventHandler = @Sendable (HookEnvelope) -> Void

    private let queue = DispatchQueue(label: "com.agentgrid.hook-server")
    private var listener: NWListener?
    /// 等待手机端裁决的权限连接，按会话 ID 索引并携带来源以选择响应格式。
    private struct PendingApproval: @unchecked Sendable {
        var connection: NWConnection
        var source: HookSource
    }
    private let pending = PendingValueRegistry<PendingApproval>()
    private let eventHandler: EventHandler
    private let approvalTimeout: TimeInterval

    public init(
        approvalTimeout: TimeInterval = 30 * 60,
        eventHandler: @escaping EventHandler
    ) {
        self.approvalTimeout = approvalTimeout
        self.eventHandler = eventHandler
    }

    public func start(port: UInt16 = 49_361) throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        let listener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(rawValue: port)!
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for entry in pending.removeAll() {
            entry.value.connection.cancel()
        }
    }

    public func resolve(sessionID: String, decision: CodexPermissionDecision) throws {
        let entry = pending.removeValue(forKey: sessionID)
        guard let entry else { throw PermissionResolutionError.expired }
        let response: Data?
        switch entry.value.source {
        case .codex:
            response = try? CodexHookOutput.permission(decision)
        case .claude:
            let claudeDecision: ClaudePermissionDecision = decision == .allow ? .allow : .deny
            response = try? ClaudeHookOutput.permission(claudeDecision)
        }
        guard let response else {
            entry.value.connection.cancel()
            throw PermissionResolutionError.expired
        }
        entry.value.connection.send(content: response, completion: .contentProcessed { _ in
            entry.value.connection.cancel()
        })
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case let .failed(error) = state {
                fputs("AgentPager Hook 连接错误：\(error)\n", stderr)
                connection?.cancel()
            }
            if case .failed = state {
                if let connection { self?.discardPending(connection) }
            } else if case .cancelled = state, let connection {
                self?.discardPending(connection)
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let newline = nextBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let payloadData = nextBuffer.prefix(upTo: newline)
                self.handle(Data(payloadData), connection: connection)
                return
            }

            if isComplete || error != nil || nextBuffer.count > 1_048_576 {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: nextBuffer)
        }
    }

    private func handle(_ data: Data, connection: NWConnection) {
        let envelope = decodeEnvelope(data)

        switch envelope {
        case let .codex(payload):
            // Codex 走原有路径；旧版 CLI 未带信封时也落到这里。
            if payload.hookEventName == .stop {
                finishPending(sessionID: payload.sessionID)
            }
            eventHandler(.codex(payload))
            if payload.hookEventName == .permissionRequest {
                holdForApproval(
                    sessionID: payload.sessionID,
                    source: .codex,
                    connection: connection
                )
            } else {
                acknowledge(connection)
            }
        case let .claude(payload):
            if let event = payload.event, [.stop, .sessionEnd, .permissionDenied].contains(event) {
                finishPending(sessionID: payload.sessionID)
            }
            eventHandler(.claude(payload))
            if payload.event == .permissionRequest {
                holdForApproval(
                    sessionID: payload.sessionID,
                    source: .claude,
                    connection: connection
                )
            } else {
                acknowledge(connection)
            }
        case .permissionExpired:
            // 该事件只由服务器内部定时器生成，不存在对应的线缆载荷。
            acknowledge(connection)
        case nil:
            // 无法识别来源时按 Codex 兼容旧 CLI；解析失败则放行不阻塞。
            if let payload = try? JSONDecoder().decode(CodexHookPayload.self, from: data) {
                if payload.hookEventName == .stop {
                    finishPending(sessionID: payload.sessionID)
                }
                eventHandler(.codex(payload))
                if payload.hookEventName == .permissionRequest {
                    holdForApproval(
                        sessionID: payload.sessionID,
                        source: .codex,
                        connection: connection
                    )
                } else {
                    acknowledge(connection)
                }
            } else {
                connection.cancel()
            }
        }
    }

    private func holdForApproval(
        sessionID: String,
        source: HookSource,
        connection: NWConnection
    ) {
        let id = UUID()
        let displaced = pending.replaceValue(
            PendingApproval(connection: connection, source: source),
            forKey: sessionID,
            id: id
        )
        if let displaced {
            // 手机协议目前按任务而不是按单次工具调用审批。若同一会话并发
            // 发出第二个请求，让旧请求回退到 Codex 本地审批，避免连接被
            // 覆盖后一直挂到一小时超时；手机保留并展示最新请求。
            acknowledge(displaced.value.connection)
        }
        queue.asyncAfter(deadline: .now() + approvalTimeout) { [weak self] in
            self?.expireApproval(sessionID: sessionID, id: id)
        }
    }

    private func expireApproval(sessionID: String, id: UUID) {
        guard let entry = pending.removeValue(forKey: sessionID, matching: id) else {
            return
        }
        // 超时后返回空响应，让 Claude 回到本机审批而不是保留一个无限期
        // AgentPagerHooks 进程；同时清除手机上的等待状态。
        acknowledge(entry.value.connection)
        eventHandler(.permissionExpired(sessionID: sessionID))
    }

    private func finishPending(sessionID: String) {
        guard let entry = pending.removeValue(forKey: sessionID) else { return }
        acknowledge(entry.value.connection)
    }

    private func discardPending(_ connection: NWConnection) {
        _ = pending.removeAll { entry in
            entry.value.connection === connection
        }
    }

    private func acknowledge(_ connection: NWConnection) {
        // 空行不作阻断性决定；用于被替换的 PermissionRequest 时，
        // Codex 会回退到正常的本地审批流程。
        connection.send(content: Data("\n".utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func decodeEnvelope(_ data: Data) -> HookEnvelope? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawSource = object["hook_source"] as? String,
              let source = HookSource(rawValue: rawSource),
              let payloadObject = object["payload"] else {
            return nil
        }

        let payloadData = try? JSONSerialization.data(withJSONObject: payloadObject)
        switch source {
        case .codex:
            if let payloadData,
               let payload = try? JSONDecoder().decode(CodexHookPayload.self, from: payloadData) {
                return .codex(payload)
            }
            return nil
        case .claude:
            if let payloadData,
               let payload = try? JSONDecoder().decode(ClaudeHookPayload.self, from: payloadData) {
                return .claude(payload)
            }
            return nil
        }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        return ["127.0.0.1", "::1", "localhost"].contains("\(host)".lowercased())
    }
}

enum PermissionResolutionError: LocalizedError {
    case expired

    var errorDescription: String? {
        "审批连接已结束，请在电脑上处理当前请求"
    }
}

/// 线程安全的“每个会话只保留最新请求”容器。ID 让延迟超时回调不会误删
/// 同一会话中更新的请求，也便于对替换/清理规则做无网络单元测试。
final class PendingValueRegistry<Value: Sendable>: @unchecked Sendable {
    struct Entry: Sendable {
        var id: UUID
        var value: Value
    }

    private let lock = NSLock()
    private var storage: [String: Entry] = [:]

    var count: Int {
        lock.withLock { storage.count }
    }

    @discardableResult
    func replaceValue(
        _ value: Value,
        forKey key: String,
        id: UUID = UUID()
    ) -> Entry? {
        lock.withLock {
            storage.updateValue(Entry(id: id, value: value), forKey: key)
        }
    }

    func removeValue(forKey key: String) -> Entry? {
        lock.withLock { storage.removeValue(forKey: key) }
    }

    func removeValue(forKey key: String, matching id: UUID) -> Entry? {
        lock.withLock {
            guard storage[key]?.id == id else { return nil }
            return storage.removeValue(forKey: key)
        }
    }

    func removeAll() -> [Entry] {
        lock.withLock {
            defer { storage.removeAll() }
            return Array(storage.values)
        }
    }

    func removeAll(where predicate: (Entry) -> Bool) -> [Entry] {
        lock.withLock {
            let keys = storage.compactMap { predicate($0.value) ? $0.key : nil }
            return keys.compactMap { storage.removeValue(forKey: $0) }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
