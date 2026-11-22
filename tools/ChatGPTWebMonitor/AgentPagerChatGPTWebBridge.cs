using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

internal static class AgentPagerChatGPTWebBridge
{
    private const int HttpPort = 49363;
    private const int HookPort = 49361;
    // Compatibility capability token, not a user credential. Never used outside loopback.
    private const string Token = "apw_1119_8f6db7be5a2a45e2a82f4667240bc921";
    private static readonly object SessionLock = new();
    private static readonly ChatGPTWebStatusTracker Tracker = new(SendEvent);
    private static readonly SemaphoreSlim Clients = new(16);
    private static readonly string LogPath = Path.Combine(AppContext.BaseDirectory, "AgentPagerChatGPTWebBridge.log");

    [STAThread]
    private static int Main()
    {
        var listener = new TcpListener(IPAddress.Loopback, HttpPort);
        try
        {
            listener.Start(16);
            ThreadPool.QueueUserWorkItem(_ => AcceptLoop(listener));
            WriteLog("listening on 127.0.0.1:" + HttpPort);
            while (true)
            {
                lock (SessionLock) Tracker.Tick();
                Thread.Sleep(1000);
            }
        }
        catch (Exception error)
        {
            WriteLog("bridge error: " + error.GetType().Name);
            return 1;
        }
        finally { listener.Stop(); }
    }

    private static void AcceptLoop(TcpListener listener)
    {
        while (true)
        {
            try
            {
                var client = listener.AcceptTcpClient();
                if (!Clients.Wait(0)) { client.Dispose(); continue; }
                ThreadPool.QueueUserWorkItem(_ =>
                {
                    try { HandleHttp(client); }
                    finally { Clients.Release(); }
                });
            }
            catch (SocketException) { return; }
            catch (ObjectDisposedException) { return; }
        }
    }

    private static void HandleHttp(TcpClient client)
    {
        try
        {
            client.ReceiveTimeout = 5000;
            client.SendTimeout = 5000;
            using (client)
            using (var stream = client.GetStream())
            {
                var headerText = ReadHeaders(stream);
                if (headerText is null) return;
                var lines = headerText.Split("\r\n", StringSplitOptions.None);
                var requestLine = lines[0].Split(' ');
                if (requestLine.Length != 3) return;
                var method = requestLine[0];
                var path = requestLine[1];
                var headers = ParseHeaders(lines);
                var origin = Header(headers, "origin");
                // Extension origin only, no webpage/opaque origin and no wildcard CORS.
                if (!Regex.IsMatch(origin, "\\Achrome-extension://[a-p]{32}\\z"))
                {
                    Respond(stream, 403, "Forbidden", "{\"ok\":false}", null);
                    return;
                }
                if (path != "/state")
                {
                    Respond(stream, 404, "Not Found", "{\"ok\":false}", origin);
                    return;
                }
                if (method == "OPTIONS")
                {
                    Respond(stream, 204, "No Content", "", origin);
                    return;
                }
                if (method != "POST" || Header(headers, "x-agentpager-token") != Token)
                {
                    Respond(stream, 403, "Forbidden", "{\"ok\":false}", origin);
                    return;
                }
                if (headers.ContainsKey("transfer-encoding") ||
                    !int.TryParse(Header(headers, "content-length"), out var length) || length < 2 || length > 16384)
                {
                    Respond(stream, 400, "Bad Request", "{\"ok\":false}", origin);
                    return;
                }
                Dictionary<string, object> message;
                try
                {
                    var body = ReadBody(stream, length);
                    message = body is null ? null : JsonSerializer.Deserialize<Dictionary<string, object>>(body);
                }
                catch (JsonException) { message = null; }
                bool accepted;
                lock (SessionLock) accepted = message is not null && Tracker.Accept(message);
                Respond(stream, accepted ? 200 : 400, accepted ? "OK" : "Bad Request",
                    accepted ? "{\"ok\":true}" : "{\"ok\":false}", origin);
            }
        }
        catch (Exception error)
        {
            WriteLog("http request error: " + error.GetType().Name);
            client.Dispose();
        }
    }

    private static string ReadHeaders(NetworkStream stream)
    {
        using var bytes = new MemoryStream();
        var matched = 0;
        while (bytes.Length < 16384)
        {
            var value = stream.ReadByte();
            if (value < 0) return null;
            bytes.WriteByte((byte)value);
            if ((matched == 0 || matched == 2) && value == 13) matched++;
            else if ((matched == 1 || matched == 3) && value == 10) matched++;
            else matched = value == 13 ? 1 : 0;
            if (matched == 4) return Encoding.ASCII.GetString(bytes.ToArray(), 0, (int)bytes.Length - 4);
        }
        return null;
    }

    private static Dictionary<string, string> ParseHeaders(string[] lines)
    {
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon <= 0) continue;
            // Ambiguous HTTP framing is rejected, not normalized.
            if (!headers.TryAdd(line[..colon].Trim(), line[(colon + 1)..].Trim()))
                throw new InvalidDataException("Duplicate header");
        }
        return headers;
    }

    private static string Header(Dictionary<string, string> headers, string name) =>
        headers.TryGetValue(name, out var value) ? value : "";

    private static string ReadBody(NetworkStream stream, int length)
    {
        var bytes = new byte[length];
        var offset = 0;
        while (offset < length)
        {
            var read = stream.Read(bytes, offset, length - offset);
            if (read <= 0) return null;
            offset += read;
        }
        return Encoding.UTF8.GetString(bytes);
    }

    private static void Respond(NetworkStream stream, int code, string status, string body, string origin)
    {
        var bytes = Encoding.UTF8.GetBytes(body);
        var header = new StringBuilder();
        header.Append("HTTP/1.1 ").Append(code).Append(' ').Append(status).Append("\r\n");
        header.Append("Content-Type: application/json; charset=utf-8\r\n");
        header.Append("Content-Length: ").Append(bytes.Length).Append("\r\n");
        header.Append("Connection: close\r\n");
        if (origin is not null)
        {
            header.Append("Access-Control-Allow-Origin: ").Append(origin).Append("\r\n");
            header.Append("Access-Control-Allow-Methods: POST, OPTIONS\r\n");
            header.Append("Access-Control-Allow-Headers: Content-Type, X-AgentPager-Token\r\n");
            header.Append("Access-Control-Allow-Private-Network: true\r\n");
            header.Append("Vary: Origin\r\n");
        }
        header.Append("\r\n");
        stream.Write(Encoding.ASCII.GetBytes(header.ToString()));
        stream.Write(bytes);
        stream.Flush();
    }

    private static bool SendEvent(Dictionary<string, object> payload)
    {
        try
        {
            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(payload) + "\n");
            using var client = new TcpClient(AddressFamily.InterNetwork);
            using var deadline = new CancellationTokenSource(TimeSpan.FromMilliseconds(1500));
            client.ConnectAsync(IPAddress.Loopback, HookPort, deadline.Token).AsTask().GetAwaiter().GetResult();
            using var stream = client.GetStream();
            stream.ReadTimeout = 1500;
            stream.WriteTimeout = 1500;
            stream.Write(bytes);
            stream.Flush();
            return stream.ReadByte() == 10;
        }
        catch (IOException) { return false; }
        catch (SocketException) { return false; }
        catch (InvalidOperationException) { return false; }
        catch (OperationCanceledException) { return false; }
    }

    private static void WriteLog(string message)
    {
        try { File.AppendAllText(LogPath, DateTime.Now.ToString("s") + " " + message + Environment.NewLine, Encoding.UTF8); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}
