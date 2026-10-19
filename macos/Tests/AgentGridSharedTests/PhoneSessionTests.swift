import Foundation
import Testing
@testable import AgentGridShared

private final class FakeTransport: PhoneSessionTransport, @unchecked Sendable {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private var _connects: [String] = []
    private var _sent: [String] = []
    private var _disconnects = 0
    var acceptsSend = true

    init() {
        let stream = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
    }

    var connects: [String] { lock.withLock { _connects } }
    var sent: [String] { lock.withLock { _sent } }
    var disconnects: Int { lock.withLock { _disconnects } }

    func emit(_ event: TransportEvent) { continuation.yield(event) }

    func connect(host: String, port: Int) { lock.withLock { _connects.append("\(host):\(port)") } }

    func send(_ text: String) -> Bool {
        guard acceptsSend else { return false }
        lock.withLock { _sent.append(text) }
        return true
    }

    func disconnect() { lock.withLock { _disconnects += 1 } }
}

private final class MemoryStore: PhoneCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var pairing: PairingPayload?
    private var sequence: UInt64 = 0
    var failSave = false

    init(pairing: PairingPayload? = nil) { self.pairing = pairing }

    func load() throws -> PairingPayload? { lock.withLock { pairing } }

    func save(_ pairing: PairingPayload) throws {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        lock.withLock { self.pairing = pairing }
    }

    func clear() throws { lock.withLock { pairing = nil } }

    func reserveNextSequence() throws -> UInt64 {
        lock.withLock {
            sequence += 1
            return sequence
        }
    }

    var storedPairing: PairingPayload? { lock.withLock { pairing } }
}

private let secret = Data(repeating: 0x5A, count: 32)

private func pairingPayload(host: String = "192.168.1.8", port: UInt16 = 49_362) -> PairingPayload {
    PairingPayload(serviceID: "mac", host: host, port: port, secret: secret.base64EncodedString())
}

private func pairingText(_ payload: PairingPayload = pairingPayload()) throws -> String {
    String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
}

private func snapshotText(
    id: UUID = UUID(),
    sentAt: Int64 = 1_785_067_200_000,
    taskTitle: String = "任务"
) throws -> String {
    let payload = StateSnapshotPayload(
        tasks: [TaskSnapshot(id: "t1", source: .codexCLI, projectName: "AgentPager", title: taskTitle, lifecycle: .waitingApproval, capabilities: [.approve, .deny])],
        usage: nil,
        focusedTaskID: "t1",
        pendingRequests: [PendingRequest(taskID: "t1", kind: .approval, summary: "运行测试")]
    )
    let envelope = MessageEnvelope(messageId: id, type: "state.snapshot", sentAt: sentAt, payload: payload)
    return String(decoding: try ProtocolCodec.encode(envelope), as: UTF8.self)
}

private func ackText(requestID: UUID, result: ControlResult) throws -> String {
    let envelope = MessageEnvelope(
        type: "control.ack",
        payload: ControlAckPayload(requestID: requestID, result: result)
    )
    return String(decoding: try ProtocolCodec.encode(envelope), as: UTF8.self)
}

