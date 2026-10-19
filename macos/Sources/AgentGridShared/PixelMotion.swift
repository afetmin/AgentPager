import Foundation

public struct PixelSample: Equatable, Sendable {
    public var index: Int
    public var intensity: Double
    public var offsetX: Double
    public var offsetY: Double
    public var scale: Double

    public init(
        index: Int,
        intensity: Double,
        offsetX: Double,
        offsetY: Double,
        scale: Double
    ) {
        self.index = index
        self.intensity = intensity
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scale = scale
    }
}

public struct PixelGlowLayer: Equatable, Sendable {
    public var opacity: Double
    public var blurRadius: Double

    public init(opacity: Double, blurRadius: Double) {
        self.opacity = opacity
        self.blurRadius = blurRadius
    }
}

public enum PixelPalette {
    public static func hex(
        lifecycle: AgentLifecycle,
        activity: AgentActivity?
    ) -> UInt32 {
        switch lifecycle {
        case .waitingApproval: 0xFDBA4A
        case .waitingAnswer: 0xFACC15
        case .succeeded: 0x4ADE80
        case .interrupted, .offline: 0x64748B
        case .idle: 0x5EEAD4
        case .starting: 0xA78BFA
        case .running:
            switch activity {
            case .reading, .searching, .browsing: 0x5EEAD4
            case .editing: 0x818CF8
            case .executing: 0xFB923C
            case .testing: 0x60A5FA
            case .delegating: 0xA78BFA
            case .thinking, nil: 0xA78BFA
            }
        }
    }

    /// 在两种状态色之间逐通道插值，与手机端的颜色过渡保持一致。
    public static func blend(
        from: UInt32,
        to: UInt32,
        progress: Double
    ) -> UInt32 {
        let amount = min(1, max(0, progress))
        let red = interpolateChannel(from: from >> 16, to: to >> 16, progress: amount)
        let green = interpolateChannel(from: from >> 8, to: to >> 8, progress: amount)
        let blue = interpolateChannel(from: from, to: to, progress: amount)
        return red << 16 | green << 8 | blue
    }

    private static func interpolateChannel(
        from: UInt32,
        to: UInt32,
        progress: Double
    ) -> UInt32 {
        let start = Double(from & 0xFF)
        let end = Double(to & 0xFF)
        return UInt32(min(255, max(0, start + (end - start) * progress)))
    }
}

public enum PixelMotion {
    public static let transitionDuration: TimeInterval = 0.24
    public static let innerGlowOpacity = 0.68
    public static let middleGlowOpacity = 0.36
    public static let outerGlowOpacity = 0.17
    public static let innerGlowRadius = 3.8
    public static let middleGlowRadius = 9.0
    public static let outerGlowRadius = 18.0

    private static let spiralOrder = [4, 1, 2, 5, 8, 7, 6, 3, 0]
    private static let perimeterOrder = [0, 1, 2, 5, 8, 7, 6, 3]
    private static let successOrder = [6, 7, 5, 2]
    private static let thinkingOrder = [0, 2, 8, 6]

    public static func sample(
        lifecycle: AgentLifecycle,
        activity: AgentActivity?,
        elapsed: TimeInterval
    ) -> [PixelSample] {
        (0..<9).map { index in
            let row = Double(index / 3 - 1)
            let column = Double(index % 3 - 1)
            let phase = Double(index) * 0.73
            let t = max(0, elapsed)
            let values = motion(
                lifecycle: lifecycle,
                activity: activity,
                index: index,
                row: row,
                column: column,
                phase: phase,
                elapsed: t
            )
            return PixelSample(
                index: index,
                intensity: clamp(values.intensity, 0, 1),
                offsetX: clamp(values.offsetX, -1, 1),
                offsetY: clamp(values.offsetY, -1, 1),
                scale: clamp(values.scale, 0.62, 1.28)
            )
        }
    }

    /// 先压低暗格能量，再加强中高亮格，使负空间和手机端保持一致。
    public static func glowLayers(
        intensity: Double,
        burst: Double
    ) -> [PixelGlowLayer] {
        let energy = glowEnergy(intensity: intensity, burst: burst)
        return [
            PixelGlowLayer(opacity: energy * innerGlowOpacity, blurRadius: innerGlowRadius),
            PixelGlowLayer(opacity: energy * middleGlowOpacity, blurRadius: middleGlowRadius),
            PixelGlowLayer(opacity: energy * outerGlowOpacity, blurRadius: outerGlowRadius),
        ]
    }

