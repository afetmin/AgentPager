import Darwin
import Foundation
import Network
import Testing
@testable import AgentGridCore

private func randomPort() -> UInt16 {
    UInt16.random(in: 50_000..<60_000)
}

/// 阻塞式测试客户端；`receiveTimeout` 秒内没有数据则视为超时。
private final class TestClient {
    private let descriptor: Int32

    init?(host: String, port: UInt16, receiveTimeout: Int = 3) {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            close(descriptor)
            return nil
        }

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            return nil
        }

        var timeout = timeval(tv_sec: receiveTimeout, tv_usec: 0)
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    func sendLine(_ text: String) {
        let bytes = Array((text + "\n").utf8)
        _ = send(descriptor, bytes, bytes.count, 0)
    }

    /// 返回收到的数据；对端关闭返回空数据，超时返回 nil。
    func receive() -> Data? {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count < 0 { return nil }
        return Data(buffer.prefix(count))
    }
}

private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}

private func claudeHook(event: String, sessionID: String) -> String {
    """
    {"hook_source":"claude","payload":{"cwd":"/tmp/agentpager",\
    "hook_event_name":"\(event)","session_id":"\(sessionID)",\
    "tool_name":"Bash","tool_input":{"command":"ls"}}}
    """
}

private func startServer(
    onEvent: @escaping HookBridgeServer.EventHandler = { _ in }
) throws -> (server: HookBridgeServer, port: UInt16) {
    for _ in 0..<5 {
        let server = HookBridgeServer(eventHandler: onEvent)
        let port = randomPort()
        do {
            try server.start(port: port)
            // 等待 listener 就绪。
            Thread.sleep(forTimeInterval: 0.3)
            return (server, port)
        } catch {
            server.stop()
        }
    }
    throw CocoaError(.fileWriteUnknown)
}

@Test("Hook 服务器接受回环连接并对普通事件返回空行")
func hookServerAcknowledgesLoopbackEvents() throws {
    let (server, port) = try startServer()
    defer { server.stop() }

    let client = try #require(TestClient(host: "127.0.0.1", port: port))
    client.sendLine(claudeHook(event: "Stop", sessionID: "ack-1"))

    #expect(client.receive() == Data("\n".utf8))
}

@Test("来自局域网地址的连接不会产生 Hook 事件")
func hookServerIgnoresNonLoopbackConnections() throws {
    let lanAddress = LocalNetworkAddress.preferredIPv4()
    // 没有局域网地址（如无网络的 CI 沙盒）时无法验证，直接跳过。
    guard lanAddress != "127.0.0.1" else { return }

    let events = EventCounter()
    let (server, port) = try startServer { _ in events.increment() }
    defer { server.stop() }

    // 局域网来源可能在 TCP 层连上，但服务器必须立刻丢弃，不读取、不响应、不上报事件。
    if let client = TestClient(host: lanAddress, port: port) {
        client.sendLine(claudeHook(event: "Stop", sessionID: "lan-1"))
        #expect(client.receive() != Data("\n".utf8))
    }
    Thread.sleep(forTimeInterval: 0.3)
    #expect(events.value == 0)

    // 回环来源仍然正常。
    let loopback = try #require(TestClient(host: "127.0.0.1", port: port))
    loopback.sendLine(claudeHook(event: "Stop", sessionID: "loop-1"))
    #expect(loopback.receive() == Data("\n".utf8))
    #expect(events.value == 1)
}

@Test("同一会话的新权限请求让旧请求回退本地审批，并只回应最新请求")
func hookServerReplacesPendingPermissionForSameSession() throws {
    let (server, port) = try startServer()
    defer { server.stop() }

    let first = try #require(TestClient(host: "127.0.0.1", port: port))
    first.sendLine(claudeHook(event: "PermissionRequest", sessionID: "perm-1"))
    Thread.sleep(forTimeInterval: 0.3)

    let second = try #require(TestClient(host: "127.0.0.1", port: port))
    second.sendLine(claudeHook(event: "PermissionRequest", sessionID: "perm-1"))
    Thread.sleep(forTimeInterval: 0.3)

    // 旧请求收到空行而不是一直挂起，Agent 会回退到本地审批流程。
    #expect(first.receive() == Data("\n".utf8))

    try server.resolve(sessionID: "perm-1", decision: .allow)
    let response = try #require(second.receive())
    #expect(!response.isEmpty)
}

