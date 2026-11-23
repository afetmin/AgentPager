import AgentGridShared
import SwiftUI

private struct PixelRenderKey: Equatable {
    let lifecycle: AgentLifecycle
    let activity: AgentActivity?
    let changedAt: Date
}

private struct PixelRenderedFrame {
    let samples: [PixelSample]
    let colorHex: UInt32
}

private struct PixelFrameTransition {
    let source: PixelRenderedFrame
    let startedAt: Date
}

struct PixelCoreView: View {
    let lifecycle: AgentLifecycle
    let activity: AgentActivity?
    let changedAt: Date
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var transition: PixelFrameTransition?

    init(
        lifecycle: AgentLifecycle,
        activity: AgentActivity?,
        changedAt: Date,
        compact: Bool = true
    ) {
        self.lifecycle = lifecycle
        self.activity = activity
        self.changedAt = changedAt
        self.compact = compact
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: reduceMotion)) { context in
            let frame = renderedFrame(
                for: renderKey,
                at: context.date,
                transition: transition
            )
            Canvas(rendersAsynchronously: false) { graphics, size in
                draw(
                    in: &graphics,
                    size: size,
                    frame: frame,
                    elapsed: elapsed(at: context.date, for: lifecycle)
                )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("任务状态 \(lifecycle.rawValue)")
        .onChange(of: renderKey) { oldKey, _ in
            guard !reduceMotion else {
                transition = nil
                return
            }
            let now = Date.now
            let source = renderedFrame(
                for: oldKey,
                at: now,
                transition: transition
            )
            transition = PixelFrameTransition(source: source, startedAt: now)
        }
        .onChange(of: reduceMotion) {
            if reduceMotion {
                transition = nil
            }
        }
    }

    private var renderKey: PixelRenderKey {
        PixelRenderKey(
            lifecycle: lifecycle,
            activity: activity,
            changedAt: changedAt
        )
    }

    private var frameInterval: TimeInterval {
        switch lifecycle {
        case .idle, .offline:
            1 / 30
        case .succeeded, .interrupted:
            1 / 30
        default:
            1 / 60
        }
    }

    private func elapsed(
        at date: Date,
        for lifecycle: AgentLifecycle
    ) -> TimeInterval {
        reduceMotion
            ? PixelMotion.reducedMotionElapsed(lifecycle: lifecycle)
            : max(0, date.timeIntervalSince(changedAt))
    }

    private func renderedFrame(
        for key: PixelRenderKey,
        at date: Date,
        transition: PixelFrameTransition?
    ) -> PixelRenderedFrame {
        let targetElapsed = reduceMotion
            ? PixelMotion.reducedMotionElapsed(lifecycle: key.lifecycle)
            : max(0, date.timeIntervalSince(key.changedAt))
        let target = PixelRenderedFrame(
            samples: PixelMotion.sample(
                lifecycle: key.lifecycle,
                activity: key.activity,
                elapsed: targetElapsed
            ),
            colorHex: PixelPalette.hex(
                lifecycle: key.lifecycle,
                activity: key.activity
            )
        )
        guard !reduceMotion, let transition else {
            return target
        }

        let progress = PixelMotion.transitionProgress(
            elapsed: max(0, date.timeIntervalSince(transition.startedAt))
        )
        guard progress < 1 else {
            return target
        }
        return PixelRenderedFrame(
            samples: PixelMotion.blendSamples(
                from: transition.source.samples,
                to: target.samples,
                progress: progress
            ),
            colorHex: PixelPalette.blend(
                from: transition.source.colorHex,
                to: target.colorHex,
                progress: progress
            )
        )
    }

    private func draw(
        in graphics: inout GraphicsContext,
        size: CGSize,
        frame: PixelRenderedFrame,
        elapsed: TimeInterval
    ) {
        let color = Color(pixelHex: frame.colorHex)
        let burst = PixelMotion.burst(
            lifecycle: lifecycle,
            elapsed: elapsed
        )
        let side = min(size.width, size.height) * (compact ? 0.68 : 0.62)
        let step = side / 3
        let cell = step * 0.58
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        for sample in frame.samples {
            let row = Double(sample.index / 3 - 1)
            let column = Double(sample.index % 3 - 1)
            let point = CGPoint(
                x: center.x + (column + sample.offsetX) * step,
                y: center.y + (row + sample.offsetY) * step
            )
            let cellSide = cell * sample.scale
            let rect = CGRect(
                x: point.x - cellSide / 2,
                y: point.y - cellSide / 2,
                width: cellSide,
                height: cellSide
            )

            // 每个亮格分别绘制外、中、内三层 Bloom，位移时光晕跟随该格。
            for glow in PixelMotion.glowLayers(
                intensity: sample.intensity,
                burst: burst
            ).reversed() where glow.opacity > 0 {
                graphics.drawLayer { layer in
                    layer.addFilter(.blur(radius: glow.blurRadius))
                    layer.fill(
                        Path(rect),
                        with: .color(color.opacity(glow.opacity))
                    )
                }
            }

            graphics.fill(
                Path(rect),
                with: .color(color.opacity(0.04))
            )
            graphics.fill(
                Path(rect),
                with: .color(color.opacity(0.03 + sample.intensity * 0.97))
            )
        }
    }
}
