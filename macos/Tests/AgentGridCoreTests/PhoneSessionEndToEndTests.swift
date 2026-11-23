import Foundation
import Testing
@testable import AgentGridCore

private final class SequenceStore: PhoneCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var pairing: PairingPayload?
    private var sequence: UInt64 = 0

    func load() throws -> PairingPayload? { lock.withLock { pairing } }
    func save(_ pairing: PairingPayload) throws { lock.withLock { self.pairing = pairing } }
    func clear() throws { lock.withLock { pairing = nil } }
    func reserveNextSequence() throws -> UInt64 {
        lock.withLock {
            sequence += 1
            return sequence
        }
    }
}

private final class ControlRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var guardian = ReplayGuard()
    private(set) var accepted: [SignedControlEnvelope] = []
    private(set) var rejectedCount = 0
    var clients = 0

    func handle(_ text: String, secret: Data) -> ControlAckPayload? {
        guard let request = try? JSONDecoder().decode(SignedControlEnvelope.self, from: Data(text.utf8)) else {
            return nil
        }
        return lock.withLock {
            do {
                try guardian.validate(request, secret: secret)
                accepted.append(request)
                return ControlAckPayload(requestID: request.messageId, result: .accepted)
            } catch {
                rejectedCount += 1
                return ControlAckPayload(requestID: request.messageId, result: .rejected, reason: "签名或序号无效")
            }
        }
    }

    func setClients(_ count: Int) { lock.withLock { clients = count } }
    var clientCount: Int { lock.withLock { clients } }
    var acceptedRequests: [SignedControlEnvelope] { lock.withLock { accepted } }
    var rejections: Int { lock.withLock { rejectedCount } }
}

private func wait(_ timeout: Duration = .seconds(5), until condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

@Test("手机会话通过真实 WebSocket 接收快照并完成签名控制往返")
func phoneSessionTalksToBridgeServer() async throws {
    let secret = Data((0..<32).map { UInt8($0) })
    let recorder = ControlRecorder()
    let serverBox = ServerBox()
    let server = WebSocketServer(
        messageHandler: { text in
            guard let ack = recorder.handle(text, secret: secret),
                  let data = try? ProtocolCodec.encode(MessageEnvelope(type: "control.ack", payload: ack)),
                  let reply = String(data: data, encoding: .utf8) else { return }
            serverBox.server?.broadcast(reply)
        },
        countHandler: { recorder.setClients($0) }
    )
    serverBox.server = server
    let port = UInt16.random(in: 49_800...59_800)
    try server.start(port: port)
    defer { server.stop() }

    let transport = URLSessionPhoneTransport()
    let session = PhoneSession(store: SequenceStore(), transport: transport, deviceID: "iphone-e2e")
    let pairing = PairingText.makeForTest(host: "127.0.0.1", port: port, secret: secret)
    #expect(await session.pair(pairing) == .connecting)
    #expect(await wait { await session.currentState.link == .connected })
    #expect(await wait { recorder.clientCount == 1 })

    let snapshot = StateSnapshotPayload(
        tasks: [TaskSnapshot(id: "t1", source: .claudeCode, projectName: "AgentPager", lifecycle: .waitingApproval, capabilities: [.approve, .deny])],
        usage: nil,
        focusedTaskID: "t1",
        pendingRequests: [PendingRequest(taskID: "t1", kind: .approval, summary: "运行 swift test")]
    )
    let snapshotText = String(
        decoding: try ProtocolCodec.encode(MessageEnvelope(type: "state.snapshot", payload: snapshot)),
        as: UTF8.self
    )
    server.broadcast(snapshotText)
    #expect(await wait { await session.currentState.snapshot.tasks.first?.id == "t1" })
    #expect(await session.currentState.snapshot.pendingRequests.first?.summary == "运行 swift test")

    guard case let .queued(first) = await session.control(taskID: "t1", action: .approve) else {
        Issue.record("控制请求应当入队")
        return
    }
    guard case let .queued(second) = await session.control(taskID: "t1", action: .answer, value: "好") else {
        Issue.record("第二个控制请求应当入队")
        return
    }
    #expect(await wait {
        let state = await session.currentState
        return state.delivery(for: first) == .acknowledged(result: .accepted, reason: nil)
            && state.delivery(for: second) == .acknowledged(result: .accepted, reason: nil)
    })
    #expect(recorder.rejections == 0)
    #expect(recorder.acceptedRequests.map(\.sequence) == [1, 2])
    #expect(recorder.acceptedRequests.map(\.payload.action) == [.approve, .answer])
    #expect(recorder.acceptedRequests.allSatisfy { $0.deviceId == "iphone-e2e" })

    await session.shutdown()
}

private final class ServerBox: @unchecked Sendable {
    var server: WebSocketServer?
}

private enum PairingText {
    static func makeForTest(host: String, port: UInt16, secret: Data) -> String {
        let payload = PairingPayload(serviceID: "e2e", host: host, port: port, secret: secret.base64EncodedString())
        return String(decoding: (try? JSONEncoder().encode(payload)) ?? Data(), as: UTF8.self)
    }
}
