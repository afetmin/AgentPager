import Dispatch
import Foundation

/// A persisted rollout can outlive the Codex process that was writing it. Probe
/// open writable descriptors rather than treating the file's existence as life.
/// Failures are unknown (nil), never evidence that every session has stopped.
enum CodexSessionLivenessProbe {
    static func liveTranscriptPaths() -> Set<String>? {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-c", "codex", "-Fpcfan"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return nil
        }
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 3,
            execute: timeout
        )
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Exit 1 with no diagnostic/output means no matching Codex process.
        // Permission errors, partial results and timeouts must not clear tasks.
        guard errorData.isEmpty else { return nil }
        if process.terminationStatus == 1, data.isEmpty { return [] }
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return writableTranscriptPaths(from: text)
    }

    static func writableTranscriptPaths(from output: String) -> Set<String> {
        var paths: Set<String> = []
        var isCodex = false
        var isWritable = false
        for line in output.split(separator: "\n") {
            switch line.first {
            case "p":
                isCodex = false
                isWritable = false
            case "c":
                isCodex = line.dropFirst().lowercased().hasPrefix("codex")
            case "f":
                isWritable = false
            case "a":
                isWritable = line == "aw" || line == "au"
            case "n" where isCodex && isWritable:
                let path = String(line.dropFirst())
                guard path.hasPrefix("/"), path.hasSuffix(".jsonl") else { continue }
                paths.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
            default:
                break
            }
        }
        return paths
    }
}
