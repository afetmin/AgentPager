import Foundation
import Testing
@testable import AgentGridShared

@Test("控制消息签名可验证")
func controlSignatureRoundTrip() throws {
    let secret = Data(repeating: 0x42, count: 32)
    var envelope = SignedControlEnvelope(
        messageId: UUID(uuidString: "6f539e96-6bce-4fdc-94d5-3cf4ea755622")!,
        sentAt: 1_785_067_200_000,
        deviceId: "nova4",
        sequence: 7,
        nonce: "nonce-7",
        payload: ControlPayload(taskID: "task-1", action: .approve)
    )
    envelope.signature = try ControlSigner.sign(envelope, secret: secret)

    #expect(try ControlSigner.verify(envelope, secret: secret))
}

@Test("控制消息修改后签名失效")
func tamperedControlIsRejected() throws {
    let secret = Data(repeating: 0x24, count: 32)
    var envelope = SignedControlEnvelope(
        sentAt: 1_785_067_200_000,
        deviceId: "nova4",
        sequence: 1,
        nonce: "nonce-1",
        payload: ControlPayload(taskID: "task-1", action: .approve)
    )
    envelope.signature = try ControlSigner.sign(envelope, secret: secret)
    envelope.payload.action = .deny

    #expect(try !ControlSigner.verify(envelope, secret: secret))
}

@Test("重放保护拒绝相同序号和 nonce")
func replayGuardRejectsReplay() throws {
    let now = Date(timeIntervalSince1970: 1_785_067_200)
    let secret = Data(repeating: 0x11, count: 32)
    var envelope = SignedControlEnvelope(
        sentAt: Int64(now.timeIntervalSince1970 * 1_000),
        deviceId: "nova4",
        sequence: 1,
        nonce: "same-nonce",
        payload: ControlPayload(taskID: "task-1", action: .approve)
    )
    envelope.signature = try ControlSigner.sign(envelope, secret: secret)
    var guardState = ReplayGuard()

    try guardState.validate(envelope, secret: secret, now: now)
    #expect(throws: ProtocolError.replayed) {
        try guardState.validate(envelope, secret: secret, now: now)
    }
}

@Test("状态协议使用整数毫秒时间戳")
func stateProtocolUsesIntegerMilliseconds() throws {
    let task = TaskSnapshot(
        id: "task-1",
        source: .codexCLI,
        projectName: "AgentGrid",
        lifecycle: .running,
        startedAt: Date(timeIntervalSince1970: 100.123_456),
        updatedAt: Date(timeIntervalSince1970: 101.654_321)
    )
    let envelope = MessageEnvelope(
        type: "state.snapshot",
        payload: StateSnapshotPayload(
            tasks: [task],
            usage: nil,
            focusedTaskID: task.id
        )
    )

    let object = try #require(
        JSONSerialization.jsonObject(with: ProtocolCodec.encode(envelope))
            as? [String: Any]
    )
    let payload = try #require(object["payload"] as? [String: Any])
    let tasks = try #require(payload["tasks"] as? [[String: Any]])
    let encodedTask = try #require(tasks.first)

    #expect((encodedTask["startedAt"] as? NSNumber)?.int64Value == 100_123)
    #expect((encodedTask["startedAt"] as? NSNumber)?.doubleValue == 100_123)
    #expect((encodedTask["updatedAt"] as? NSNumber)?.int64Value == 101_654)
}

@Test("状态快照发送前过滤内部工具包装")
func stateSnapshotFiltersInternalToolWrappersBeforeSending() throws {
    let commandTask = TaskSnapshot(
        id: "command-task",
        source: .codexDesktop,
        projectName: "AgentGrid",
        latestStep: """
        const r = await tools.exec_command({cmd:"swift test",workdir:"/tmp/AgentGrid"});text(r.output)
        """,
        lifecycle: .running
    )
    let patchTask = TaskSnapshot(
        id: "patch-task",
        source: .codexDesktop,
        projectName: "AgentGrid",
        latestStep: """
        apply_patch *** Begin Patch *** Update File: /tmp/AgentGrid/App.swift @@ -旧内容 +新内容 *** End Patch
        """,
        lifecycle: .running
    )
    let envelope = MessageEnvelope(
        type: "state.snapshot",
        payload: StateSnapshotPayload(
            tasks: [commandTask, patchTask],
            usage: nil,
            focusedTaskID: commandTask.id
        )
    )

    let object = try #require(
        JSONSerialization.jsonObject(with: ProtocolCodec.encode(envelope))
            as? [String: Any]
    )
    let payload = try #require(object["payload"] as? [String: Any])
    let tasks = try #require(payload["tasks"] as? [[String: Any]])

    #expect(tasks[0]["latestStep"] as? String == "swift test")
    #expect(tasks[1]["latestStep"] as? String == "/tmp/AgentGrid/App.swift")
}