private func eventually(
    _ timeout: Duration = .seconds(2),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private func makeSession(
    store: MemoryStore = MemoryStore(),
    transport: FakeTransport = FakeTransport(),
    retryDelay: Duration? = nil,
    ackTimeoutMillis: Int = 15_000
) -> PhoneSession {
    PhoneSession(
        store: store,
        transport: transport,
        deviceID: "iphone-test",
        makeNonce: { UUID().uuidString },
        sleep: { milliseconds in
            if let retryDelay, milliseconds != ackTimeoutMillis {
                try await Task.sleep(for: retryDelay)
            } else {
                try await Task.sleep(for: .milliseconds(milliseconds))
            }
        },
        acknowledgmentTimeoutMillis: ackTimeoutMillis
    )
}

@Test("配对文本无效时被拒绝且不保存")
func rejectsInvalidPairing() async throws {
    let store = MemoryStore()
    let session = makeSession(store: store)

    #expect(await session.pair("not json") == .rejected(.invalidPairing))
    #expect(await session.pair(try pairingText(PairingPayload(version: 2, serviceID: "m", host: "h", port: 1, secret: secret.base64EncodedString()))) == .rejected(.unsupportedVersion))
    #expect(await session.pair(try pairingText(pairingPayload(host: " "))) == .rejected(.invalidEndpoint))
    #expect(await session.pair(try pairingText(PairingPayload(serviceID: "m", host: "h", port: 1, secret: "###"))) == .rejected(.invalidSecret))
    #expect(store.storedPairing == nil)
}

@Test("弯引号包裹的配对文本也能被接受")
func acceptsSmartQuotes() async throws {
    let transport = FakeTransport()
    let session = makeSession(transport: transport)
    let curly = try pairingText().replacingOccurrences(of: "\"", with: "\u{201C}")

    #expect(await session.pair(curly) == .connecting)
}

@Test("配对成功后保存凭据并连接，收到打开事件后进入已连接")
func pairingSavesAndConnects() async throws {
    let store = MemoryStore()
    let transport = FakeTransport()
    let session = makeSession(store: store, transport: transport)

    #expect(await session.pair("  \(try pairingText())\n") == .connecting)
    #expect(store.storedPairing == pairingPayload())
    #expect(transport.connects == ["192.168.1.8:49362"])
    #expect(await session.currentState.link == .connecting)

    transport.emit(.opened)
    #expect(await eventually { await session.currentState.link == .connected })
}

@Test("启动时恢复已保存的配对并自动连接")
func startRestoresPairing() async throws {
    let transport = FakeTransport()
    let session = makeSession(store: MemoryStore(pairing: pairingPayload()), transport: transport)

    await session.start()

    #expect(transport.connects == ["192.168.1.8:49362"])
    #expect(await session.currentState.pairing == PairingSummary(serviceID: "mac", host: "192.168.1.8", port: 49_362))
}

@Test("已保存的配对损坏时清除并报告凭据故障")
func startClearsCorruptPairing() async throws {
    let store = MemoryStore(pairing: PairingPayload(serviceID: "m", host: "h", port: 1, secret: "###"))
    let transport = FakeTransport()
    let session = makeSession(store: store, transport: transport)

    await session.start()

    #expect(store.storedPairing == nil)
    #expect(transport.connects.isEmpty)
    #expect(await session.currentState.problem == .credentialFailure)
}

@Test("状态快照被接受，旧快照和重复消息被忽略")
func snapshotsAreOrdered() async throws {
    let transport = FakeTransport()
    let session = makeSession(transport: transport)
    _ = await session.pair(try pairingText())
    transport.emit(.opened)

    let id = UUID()
    transport.emit(.text(try snapshotText(id: id, sentAt: 2_000, taskTitle: "新")))
    #expect(await eventually { await session.currentState.snapshot.tasks.first?.title == "新" })

    transport.emit(.text(try snapshotText(sentAt: 1_000, taskTitle: "旧")))
    transport.emit(.text(try snapshotText(id: id, sentAt: 2_000, taskTitle: "重复")))
    transport.emit(.text(try snapshotText(sentAt: 3_000, taskTitle: "最新")))
    #expect(await eventually { await session.currentState.snapshot.tasks.first?.title == "最新" })
    #expect(await session.currentState.snapshot.pendingRequests.first?.summary == "运行测试")
}

@Test("控制请求带有可验证的签名、递增序号和设备标识")
func controlRequestIsSigned() async throws {
    let transport = FakeTransport()
    let session = makeSession(transport: transport)
    _ = await session.pair(try pairingText())
    transport.emit(.opened)
    #expect(await eventually { await session.currentState.link == .connected })

    guard case let .queued(first) = await session.control(taskID: "t1", action: .approve) else {
        Issue.record("应当入队")
        return
    }
    _ = await session.control(taskID: "t1", action: .answer, value: "继续")

    let requests = try transport.sent.map {
        try JSONDecoder().decode(SignedControlEnvelope.self, from: Data($0.utf8))
    }
    #expect(requests.count == 2)
    #expect(requests[0].messageId == first)
    #expect(requests.map(\.sequence) == [1, 2])
    #expect(requests.allSatisfy { $0.deviceId == "iphone-test" })
    #expect(Set(requests.map(\.nonce)).count == 2)
    #expect(requests[1].payload.value == "继续")
    for request in requests {
        #expect(try ControlSigner.verify(request, secret: secret))
    }
    var guardian = ReplayGuard()
    for request in requests {
        try guardian.validate(request, secret: secret)
    }
}

@Test("未配对或未连接时控制请求被拒绝")
func controlRequiresConnection() async throws {
    let transport = FakeTransport()
    let session = makeSession(transport: transport)

    #expect(await session.control(taskID: "t", action: .approve) == .rejected(.notPaired))
    _ = await session.pair(try pairingText())
    #expect(await session.control(taskID: "t", action: .approve) == .rejected(.notConnected))
    #expect(transport.sent.isEmpty)
}

@Test("确认回执更新控制结果，未知回执被忽略")
func acknowledgmentUpdatesDelivery() async throws {
    let transport = FakeTransport()
    let session = makeSession(transport: transport)
    _ = await session.pair(try pairingText())
    transport.emit(.opened)
    #expect(await eventually { await session.currentState.link == .connected })
    guard case let .queued(id) = await session.control(taskID: "t1", action: .deny) else {
        Issue.record("应当入队")
        return
    }

    transport.emit(.text(try ackText(requestID: UUID(), result: .accepted)))
    transport.emit(.text(try ackText(requestID: id, result: .stale)))

    #expect(await eventually {
        await session.currentState.delivery(for: id) == .acknowledged(result: .stale, reason: nil)
    })
}

