import Darwin
import Foundation
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

@Test("Hook 服务器不在局域网地址上监听")
func hookServerRejectsNonLoopbackConnections() throws {
    let lanAddress = LocalNetworkAddress.preferredIPv4()
    // 没有局域网地址（如无网络的 CI 沙盒）时无法验证，直接跳过。
    guard lanAddress != "127.0.0.1" else { return }

    let (server, port) = try startServer()
    defer { server.stop() }

    #expect(TestClient(host: "127.0.0.1", port: port) != nil)
    #expect(TestClient(host: lanAddress, port: port) == nil)
}

@Test("同一会话的新权限请求会关闭旧连接并只回应最新请求")
func hookServerReplacesPendingPermissionForSameSession() throws {
    let (server, port) = try startServer()
    defer { server.stop() }

    let first = try #require(TestClient(host: "127.0.0.1", port: port))
    first.sendLine(claudeHook(event: "PermissionRequest", sessionID: "perm-1"))
    Thread.sleep(forTimeInterval: 0.3)

    let second = try #require(TestClient(host: "127.0.0.1", port: port))
    second.sendLine(claudeHook(event: "PermissionRequest", sessionID: "perm-1"))
    Thread.sleep(forTimeInterval: 0.3)

    // 旧连接被服务器关闭：对端关闭表现为读到 0 字节而不是超时。
    #expect(first.receive() == Data())

    server.resolve(sessionID: "perm-1", decision: .allow)
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
    server.resolve(sessionID: "perm-2", decision: .allow)
}
