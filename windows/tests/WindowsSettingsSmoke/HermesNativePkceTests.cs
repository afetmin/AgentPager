using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AgentPager.Core;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using static HermesAuthTests;

internal static class HermesNativePkceTests
{
    public static async Task Run()
    {
        var builder = WebApplication.CreateSlimBuilder(); builder.Logging.ClearProviders(); builder.WebHost.UseUrls("http://127.0.0.1:0");
        await using var app = builder.Build();
        var flows = new ConcurrentDictionary<string,(string State,string Challenge,string Redirect)>();
        var codes = new ConcurrentDictionary<string,string>();
        var passwordCalls=0;var unexpected=0;
        app.MapGet("/{mode}/api/status",()=>Results.Json(new{auth_providers=new[]{"basic"},auth_flows=new[]{"cookie","native_pkce"}}));
        app.MapGet("/{mode}/auth/native/authorize",(HttpContext c,string mode)=>{
            Check(c.Request.Headers.Cookie.Count==0 && c.Request.Headers.Authorization.Count==0,"Native authorize must be isolated");
            var challenge=c.Request.Query["code_challenge"].ToString(); var state=c.Request.Query["state"].ToString(); var redirect=c.Request.Query["redirect_uri"].ToString();
            Check(challenge.Length==43 && state.Length>=32 && c.Request.Query["code_challenge_method"]=="S256" && c.Request.Query["provider"]=="basic","Native S256 request missing");
            Check(new Uri(redirect).Host=="127.0.0.1","Native redirect must be loopback literal");
            var broker=Guid.NewGuid().ToString("N");flows[broker]=(state,challenge,redirect);
            c.Response.Headers.Append("Set-Cookie",$"hermes_session_pkce_0123456789abcdef={broker}; HttpOnly; Path=/{mode}; SameSite=None");
            c.Response.Headers.Append("Set-Cookie","unrelated=private-do-not-forward; HttpOnly");
            c.Response.StatusCode=302;c.Response.Headers.Location=mode=="bad-location"?"http://127.0.0.1:1/leak":$"/{mode}/login";
            return Task.CompletedTask;
        });
        app.MapGet("/{mode}/login",()=>{unexpected++;return "Do not follow browser redirect";});
        app.MapPost("/{mode}/auth/password-login",async(HttpContext c,string mode)=>{
            passwordCalls++;using var doc=await JsonDocument.ParseAsync(c.Request.Body);
            Check(doc.RootElement.GetProperty("password").GetString()=="fixture-password","Wrong password body");
            var cookie=c.Request.Headers.Cookie.ToString();Check(cookie.StartsWith("hermes_session_pkce_0123456789abcdef=")&&!cookie.Contains("unrelated"),"Only broker cookie may be submitted");
            var key=cookie.Split('=',2)[1];Check(flows.TryGetValue(key,out var flow),"Unknown broker");
            var code=Guid.NewGuid().ToString("N");codes[code]=flow.Challenge;
            var state=mode=="wrong-state"?"wrong-state":flow.State;
            var next=flow.Redirect+"?code="+code+"&state="+state;
            if(mode=="wrong-callback")next="http://127.0.0.1:1/other?code="+code+"&state="+state;
            await c.Response.WriteAsJsonAsync(new{ok=true,next});
        });
        app.MapPost("/{mode}/auth/native/token",async(HttpContext c)=>{
            Check(c.Request.Headers.Cookie.Count==0,"Native token exchange must not forward broker cookie");
            using var doc=await JsonDocument.ParseAsync(c.Request.Body);var code=doc.RootElement.GetProperty("code").GetString()!;
            var verifier=doc.RootElement.GetProperty("code_verifier").GetString()!;
            var calculated=Convert.ToBase64String(SHA256.HashData(Encoding.ASCII.GetBytes(verifier))).TrimEnd('=').Replace('+','-').Replace('/','_');
            Check(codes.TryRemove(code,out var expected)&&expected==calculated,"S256 verifier mismatch or code replay");
            await c.Response.WriteAsJsonAsync(new{access_token="native-access",refresh_token="native-refresh",provider="basic",token_type="Bearer",expires_at=DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds()});
        });
        app.MapGet("/{mode}/api/auth/me",(HttpRequest r)=>r.Headers.Authorization=="Bearer native-access"
            ?Results.Json(new{provider="basic",user_id="fixture-user",expires_at=DateTimeOffset.UtcNow.AddHours(1).ToUnixTimeSeconds()})
            :Results.Unauthorized()); // Ordinary browser cookies would fail on the protected Webapp.
        await app.StartAsync(); using var client=new NativeHermesAuthClient(); var endpoint=app.Urls.Single();
        var session=await client.LoginAsync(endpoint+"/ok","fixture-user","fixture-password");
        Check(session.AccessToken=="native-access"&&session.RefreshToken=="native-refresh"&&passwordCalls==1&&unexpected==0,"Native login did not exchange/verify the protected Webapp session");
        foreach(var mode in new[]{"wrong-state","wrong-callback","bad-location"})
        {
            var before=passwordCalls;
            try{await client.LoginAsync(endpoint+"/"+mode,"fixture-user","fixture-password");throw new Exception("Unsafe native callback accepted");}
            catch(HermesAuthenticationException){ }
            Check(passwordCalls-before==(mode=="bad-location"?0:1),"Native failure downgraded/repeated password login");
        }
        Check(unexpected==0,"Native flow followed browser redirects");
        Console.WriteLine("PASS native PKCE protected-Webapp login: S256, broker-cookie isolation, exact callback/state, token exchange, bearer verify, no redirect/downgrade/retry");
    }
}
