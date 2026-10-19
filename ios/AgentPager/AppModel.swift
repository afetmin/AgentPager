import AgentGridShared
import Observation
import SwiftUI

/// 把 `PhoneSession` 的状态流桥接给 SwiftUI。
@MainActor
@Observable
final class AppModel {
    private(set) var state = PhoneSessionState()
    private(set) var pairingError: String?
    private(set) var controlError: String?

    private let session: PhoneSession
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(session: PhoneSession) {
        self.session = session
    }

    convenience init() {
        let store = KeychainCredentialStore()
        let deviceID = (try? store.deviceID()) ?? UUID().uuidString.lowercased()
        self.init(session: PhoneSession(
            store: store,
            transport: URLSessionPhoneTransport(),
            deviceID: deviceID
        ))
    }

    func start() {
        guard observation == nil else { return }
        observation = Task { [session] in
            let states = await session.states()
            for await next in states {
                self.state = next
            }
        }
        Task { await session.start() }
    }

    func appBecameActive() {
        Task { await session.reconnectNow() }
    }

    func pair(with text: String) async -> Bool {
        pairingError = nil
        switch await session.pair(text) {
        case .connecting:
            return true
        case let .rejected(problem):
            pairingError = Self.message(for: problem)
            return false
        }
    }

    func send(_ action: ControlAction, to task: TaskSnapshot, value: String? = nil) {
        controlError = nil
        Task {
            if case let .rejected(problem) = await session.control(
                taskID: task.id,
                action: action,
                value: value
            ) {
                controlError = Self.message(for: problem)
            }
        }
    }

    func unpair() {
        Task { await session.unpair() }
    }

    func clearPairingError() {
        pairingError = nil
    }

    static func message(for problem: PhoneSessionProblem) -> String {
        switch problem {
        case .invalidPairing: "不是有效的配对内容，请重新扫描或复制 Mac 端的配对文本。"
        case .unsupportedVersion: "配对版本不受支持，请先升级 AgentPager。"
        case .invalidEndpoint: "配对信息中的地址无效。"
        case .invalidSecret: "配对信息中的密钥无效。"
        case .notPaired: "尚未配对。"
        case .notConnected: "未连接到 Mac，请稍后再试。"
        case .credentialFailure: "无法读写钥匙串中的配对信息。"
        case .sequenceFailure: "无法生成控制序号。"
        case .transportFailure: "无法连接到 Mac，请确认两台设备在同一局域网。"
        case .protocolFailure: "收到无法识别的消息。"
        }
    }
}
