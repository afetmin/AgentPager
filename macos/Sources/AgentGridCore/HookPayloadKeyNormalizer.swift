import Foundation

/// 兼容客户端的 Hook 载荷可能把同一字段写成 camelCase（如 `sessionId`）或 snake_case
/// （`session_id`）。Claude 解码器只认 snake_case，这里在顶层补齐缺失的 snake_case 键。
///
/// 已存在的 snake_case 键永不被覆盖；嵌套对象（如 `tool_input`）原样保留，
/// 避免改写工具参数的真实字段名。
public enum HookPayloadKeyNormalizer {
    public static func snakeCasedKeys(_ object: [String: Any]) -> [String: Any] {
        var result = object
        for (key, value) in object {
            let snake = snakeCase(key)
            if snake != key, result[snake] == nil {
                result[snake] = value
            }
        }
        return result
    }

    static func snakeCase(_ key: String) -> String {
        var output = ""
        for character in key {
            if character.isUppercase {
                output.append("_")
                output.append(contentsOf: character.lowercased())
            } else {
                output.append(character)
            }
        }
        return output
    }
}
