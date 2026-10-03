import Foundation
import Testing
@testable import AgentGridCore

@Test("持久 Task Catalog 在一次提交中完成标题富化和字段白名单")
func persistentCatalogCommitsProjectionAndStorageTogether() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let taskFile = directory.appendingPathComponent("tasks.json")
    let titleFile = directory.appendingPathComponent("session_index.jsonl")
    try Data(
        """
        {"id":"session-1","thread_name":"深化持久 Task Catalog","updated_at":"2026-07-26T12:00:00Z"}

        """.utf8
    ).write(to: titleFile)

    let now = Date.now
    let task = TaskSnapshot(
        id: "session-1",
        source: .codexCLI,
        projectName: "AgentGrid",
        userPrompt: "优化架构",
        latestStep: "swift test",
        subagents: [
            SubagentSnapshot(
                id: "child",
                path: "/root/catalog",
                latestStep: "编写逻辑测试",
                startedAt: now,
                updatedAt: now
            ),
        ],
        lifecycle: .running,
        updatedAt: now
    )
    let persistence = TaskSnapshotPersistence(fileURL: taskFile)
    var catalog = PersistentTaskCatalog(
        persistence: persistence,
        titleReader: CodexSessionTitleReader(indexURL: titleFile)
    )

    let acceptedCommit = catalog.accept(.synthetic(task))
    let commit = try #require(acceptedCommit)
    let restored = try #require(persistence.load().first)

    #expect(commit.persistenceError == nil)
    #expect(
        commit.projection.tasks[0].title
            == "AgentGrid · 深化持久 Task Catalog"
    )
    #expect(restored.title == "AgentGrid · 深化持久 Task Catalog")
    #expect(restored.userPrompt == "优化架构")
    #expect(restored.latestStep == nil)
    #expect(restored.subagents.isEmpty)

    try Data(
        """
        {"id":"session-1","thread_name":"用户重命名后的任务标题","updated_at":"2026-07-26T12:01:00Z"}

        """.utf8
    ).write(to: titleFile)

    let optionalRenamedCommit = catalog.maintain(now: now)
    let renamedCommit = try #require(optionalRenamedCommit)
    #expect(
        renamedCommit.projection.tasks[0].title
            == "AgentGrid · 用户重命名后的任务标题"
    )
}

@Test("无语义变化时持久 Task Catalog 不产生重复提交")
func persistentCatalogSkipsDuplicateCommit() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let now = Date.now
    let persistence = TaskSnapshotPersistence(
        fileURL: directory.appendingPathComponent("tasks.json")
    )
    var catalog = PersistentTaskCatalog(
        persistence: persistence,
        titleReader: CodexSessionTitleReader(
            indexURL: directory.appendingPathComponent("missing-index.jsonl")
        )
    )
    let signal = CodexRolloutSignal(
        sessionID: "session-1",
        cwd: "/tmp/AgentGrid",
        lifecycle: .running,
        activity: .thinking,
        timestamp: now
    )

    #expect(catalog.accept(.rollout([signal])) != nil)
    #expect(catalog.accept(.rollout([signal])) == nil)
}