    public static func glowEnergy(
        intensity: Double,
        burst: Double
    ) -> Double {
        let visibleIntensity = clamp((intensity - 0.06) / 0.94, 0, 1)
        return clamp(visibleIntensity * burst * 1.18, 0, 1.45)
    }

    public static func burst(
        lifecycle: AgentLifecycle,
        elapsed: TimeInterval
    ) -> Double {
        guard elapsed < 1.2 else { return 1 }
        switch lifecycle {
        case .waitingApproval, .waitingAnswer, .succeeded:
            return 1 + 0.4 * easeOutCubic(1 - elapsed / 1.2)
        default:
            return 1
        }
    }

    /// 状态切换使用与手机端相同的强减速曲线。
    public static func transitionProgress(elapsed: TimeInterval) -> Double {
        let linear = clamp(elapsed / transitionDuration, 0, 1)
        return easeOutQuint(linear)
    }

    /// 对两组 3×3 样本逐格插值，保持快速连续切换时的视觉连续性。
    public static func blendSamples(
        from: [PixelSample],
        to: [PixelSample],
        progress: Double
    ) -> [PixelSample] {
        let amount = clamp(progress, 0, 1)
        guard amount > 0 else { return from }
        guard amount < 1 else { return to }

        return to.enumerated().map { position, target in
            let source = from.indices.contains(position) && from[position].index == target.index
                ? from[position]
                : target
            return PixelSample(
                index: target.index,
                intensity: lerp(from: source.intensity, to: target.intensity, progress: amount),
                offsetX: lerp(from: source.offsetX, to: target.offsetX, progress: amount),
                offsetY: lerp(from: source.offsetY, to: target.offsetY, progress: amount),
                scale: lerp(from: source.scale, to: target.scale, progress: amount)
            )
        }
    }

    /// 减少动态效果时选择有辨识度的静止帧。
    public static func reducedMotionElapsed(
        lifecycle: AgentLifecycle
    ) -> TimeInterval {
        switch lifecycle {
        case .starting:
            0.82
        case .succeeded, .interrupted:
            1.2
        default:
            0.68
        }
    }

