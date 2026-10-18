import Foundation
import Testing
@testable import AgentGridCore

@Test("Only writable Codex rollout descriptors count as live")
func codexLivenessRequiresWritableDescriptor() {
    let output = """
    p100
    ccodex
    f19
    au
    n/tmp/project with spaces/rollout-live.jsonl
    f20
    ar
    n/tmp/rollout-readonly.jsonl
    f21
    aw
    n/tmp/other.log
    p200
    cAgentPagerBridge
    f8
    ar
    n/tmp/rollout-inspected.jsonl
    p300
    ccodex
    f5
    aw
    n/tmp/rollout-cli.jsonl
    """
    #expect(CodexSessionLivenessProbe.writableTranscriptPaths(from: output) == [
        "/tmp/project with spaces/rollout-live.jsonl",
        "/tmp/rollout-cli.jsonl",
    ])
}

@Test("Live session matching covers restored filenames and Hook transcript paths")
func codexLivenessMatchesRestoredAndHookSessions() {
    var observation = CodexRolloutObservation(
        sessionsRoot: URL(fileURLWithPath: "/unused"),
        lookback: 60,
        discoveryInterval: 3,
        liveTranscriptPaths: {
            ["/tmp/rollout-restored-id.jsonl", "/tmp/custom-hook.jsonl"]
        }
    )
    observation.include(CodexHookPayload(
        cwd: "/tmp/AgentPager",
        hookEventName: .sessionStart,
        sessionID: "hook-id",
        transcriptPath: "/tmp/custom-hook.jsonl"
    ))

    #expect(observation.liveSessionIDs(matching: ["restored-id", "hook-id", "stopped-id"])
        == ["restored-id", "hook-id"])
}

@Test("A failed OS probe remains unknown instead of declaring all sessions dead")
func codexLivenessProbeFailureRemainsUnknown() {
    let observation = CodexRolloutObservation(
        sessionsRoot: URL(fileURLWithPath: "/unused"),
        lookback: 60,
        discoveryInterval: 3,
        liveTranscriptPaths: { nil }
    )
    #expect(observation.liveSessionIDs(matching: ["session"]) == nil)
}
