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