    private static func motion(
        lifecycle: AgentLifecycle,
        activity: AgentActivity?,
        index: Int,
        row: Double,
        column: Double,
        phase: Double,
        elapsed t: Double
    ) -> (intensity: Double, offsetX: Double, offsetY: Double, scale: Double) {
        switch lifecycle {
        case .offline:
            let cycle = positiveModulo(t, 3.6)
            let pulseValue = max(
                pulse(cycle, center: 0.12, radius: 0.10),
                pulse(cycle, center: 0.34, radius: 0.10) * 0.42
            )
            let belongsToCross = abs(abs(row) - abs(column)) < 0.01
            return (
                belongsToCross ? 0.20 + 0.24 * pulseValue : 0.025,
                row == 0 ? column * 0.08 : 0,
                belongsToCross ? -0.035 * pulseValue : 0.04,
                belongsToCross ? 0.80 + 0.08 * pulseValue : 0.66
            )
        case .idle:
            let distance = abs(row) + abs(column)
            let breath = wave(t * 1.12)
            let base = switch distance {
            case 0: 0.58
            case 1: 0.18
            default: 0.035
            }
            let amplitude = switch distance {
            case 0: 0.32
            case 1: 0.18
            default: 0.045
            }
            return (
                base + amplitude * breath,
                column * 0.015 * breath,
                row * 0.015 * breath,
                0.76 + (0.08 + 0.12 * breath) / (distance + 1)
            )
        case .starting:
            let order = spiralOrder.firstIndex(of: index) ?? 0
            let localProgress = clamp((t - Double(order) * 0.055) / 0.24, 0, 1)
            let ignition = easeOutQuint(localProgress)
            let spark = pulse(
                t,
                center: Double(order) * 0.055 + 0.13,
                radius: 0.13
            )
            let settle = easeOutCubic(clamp((t - 0.66) / 0.30, 0, 1))
            let belongsToCore = abs(row) + abs(column) <= 1
            let settledIntensity = belongsToCore ? 0.72 : 0.12
            let settledScale = belongsToCore ? 0.96 : 0.74
            let ignitionIntensity = 0.08 + 0.58 * ignition + 0.34 * spark
            let ignitionScale = 0.68 + 0.28 * ignition + 0.08 * spark
            return (
                lerp(from: ignitionIntensity, to: settledIntensity, progress: settle),
                -column * 0.54 * (1 - ignition),
                -row * 0.54 * (1 - ignition),
                lerp(from: ignitionScale, to: settledScale, progress: settle)
            )
        case .waitingApproval:
            let cycle = positiveModulo(t, 1.55)
            let beat = max(
                pulse(cycle, center: 0.13, radius: 0.12),
                pulse(cycle, center: 0.39, radius: 0.11) * 0.76
            )
            let centerImpact = max(
                pulse(cycle, center: 0.19, radius: 0.12),
                pulse(cycle, center: 0.45, radius: 0.11) * 0.76
            )
            let isCenter = row == 0 && column == 0
            return (
                isCenter ? 0.24 + 0.76 * centerImpact : 0.34 + 0.66 * beat,
                isCenter ? 0 : -column * 0.16 * beat,
                isCenter ? 0 : -row * 0.16 * beat,
                0.88 + 0.16 * (isCenter ? centerImpact : beat)
            )
        case .waitingAnswer:
            let cycle = positiveModulo(t, 1.75)
            let columnOrder = Int((column + 1).rounded())
            let dot = pulse(
                cycle,
                center: 0.20 + Double(columnOrder) * 0.27,
                radius: 0.18
            )
            let belongsToEllipsis = row == 0
            return (
                belongsToEllipsis ? 0.28 + 0.72 * dot : 0.025 + 0.12 * dot,
                0,
                belongsToEllipsis ? -0.10 * dot : -row * 0.14 * dot,
                belongsToEllipsis ? 0.86 + 0.18 * dot : 0.68 + 0.12 * dot
            )
        case .succeeded:
            let burstProgress = min(1, t / 0.30)
            let explosion = sin(burstProgress * .pi) * 0.58
            let resolve = easeOutQuint(clamp((t - 0.16) / 0.48, 0, 1))
            let pathOrder = successOrder.firstIndex(of: index)
            let belongsToCheck = pathOrder != nil
            let draw = pathOrder.map {
                easeOutQuint(clamp((t - 0.32 - Double($0) * 0.055) / 0.18, 0, 1))
            } ?? 0
            let flourish = pathOrder.map {
                pulse(t, center: 0.78 + Double($0) * 0.035, radius: 0.10)
            } ?? 0
            return (
                belongsToCheck
                    ? 0.20 + 0.74 * draw + 0.06 * flourish
                    : 0.82 * (1 - resolve) + 0.035,
                column * explosion * (1 - resolve),
                row * explosion * (1 - resolve),
                belongsToCheck ? 0.82 + 0.16 * draw + 0.08 * flourish : 0.70
            )
        case .interrupted:
            let progress = easeOutQuint(min(1, t / 0.42))
            let severed = (row == 0 && column == 0) || (row == 1 && column == -1)
            let flicker = t < 0.34 ? 0.30 + 0.70 * wave(t * 34 + phase) : 0
            let settledIntensity = severed ? 0.025 : (row == 0 ? 0.22 : 0.42)
            let settledX = row == 0
                ? (column < 0 ? -0.18 : 0.18)
                : column * 0.035
            let settledY = row == 0 ? 0.12 : row * 0.02
            let jitter = sin(t * 58 + phase) * 0.22 * (1 - progress)
            return (
                flicker * (1 - progress) + settledIntensity * progress,
                jitter + settledX * progress,
                settledY * progress,
                (0.92 + 0.08 * wave(t * 9 + phase)) * (1 - progress)
                    + (severed ? 0.68 : 0.86) * progress
            )
        case .running:
            return activityMotion(
                activity: activity,
                row: row,
                column: column,
                phase: phase,
                elapsed: t
            )
        }
    }

