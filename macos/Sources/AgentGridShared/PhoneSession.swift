import Foundation

public enum LinkState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
}

public struct PairingSummary: Equatable, Sendable {
    public var serviceID: String
    public var host: String
    public var port: Int

    public init(serviceID: String, host: String, port: Int) {
        self.serviceID = serviceID
        self.host = host
        self.port = port
    }
}

public enum PhoneSessionProblem: Error, Equatable, Sendable {
    case invalidPairing
    case unsupportedVersion
    case invalidEndpoint
    case invalidSecret
    case notPaired
    case notConnected
    case credentialFailure
    case sequenceFailure
    case transportFailure
    case protocolFailure
}

public enum PairingOutcome: Equatable, Sendable {
    case connecting
    case rejected(PhoneSessionProblem)
}

public enum ControlSubmission: Equatable, Sendable {
    case queued(UUID)
    case rejected(PhoneSessionProblem)
}

public enum ControlDelivery: Equatable, Sendable {
    case pending(submittedAt: Int64)
    case acknowledged(result: ControlResult, reason: String?)
    case timedOut
    case sendFailed
}

public struct ControlRecord: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var delivery: ControlDelivery
}

public struct PhoneSessionState: Equatable, Sendable {
    public var pairing: PairingSummary?
    public var link: LinkState
    public var snapshot: StateSnapshotPayload
    /// 按提交顺序保留最近的控制请求。
    public var controls: [ControlRecord]
    public var problem: PhoneSessionProblem?
    /// 每接受一份状态快照加一；快照内容不变时用来区分“收到了新消息”。
    public var snapshotRevision: Int

    public init(
        pairing: PairingSummary? = nil,
        link: LinkState = .disconnected,
        snapshot: StateSnapshotPayload = StateSnapshotPayload(tasks: [], usage: nil, focusedTaskID: nil),
        controls: [ControlRecord] = [],
        problem: PhoneSessionProblem? = nil,
        snapshotRevision: Int = 0
    ) {
        self.snapshotRevision = snapshotRevision
        self.pairing = pairing
        self.link = link
        self.snapshot = snapshot
        self.controls = controls
        self.problem = problem
    }

    public func delivery(for requestID: UUID) -> ControlDelivery? {
        controls.first { $0.id == requestID }?.delivery
    }
}

public protocol PhoneCredentialStore: Sendable {
    func load() throws -> PairingPayload?
    func save(_ pairing: PairingPayload) throws
    func clear() throws
    /// 控制序号绑定设备身份，解除配对后仍需保持单调，避免被 Bridge 判为重放。
    func reserveNextSequence() throws -> UInt64
}

