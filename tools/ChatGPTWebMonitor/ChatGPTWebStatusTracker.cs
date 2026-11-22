#nullable disable
using System.Text.RegularExpressions;

// Status-only reducer: no page messages, response bodies, cookies or credentials.
// Transport is injected so request migration, retries and expiry are deterministic in tests.
public sealed class ChatGPTWebStatusTracker
{
    private readonly Dictionary<string, Session> sessions = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> aliases = new(StringComparer.Ordinal);
    private readonly Func<Dictionary<string, object>, bool> publish;
    private readonly Func<DateTime> clock;
    private const int MaxSessions = 2048;
    private const int MaxRequests = 512;
    private const int MaxAliases = 4096;
    private static readonly TimeSpan LeaseDuration = TimeSpan.FromSeconds(100);
    private static readonly Regex HashPattern = new("\\A[0-9a-f]{64}\\z", RegexOptions.CultureInvariant);
    public ChatGPTWebStatusTracker(Func<Dictionary<string, object>, bool> publish, Func<DateTime> clock = null)
    {
        this.publish = publish;
        this.clock = clock ?? (() => DateTime.UtcNow);
    }

    public bool Accept(Dictionary<string, object> message)
    {
        var action = Text(message, "action");
        var hash = Text(message, "conversationHash");
        var request = Text(message, "requestId");
        var previous = Text(message, "previousConversationHash");
        if (!HashPattern.IsMatch(hash) || action is not ("start" or "finish" or "heartbeat" or "metadata" or "rekey"))
            return false;
        if (action is "start" or "finish" or "heartbeat" && (request.Length == 0 || request.Length > 512))
            return false;
        if (action == "rekey" && (!HashPattern.IsMatch(previous) || previous == hash)) return false;
        var mode = Text(message, "mode");
        mode = mode is "Chat" or "Work" ? mode : "ChatGPT";
        var title = Title(Text(message, "title"));
        var now = clock();
        hash = Resolve(hash);
        if (action == "rekey")
        {
            previous = Resolve(previous);
            if (previous == hash) return true; // Idempotent retries, never an alias cycle.
            if (aliases.Count >= MaxAliases) return false;
            if (sessions.TryGetValue(previous, out var old))
            {
                if (sessions.TryGetValue(hash, out var actual))
                {
                    if (actual.Requests.Keys.Union(old.Requests.Keys).Count() > MaxRequests) return false;
                    foreach (var (id, seen) in old.Requests)
                        if (!actual.Requests.TryGetValue(id, out var existingSeen) || seen > existingSeen)
                            actual.Requests[id] = seen;
                    actual.IsStarted |= old.IsStarted;
                    actual.Completed &= old.Completed;
                    actual.PendingPrevious.UnionWith(old.PendingPrevious);
                    if (old.LastSeen > actual.LastSeen) actual.LastSeen = old.LastSeen;
                    if (actual.Title.Length == 0) actual.Title = old.Title;
                }
                else
                {
                    actual = old;
                    sessions[hash] = actual;
                }
                sessions.Remove(previous);
                actual.Hash = hash;
                actual.PendingPrevious.Add("agentpager-chatgpt-web-" + previous);
                if (title.Length > 0) actual.Title = title;
                FlushIdentity(actual);
            }
            aliases[previous] = hash;
            return true;
        }
        if (!sessions.TryGetValue(hash, out var state))
        {
            // Opening/switching an idle conversation is never evidence of activity.
            if (action is "metadata" or "finish") return true;
            if (sessions.Count >= MaxSessions) return false;
            state = new Session { Hash = hash, Mode = mode, Title = title, LastSeen = now };
            sessions[hash] = state;
        }
        if (action == "metadata")
        {
            if (title.Length > 0 && state.Title != title)
            {
                state.Title = title;
                if (state.IsStarted || state.Completed) Send(state, "SessionMetadata");
            }
            return true; // Metadata must not renew a generation lease.
        }
        if (action == "finish")
        {
            if (ExpireRequests(state, now) && state.Requests.Count == 0)
            {
                state.PendingEnd = "SessionOffline";
                FlushEnd(state);
                return true;
            }
            if (!state.Requests.Remove(request)) return true; // A late/foreign finish is not success.
            if (state.Requests.Count == 0)
            {
                state.PendingEnd = "Stop";
                FlushEnd(state);
            }
            return true;
        }
        if (state.Completed && !state.Expired && action == "heartbeat") return true; // Stale heartbeat must not resurrect a successful turn.
        ExpireRequests(state, now);
        if (!state.Requests.ContainsKey(request) && state.Requests.Count >= MaxRequests) return false;
        if (state.Completed)
        {
            state.TurnID = Guid.NewGuid().ToString("N");
            state.Completed = false;
        }
        state.PendingEnd = null; // New activity cancels a failed old Stop retry.
        state.Requests[request] = now;
        state.LastSeen = now;
        state.Mode = mode;
        if (title.Length > 0) state.Title = title;
        EnsureRunning(state, now);
        return true;
    }

    public int ActiveSessionCount => sessions.Values.Count(state => state.Requests.Count > 0);