@Test("Hook 进程提前断开后挂起的权限请求被释放")
func hookServerReleasesPendingPermissionWhenClientDisconnects() throws {
    let (server, port) = try startServer()
    defer { server.stop() }

    var client: TestClient? = try #require(TestClient(host: "127.0.0.1", port: port))
    client?.sendLine(claudeHook(event: "PermissionRequest", sessionID: "perm-2"))
    Thread.sleep(forTimeInterval: 0.3)
    client = nil
    Thread.sleep(forTimeInterval: 0.3)

    // 条目已被清理后，resolve 不应再向任何连接写入，也不应崩溃。
    try server.resolve(sessionID: "perm-2", decision: .allow)
}

@Test("Hook Bridge 只接受回环来源")
func hookBridgeAcceptsLoopbackOnly() {
    let port = NWEndpoint.Port(rawValue: 49_361)!

    #expect(HookBridgeServer.isLoopback(.hostPort(host: "127.0.0.1", port: port)))
    #expect(HookBridgeServer.isLoopback(.hostPort(host: "::1", port: port)))
    #expect(!HookBridgeServer.isLoopback(.hostPort(host: "192.168.1.20", port: port)))
}

@Test("同会话只保留最新审批，旧超时回调不能删除新请求")
func pendingRegistryKeepsLatestRequest() throws {
    let registry = PendingValueRegistry<String>()
    let oldID = UUID()
    let newID = UUID()

    let first = registry.replaceValue("old", forKey: "session", id: oldID)
    #expect(first == nil)
    let displaced = try #require(
        registry.replaceValue("new", forKey: "session", id: newID)
    )
    #expect(displaced.value == "old")
    #expect(registry.count == 1)
    #expect(registry.removeValue(forKey: "session", matching: oldID) == nil)
    #expect(registry.count == 1)
    #expect(registry.removeValue(forKey: "session", matching: newID)?.value == "new")
    #expect(registry.count == 0)
}

@Test("已结束的审批连接不能被手机控制误报为批准成功")
func expiredPermissionConnectionRejectsResolution() {
    let server = HookBridgeServer { _ in }
    #expect(throws: PermissionResolutionError.self) {
        try server.resolve(sessionID: "expired-session", decision: .allow)
    }
}

private final class EnvelopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [HookEnvelope] = []

    var claudePayloads: [ClaudeHookPayload] {
        lock.withLock {
            items.compactMap { item in
                if case let .claude(payload) = item { return payload }
                return nil
            }
        }
    }

    func record(_ envelope: HookEnvelope) { lock.withLock { items.append(envelope) } }
}

@Test("信封里的 agent_id 写入 Claude 载荷，兼容客户端的 camelCase 字段也能解码")
func hookServerCarriesAgentIDAndAcceptsCamelCase() throws {
    let recorder = EnvelopeRecorder()
    let (server, port) = try startServer { recorder.record($0) }
    defer { server.stop() }

    let client = try #require(TestClient(host: "127.0.0.1", port: port))
    client.sendLine(
        """
        {"hook_source":"claude","agent_id":"zcode","payload":{"cwd":"/tmp/agentpager",\
        "hookEventName":"UserPromptSubmit","sessionId":"zcode-1","prompt":"你好"}}
        """
    )
    #expect(client.receive() == Data("\n".utf8))

    let payload = try #require(recorder.claudePayloads.first)
    #expect(payload.integrationID == "zcode")
    #expect(payload.sessionID == "zcode-1")
    #expect(payload.event == .userPromptSubmit)
}

@Test("不带 agent_id 的旧信封保持原行为，integrationID 为 nil")
func hookServerLegacyEnvelopeHasNoIntegration() throws {
    let recorder = EnvelopeRecorder()
    let (server, port) = try startServer { recorder.record($0) }
    defer { server.stop() }

    let client = try #require(TestClient(host: "127.0.0.1", port: port))
    client.sendLine(claudeHook(event: "Stop", sessionID: "legacy-1"))
    #expect(client.receive() == Data("\n".utf8))

    #expect(recorder.claudePayloads.first?.integrationID == nil)
}