/// 手机端会话：保存配对、维持到 Bridge 的连接、接收状态快照，并发送带签名的控制请求。
public actor PhoneSession {
    private static let maxControlHistory = 50
    /// 连续失败多少次后才去局域网里重新查找 Bridge。
    private static let discoveryThreshold = 2

    private let store: PhoneCredentialStore
    private let transport: PhoneSessionTransport
    private let locator: BridgeLocator?
    private let deviceID: String
    private let now: @Sendable () -> Int64
    private let makeRequestID: @Sendable () -> UUID
    private let makeNonce: @Sendable () -> String
    private let sleep: @Sendable (Int) async throws -> Void
    private let acknowledgmentTimeoutMillis: Int

    private var state = PhoneSessionState()
    private var pairing: PairingPayload?
    private var started = false
    private var stopped = false
    private var retryCount = 0
    private var reconnectTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var lastSnapshotSentAt = Int64.min
    private var lastSnapshotMessageID: String?
    private var subscribers: [UUID: AsyncStream<PhoneSessionState>.Continuation] = [:]

    public init(
        store: PhoneCredentialStore,
        transport: PhoneSessionTransport,
        locator: BridgeLocator? = nil,
        deviceID: String,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
        makeRequestID: @escaping @Sendable () -> UUID = { UUID() },
        makeNonce: @escaping @Sendable () -> String = { UUID().uuidString },
        sleep: @escaping @Sendable (Int) async throws -> Void = { milliseconds in
            try await Task.sleep(for: .milliseconds(milliseconds))
        },
        acknowledgmentTimeoutMillis: Int = 15_000
    ) {
        self.store = store
        self.transport = transport
        self.locator = locator
        self.deviceID = deviceID
        self.now = now
        self.makeRequestID = makeRequestID
        self.makeNonce = makeNonce
        self.sleep = sleep
        self.acknowledgmentTimeoutMillis = acknowledgmentTimeoutMillis
    }

    public var currentState: PhoneSessionState { state }

    /// 订阅状态变化；先收到当前状态，之后每次变化收到最新值。
    public func states() -> AsyncStream<PhoneSessionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: PhoneSessionState.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        subscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    public func start() {
        guard !started else { return }
        started = true
        stopped = false
        beginConsumingEvents()
        let restored: PairingPayload?
        do {
            restored = try store.load()
        } catch {
            try? store.clear()
            update { $0.problem = .credentialFailure }
            return
        }
        guard let restored else {
            state = PhoneSessionState()
            publish()
            return
        }
        guard Self.validate(restored) == nil else {
            try? store.clear()
            state = PhoneSessionState(problem: .credentialFailure)
            publish()
            return
        }
        pairing = restored
        update {
            $0.pairing = restored.summary
            $0.problem = nil
        }
        connect(restored)
    }

    public func pair(_ encodedPairing: String) -> PairingOutcome {
        guard let data = Self.normalizedPairingText(encodedPairing).data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PairingPayload.self, from: data) else {
            return .rejected(.invalidPairing)
        }
        if let problem = Self.validate(decoded) {
            return .rejected(problem)
        }
        do {
            try store.save(decoded)
        } catch {
            return .rejected(.credentialFailure)
        }
        stopped = false
        started = true
        beginConsumingEvents()
        cancelReconnect()
        cancelTimeouts()
        transport.disconnect()
        pairing = decoded
        retryCount = 0
        resetSnapshotTracking()
        state = PhoneSessionState(pairing: decoded.summary, link: .connecting)
        publish()
        transport.connect(host: decoded.host, port: Int(decoded.port))
        return .connecting
    }

    public func control(
        taskID: String,
        action: ControlAction,
        value: String? = nil
    ) -> ControlSubmission {
        guard let pairing else { return .rejected(.notPaired) }
        guard state.link == .connected else { return .rejected(.notConnected) }
        guard let secret = Data(base64Encoded: pairing.secret), !secret.isEmpty else {
            return .rejected(.invalidSecret)
        }
        let sequence: UInt64
        do {
            sequence = try store.reserveNextSequence()
        } catch {
            return .rejected(.sequenceFailure)
        }

        let requestID = makeRequestID()
        let sentAt = now()
        var envelope = SignedControlEnvelope(
            messageId: requestID,
            sentAt: sentAt,
            deviceId: deviceID,
            sequence: sequence,
            nonce: makeNonce(),
            payload: ControlPayload(taskID: taskID, action: action, value: value)
        )
        let encoded: String
        do {
            envelope.signature = try ControlSigner.sign(envelope, secret: secret)
            guard let text = String(data: try ProtocolCodec.encode(envelope), encoding: .utf8) else {
                return .rejected(.protocolFailure)
            }
            encoded = text
        } catch {
            return .rejected(.protocolFailure)
        }

        updateControl(requestID, .pending(submittedAt: sentAt))
        guard transport.send(encoded) else {
            updateControl(requestID, .sendFailed)
            return .rejected(.transportFailure)
        }
        let timeout = acknowledgmentTimeoutMillis
        let wait = sleep
        timeoutTasks[requestID] = Task { [weak self] in
            do { try await wait(timeout) } catch { return }
            await self?.expireControl(requestID)
        }
        return .queued(requestID)
    }

    /// 回到前台时调用：iOS 会在后台挂起 socket，这里不等退避计时直接重连。
    public func reconnectNow() {
        guard !stopped, let pairing, state.link != .connected else { return }
        cancelReconnect()
        retryCount = 0
        connect(pairing)
    }

    public func unpair() {
        stopped = true
        cancelReconnect()
        cancelTimeouts()
        transport.disconnect()
        do {
            try store.clear()
        } catch {
            stopped = false
            update {
                $0.link = .disconnected
                $0.problem = .credentialFailure
            }
            return
        }
        pairing = nil
        retryCount = 0
        resetSnapshotTracking()
        state = PhoneSessionState()
        publish()
    }

    public func shutdown() {
        stopped = true
        cancelReconnect()
        cancelTimeouts()
        eventsTask?.cancel()
        eventsTask = nil
        transport.disconnect()
        subscribers.values.forEach { $0.finish() }
        subscribers.removeAll()
    }

    // MARK: - 传输事件

    private func beginConsumingEvents() {
        guard eventsTask == nil else { return }
        let events = transport.events
        eventsTask = Task { [weak self] in
            for await event in events {
                await self?.accept(event)
            }
        }
    }

    private func accept(_ event: TransportEvent) {
        switch event {
        case .opened:
            retryCount = 0
            // 新连接的第一帧必须被接受：Mac 重启或时钟回拨后 sentAt 可能小于旧连接的最后一帧。
            resetSnapshotTracking()
            cancelReconnect()
            update {
                $0.link = .connected
                $0.problem = nil
            }
        case let .text(text):
            accept(message: text)
        case .closed, .failed:
            // 解除配对后晚到的终止事件不应把状态改回“传输失败”。
            guard pairing != nil else { return }
            disconnectAndRetry()
        }
    }

    private struct IncomingHeader: Decodable {
        var version: Int
        var messageId: String
        var type: String
        var sentAt: Int64
    }

    private func accept(message text: String) {
        let decoder = ProtocolCodec.makeDecoder()
        guard let data = text.data(using: .utf8),
              let header = try? decoder.decode(IncomingHeader.self, from: data),
              header.version == 1 else {
            update { $0.problem = .protocolFailure }
            return
        }
        switch header.type {
        case "state.snapshot":
            if header.sentAt < lastSnapshotSentAt || header.messageId == lastSnapshotMessageID {
                return
            }
            guard let envelope = try? decoder.decode(
                MessageEnvelope<StateSnapshotPayload>.self,
                from: data
            ) else {
                update { $0.problem = .protocolFailure }
                return
            }
            lastSnapshotSentAt = header.sentAt
            lastSnapshotMessageID = header.messageId
            update {
                $0.snapshot = envelope.payload
                $0.snapshotRevision += 1
                $0.problem = nil
            }
        case "control.ack":
            guard let envelope = try? decoder.decode(
                MessageEnvelope<ControlAckPayload>.self,
                from: data
            ) else {
                update { $0.problem = .protocolFailure }
                return
            }
            let acknowledgment = envelope.payload
            guard case .pending = state.delivery(for: acknowledgment.requestID) else { return }
            timeoutTasks.removeValue(forKey: acknowledgment.requestID)?.cancel()
            updateControl(
                acknowledgment.requestID,
                .acknowledged(result: acknowledgment.result, reason: acknowledgment.reason)
            )
        default:
            break
        }
    }

    private func connect(_ value: PairingPayload) {
        update { $0.link = .connecting }
        transport.connect(host: value.host, port: Int(value.port))
    }

    private func disconnectAndRetry() {
        update {
            $0.link = .disconnected
            $0.problem = .transportFailure
        }
        guard !stopped, pairing != nil, reconnectTask == nil else { return }
        let exponent = min(retryCount, 5)
        retryCount += 1
        let delay = min(30_000, 1_000 << exponent)
        let wait = sleep
        reconnectTask = Task { [weak self] in
            do { try await wait(delay) } catch { return }
            await self?.reconnectTimerFired()
        }
    }

    private func reconnectTimerFired() async {
        reconnectTask = nil
        guard !stopped, var target = pairing else { return }
        // 旧地址连续失败两次后，尝试通过 Bonjour 找回这台 Mac 的新地址。
        if let locator, retryCount >= Self.discoveryThreshold,
           let found = await locator.locate(serviceID: target.serviceID) {
            // 查找期间可能已解除配对、重新配对或回到前台连上了。
            guard !stopped, let current = pairing, current == target, state.link != .connected else {
                return
            }
            if found.host != target.host || found.port != Int(target.port), found.port > 0, found.port <= Int(UInt16.max) {
                target.host = found.host
                target.port = UInt16(found.port)
                guard (try? store.save(target)) != nil else {
                    connect(current)
                    return
                }
                pairing = target
                update { $0.pairing = target.summary }
            }
        }
        guard !stopped, state.link != .connected else { return }
        connect(target)
    }

    private func expireControl(_ requestID: UUID) {
        timeoutTasks.removeValue(forKey: requestID)
        if case .pending = state.delivery(for: requestID) {
            updateControl(requestID, .timedOut)
        }
    }

    // MARK: - 状态

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func cancelTimeouts() {
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()
    }

    private func resetSnapshotTracking() {
        lastSnapshotSentAt = .min
        lastSnapshotMessageID = nil
    }

    private func updateControl(_ requestID: UUID, _ delivery: ControlDelivery) {
        update { state in
            if let index = state.controls.firstIndex(where: { $0.id == requestID }) {
                state.controls[index].delivery = delivery
            } else {
                state.controls.append(ControlRecord(id: requestID, delivery: delivery))
            }
            if state.controls.count > Self.maxControlHistory {
                state.controls.removeFirst(state.controls.count - Self.maxControlHistory)
            }
        }
    }

    private func update(_ change: (inout PhoneSessionState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        publish()
    }

    private func publish() {
        subscribers.values.forEach { $0.yield(state) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    /// 从聊天软件或备忘录粘贴时，引号常被替换成弯引号，先还原成 JSON 可解析的直引号。
    nonisolated static func normalizedPairingText(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for quote in ["\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{FF02}"] {
            result = result.replacingOccurrences(of: quote, with: "\"")
        }
        return result
    }

    nonisolated static func validate(_ value: PairingPayload) -> PhoneSessionProblem? {
        if value.version != 1 { return .unsupportedVersion }
        if value.host.trimmingCharacters(in: .whitespaces).isEmpty || value.port == 0 {
            return .invalidEndpoint
        }
        guard let secret = Data(base64Encoded: value.secret), !secret.isEmpty else {
            return .invalidSecret
        }
        return nil
    }
}

extension PairingPayload {
    var summary: PairingSummary {
        PairingSummary(serviceID: serviceID, host: host, port: Int(port))
    }
}

extension ProtocolCodec {
    /// 与 `encode` 对称：时间戳按毫秒整数解码。
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
