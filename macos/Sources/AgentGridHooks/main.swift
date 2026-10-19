import AgentGridCore
import Foundation
import Network

private final class HookClientState: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didFinish = false
    private var response = Data()

    func append(_ data: Data) {
        lock.lock()
        response.append(data)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return }
        didFinish = true
        semaphore.signal()
    }

    func wait(until timeout: DispatchTime) -> Data {
        _ = semaphore.wait(timeout: timeout)
        lock.lock()
        defer { lock.unlock() }
        return response
    }
}

@main
struct AgentPagerHooksCommand {
    static func main() {
        let source = resolveSource(from: CommandLine.arguments)
        let input = FileHandle.standardInput.readDataToEndOfFile()

        // 按来源解码载荷，仅用于判断事件类型以设置等待时长；
        // 解析失败时保持 fail-open，不能阻塞 Agent。
        let isPermission: Bool
        switch source {
        case .claude:
            var decodable = input
            if resolveAgent(from: CommandLine.arguments) != nil,
               let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
               let normalized = try? JSONSerialization.data(
                   withJSONObject: HookPayloadKeyNormalizer.snakeCasedKeys(object)
               ) {
                decodable = normalized
            }
            let payload = try? JSONDecoder().decode(ClaudeHookPayload.self, from: decodable)
            isPermission = payload?.event == .permissionRequest
        case .codex:
            let payload = try? JSONDecoder().decode(CodexHookPayload.self, from: input)
            isPermission = payload?.hookEventName == .permissionRequest
        }

        let line = wrapInEnvelope(input: input, source: source, agentID: resolveAgent(from: CommandLine.arguments))
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: 49_361)!,
            using: .tcp
        )
        let queue = DispatchQueue(label: "com.agentgrid.hook-client")
        let clientState = HookClientState()

        connection.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .ready:
                connection.send(content: line, completion: .contentProcessed { error in
                    if error != nil {
                        clientState.finish()
                        return
                    }
                    connection.receiveMessage { data, _, _, _ in
                        if let data {
                            clientState.append(data)
                        }
                        clientState.finish()
                    }
                })
            case .failed, .cancelled:
                clientState.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)

        // 权限请求可能等用户在手机上操作很久；与安装到 settings.json 的
        // hook timeout 对齐：Codex 1 小时、Claude 24 小时。其余事件 5 秒放行。
        let timeout: DispatchTime = isPermission
            ? .now() + (source == .claude ? 86_400 : 3_600)
            : .now() + 5
        let response = clientState.wait(until: timeout)
        connection.cancel()

        if !response.isEmpty {
            FileHandle.standardOutput.write(response)
        }
    }

    private static func resolveSource(from arguments: [String]) -> HookSource {
        // 兼容 `--source claude` 与 `--source=claude` 两种写法。
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            if argument == "--source", let value = iterator.next() {
                return HookSource(rawValue: value) ?? .codex
            }
            if argument.hasPrefix("--source=") {
                let value = String(argument.dropFirst("--source=".count))
                return HookSource(rawValue: value) ?? .codex
            }
        }
        return .codex
    }

    /// 解析 `--agent <id>` / `--agent=<id>`：兼容客户端（ZCode、WorkBuddy 等）的标识。
    private static func resolveAgent(from arguments: [String]) -> String? {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            if argument == "--agent", let value = iterator.next(), !value.isEmpty {
                return value
            }
            if argument.hasPrefix("--agent=") {
                let value = String(argument.dropFirst("--agent=".count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// 把原始 Hook 载荷包进 `{hook_source, agent_id?, payload}` 信封并加换行，
    /// 让桥接服务器能按来源选择解码器与响应格式。
    private static func wrapInEnvelope(input: Data, source: HookSource, agentID: String?) -> Data {
        guard let payload = try? JSONSerialization.jsonObject(with: input) else {
            // 极端情况下无法解析时，退化为原样发送，服务器仍按 codex 兼容。
            var fallback = input
            fallback.append(UInt8(ascii: "\n"))
            return fallback
        }
        var envelope: [String: Any] = [
            "hook_source": source.rawValue,
            "payload": payload,
        ]
        if let agentID {
            envelope["agent_id"] = agentID
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? input
        var line = data
        line.append(UInt8(ascii: "\n"))
        return line
    }
}
