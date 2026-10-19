import CryptoKit
import Foundation

public struct MessageEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public var version: Int
    public var messageId: UUID
    public var type: String
    public var sentAt: Int64
    public var payload: Payload

    public init(
        version: Int = 1,
        messageId: UUID = UUID(),
        type: String,
        sentAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        payload: Payload
    ) {
        self.version = version
        self.messageId = messageId
        self.type = type
        self.sentAt = sentAt
        self.payload = payload
    }
}

public struct SignedControlEnvelope: Codable, Equatable, Sendable {
    public var version: Int
    public var messageId: UUID
    public var type: String
    public var sentAt: Int64
    public var deviceId: String
    public var sequence: UInt64
    public var nonce: String
    public var payload: ControlPayload
    public var signature: String

    public init(
        version: Int = 1,
        messageId: UUID = UUID(),
        type: String = "control.request",
        sentAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        deviceId: String,
        sequence: UInt64,
        nonce: String,
        payload: ControlPayload,
        signature: String = ""
    ) {
        self.version = version
        self.messageId = messageId
        self.type = type
        self.sentAt = sentAt
        self.deviceId = deviceId
        self.sequence = sequence
        self.nonce = nonce
        self.payload = payload
        self.signature = signature
    }
}

public enum ProtocolError: Error, Equatable {
    case invalidVersion
    case expired
    case replayed
    case invalidSignature
}

public enum ControlSigner {
    public static func sign(_ envelope: SignedControlEnvelope, secret: Data) throws -> String {
        let key = SymmetricKey(data: secret)
        let authentication = HMAC<SHA256>.authenticationCode(
            for: try signingData(for: envelope),
            using: key
        )
        return Data(authentication).base64EncodedString()
    }

    public static func verify(_ envelope: SignedControlEnvelope, secret: Data) throws -> Bool {
        guard let signature = Data(base64Encoded: envelope.signature) else {
            return false
        }
        let key = SymmetricKey(data: secret)
        return HMAC<SHA256>.isValidAuthenticationCode(
            signature,
            authenticating: try signingData(for: envelope),
            using: key
        )
    }

    public static func signingData(for envelope: SignedControlEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(envelope.payload)
        guard let payloadText = String(data: payload, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                envelope.payload,
                .init(codingPath: [], debugDescription: "无法生成规范 JSON")
            )
        }

        return [
            String(envelope.version),
            envelope.messageId.uuidString.lowercased(),
            String(envelope.sentAt),
            envelope.deviceId,
            String(envelope.sequence),
            envelope.nonce,
            envelope.type,
            payloadText,
        ].joined(separator: "\n").data(using: .utf8) ?? Data()
    }
}

public struct ReplayGuard: Sendable {
    private var highestSequence: [String: UInt64] = [:]
    private var nonces: [String: Date] = [:]
    public var maxClockSkew: TimeInterval
    public var nonceLifetime: TimeInterval

    public init(maxClockSkew: TimeInterval = 90, nonceLifetime: TimeInterval = 5 * 60) {
        self.maxClockSkew = maxClockSkew
        self.nonceLifetime = nonceLifetime
    }

    public mutating func validate(
        _ envelope: SignedControlEnvelope,
        secret: Data,
        now: Date = .now
    ) throws {
        guard envelope.version == 1 else {
            throw ProtocolError.invalidVersion
        }

        let sentDate = Date(timeIntervalSince1970: TimeInterval(envelope.sentAt) / 1_000)
        guard abs(now.timeIntervalSince(sentDate)) <= maxClockSkew else {
            throw ProtocolError.expired
        }

        nonces = nonces.filter { now.timeIntervalSince($0.value) <= nonceLifetime }
        guard nonces[envelope.nonce] == nil,
              envelope.sequence > (highestSequence[envelope.deviceId] ?? 0) else {
            throw ProtocolError.replayed
        }

        guard try ControlSigner.verify(envelope, secret: secret) else {
            throw ProtocolError.invalidSignature
        }

        nonces[envelope.nonce] = now
        highestSequence[envelope.deviceId] = envelope.sequence
    }
}

public struct StateSnapshotPayload: Codable, Equatable, Sendable {
    public var tasks: [TaskSnapshot]
    /// Codex 用量。字段名保持不变以兼容旧版手机端。
    public var usage: UsageSnapshot?
    /// Claude Code 用量；旧版 Bridge 不发送，旧版手机端会忽略。
    public var claudeUsage: UsageSnapshot?
    public var focusedTaskID: String?
    public var pendingRequests: [PendingRequest]

    public init(
        tasks: [TaskSnapshot],
        usage: UsageSnapshot?,
        claudeUsage: UsageSnapshot? = nil,
        focusedTaskID: String?,
        pendingRequests: [PendingRequest] = []
    ) {
        // 状态发送前统一清洗，防止任一事件入口把内部工具包装泄漏到手机。
        self.tasks = tasks.map { task in
            var sanitizedTask = task
            sanitizedTask.latestStep = ToolStepSanitizer.sanitizedForTransport(
                task.latestStep
            )
            sanitizedTask.subagents = task.subagents.map { subagent in
                var sanitizedSubagent = subagent
                sanitizedSubagent.latestStep = ToolStepSanitizer.sanitizedForTransport(
                    subagent.latestStep
                )
                return sanitizedSubagent
            }
            return sanitizedTask
        }
        self.usage = usage
        self.claudeUsage = claudeUsage
        self.focusedTaskID = focusedTaskID
        self.pendingRequests = pendingRequests
    }
}

public enum PendingRequestKind: String, Codable, Sendable {
    case approval
    case question
}

public struct PendingRequest: Codable, Equatable, Sendable {
    public var taskID: String
    public var kind: PendingRequestKind
    public var summary: String?
    public var options: [String]

    public init(
        taskID: String,
        kind: PendingRequestKind,
        summary: String?,
        options: [String] = []
    ) {
        self.taskID = taskID
        self.kind = kind
        self.summary = summary
        self.options = options
    }
}

public struct ControlAckPayload: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var result: ControlResult
    public var reason: String?

    public init(requestID: UUID, result: ControlResult, reason: String? = nil) {
        self.requestID = requestID
        self.result = result
        self.reason = reason
    }
}

public enum ProtocolCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Int64(date.timeIntervalSince1970 * 1_000))
        }
        return try encoder.encode(value)
    }
}
