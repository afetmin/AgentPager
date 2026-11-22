using System.Net;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using AgentPager.Bridge;
using AgentPager.Core;

internal static class PhoneSecurityTests
{
    internal static void IdentitySurvivesRestart(string testRoot)
    {
        var path = Path.Combine(testRoot, "phone-identity", "fixture.bin");
        using var cipher = new AesGcm(RandomNumberGenerator.GetBytes(32), 16);
        byte[] Protect(byte[] pfx)
        {
            var encrypted = new byte[28 + pfx.Length];
            RandomNumberGenerator.Fill(encrypted.AsSpan(0, 12));
            cipher.Encrypt(encrypted.AsSpan(0, 12), pfx, encrypted.AsSpan(28), encrypted.AsSpan(12, 16));
            return encrypted;
        }
        byte[] Unprotect(byte[] encrypted)
        {
            var pfx = new byte[encrypted.Length - 28];
            cipher.Decrypt(encrypted.AsSpan(0, 12), encrypted.AsSpan(28), encrypted.AsSpan(12, 16), pfx);
            return pfx;
        }

        string pin;
        using (var initial = PhoneTlsIdentity.LoadOrCreate(path, Protect, Unprotect))
            pin = PhoneTlsIdentity.Fingerprint(initial);
        var stored = File.ReadAllBytes(path);
        using (var reloaded = PhoneTlsIdentity.LoadOrCreate(path,
            _ => throw new Exception("Restart must not create a new TLS identity"), Unprotect))
            Check(reloaded.HasPrivateKey && PhoneTlsIdentity.Fingerprint(reloaded) == pin, "TLS identity changed across restart");
        stored[^1] ^= 1;
        File.WriteAllBytes(path, stored);
        try
        {
            using var invalid = PhoneTlsIdentity.LoadOrCreate(path,
                _ => throw new Exception("Damaged identity must not be replaced silently"), Unprotect);
            throw new Exception("Corrupt TLS identity accepted");
        }
        catch (CryptographicException) { }
        Console.WriteLine("PASS phone certificate identity survives protected restart and fails closed on corruption (injected cipher, not Windows DPAPI)");
    }

    internal static async Task RejectUnsafeConnections(BridgeRuntime runtime, CancellationToken token)
    {
        var pairing = PhoneFixture.Pairing(runtime);
        var endpoint = PhoneFixture.Endpoint(pairing);
        var wrong = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32));
        using var distinct = PhoneTlsIdentity.Create();
        using (var unauthenticated = PhoneFixture.Socket(pairing, null))
            await Reject(unauthenticated, endpoint, HttpStatusCode.Unauthorized, token);
        using (var incorrect = PhoneFixture.Socket(pairing, wrong))
            await Reject(incorrect, endpoint, HttpStatusCode.Unauthorized, token);
        using (var queryOnly = PhoneFixture.Socket(pairing, null))
            await Reject(queryOnly, new UriBuilder(endpoint) { Query = "secret=" + Uri.EscapeDataString(pairing.Secret) }.Uri,
                HttpStatusCode.Unauthorized, token);
        using (var browser = PhoneFixture.Socket(pairing, pairing.Secret))
        {
            browser.Options.SetRequestHeader("Origin", "https://fixture.invalid");
            await Reject(browser, endpoint, HttpStatusCode.Forbidden, token);
        }
        using (var incorrectPin = PhoneFixture.Socket(pairing, pairing.Secret, PhoneTlsIdentity.Fingerprint(distinct)))
            await Reject(incorrectPin, endpoint, null, token);
        using (var legacy = new ClientWebSocket())
            await Reject(legacy, new Uri("ws://127.0.0.1:49362/agentgrid"), HttpStatusCode.NotFound, token);
        using (var cleartext = new ClientWebSocket())
            // Kestrel may simply terminate a cleartext connection on a TLS-only port.
            await Reject(cleartext, new UriBuilder(endpoint) { Scheme = "ws" }.Uri, null, token);
        Check(runtime.State.PhoneCount == 0, "A rejected upgrade must not count as a phone");
        Console.WriteLine("PASS phone rejects missing/wrong/query-only bearer, browser Origin, wrong pin, and plaintext upgrades");
    }

    internal static async Task VerifySignedControl(ClientWebSocket socket, PairingPayload pairing, CancellationToken token)
    {
        var request = new SignedControlEnvelope(1, Guid.NewGuid(), "control.request", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            "synthetic-phone-security-test", 1, Guid.NewGuid().ToString(), new("no-such-task", ControlAction.Approve, null), "");
        request = request with { Signature = Convert.ToBase64String(HMACSHA256.HashData(Convert.FromBase64String(pairing.Secret), ControlSigner.SigningData(request))) };
        var text = JsonSerializer.SerializeToUtf8Bytes(request, WireJson.Options);
        async Task<ControlAckPayload> Submit()
        {
            await socket.SendAsync(text, WebSocketMessageType.Text, true, token);
            var buffer = new byte[32768];
            while (true)
            {
                using var bytes = new MemoryStream();
                WebSocketReceiveResult frame;
                do
                {
                    frame = await socket.ReceiveAsync(buffer, token);
                    Check(frame.MessageType == WebSocketMessageType.Text, "Expected a secure text frame");
                    bytes.Write(buffer, 0, frame.Count);
                } while (!frame.EndOfMessage);
                var received = Encoding.UTF8.GetString(bytes.ToArray());
                Check(!received.Contains(pairing.Secret, StringComparison.Ordinal) && !received.Contains(pairing.CertificateSha256!, StringComparison.Ordinal),
                    "Pairing material must stay out of application frames");
                using var json = JsonDocument.Parse(received);
                if (json.RootElement.GetProperty("type").GetString() == "control.ack")
                    return json.RootElement.GetProperty("payload").Deserialize<ControlAckPayload>(WireJson.Options)!;
            }
        }
        var first = await Submit();
        var replay = await Submit();
        Check(first.RequestID == request.MessageId && first.Reason is not null && first.Reason != "签名或序号无效", "Valid signed control did not reach the task catalog");
        Check(replay.RequestID == request.MessageId && replay.Result == ControlResult.Rejected && replay.Reason == "签名或序号无效", "Existing signed control replay guard must still reject replays");
        Console.WriteLine("PASS authorized phone receives snapshots, valid signed control reaches catalog, and replay is rejected");
    }

    private static async Task Reject(ClientWebSocket socket, Uri uri, HttpStatusCode? expected, CancellationToken token)
    {
        socket.Options.CollectHttpResponseDetails = true;
        try { await socket.ConnectAsync(uri, token); }
        catch (WebSocketException) when (expected is null || socket.HttpStatusCode == expected) { return; }
        throw new Exception("Unsafe phone upgrade was accepted");
    }

    private static void Check(bool ok, string error) { if (!ok) throw new Exception(error); }
}