@Test("超时未确认的控制请求标记为超时")
func controlTimesOut() async throws {
    let transport = FakeTransport()
    let session = makeSession(transport: transport, ackTimeoutMillis: 20)
    _ = await session.pair(try pairingText())
    transport.emit(.opened)
    #expect(await eventually { await session.currentState.link == .connected })
    guard case let .queued(id) = await session.control(taskID: "t1", action: .approve) else {
        Issue.record("应当入队")
        return
    }

    #expect(await eventually { await session.currentState.delivery(for: id) == .timedOut })
}

@Test("发送失败时记录失败并拒绝")
func sendFailureIsReported() async throws {
    let transport = FakeTransport()
    let session = makeSession(transport: transport)
    _ = await session.pair(try pairingText())
    transport.emit(.opened)
    #expect(await eventually { await session.currentState.link == .connected })
    transport.acceptsSend = false

    #expect(await session.control(taskID: "t1", action: .approve) == .rejected(.transportFailure))
    #expect(await session.currentState.controls.last?.delivery == .sendFailed)
}

@Test("连接断开后按退避自动重连")
func reconnectsAfterFailure() async throws {
    let transport = FakeTransport()
    let session = makeSession(transport: transport, retryDelay: .milliseconds(5))
    _ = await session.pair(try pairingText())
    transport.emit(.opened)
    #expect(await eventually { await session.currentState.link == .connected })

    transport.emit(.failed("断开"))

    #expect(await eventually { transport.connects.count >= 2 })
    #expect(await session.currentState.problem == .transportFailure || transport.connects.count >= 2)
    transport.emit(.opened)
    #expect(await eventually { await session.currentState.link == .connected })
    #expect(await session.currentState.problem == nil)
}

@Test("回到前台时立即重连，不等退避计时")
func reconnectNowSkipsBackoff() async throws {
    let transport = FakeTransport()
    let session = makeSession(transport: transport)
    _ = await session.pair(try pairingText())
    transport.emit(.failed("后台挂起"))
    #expect(await eventually { await session.currentState.link == .disconnected })
    #expect(transport.connects.count == 1)

    await session.reconnectNow()

    #expect(transport.connects.count == 2)
    #expect(await session.currentState.link == .connecting)
}

@Test("解除配对清除凭据并断开，不再重连")
func unpairClearsEverything() async throws {
    let store = MemoryStore()
    let transport = FakeTransport()
    let session = makeSession(store: store, transport: transport, retryDelay: .milliseconds(5))
    _ = await session.pair(try pairingText())
    transport.emit(.opened)
    #expect(await eventually { await session.currentState.link == .connected })

    await session.unpair()
    transport.emit(.failed("晚到的事件"))
    try? await Task.sleep(for: .milliseconds(50))

    #expect(store.storedPairing == nil)
    #expect(await session.currentState == PhoneSessionState())
    #expect(transport.connects.count == 1)
    // 序号不随解除配对重置。
    let next = try store.reserveNextSequence()
    #expect(next == 1)
}

@Test("保存凭据失败时配对被拒绝")
func saveFailureRejectsPairing() async throws {
    let store = MemoryStore()
    store.failSave = true
    let transport = FakeTransport()
    let session = makeSession(store: store, transport: transport)

    #expect(await session.pair(try pairingText()) == .rejected(.credentialFailure))
    #expect(transport.connects.isEmpty)
}
