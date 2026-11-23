import Foundation

/// 写入 ZCode `~/.zcode/cli/config.json` 的 Hook 安装器。
///
/// ZCode 的结构与 Claude Code 不同：`hooks` 下是 `{ enabled, events }`，事件名是
/// 严格白名单——出现任何白名单之外的事件，ZCode 会静默丢弃整份 hooks 配置。
/// 因此这里只写入调用方传入的事件（由 `AgentIntegrations` 限定为 ZCode 的 7 个事件）。
///
/// 与 Claude 安装器一致：保留用户既有 Hook，只替换 AgentPager 管理项，幂等。
public enum ZcodeHookInstaller {
    /// ZCode 单个 Hook 的默认超时（秒）。只有超过它的事件才需要显式写 `timeout`。
    static let defaultTimeout = 60

    public static func install(
        existingData: Data?,
        command: String,
        events: [AgentIntegration.HookEvent]
    ) throws -> HookFileMutation {
        var root = try rootObject(existingData)
        var hooksRoot = try hooksObject(in: root)
        var eventMap = try eventsObject(in: hooksRoot)

        removeManagedGroups(from: &eventMap)

        for event in events {
            var hook: [String: Any] = ["type": "command", "command": command]
            if let timeout = event.timeout, timeout > defaultTimeout {
                hook["timeout"] = timeout
            }
            let groups = eventMap[event.name] as? [[String: Any]] ?? []
            eventMap[event.name] = groups + [["hooks": [hook]]]
        }

        // `enabled` 是用户对其所有 Hook 的总开关：明确设为 false 时绝不改回 true，
        // 否则会悄悄重新启用用户关掉的第三方 Hook。此时我们的 Hook 保持休眠。
        if hooksRoot["enabled"] == nil {
            hooksRoot["enabled"] = true
        }
        hooksRoot["events"] = eventMap
        root["hooks"] = hooksRoot

        let data = try serialize(root)
        return HookFileMutation(
            contents: data,
            changed: data != existingData,
            hasRemainingHooks: true
        )
    }

    public static func uninstall(existingData: Data?) throws -> HookFileMutation {
        guard let existingData else {
            return HookFileMutation(contents: nil, changed: false, hasRemainingHooks: false)
        }
        var root = try rootObject(existingData)
        var hooksRoot = try hooksObject(in: root)
        var eventMap = try eventsObject(in: hooksRoot)

        let removed = removeManagedGroups(from: &eventMap)
        guard removed else {
            return HookFileMutation(
                contents: existingData,
                changed: false,
                hasRemainingHooks: !eventMap.isEmpty
            )
        }

        hooksRoot["events"] = eventMap
        // 只剩我们自己搭的 enabled/events 脚手架时整体移除，不留 `{"enabled":true,"events":{}}`。
        let onlyScaffolding = eventMap.isEmpty
            && hooksRoot.keys.allSatisfy { $0 == "enabled" || $0 == "events" }
        if onlyScaffolding {
            root.removeValue(forKey: "hooks")
        } else {
            if eventMap.isEmpty {
                hooksRoot.removeValue(forKey: "events")
            }
            root["hooks"] = hooksRoot
        }

        if root.isEmpty {
            return HookFileMutation(contents: nil, changed: true, hasRemainingHooks: false)
        }
        return HookFileMutation(
            contents: try serialize(root),
            changed: true,
            hasRemainingHooks: !eventMap.isEmpty
        )
    }

    public static func isInstalled(
        data: Data?,
        events: [AgentIntegration.HookEvent]
    ) -> Bool {
        guard let root = try? rootObject(data),
              let hooksRoot = try? hooksObject(in: root),
              let eventMap = try? eventsObject(in: hooksRoot) else {
            return false
        }
        return events.allSatisfy { event in
            (eventMap[event.name] as? [[String: Any]] ?? []).contains(where: isManaged)
        }
    }

    /// 用户把 `hooks.enabled` 关掉时，我们的 Hook 虽已写入但不会运行。
    public static func isMasterSwitchOff(data: Data?) -> Bool {
        guard let root = try? rootObject(data),
              let hooksRoot = try? hooksObject(in: root) else {
            return false
        }
        return hooksRoot["enabled"] as? Bool == false
    }

    // MARK: - 内部

    /// 返回是否真的移除了东西；空事件键一并删除。
    @discardableResult
    private static func removeManagedGroups(from eventMap: inout [String: Any]) -> Bool {
        var removedAny = false
        for (name, value) in eventMap {
            guard let groups = value as? [[String: Any]] else { continue }
            let remaining = groups.filter { !isManaged($0) }
            guard remaining.count != groups.count else { continue }
            removedAny = true
            if remaining.isEmpty {
                eventMap.removeValue(forKey: name)
            } else {
                eventMap[name] = remaining
            }
        }
        return removedAny
    }

    static func isManaged(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains {
            let command = $0["command"] as? String
            return command?.contains("AgentPagerHooks") == true
                || command?.contains("AgentGridHooks") == true
        }
    }

    private static func rootObject(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let dictionary = value as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return dictionary
    }

    /// `hooks` 存在但不是对象时视为损坏，拒绝覆盖用户数据。
    private static func hooksObject(in root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let dictionary = value as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return dictionary
    }

    private static func eventsObject(in hooksRoot: [String: Any]) throws -> [String: Any] {
        guard let value = hooksRoot["events"] else { return [:] }
        guard let dictionary = value as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return dictionary
    }

    private static func serialize(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }
}
