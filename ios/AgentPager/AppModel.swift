import AgentGridShared
import Observation
import SwiftUI

/// 把 `PhoneSession` 的状态流桥接给 SwiftUI，并维护任务列表的展示投影。
@MainActor
@Observable
final class AppModel {
    private(set) var state = PhoneSessionState()
    private(set) var projection = TaskDashboardProjection.empty
    private(set) var pairingError: String?
    private(set) var controlError: String?

    /// 专用模式：保持屏幕常亮，并隐藏状态栏与 Home 指示条，把设备当作桌面状态终端。
    var terminalMode: Bool {
        didSet { Self.defaults.set(terminalMode, forKey: Self.terminalModeKey) }
    }

    /// 提示音：任务进入运行、等待输入、完成或中断时播放，只在前台连接期间有效。
    var soundEnabled: Bool {
        didSet { Self.defaults.set(soundEnabled, forKey: Self.soundEnabledKey) }
    }

    private let session: PhoneSession
    @ObservationIgnored private let sound = SoundEngine()
    @ObservationIgnored private var soundTracker = TaskSoundTracker()
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var idleTransition: Task<Void, Never>?

    private static let terminalModeKey = "terminal-mode"
    private static let soundEnabledKey = "sound-enabled"
    private static var defaults: UserDefaults { .standard }

    init(session: PhoneSession) {
        self.session = session
        terminalMode = Self.defaults.object(forKey: Self.terminalModeKey) as? Bool ?? true
        soundEnabled = Self.defaults.object(forKey: Self.soundEnabledKey) as? Bool ?? true
    }

    convenience init() {
        let store = KeychainCredentialStore()
        let deviceID = (try? store.deviceID()) ?? UUID().uuidString.lowercased()
        self.init(session: PhoneSession(
            store: store,
            transport: URLSessionPhoneTransport(),
            locator: BonjourBridgeLocator(),
            deviceID: deviceID
        ))
    }

    func start() {
        guard observation == nil else { return }
        observation = Task { [session] in
            let states = await session.states()
            for await next in states {
                self.apply(next)
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

    func send(_ action: ControlAction, taskID: String, value: String? = nil) {
        controlError = nil
        Task {
            if case let .rejected(problem) = await session.control(
                taskID: taskID,
                action: action,
                value: value
            ) {
                controlError = Self.message(for: problem)
            }
        }
    }

    /// 点开任务：聚焦，并把未读的完成任务标为已读。
    func select(_ task: TaskSnapshot) {
        if task.isUnread {
            send(.markRead, taskID: task.id)
        }
        projection = projection.focusing(task.id)
    }

    func toggleDashboard() {
        projection = projection.togglingDashboard()
    }

    func unpair() {
        Task { await session.unpair() }
    }

    func clearPairingError() {
        pairingError = nil
    }

    private func apply(_ next: PhoneSessionState) {
        let previous = state
        state = next
        playCueIfNeeded(previous: previous, next: next)
        if next.snapshot != previous.snapshot {
            reproject()
        }
    }

    /// 每次新连接重新建立基线：第一份快照不发声，之后只对生命周期变化发声。
    private func playCueIfNeeded(previous: PhoneSessionState, next: PhoneSessionState) {
        guard next.link == .connected else { return }
        if previous.link != .connected {
            soundTracker = TaskSoundTracker()
        }
        guard next.snapshotRevision != previous.snapshotRevision else { return }
        if let cue = soundTracker.nextCue(tasks: next.snapshot.tasks, soundEnabled: soundEnabled) {
            sound.play(cue)
        }
    }

    private func reproject() {
        projection = TaskDashboardProjector.project(
            snapshot: state.snapshot,
            previous: projection,
            now: .now
        )
        scheduleIdleTransition()
    }

    /// 全部任务结束后，到点自动切换到状态态。
    private func scheduleIdleTransition() {
        idleTransition?.cancel()
        idleTransition = nil
        guard let transitionAt = projection.nextDashboardAt else { return }
        idleTransition = Task { [weak self] in
            let delay = max(0, transitionAt.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.reproject()
        }
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
