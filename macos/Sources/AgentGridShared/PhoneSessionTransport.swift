import Foundation

public enum TransportEvent: Equatable, Sendable {
    case opened
    case text(String)
    case closed(String?)
    case failed(String?)
}

/// 手机到 Bridge 的 WebSocket 通道。`events` 只会收到当前连接代的事件，
/// 主动 `disconnect()` 或被新的 `connect` 取代的连接不再上报。
public protocol PhoneSessionTransport: Sendable {
    var events: AsyncStream<TransportEvent> { get }

    func connect(host: String, port: Int)

    /// 把一帧文本排入发送队列；已断开时返回 `false`。队列保持提交顺序，
    /// 控制序号依赖这一点（Bridge 会拒绝序号回退的请求）。
    func send(_ text: String) -> Bool

    func disconnect()
}

public final class URLSessionPhoneTransport: NSObject, PhoneSessionTransport, @unchecked Sendable {
    public let events: AsyncStream<TransportEvent>

    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var terminated = true
    private var pingTask: Task<Void, Never>?
    private let pingInterval: Duration

    public init(pingInterval: Duration = .seconds(20)) {
        let stream = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
        events = stream.stream
        continuation = stream.continuation
        self.pingInterval = pingInterval
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
        continuation.finish()
    }

    public func connect(host: String, port: Int) {
        guard let url = Self.endpointURL(host: host, port: port) else {
            continuation.yield(.failed("无效的 Bridge 地址"))
            return
        }
        let next = session.webSocketTask(with: url)
        let previous = lock.withLock { () -> URLSessionWebSocketTask? in
            let previous = task
            task = next
            terminated = false
            pingTask?.cancel()
            pingTask = nil
            return previous
        }
        previous?.cancel(with: .goingAway, reason: nil)
        next.resume()
        receiveLoop(next)
    }

    public func send(_ text: String) -> Bool {
        guard let current = lock.withLock({ terminated ? nil : task }) else { return false }
        current.send(.string(text)) { [weak self] error in
            if let error {
                self?.finish(current, .failed(error.localizedDescription))
            }
        }
        return true
    }

    public func disconnect() {
        let previous = lock.withLock { () -> URLSessionWebSocketTask? in
            let previous = task
            task = nil
            terminated = true
            pingTask?.cancel()
            pingTask = nil
            return previous
        }
        previous?.cancel(with: .normalClosure, reason: nil)
    }

    static func endpointURL(host: String, port: Int) -> URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = "/agentgrid"
        return components.url
    }

    private func receiveLoop(_ current: URLSessionWebSocketTask) {
        current.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                let text: String?
                switch message {
                case let .string(value): text = value
                case let .data(data): text = String(data: data, encoding: .utf8)
                @unknown default: text = nil
                }
                if let text, self.isCurrent(current) {
                    self.continuation.yield(.text(text))
                }
                self.receiveLoop(current)
            case let .failure(error):
                self.finish(current, .failed(error.localizedDescription))
            }
        }
    }

    private func isCurrent(_ candidate: URLSessionWebSocketTask) -> Bool {
        lock.withLock { task === candidate && !terminated }
    }

    /// 每个连接代只上报一次终止事件（接收失败、发送失败、关闭帧可能同时到达）。
    private func finish(_ candidate: URLSessionWebSocketTask, _ event: TransportEvent) {
        let shouldReport = lock.withLock { () -> Bool in
            guard task === candidate, !terminated else { return false }
            terminated = true
            pingTask?.cancel()
            pingTask = nil
            return true
        }
        if shouldReport {
            candidate.cancel(with: .goingAway, reason: nil)
            continuation.yield(event)
        }
    }

    private func startPinging(_ candidate: URLSessionWebSocketTask) {
        let interval = pingInterval
        let ping = Task { [weak self, weak candidate] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let owner = self, let candidate else { return }
                candidate.sendPing { error in
                    if let error {
                        owner.finish(candidate, .failed(error.localizedDescription))
                    }
                }
            }
        }
        lock.withLock {
            if task === candidate {
                pingTask?.cancel()
                pingTask = ping
            } else {
                ping.cancel()
            }
        }
    }
}

extension URLSessionPhoneTransport: URLSessionWebSocketDelegate {
    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard isCurrent(webSocketTask) else { return }
        continuation.yield(.opened)
        startPinging(webSocketTask)
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(webSocketTask, .closed(reason.flatMap { String(data: $0, encoding: .utf8) }))
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let socket = task as? URLSessionWebSocketTask else { return }
        finish(socket, error.map { .failed($0.localizedDescription) } ?? .closed(nil))
    }
}
