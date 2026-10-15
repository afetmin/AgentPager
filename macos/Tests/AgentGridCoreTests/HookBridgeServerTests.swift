import Foundation
import Network
import Testing
@testable import AgentGridCore

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
