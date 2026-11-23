import Testing
@testable import AgentGridShared

@Test("像素状态使用连续强度与连续位移")
func pixelMotionIsContinuous() {
    let first = PixelMotion.sample(
        lifecycle: .running,
        activity: .editing,
        elapsed: 0.100
    )
    let second = PixelMotion.sample(
        lifecycle: .running,
        activity: .editing,
        elapsed: 0.116
    )

    #expect(first.count == 9)
    #expect(second.count == 9)
    #expect(zip(first, second).contains { lhs, rhs in
        abs(lhs.intensity - rhs.intensity) > 0.0001
            || abs(lhs.offsetX - rhs.offsetX) > 0.0001
            || abs(lhs.offsetY - rhs.offsetY) > 0.0001
    })
    #expect(zip(first, second).allSatisfy { lhs, rhs in
        abs(lhs.intensity - rhs.intensity) < 0.30
            && abs(lhs.offsetX - rhs.offsetX) < 0.30
            && abs(lhs.offsetY - rhs.offsetY) < 0.30
    })
    #expect(first.allSatisfy {
        abs($0.offsetX) <= 1 && abs($0.offsetY) <= 1
    })
}

@Test("每个亮像素保留与手机一致的三层 Bloom")
func eachLitPixelOwnsBloomLayers() {
    let lit = PixelMotion.glowLayers(intensity: 0.82, burst: 1.0)
    let dark = PixelMotion.glowLayers(intensity: 0, burst: 1.0)

    #expect(lit.count == 3)
    #expect(lit.allSatisfy { $0.opacity > 0 && $0.blurRadius > 0 })
    #expect(lit[0].opacity > lit[1].opacity)
    #expect(lit[1].opacity > lit[2].opacity)
    #expect(lit[0].opacity > 0.60)
    #expect(lit[2].opacity > 0.15)
    #expect(lit[2].blurRadius >= 18)
    #expect(dark.allSatisfy { $0.opacity == 0 })
}

@Test("同一状态只使用一个色相家族")
func lifecyclePaletteUsesSingleHueFamily() {
    #expect(PixelPalette.hex(lifecycle: .running, activity: .thinking) == 0xA78BFA)
    #expect(PixelPalette.hex(lifecycle: .running, activity: .editing) == 0x818CF8)
    #expect(PixelPalette.hex(lifecycle: .running, activity: .executing) == 0xFB923C)
    #expect(PixelPalette.hex(lifecycle: .waitingApproval, activity: nil) == 0xFDBA4A)
    #expect(PixelPalette.hex(lifecycle: .succeeded, activity: nil) == 0x4ADE80)
}

@Test("第一排状态和中断态保留可辨识的像素图案")
func quietLifecyclePatternsRemainRecognizable() {
    let cases: [(AgentLifecycle, AgentActivity?)] = [
        (.offline, nil),
        (.idle, nil),
        (.starting, nil),
        (.running, .editing),
        (.interrupted, nil),
    ]

    for (lifecycle, activity) in cases {
        let samples = PixelMotion.sample(
            lifecycle: lifecycle,
            activity: activity,
            elapsed: 1.6
        )
        let intensityRange = range(samples.map(\.intensity))
        let horizontalRange = range(samples.map(\.offsetX))
        let verticalRange = range(samples.map(\.offsetY))
        let scaleRange = range(samples.map(\.scale))

        #expect(
            max(intensityRange, horizontalRange, verticalRange, scaleRange) >= 0.08,
            "状态 \(lifecycle.rawValue) 的稳定帧缺少可辨识图案"
        )
    }
}

@Test("成功态最终收束为与手机一致的像素勾")
func succeededLifecycleSettlesIntoCheckmark() {
    let samples = PixelMotion.sample(
        lifecycle: .succeeded,
        activity: nil,
        elapsed: 1.2
    )
    let litIndices = Set(samples.filter { $0.intensity >= 0.80 }.map(\.index))
    let darkIndices = Set(samples.filter { $0.intensity <= 0.10 }.map(\.index))

    #expect(litIndices == Set([2, 5, 6, 7]))
    #expect(darkIndices == Set([0, 1, 3, 4, 8]))
}

@Test("等待回答态使用与手机一致的中排三点")
func waitingAnswerUsesMiddleEllipsis() {
    let samples = PixelMotion.sample(
        lifecycle: .waitingAnswer,
        activity: nil,
        elapsed: 0.20
    )

    #expect(samples[3].intensity > 0.90)
    #expect(samples[3].intensity > samples[4].intensity)
    #expect(samples[4].intensity >= samples[5].intensity)
    #expect(samples.enumerated().allSatisfy { index, sample in
        (3...5).contains(index) || sample.intensity < 0.18
    })
}

@Test("运行活动在同一时刻拥有不同运动签名")
func runningActivitiesHaveDistinctMotionSignatures() {
    let signatures = Dictionary(uniqueKeysWithValues: AgentActivity.allCases.map { activity in
        (
            activity,
            PixelMotion.sample(
                lifecycle: .running,
                activity: activity,
                elapsed: 0.74
            )
        )
    })

    for (index, lhs) in AgentActivity.allCases.enumerated() {
        for rhs in AgentActivity.allCases.dropFirst(index + 1) {
            let distance = zip(signatures[lhs, default: []], signatures[rhs, default: []])
                .reduce(0.0) { result, samples in
                    result
                        + abs(samples.0.intensity - samples.1.intensity)
                        + abs(samples.0.offsetX - samples.1.offsetX)
                        + abs(samples.0.offsetY - samples.1.offsetY)
                        + abs(samples.0.scale - samples.1.scale)
                }
            #expect(distance > 0.20, "活动 \(lhs.rawValue) 与 \(rhs.rawValue) 的像素签名过于相似")
        }
    }
}

@Test("状态过渡从旧帧连续插值到新帧")
func lifecycleTransitionBlendsFrames() {
    let from = PixelMotion.sample(
        lifecycle: .idle,
        activity: nil,
        elapsed: 0.68
    )
    let to = PixelMotion.sample(
        lifecycle: .waitingApproval,
        activity: nil,
        elapsed: 0
    )

    #expect(PixelMotion.blendSamples(from: from, to: to, progress: 0) == from)
    #expect(PixelMotion.blendSamples(from: from, to: to, progress: 1) == to)

    let midpoint = PixelMotion.blendSamples(from: from, to: to, progress: 0.5)
    for index in midpoint.indices {
        #expect(
            abs(midpoint[index].intensity - (from[index].intensity + to[index].intensity) / 2)
                < 0.0001
        )
    }
    #expect(PixelMotion.transitionProgress(elapsed: 0.08) > 0.33)
    #expect(abs(PixelMotion.transitionProgress(elapsed: 0.24) - 1) < 0.0001)
    #expect(
        PixelPalette.blend(
            from: 0x000000,
            to: 0xFFFFFF,
            progress: 0.5
        ) == 0x7F7F7F
    )
}

private func range(_ values: [Double]) -> Double {
    guard let minimum = values.min(), let maximum = values.max() else { return 0 }
    return maximum - minimum
}
