import Testing
@testable import AgentGridCore

private typealias Candidate = LocalNetworkAddress.Candidate

@Test("二维码地址优先 en0，其次 en1")
func prefersPrimaryWiFiInterface() {
    let address = LocalNetworkAddress.select(from: [
        Candidate(interface: "en1", address: "192.168.1.20"),
        Candidate(interface: "en0", address: "192.168.1.10"),
    ])
    #expect(address == "192.168.1.10")
}

@Test("只有有线网卡 en5 时使用它而不是回环")
func fallsBackToOtherEthernetInterfaces() {
    let address = LocalNetworkAddress.select(from: [
        Candidate(interface: "utun3", address: "10.8.0.2"),
        Candidate(interface: "en5", address: "10.0.0.7"),
    ])
    #expect(address == "10.0.0.7")
}

@Test("忽略 VPN、虚拟网桥与链路本地地址")
func ignoresVirtualAndLinkLocalInterfaces() {
    let address = LocalNetworkAddress.select(from: [
        Candidate(interface: "utun3", address: "10.8.0.2"),
        Candidate(interface: "bridge100", address: "192.168.64.1"),
        Candidate(interface: "en0", address: "169.254.10.4"),
    ])
    #expect(address == "127.0.0.1")
}
