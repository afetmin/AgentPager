using System.Text;
using System.Text.Json.Nodes;

namespace AgentPager.Core;

/// <summary>
/// 兼容客户端的 Hook 载荷可能把同一字段写成 camelCase（如 sessionId）或 snake_case（session_id）。
/// Claude 解码器只认 snake_case，这里在顶层补齐缺失的 snake_case 键。
/// 已存在的 snake_case 键永不被覆盖；嵌套对象（如 tool_input）原样保留，
/// 避免改写工具参数的真实字段名。
/// </summary>
public static class HookPayloadKeyNormalizer
{
    public static JsonObject SnakeCasedKeys(JsonObject source)
    {
        var result = (JsonObject)source.DeepClone();
        foreach (var (key, value) in source)
        {
            var snake = SnakeCase(key);
            if (snake != key && !result.ContainsKey(snake))
                result[snake] = value?.DeepClone();
        }
        return result;
    }

    public static string SnakeCase(string key)
    {
        var builder = new StringBuilder(key.Length + 4);
        foreach (var character in key)
        {
            if (char.IsUpper(character))
            {
                builder.Append('_');
                builder.Append(char.ToLowerInvariant(character));
            }
            else
            {
                builder.Append(character);
            }
        }
        return builder.ToString();
    }
}
