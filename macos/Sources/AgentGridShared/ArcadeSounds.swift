import Foundation

public enum ArcadeSoundCue: CaseIterable, Sendable {
    case taskAcknowledge
    case inputRequired
    case taskComplete
    case taskInterrupted

    var priority: Int {
        switch self {
        case .inputRequired: 400
        case .taskComplete: 300
        case .taskInterrupted: 200
        case .taskAcknowledge: 100
        }
    }
}

extension AgentLifecycle {
    fileprivate var soundCue: ArcadeSoundCue? {
        switch self {
        // 只在真正进入运行态时确认，避免 starting -> running 连响两次。
        case .running: .taskAcknowledge
        case .waitingApproval, .waitingAnswer: .inputRequired
        case .succeeded: .taskComplete
        case .interrupted: .taskInterrupted
        default: nil
        }
    }
}

/// 只根据任务快照差分选择提示音，避免界面刷新或普通内容更新重复播放。
/// 每次新连接使用新的实例：第一份快照只用来建立基线，不发声。
public struct TaskSoundTracker: Sendable {
    private var initialized = false
    private var previousLifecycles: [String: AgentLifecycle] = [:]

    public init() {}

    public mutating func nextCue(tasks: [TaskSnapshot], soundEnabled: Bool = true) -> ArcadeSoundCue? {
        let current = Dictionary(tasks.map { ($0.id, $0.lifecycle) }, uniquingKeysWith: { $1 })
        defer { previousLifecycles = current }
        guard initialized else {
            initialized = true
            return nil
        }
        guard soundEnabled else { return nil }

        return tasks
            .filter { !$0.isMuted && previousLifecycles[$0.id] != $0.lifecycle }
            .compactMap { task in task.lifecycle.soundCue.map { ($0, task.updatedAt) } }
            .max { lhs, rhs in
                lhs.0.priority != rhs.0.priority
                    ? lhs.0.priority < rhs.0.priority
                    : lhs.1 < rhs.1
            }?
            .0
    }
}

/// 与 Android 端一致的复古提示音：方波、失谐声部与三角波叠加，再做硬削波。
public enum ArcadeSoundSynthesizer {
    public static let defaultSampleRate = 48_000

    /// 单声道浮点 PCM，取值范围 [-1, 1]。
    public static func render(_ cue: ArcadeSoundCue, sampleRate: Int = defaultSampleRate) -> [Float] {
        precondition(sampleRate >= 8_000, "采样率过低")
        let raw: [Float]
        switch cue {
        case .taskAcknowledge: raw = acknowledge(sampleRate)
        case .inputRequired: raw = inputRequired(sampleRate)
        case .taskComplete: raw = taskComplete(sampleRate)
        case .taskInterrupted: raw = taskInterrupted(sampleRate)
        }
        return raw.map { min(1, max(-1, $0 * 1.5)) }
    }

    public static func duration(of cue: ArcadeSoundCue) -> TimeInterval {
        switch cue {
        case .taskAcknowledge: 0.22
        case .inputRequired: 0.6
        case .taskComplete: 1.1
        case .taskInterrupted: 0.5
        }
    }

    private static func acknowledge(_ rate: Int) -> [Float] {
        var out = buffer(0.22, rate)
        pulse(&out, rate, 987.76, 0.0, 0.055, 0.2, 0.004, 0.008)
        pulse(&out, rate, 1_318.51, 0.06, 0.12, 0.24, 0.008, 0.018)
        return out
    }

    private static func inputRequired(_ rate: Int) -> [Float] {
        var out = buffer(0.6, rate)
        pulse(&out, rate, 523.25, 0.0, 0.1, 0.2, 0.005, 0.02)
        pulse(&out, rate, 698.46, 0.1, 0.1, 0.22, 0.005, 0.02)
        pulse(&out, rate, 698.46, 0.28, 0.1, 0.2, 0.005, 0.02)
        pulse(&out, rate, 880.0, 0.38, 0.16, 0.21, 0.005, 0.03)
        triangle(&out, rate, 174.61, 0.0, 0.5, 0.05, 0.005, 0.1)
        return out
    }

    private static func taskComplete(_ rate: Int) -> [Float] {
        var out = buffer(1.1, rate)
        pulse(&out, rate, 659.25, 0.0, 0.07, 0.2, 0.005, 0.02)
        pulse(&out, rate, 783.99, 0.08, 0.07, 0.2, 0.005, 0.02)
        pulse(&out, rate, 1_046.5, 0.16, 0.55, 0.22, 0.005, 0.25)
        triangle(&out, rate, 523.25, 0.16, 0.55, 0.1, 0.005, 0.2)
        triangle(&out, rate, 1_046.5, 0.5, 0.5, 0.04, 0.005, 0.2)
        return out
    }

    private static func taskInterrupted(_ rate: Int) -> [Float] {
        var out = buffer(0.5, rate)
        for (index, frequency) in [261.63, 220.0, 174.61].enumerated() {
            let start = Double(index) * 0.13
            pulse(&out, rate, frequency, start, 0.12, 0.2, 0.005, 0.015)
            pulse(&out, rate, frequency * 1.015, start, 0.12, 0.12, 0.005, 0.015)
        }
        triangle(&out, rate, 87.305, 0.0, 0.4, 0.06, 0.005, 0.1)
        return out
    }

    private static func buffer(_ seconds: Double, _ rate: Int) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    private static func pulse(
        _ out: inout [Float], _ rate: Int, _ frequency: Double,
        _ start: Double, _ duration: Double, _ amplitude: Double,
        _ attack: Double, _ release: Double, duty: Double = 0.5
    ) {
        wave(&out, rate, start, duration, amplitude, attack, release) { elapsed in
            (elapsed * frequency).truncatingRemainder(dividingBy: 1) < duty ? 1 : -1
        }
    }

    private static func triangle(
        _ out: inout [Float], _ rate: Int, _ frequency: Double,
        _ start: Double, _ duration: Double, _ amplitude: Double,
        _ attack: Double, _ release: Double
    ) {
        wave(&out, rate, start, duration, amplitude, attack, release) { elapsed in
            let phase = (elapsed * frequency).truncatingRemainder(dividingBy: 1)
            return 2 * abs(2 * phase - 1) - 1
        }
    }

    private static func wave(
        _ out: inout [Float], _ rate: Int,
        _ start: Double, _ duration: Double, _ amplitude: Double,
        _ attack: Double, _ release: Double,
        _ waveform: (Double) -> Double
    ) {
        let first = Int(start * Double(rate))
        let count = Int(duration * Double(rate))
        for offset in 0..<count {
            let index = first + offset
            if index >= out.count { return }
            let elapsed = Double(offset) / Double(rate)
            let attackGain = attack <= 0 ? 1 : min(1, max(0, elapsed / attack))
            let remaining = Double(count - offset) / Double(rate)
            let releaseGain = release <= 0 ? 1 : min(1, max(0, remaining / release))
            out[index] += Float(waveform(elapsed) * amplitude * min(attackGain, releaseGain))
        }
    }
}
