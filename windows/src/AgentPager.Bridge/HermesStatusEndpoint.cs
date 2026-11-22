using System.Net;
using AgentPager.Core;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;

namespace AgentPager.Bridge;

internal static class HermesStatusEndpoint
{
    public static void MapHermesStatus(this WebApplication app, string token,
        Action<HermesHeartbeat> accept)
    {
        app.MapMethods("/hermes-status", ["POST", "OPTIONS"], async context =>
        {
            // Never accept a heartbeat via the phone-facing LAN address or a rebinding hostname.
            if (context.Connection.RemoteIpAddress is not { } remote || !IPAddress.IsLoopback(remote) ||
                context.Connection.LocalIpAddress is not { } local || !IPAddress.IsLoopback(local) ||
                context.Request.Host.Host != "127.0.0.1")
            {
                context.Response.StatusCode = StatusCodes.Status403Forbidden;
                return;
            }

            var origin = context.Request.Headers.Origin.ToString();
            if (origin.Length > 0 && origin != "null")
            {
                context.Response.StatusCode = StatusCodes.Status403Forbidden;
                return;
            }
            if (origin == "null") context.Response.Headers.AccessControlAllowOrigin = "null";
            if (HttpMethods.IsOptions(context.Request.Method))
            {
                context.Response.Headers.AccessControlAllowMethods = "POST";
                context.Response.StatusCode = StatusCodes.Status204NoContent;
                return;
            }

            if (context.Request.ContentLength is not (> 0 and <= HermesHeartbeat.MaximumBytes) ||
                context.Request.ContentType?.Split(';', 2)[0] != "text/plain")
            {
                context.Response.StatusCode = StatusCodes.Status400BadRequest;
                return;
            }
            var body = new byte[(int)context.Request.ContentLength.Value];
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(context.RequestAborted);
            timeout.CancelAfter(TimeSpan.FromSeconds(2));
            try { await context.Request.Body.ReadExactlyAsync(body, timeout.Token); }
            catch (OperationCanceledException) { context.Response.StatusCode = StatusCodes.Status408RequestTimeout; return; }
            catch (IOException) { context.Response.StatusCode = StatusCodes.Status400BadRequest; return; }

            if (HermesHeartbeat.Parse(body, DateTimeOffset.UtcNow, token) is not { } heartbeat)
            {
                context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                return;
            }
            accept(heartbeat);
            context.Response.StatusCode = StatusCodes.Status204NoContent;
        });
    }

}
