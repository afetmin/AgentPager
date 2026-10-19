import CryptoKit
import Foundation
import Network

public final class WebSocketServer: @unchecked Sendable {
    public typealias MessageHandler = @Sendable (String) -> Void
    public typealias CountHandler = @Sendable (Int) -> Void
    public typealias LocalHTTPHandler = @Sendable (String) -> String?

    private let queue = DispatchQueue(label: "com.agentgrid.websocket-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private let messageHandler: MessageHandler
    private let countHandler: CountHandler
    private let localHTTPHandler: LocalHTTPHandler?

    public init(
        messageHandler: @escaping MessageHandler,
        countHandler: @escaping CountHandler,
        localHTTPHandler: LocalHTTPHandler? = nil
    ) {
        self.messageHandler = messageHandler
        self.countHandler = countHandler
        self.localHTTPHandler = localHTTPHandler
    }

    /// `serviceID` 写入 Bonjour TXT 记录（键 `id`），手机在 IP 变化后据此认出自己配对的那台 Mac。
    public func start(port: UInt16 = 49_362, serviceID: String? = nil) throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(
            name: "AgentPager Bridge",
            type: BridgeServiceDiscovery.serviceType,
            txtRecord: serviceID.map { NWTXTRecord([BridgeServiceDiscovery.serviceIDKey: $0]).data }
        )
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
            clients.values.forEach { $0.cancel() }
            clients.removeAll()
        }
        countHandler(0)
    }

    public func broadcast(_ text: String) {
        let frame = Self.serverFrame(opcode: 0x1, payload: Data(text.utf8))
        let connections = lock.withLock { Array(clients.values) }
        connections.forEach { connection in
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHandshake(on: connection, buffer: Data())
    }

    private func receiveHandshake(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }

            guard let text = String(data: next, encoding: .utf8) else {
                connection.cancel()
                return
            }
            if text.contains("\r\n\r\n") {
                self.finishHandshake(text, connection: connection)
                return
            }
            if isComplete || error != nil || next.count > 32 * 1_024 {
                connection.cancel()
                return
            }
            self.receiveHandshake(on: connection, buffer: next)
        }
    }

    private func finishHandshake(_ request: String, connection: NWConnection) {
        let requestPath = request
            .split(separator: "\r\n")
            .first?
            .split(separator: " ")
            .dropFirst()
            .first
            .map(String.init)

        if let requestPath,
           isLoopback(connection.endpoint),
           let body = localHTTPHandler?(requestPath) {
            let response = [
                "HTTP/1.1 200 OK",
                "Content-Type: application/json; charset=utf-8",
                "Content-Length: \(body.utf8.count)",
                "Connection: close",
                "\r\n\(body)",
            ].joined(separator: "\r\n")
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let key = request
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
            .split(separator: ":", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespaces)

        guard let key else {
            connection.cancel()
            return
        }

        let magic = Data("\(key)258EAFA5-E914-47DA-95CA-C5AB0DC85B11".utf8)
        let accept = Data(Insecure.SHA1.hash(data: magic)).base64EncodedString()
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "\r\n",
        ].joined(separator: "\r\n")

        let id = UUID()
        lock.withLock {
            clients[id] = connection
        }
        countHandler(lock.withLock { clients.count })

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state { self.remove(id) }
            if case .cancelled = state { self.remove(id) }
        }
        connection.send(content: Data(response.utf8), completion: .contentProcessed {
            [weak self] error in
            if error == nil {
                self?.receiveFrames(id: id, connection: connection, buffer: Data())
            } else {
                self?.remove(id)
            }
        })
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        let value = "\(host)"
        return value == "127.0.0.1" || value == "::1" || value == "localhost"
    }

    private func receiveFrames(id: UUID, connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }

            while let decoded = Self.decodeClientFrame(next) {
                next.removeFirst(decoded.consumed)
                switch decoded.opcode {
                case 0x1:
                    if let text = String(data: decoded.payload, encoding: .utf8) {
                        self.messageHandler(text)
                    }
                case 0x8:
                    connection.send(
                        content: Self.serverFrame(opcode: 0x8, payload: Data()),
                        completion: .contentProcessed { _ in connection.cancel() }
                    )
                    self.remove(id)
                    return
                case 0x9:
                    connection.send(
                        content: Self.serverFrame(opcode: 0xA, payload: decoded.payload),
                        completion: .contentProcessed { _ in }
                    )
                default:
                    break
                }
            }

            if isComplete || error != nil || next.count > 1_048_576 {
                self.remove(id)
                return
            }
            self.receiveFrames(id: id, connection: connection, buffer: next)
        }
    }

    private func remove(_ id: UUID) {
        let count = lock.withLock { () -> Int in
            clients.removeValue(forKey: id)?.cancel()
            return clients.count
        }
        countHandler(count)
    }

    private static func serverFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length <= UInt16.max {
            frame.append(126)
            frame.append(contentsOf: withUnsafeBytes(of: UInt16(length).bigEndian, Array.init))
        } else {
            frame.append(127)
            frame.append(contentsOf: withUnsafeBytes(of: UInt64(length).bigEndian, Array.init))
        }
        frame.append(payload)
        return frame
    }

    static func decodeClientFrame(
        _ data: Data
    ) -> (opcode: UInt8, payload: Data, consumed: Int)? {
        // Data.removeFirst 会保留非零 startIndex，先规范为零基数组再解码。
        let bytes = Array(data)
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        let isMasked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var index = 2

        if length == 126 {
            guard bytes.count >= index + 2 else { return nil }
            length = Int(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
            index += 2
        } else if length == 127 {
            guard bytes.count >= index + 8 else { return nil }
            var value: UInt64 = 0
            for byte in bytes[index..<(index + 8)] {
                value = (value << 8) | UInt64(byte)
            }
            guard value <= 1_048_576 else { return nil }
            length = Int(value)
            index += 8
        }

        let maskLength = isMasked ? 4 : 0
        guard bytes.count >= index + maskLength + length else { return nil }
        let mask = isMasked ? Array(bytes[index..<(index + 4)]) : []
        index += maskLength
        var payload = Data(bytes[index..<(index + length)])
        if isMasked {
            for offset in payload.indices {
                payload[offset] ^= mask[offset % 4]
            }
        }
        return (opcode, payload, index + length)
    }
}