    private static func activityMotion(
        activity: AgentActivity?,
        row: Double,
        column: Double,
        phase: Double,
        elapsed t: Double
    ) -> (intensity: Double, offsetX: Double, offsetY: Double, scale: Double) {
        switch activity {
        case .reading:
            let scanPosition = -1 + positiveModulo(t * 0.72, 1) * 2
            let scan = clamp(1 - abs(row - scanPosition) / 0.82, 0, 1)
            return (
                0.10 + 0.90 * scan,
                column * 0.035 * scan,
                -0.08 + 0.16 * scan,
                0.84 + 0.18 * scan
            )
        case .searching:
            let index = Int((row + 1).rounded()) * 3 + Int((column + 1).rounded())
            let order = perimeterOrder.firstIndex(of: index)
            let travel = positiveModulo(t * 0.48, 1)
            let energy = order.map {
                cyclicPulse(
                    travel,
                    center: Double($0) / Double(perimeterOrder.count),
                    radius: 0.17
                )
            } ?? 0.18 + 0.12 * wave(t * 2.2)
            return (
                0.08 + 0.92 * energy,
                column * 0.08 * energy,
                row * 0.08 * energy,
                0.80 + 0.22 * energy
            )
        case .browsing:
            let pagePosition = 1.25 - positiveModulo(t * 0.62, 1) * 2.5
            let band = clamp(1 - abs(row - pagePosition) / 0.72, 0, 1)
            let columnLead = 1 - (column + 1) * 0.10
            return (
                0.10 + 0.90 * band * columnLead,
                0,
                -0.18 * band,
                0.82 + 0.18 * band
            )
        case .editing:
            let stroke = wave(t * 5.0 - row * 1.18)
            let caret = pulse(
                positiveModulo(t, 1.12),
                center: 0.14,
                radius: 0.12
            )
            let isCaret = column == 0
            let energy = isCaret ? max(caret, stroke * 0.56) : stroke
            return (
                0.12 + 0.88 * energy,
                isCaret ? 0 : -column * (0.08 + 0.10 * stroke),
                -row * 0.035 * stroke,
                0.84 + 0.18 * energy
            )
        case .executing:
            let stream = positiveModulo(t * 2.4 + Double(Int(phase * 10) % 3) / 3, 1)
            let energy = sin(.pi * stream)
            return (0.24 + 0.76 * energy, column * 0.05, 0.48 - stream * 0.96, 0.86 + 0.17 * energy)
        case .testing:
            let cycle = positiveModulo(t, 1.46)
            let diagonal = row + column + 2
            let sweepPosition = clamp(cycle / 0.94, 0, 1) * 4
            let scan = clamp(1 - abs(diagonal - sweepPosition) / 0.82, 0, 1)
            let verdict = pulse(cycle, center: 1.15, radius: 0.15)
            let energy = max(scan, verdict)
            return (
                0.08 + 0.92 * energy,
                column * 0.08 * scan,
                row * 0.08 * scan,
                0.82 + 0.20 * energy
            )
        case .delegating:
            let cycle = positiveModulo(t, 1.34)
            let distance = (abs(row) + abs(column)) / 2
            let branch = pulse(
                cycle,
                center: 0.14 + distance * 0.62,
                radius: 0.19
            )
            let isCenter = distance == 0
            return (
                (isCenter ? 0.48 : 0.10) + (isCenter ? 0.42 : 0.90) * branch,
                column * 0.20 * branch,
                row * 0.14 * branch,
                0.82 + 0.20 * branch
            )
        case .thinking, nil:
            let index = Int((row + 1).rounded()) * 3 + Int((column + 1).rounded())
            let order = thinkingOrder.firstIndex(of: index)
            let travel = positiveModulo(t * 0.34, 1)
            let cornerEnergy = order.map {
                cyclicPulse(
                    travel,
                    center: Double($0) / Double(thinkingOrder.count),
                    radius: 0.22
                )
            } ?? 0
            let isCenter = row == 0 && column == 0
            let energy = isCenter ? 0.46 + 0.18 * wave(t * 1.8) : cornerEnergy
            return (
                isCenter || order != nil ? 0.08 + 0.92 * energy : 0.035,
                order != nil ? -column * 0.08 * cornerEnergy : 0,
                order != nil ? -row * 0.08 * cornerEnergy : 0,
                0.78 + 0.24 * energy
            )
        }
    }

    private static func wave(_ value: Double) -> Double {
        (sin(value) + 1) / 2
    }

    private static func pulse(
        _ value: Double,
        center: Double,
        radius: Double
    ) -> Double {
        let distance = abs(value - center)
        guard distance < radius else { return 0 }
        return (cos(.pi * distance / radius) + 1) / 2
    }

    private static func cyclicPulse(
        _ value: Double,
        center: Double,
        radius: Double
    ) -> Double {
        let directDistance = abs(value - center)
        let distance = min(directDistance, 1 - directDistance)
        guard distance < radius else { return 0 }
        return (cos(.pi * distance / radius) + 1) / 2
    }

    private static func positiveModulo(_ value: Double, _ divisor: Double) -> Double {
        let result = value.truncatingRemainder(dividingBy: divisor)
        return result >= 0 ? result : result + divisor
    }

    private static func easeOutCubic(_ value: Double) -> Double {
        1 - pow(1 - clamp(value, 0, 1), 3)
    }

    private static func easeOutQuint(_ value: Double) -> Double {
        1 - pow(1 - clamp(value, 0, 1), 5)
    }

    private static func lerp(
        from: Double,
        to: Double,
        progress: Double
    ) -> Double {
        from + (to - from) * progress
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}