    // Only browser web leases are owned here; never touches installed agent sessions.
    public void StopAll()
    {
        foreach (var state in sessions.Values.ToList())
            if (state.IsStarted) Send(state, "SessionOffline");
        sessions.Clear();
        aliases.Clear();
    }

    public void Tick()
    {
        var now = clock();
        foreach (var state in sessions.Values.ToList())
        {
            if (!FlushIdentity(state)) continue;
            // Expire before retrying a start: an absent browser is never a completed generation.
            if (ExpireRequests(state, now) && state.Requests.Count == 0)
            {
                state.PendingEnd = "SessionOffline";
            }
            if (state.PendingEnd is not null) FlushEnd(state);
            else if (state.Requests.Count > 0) EnsureRunning(state, now);
            else if (state.Title != state.PublishedTitle && (state.IsStarted || state.Completed))
                Send(state, "SessionMetadata");
            if (state.Requests.Count == 0 && state.PendingEnd is null && now - state.LastSeen > TimeSpan.FromDays(1))
            {
                sessions.Remove(state.Hash);
                foreach (var key in aliases.Keys.Where(key => Resolve(key) == state.Hash).ToList()) aliases.Remove(key);
            }
        }
    }

    private static bool ExpireRequests(Session state, DateTime now)
    {
        var expired = state.Requests.Where(pair => now - pair.Value > LeaseDuration).Select(pair => pair.Key).ToArray();
        foreach (var id in expired) state.Requests.Remove(id);
        return expired.Length > 0;
    }

    private void EnsureRunning(Session state, DateTime now)
    {
        if (!FlushIdentity(state)) return;
        if (state.IsStarted && now - state.LastPublished < TimeSpan.FromSeconds(20)) return;
        // A prompt-free start is Running immediately; do not emit a transient SessionStart card.
        // A sidebar spinner says the conversation is thinking, not what tool it used.
        if (Send(state, "UserPromptSubmit"))
        {
            state.IsStarted = true;
            state.LastPublished = now;
        }
    }

    private void FlushEnd(Session state)
    {
        if (!FlushIdentity(state)) return;
        if (state.IsStarted && !Send(state, state.PendingEnd)) return;
        state.Expired = state.PendingEnd == "SessionOffline";
        state.IsStarted = false;
        state.Completed = true;
        state.PendingEnd = null;
    }

    private bool FlushIdentity(Session state)
    {
        foreach (var previous in state.PendingPrevious.ToList())
        {
            if (!Send(state, "SessionMetadata", previous)) return false;
            state.PendingPrevious.Remove(previous);
        }
        return true;
    }

    private bool Send(Session state, string name, string previous = null)
    {
        var payload = new Dictionary<string, object>
        {
            ["cwd"] = state.Mode == "ChatGPT" ? @"C:\AgentPager\ChatGPT" : @"C:\AgentPager\ChatGPT " + state.Mode,
            ["hook_event_name"] = name,
            ["session_id"] = "agentpager-chatgpt-web-" + state.Hash,
            ["conversation_title"] = state.Title,
            ["source"] = "app", // Preserve installed CodexDesktop wire compatibility.
            ["turn_id"] = state.TurnID,
            ["transcript_path"] = null,
            ["tool_name"] = null,
            ["tool_use_id"] = null,
            ["tool_input"] = null,
            ["prompt"] = null,
            ["model"] = null,
        };
        if (previous is not null) payload["previous_session_id"] = previous;
        if (!publish(payload)) return false;
        state.PublishedTitle = state.Title;
        return true;
    }

    private string Resolve(string hash)
    {
        while (aliases.TryGetValue(hash, out var next)) hash = next;
        return hash;
    }

    private static string Text(Dictionary<string, object> message, string key) =>
        message.TryGetValue(key, out var value) ? value switch
        {
            string text => text,
            System.Text.Json.JsonElement element when element.ValueKind == System.Text.Json.JsonValueKind.String => element.GetString(),
            _ => "",
        } : "";

    private static string Title(string value)
    {
        var result = Regex.Replace(value ?? "", @"\s*[|·–-]\s*ChatGPT\s*$", "", RegexOptions.IgnoreCase).Trim();
        result = Regex.Replace(result, @"\s+", " ");
        if (result.Equals("ChatGPT", StringComparison.OrdinalIgnoreCase) ||
            result.Equals("New chat", StringComparison.OrdinalIgnoreCase) ||
            result.Equals("Home", StringComparison.OrdinalIgnoreCase)) return "";
        return result.Length > 180 ? result[..180] : result;
    }

    private sealed class Session
    {
        public string Hash;
        public string Mode;
        public string Title;
        public string PublishedTitle = "";
        public string TurnID = Guid.NewGuid().ToString("N");
        public DateTime LastSeen;
        public DateTime LastPublished;
        public bool IsStarted;
        public bool Completed;
        public bool Expired;
        public string PendingEnd;
        public Dictionary<string, DateTime> Requests = new(StringComparer.Ordinal);
        public HashSet<string> PendingPrevious = new(StringComparer.Ordinal);
    }
}
