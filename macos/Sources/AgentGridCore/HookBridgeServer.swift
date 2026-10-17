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
        // Hook 客户端只会从本机连入；仅绑定回环地址，避免局域网内其他设备伪造事件。
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let listener = try NWListener(using: parameters)
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
        // 无法识别来源时按 Codex 兼容旧 CLI；解析失败则直接断开，不阻塞 Agent。
        let envelope = decodeEnvelope(data)
            ?? (try? JSONDecoder().decode(CodexHookPayload.self, from: data))
            .map(HookEnvelope.codex)
        guard let envelope else {
            connection.cancel()
            return
        }

        eventHandler(envelope)

        let sessionID: String
        let source: HookSource
        let isPermissionRequest: Bool
        switch envelope {
        case let .codex(payload):
            sessionID = payload.sessionID
            source = .codex
            isPermissionRequest = payload.hookEventName == .permissionRequest
        case let .claude(payload):
            sessionID = payload.sessionID
            source = .claude
            isPermissionRequest = payload.event == .permissionRequest
        }

        if isPermissionRequest {
            holdForApproval(sessionID: sessionID, source: source, connection: connection)
        } else {
            acknowledge(connection)
        }
    }

    private func holdForApproval(
        sessionID: String,
        source: HookSource,
        connection: NWConnection
    ) {
        // 同一会话的新请求会取代旧请求；旧连接必须关闭，否则对应 Hook 进程会一直挂起。
        let previous = lock.withLock {
            let previous = pending.updateValue((connection: connection, source: source), forKey: sessionID)
            return previous?.connection
        }
        previous?.cancel()
        watchForDisconnect(sessionID: sessionID, connection: connection)
    }

    /// Hook 进程提前退出（用户在电脑端处理、超时等）时释放挂起的权限请求。
    private func watchForDisconnect(sessionID: String, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.lock.withLock {
                    if self.pending[sessionID]?.connection === connection {
                        self.pending.removeValue(forKey: sessionID)
                    }
                }
                connection.cancel()
            } else {
                self.watchForDisconnect(sessionID: sessionID, connection: connection)
            }
        }
    }

    private func acknowledge(_ connection: NWConnection) {
        // 空行响应：Codex 视为继续；Claude 视为 continue=true。两端都放行。
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
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
