import Foundation
import Testing
@testable import AgentGridShared

private func task(_ id: String, _ lifecycle: AgentLifecycle, updatedAt: TimeInterval = 0, muted: Bool = false) -> TaskSnapshot {
    TaskSnapshot(
        id: id, source: .codexCLI, projectName: id, lifecycle: lifecycle,
        updatedAt: Date(timeIntervalSince1970: updatedAt), isMuted: muted
    )
}

@Test("第一份快照只建立基线，不发声")
func firstSnapshotIsSilent() {
    var tracker = TaskSoundTracker()

    #expect(tracker.nextCue(tasks: [task("a", .running), task("b", .waitingApproval)]) == nil)
    #expect(tracker.nextCue(tasks: [task("a", .running), task("b", .waitingApproval)]) == nil)
}

@Test("生命周期变化触发对应提示音，starting 不发声")
func lifecycleChangesMapToCues() {
    var tracker = TaskSoundTracker()
    _ = tracker.nextCue(tasks: [task("a", .idle)])

    #expect(tracker.nextCue(tasks: [task("a", .starting)]) == nil)
    #expect(tracker.nextCue(tasks: [task("a", .running)]) == .taskAcknowledge)
    #expect(tracker.nextCue(tasks: [task("a", .waitingApproval)]) == .inputRequired)
    #expect(tracker.nextCue(tasks: [task("a", .waitingAnswer)]) == .inputRequired)
    #expect(tracker.nextCue(tasks: [task("a", .succeeded)]) == .taskComplete)
    #expect(tracker.nextCue(tasks: [task("a", .interrupted)]) == .taskInterrupted)
}

@Test("同时有多个变化时只播放优先级最高的一个")
func highestPriorityWins() {
    var tracker = TaskSoundTracker()
    _ = tracker.nextCue(tasks: [task("a", .idle), task("b", .idle), task("c", .idle)])

    let cue = tracker.nextCue(tasks: [task("a", .running), task("b", .succeeded), task("c", .waitingApproval)])

    #expect(cue == .inputRequired)
}

@Test("静音任务和关闭提示音不发声，但基线仍会更新")
func mutedAndDisabled() {
    var tracker = TaskSoundTracker()
    _ = tracker.nextCue(tasks: [task("a", .idle)])

    #expect(tracker.nextCue(tasks: [task("a", .running, muted: true)]) == nil)
    #expect(tracker.nextCue(tasks: [task("a", .succeeded)], soundEnabled: false) == nil)
    // 关闭期间已完成的任务不会在重新打开后补响。
    #expect(tracker.nextCue(tasks: [task("a", .succeeded)]) == nil)
}

@Test("内容更新或排序变化不重复发声")
func unchangedLifecycleIsSilent() {
    var tracker = TaskSoundTracker()
    _ = tracker.nextCue(tasks: [task("a", .running, updatedAt: 1), task("b", .succeeded)])

    #expect(tracker.nextCue(tasks: [task("b", .succeeded), task("a", .running, updatedAt: 9)]) == nil)
}

@Test("提示音渲染长度正确、不是静音且不会超出范围")
func synthesizerOutput() {
    for cue in ArcadeSoundCue.allCases {
        let samples = ArcadeSoundSynthesizer.render(cue, sampleRate: 44_100)

        #expect(samples.count == Int(ArcadeSoundSynthesizer.duration(of: cue) * 44_100))
        #expect(samples.contains { abs($0) > 0.1 })
        #expect(samples.allSatisfy { abs($0) <= 1 })
        // 末尾应已衰减到接近静音，避免爆音。
        #expect(abs(samples.last ?? 0) < 0.05)
    }
}
