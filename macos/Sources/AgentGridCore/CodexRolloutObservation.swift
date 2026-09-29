import Foundation

public struct CodexRolloutObservation: Sendable {
    private var reader: CodexRolloutReader
    private let sessionsRoot: URL
    private let lookback: TimeInterval
    private let discoveryInterval: TimeInterval
    private var nextDiscovery: Date

    public init() {
        self.init(
            sessionsRoot: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true),
            lookback: 10 * 60,
            discoveryInterval: 3
        )
    }

    init(
        sessionsRoot: URL,
        lookback: TimeInterval,
        discoveryInterval: TimeInterval,
        reader: CodexRolloutReader = CodexRolloutReader()
    ) {
        self.reader = reader
        self.sessionsRoot = sessionsRoot
        self.lookback = lookback
        self.discoveryInterval = discoveryInterval
        nextDiscovery = .distantPast
    }

    public mutating func include(_ hook: CodexHookPayload) {
        reader.track(
            filePath: hook.transcriptPath,
            sessionID: hook.sessionID,
            cwd: hook.cwd
        )
    }

    public mutating func observe(now: Date = .now) -> [CodexRolloutSignal] {
        if now >= nextDiscovery {
            reader.discoverSessions(
                in: sessionsRoot,
                modifiedAfter: now.addingTimeInterval(-lookback)
            )
            nextDiscovery = now.addingTimeInterval(discoveryInterval)
        }
        return reader.poll()
    }

    public func existingSessionIDs(
        matching sessionIDs: Set<String>
    ) -> Set<String> {
        reader.existingSessionIDs(
            in: sessionsRoot,
            matching: sessionIDs
        )
    }
}
