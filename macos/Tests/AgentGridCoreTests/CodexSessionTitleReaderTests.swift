import Foundation
import Testing
@testable import AgentGridCore

@Test("读取 Codex 总结标题并忽略无效记录")
func readsCodexSessionTitles() {
    let data = Data(
        """
        {"id":"session-1","thread_name":"优化手机任务标题","updated_at":"2026-07-26T01:00:00Z"}
        {"id":"session-2","thread_name":"   ","updated_at":"2026-07-26T01:00:00Z"}
        不是 JSON
        """.utf8
    )

    let titles = CodexSessionTitleReader.titles(from: data)

    #expect(titles == ["session-1": "优化手机任务标题"])
}

@Test("同一会话优先使用最新的 Codex 标题")
func latestCodexSessionTitleWins() {
    let data = Data(
        """
        {"id":"session-1","thread_name":"旧标题","updated_at":"2026-07-26T01:00:00Z"}
        {"id":"session-1","thread_name":"新的总结标题","updated_at":"2026-07-26T02:00:00Z"}
        """.utf8
    )

    let titles = CodexSessionTitleReader.titles(from: data)

    #expect(titles["session-1"] == "新的总结标题")
}

@Test("配置的 Codex 索引不存在时回退到用户目录索引")
func missingConfiguredIndexFallsBackToHomeIndex() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let fallback = directory.appendingPathComponent("session_index.jsonl")
    try Data(
        """
        {"id":"session-1","thread_name":"回退索引标题","updated_at":"2026-07-26T02:00:00Z"}

        """.utf8
    ).write(to: fallback)
    let reader = CodexSessionTitleReader(
        primaryIndexURL: directory.appendingPathComponent("missing/session_index.jsonl"),
        fallbackIndexURL: fallback
    )

    #expect(reader.loadTitles()["session-1"] == "回退索引标题")
    #expect(reader.revision() != nil)
}

@Test("标题索引变化或出现新任务时恢复刷新")
func titleIndexChangeOrNewTaskTriggersRefresh() {
    let firstTask = TaskSnapshot(
        id: "session-1",
        source: .codexDesktop,
        projectName: "AgentGrid",
        title: "AgentGrid · 修改标题",
        lifecycle: .running
    )
    var catalog = TaskCatalog(restoring: [firstTask])
    var synchronizer = CodexSessionTitleSynchronizer()
    let firstRevision = CodexSessionTitleRevision(
        modificationDate: Date(timeIntervalSince1970: 1),
        fileSize: 100
    )

    #expect(
        synchronizer.needsRefresh(
            for: catalog.projection().tasks,
            revision: firstRevision
        )
    )

    let changed = synchronizer.applyAvailableTitles(
        ["session-1": "同步后的总结标题"],
        revision: firstRevision,
        to: &catalog
    )

    #expect(changed)
    #expect(
        !synchronizer.needsRefresh(
            for: catalog.projection().tasks,
            revision: firstRevision
        )
    )

    let secondRevision = CodexSessionTitleRevision(
        modificationDate: Date(timeIntervalSince1970: 2),
        fileSize: 120
    )
    #expect(
        synchronizer.needsRefresh(
            for: catalog.projection().tasks,
            revision: secondRevision
        )
    )
    #expect(
        synchronizer.applyAvailableTitles(
            ["session-1": "用户修改后的标题"],
            revision: secondRevision,
            to: &catalog
        )
    )
    #expect(catalog.projection().tasks[0].title == "AgentGrid · 用户修改后的标题")

    var staleTask = catalog.projection().tasks[0]
    staleTask.title = "AgentGrid · 旧提示词标题"
    catalog.accept(.synthetic(staleTask))
    #expect(
        synchronizer.needsRefresh(
            for: catalog.projection().tasks,
            revision: secondRevision
        )
    )
    #expect(
        synchronizer.applyAvailableTitles(
            ["session-1": "用户修改后的标题"],
            revision: secondRevision,
            to: &catalog
        )
    )
    #expect(catalog.projection().tasks[0].title == "AgentGrid · 用户修改后的标题")

    let secondTask = TaskSnapshot(
        id: "session-2",
        source: .codexCLI,
        projectName: "新任务",
        lifecycle: .running
    )
    catalog.accept(.synthetic(secondTask))

    #expect(
        synchronizer.needsRefresh(
            for: catalog.projection().tasks,
            revision: secondRevision
        )
    )
}
