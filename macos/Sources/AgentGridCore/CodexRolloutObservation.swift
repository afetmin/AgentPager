import Foundation

public struct CodexRolloutObservation: Sendable {
    private var reader: CodexRolloutReader
    private let sessionsRoots: [URL]
    private let lookback: TimeInterval
    private let discoveryInterval: TimeInterval
    private var nextDiscovery: Date

    public init() {
        let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let configuredHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredRoot = configuredHome.flatMap { home -> URL? in
            guard !home.isEmpty else { return nil }
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("sessions", isDirectory: true)
        }
        self.init(
            sessionsRoot: defaultRoot,
            lookback: 10 * 60,
            discoveryInterval: 3,
            additionalSessionsRoot: configuredRoot
        )
    }

    init(
        sessionsRoot: URL,
        lookback: TimeInterval,
        discoveryInterval: TimeInterval,
        additionalSessionsRoot: URL? = nil,
        reader: CodexRolloutReader = CodexRolloutReader()
    ) {
        self.reader = reader
        var roots = [sessionsRoot]
        if let additionalSessionsRoot,
           additionalSessionsRoot.standardizedFileURL != sessionsRoot.standardizedFileURL {
            roots.append(additionalSessionsRoot)
        }
        sessionsRoots = roots
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
            for sessionsRoot in sessionsRoots {
                reader.discoverSessions(
                    in: sessionsRoot,
                    modifiedAfter: now.addingTimeInterval(-lookback)
                )
            }
            nextDiscovery = now.addingTimeInterval(discoveryInterval)
        }
        return reader.poll()
    }

    public func existingSessionIDs(
        matching sessionIDs: Set<String>
    ) -> Set<String> {
        var existing: Set<String> = []
        for sessionsRoot in sessionsRoots {
            existing.formUnion(reader.existingSessionIDs(
                in: sessionsRoot,
                matching: sessionIDs.subtracting(existing)
            ))
        }
        return existing
    }
}
