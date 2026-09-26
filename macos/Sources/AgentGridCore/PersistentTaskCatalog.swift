import Foundation

public struct TaskCatalogCommit: Equatable, Sendable {
    public var projection: TaskCatalogProjection
    public var persistenceError: String?

    public init(
        projection: TaskCatalogProjection,
        persistenceError: String?
    ) {
        self.projection = projection
        self.persistenceError = persistenceError
    }
}

public struct PersistentTaskControlResult: Equatable, Sendable {
    public var receipt: TaskControlReceipt
    public var commit: TaskCatalogCommit?

    public init(
        receipt: TaskControlReceipt,
        commit: TaskCatalogCommit?
    ) {
        self.receipt = receipt
        self.commit = commit
    }
}

public struct PersistentTaskCatalog: Sendable {
    private var catalog: TaskCatalog
    private let persistence: TaskSnapshotPersistence
    private let titleReader: CodexSessionTitleReader
    private var titleSynchronizer: CodexSessionTitleSynchronizer

    public init(
        persistence: TaskSnapshotPersistence = TaskSnapshotPersistence(),
        titleReader: CodexSessionTitleReader = CodexSessionTitleReader()
    ) {
        self.persistence = persistence
        self.titleReader = titleReader
        catalog = TaskCatalog(restoring: persistence.load())
        titleSynchronizer = CodexSessionTitleSynchronizer()
    }

    public mutating func synchronize(
        focusedTaskIDOverride: String? = nil
    ) -> TaskCatalogCommit {
        _ = refreshTitles()
        _ = catalog.maintain()
        return commit(focusedTaskIDOverride: focusedTaskIDOverride)
    }

    public mutating func accept(
        _ input: TaskCatalogInput,
        focusedTaskIDOverride: String? = nil
    ) -> TaskCatalogCommit? {
        let changed = catalog.accept(input)
        let titleChanged = refreshTitles()
        guard changed || titleChanged else {
            return nil
        }
        return commit(focusedTaskIDOverride: focusedTaskIDOverride)
    }

    public mutating func maintain(now: Date = .now) -> TaskCatalogCommit? {
        let changed = catalog.maintain(now: now)
        let titleChanged = refreshTitles()
        guard changed || titleChanged else {
            return nil
        }
        return commit()
    }

    public mutating func perform(
        _ control: AuthorizedTaskControl,
        permissionResolver: any CodexPermissionResolving,
        now: Date = .now
    ) -> PersistentTaskControlResult {
        let receipt = catalog.perform(
            control,
            permissionResolver: permissionResolver,
            now: now
        )
        let catalogCommit = receipt.committedRevision == nil ? nil : commit()
        return PersistentTaskControlResult(
            receipt: receipt,
            commit: catalogCommit
        )
    }

    public func projection() -> TaskCatalogProjection {
        catalog.projection()
    }

    private mutating func refreshTitles() -> Bool {
        let tasks = catalog.projection().tasks
        let revision = titleReader.revision()
        guard titleSynchronizer.needsRefresh(
            for: tasks,
            revision: revision
        ) else {
            return false
        }
        return titleSynchronizer.applyAvailableTitles(
            titleReader.loadTitles(),
            revision: revision,
            to: &catalog
        )
    }

    private func commit(
        focusedTaskIDOverride: String? = nil
    ) -> TaskCatalogCommit {
        let projection = catalog.projection(
            focusedTaskIDOverride: focusedTaskIDOverride
        )
        let persistenceError: String?
        do {
            try persistence.save(projection.tasks)
            persistenceError = nil
        } catch {
            persistenceError = "保存临时任务状态失败：\(error.localizedDescription)"
        }
        return TaskCatalogCommit(
            projection: projection,
            persistenceError: persistenceError
        )
    }
}
