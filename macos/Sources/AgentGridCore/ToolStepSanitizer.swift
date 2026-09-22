import Foundation

enum ToolStepSanitizer {
    static func nestedToolNames(in source: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9_$])tools\s*(?:\.\s*([A-Za-z_$][A-Za-z0-9_$]*)|\[\s*[\"']([^\"']+)[\"']\s*\])\s*\("#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let matches = expression.matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        )
        var seen = Set<String>()
        return matches.compactMap { match in
            for index in 1...2 where match.range(at: index).location != NSNotFound {
                guard let range = Range(match.range(at: index), in: source) else {
                    continue
                }
                let name = String(source[range])
                if seen.insert(name).inserted {
                    return name
                }
            }
            return nil
        }
    }

    static func isTestCommand(_ value: String?) -> Bool {
        guard let value else {
            return false
        }
        let command = value
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\r", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        guard !command.isEmpty else {
            return false
        }
        let patterns = [
            #"(^|[;&|]\s*)(swift\s+test)(\s|$)"#,
            #"(^|[;&|]\s*)(xcodebuild\b[^;&|]*\btest\b)"#,
            #"(^|[;&|]\s*)((python|python3)(\.\d+)?\s+-m\s+(pytest|unittest)|pytest)(\s|$)"#,
            #"(^|[;&|]\s*)((npm|pnpm)\s+(run\s+)?test|yarn\s+test|bun\s+test)(\s|$)"#,
            #"(^|[;&|]\s*)(cargo\s+test|go\s+test|dotnet\s+test)(\s|$)"#,
            #"(^|[;&|]\s*)((\./)?gradlew?\b[^;&|]*\btest\b|mvn\b[^;&|]*\btest\b)(\s|$)"#,
            #"(^|[;&|]\s*)(ctest|vitest|jest)(\s|$)"#,
        ]
        return patterns.contains { pattern in
            command.range(of: pattern, options: .regularExpression) != nil
        }
    }

    static func sanitizedForTransport(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = clipped(value)
        guard let normalized else {
            return nil
        }

        if normalized.contains("*** Begin Patch")
            || normalized.lowercased().contains("apply_patch") {
            // 发送补丁状态时只暴露实际修改目标，不发送工具名、协议头和差异正文。
            return patchTargetSummary(value)
        }

        if normalized.contains("tools.exec_command")
            || normalized.contains("await tools.") {
            for key in ["cmd", "command", "query", "path", "ref_id", "step"] {
                if let argument = javascriptStringArgument(named: key, in: value) {
                    return clipped(argument)
                }
            }
        }
        return normalized
    }

    static func isApplyPatchTool(_ toolName: String?) -> Bool {
        guard let toolName = toolName?.lowercased() else {
            return false
        }
        return toolName == "apply_patch"
            || toolName.hasSuffix(".apply_patch")
            || toolName.hasSuffix("__apply_patch")
    }

    static func isExecScriptTool(_ toolName: String?) -> Bool {
        guard let toolName = toolName?.lowercased() else {
            return false
        }
        return toolName == "exec"
            || toolName.hasSuffix(".exec")
            || toolName.hasSuffix("__exec")
    }

    static func patchTargetSummary(_ patch: String) -> String? {
        let prefixes = [
            "*** Update File:",
            "*** Add File:",
            "*** Delete File:",
            "*** Move to:",
        ]
        let firstTarget = prefixes.compactMap { prefix in
            patch.range(of: prefix).map { (prefix: prefix, range: $0) }
        }
        .min { left, right in
            left.range.lowerBound < right.range.lowerBound
        }
        guard let firstTarget else {
            return nil
        }

        let tail = patch[firstTarget.range.upperBound...]
        let boundaryTokens = ["\n", "\r", "\\n", "\\r", " ***", " @@", " +", " -"]
        let boundary = boundaryTokens
            .compactMap { tail.range(of: $0)?.lowerBound }
            .min()
            ?? tail.endIndex
        let path = tail[..<boundary]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : clipped(path)
    }

    static func javascriptStringArgument(
        named key: String,
        in source: String
    ) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"(?<![A-Za-z0-9_$])(?:"\#(escapedKey)"|'\#(escapedKey)'|\#(escapedKey))\s*:\s*"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: source,
                  range: NSRange(source.startIndex..., in: source)
              ),
              let matchRange = Range(match.range, in: source) else {
            return nil
        }
        return javascriptStringLiteral(in: source, startingAt: matchRange.upperBound)
    }

    private static func javascriptStringLiteral(
        in source: String,
        startingAt start: String.Index
    ) -> String? {
        guard start < source.endIndex else {
            return nil
        }
        let quote = source[start]
        guard quote == "\"" || quote == "'" || quote == "`" else {
            return nil
        }

        var result = ""
        var index = source.index(after: start)
        while index < source.endIndex {
            let character = source[index]
            if character == quote {
                return result
            }
            guard character == "\\" else {
                result.append(character)
                index = source.index(after: index)
                continue
            }

            let escapedIndex = source.index(after: index)
            guard escapedIndex < source.endIndex else {
                return nil
            }
            let escaped = source[escapedIndex]
            switch escaped {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "t": result.append("\t")
            case "\\": result.append("\\")
            case "\"": result.append("\"")
            case "'": result.append("'")
            case "`": result.append("`")
            default:
                // 未识别的转义属于命令本身，保留反斜杠避免改变展示含义。
                result.append("\\")
                result.append(escaped)
            }
            index = source.index(after: escapedIndex)
        }
        return nil
    }

    private static func clipped(_ value: String?, limit: Int = 220) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(limit))
    }
}
