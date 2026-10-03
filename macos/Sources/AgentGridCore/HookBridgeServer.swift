import Foundation
import Network

/// 桥接服务器收到并已分类的 Hook 事件。
public enum HookEnvelope: Sendable {
    case codex(CodexHookPayload)
    case claude(ClaudeHookPayload)
}

public final class HookBridgeServer: CodexPermissionResolving, @unchecked Sendable {
    public typealias EventHandler = @Sendable (HookEnvelope) -> Void

    private let queue = DispatchQueue(label: "com.agentgrid.hook-server")
    private let lock = NSLock()
    private var listener: NWListener?
    /// 等待手机端裁决的权限连接，按会话 ID 索引并携带来源以选择响应格式。
    private var pending: [String: (connection: NWConnection, source: HookSource)] = [:]
    private let eventHandler: EventHandler

    public init(eventHandler: @escaping EventHandler) {
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
        lock.withLock {
            pending.values.forEach { $0.connection.cancel() }
            pending.removeAll()
        }
    }

    public func resolve(sessionID: String, decision: CodexPermissionDecision) {
        let entry = lock.withLock { pending.removeValue(forKey: sessionID) }
        guard let entry else { return }
        let response: Data?
        switch entry.source {
        case .codex:
            response = try? CodexHookOutput.permission(decision)
        case .claude:
            let claudeDecision: ClaudePermissionDecision = decision == .allow ? .allow : .deny
            response = try? ClaudeHookOutput.permission(claudeDecision)
        }
        guard let response else {
            entry.connection.cancel()
            return
        }
        entry.connection.send(content: response, completion: .contentProcessed { _ in
            entry.connection.cancel()
        })
    }

    private func accept(_ connection: NWConnection) {
        guard Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                fputs("AgentPager Hook 连接错误：\(error)\n", stderr)
                connection.cancel()
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
        case nil:
            // 无法识别来源时按 Codex 兼容旧 CLI；解析失败则放行不阻塞。
            if let payload = try? JSONDecoder().decode(CodexHookPayload.self, from: data) {
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
        let displaced = lock.withLock {
            pending.updateValue(
                (connection: connection, source: source),
                forKey: sessionID
            )
        }
        if let displaced {
            // 手机协议目前按任务而不是按单次工具调用审批。若同一会话并发
            // 发出第二个请求，让旧请求回退到 Codex 本地审批，避免连接被
            // 覆盖后一直挂到一小时超时；手机保留并展示最新请求。
            acknowledge(displaced.connection)
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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
