import Foundation

public struct CodexRolloutObservation: Sendable {
    private var reader: CodexRolloutReader
    private let sessionsRoots: [URL]
    private let lookback: TimeInterval
    private let discoveryInterval: TimeInterval
    private var nextDiscovery: Date
    private let liveTranscriptPaths: @Sendable () -> Set<String>?

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
        reader: CodexRolloutReader = CodexRolloutReader(),
        liveTranscriptPaths: @escaping @Sendable () -> Set<String>? = {
            CodexSessionLivenessProbe.liveTranscriptPaths()
        }
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
        self.liveTranscriptPaths = liveTranscriptPaths
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

    /// nil means the OS probe failed: preserve existing tasks in that case.
    public func liveSessionIDs(matching sessionIDs: Set<String>) -> Set<String>? {
        guard !sessionIDs.isEmpty else { return [] }
        guard let paths = liveTranscriptPaths() else { return nil }
        return reader.sessionIDs(withOpenTranscriptPaths: paths, matching: sessionIDs)
    }
}
