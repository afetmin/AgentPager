using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text.Json;
using AgentPager.Bridge;
using AgentPager.Core;

internal static class PhoneFixture
{
    internal static PairingPayload Pairing(BridgeRuntime runtime) =>
        JsonSerializer.Deserialize<PairingPayload>(runtime.State.PairingText, WireJson.Options)
        ?? throw new Exception("No secure pairing advertised");

    internal static ClientWebSocket Socket(PairingPayload pairing, string? bearer, string? pin = null)
    {
        if (pairing.Version != 2 || pairing.CertificateSha256 is null) throw new Exception("Expected secure pairing QR");
        var expected = Convert.FromHexString(pin ?? pairing.CertificateSha256);
        var socket = new ClientWebSocket();
        socket.Options.RemoteCertificateValidationCallback = (_, leaf, _, _) => leaf is not null &&
            CryptographicOperations.FixedTimeEquals(SHA256.HashData(leaf.GetRawCertData()), expected);
        if (bearer is not null) socket.Options.SetRequestHeader("Authorization", "Bearer " + bearer);
        return socket;
    }

    internal static Uri Endpoint(PairingPayload pairing) => new UriBuilder("wss", pairing.Host, pairing.Port, "/agentgrid").Uri;

    internal static async Task<ClientWebSocket> ConnectAsync(BridgeRuntime runtime, CancellationToken token)
    {
        var pairing = Pairing(runtime);
        var socket = Socket(pairing, pairing.Secret);
        try { await socket.ConnectAsync(Endpoint(pairing), token); return socket; }
        catch { socket.Dispose(); throw; }
    }
}
