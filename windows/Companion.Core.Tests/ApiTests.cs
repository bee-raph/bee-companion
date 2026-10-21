using System.Net;
using System.Net.Http.Json;
using BeeCompanion.Core;
using Xunit;

namespace BeeCompanion.Tests;
public sealed class ApiTests
{
    internal static readonly InstanceConfiguration Configuration = new(1, "Test", "10000000-0000-0000-0000-000000000001", new("http://127.0.0.1:8787"), 1);
    internal sealed class MemoryVault : ISessionVault
    {
        public SessionTokens? Tokens = new("old-access", "old-refresh");
        public Task<SessionTokens?> LoadAsync(string id) => Task.FromResult(Tokens);
        public Task SaveAsync(string id, SessionTokens? tokens) { Tokens = tokens; return Task.CompletedTask; }
    }
    internal sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    { protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) => send(request); }
    internal static HttpResponseMessage Json(object value) => new(HttpStatusCode.OK) { Content = JsonContent.Create(value, options: Wire.Json) };
    [Fact] public async Task ConcurrentUnauthorizedRequestsRotateTheRefreshTokenOnlyOnce()
    {
        var refreshes = 0;
        using var http = new HttpClient(new Handler(async request =>
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("auth/refresh"))
            { Interlocked.Increment(ref refreshes); await Task.Delay(20); return Json(new SessionTokens("new-access", "new-refresh")); }
            return request.Headers.Authorization?.Parameter == "new-access" ? Json(new { ok = true }) : new(HttpStatusCode.Unauthorized);
        }));
        var vault = new MemoryVault(); using var api = new ApiClient(Configuration, vault, http);
        await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => api.GetAsync<Dictionary<string, bool>>("test")));
        Assert.Equal(1, refreshes); Assert.Equal("new-refresh", vault.Tokens!.RefreshToken);
    }
    [Fact] public async Task WrongInstanceCannotReceiveLoginCredentials()
    {
        var logins = 0;
        using var http = new HttpClient(new Handler(request =>
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("auth/login")) logins++;
            return Task.FromResult(Json(new RemoteInstance(Guid.NewGuid().ToString(), "Wrong", 1)));
        }));
        using var api = new ApiClient(Configuration, new MemoryVault(), http);
        await Assert.ThrowsAsync<InvalidDataException>(() => api.LoginAsync("owner", "not-transmitted"));
        Assert.Equal(0, logins);
    }
    [Fact] public async Task BinaryRequestsRecreateTheSameBodyAfterRefresh()
    {
        List<byte[]> bodies = [];
        using var http = new HttpClient(new Handler(async request =>
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("auth/refresh")) return Json(new SessionTokens("new-access", "new-refresh"));
            bodies.Add(await request.Content!.ReadAsByteArrayAsync());
            return bodies.Count == 1 ? new(HttpStatusCode.Unauthorized) : Json(new { ok = true });
        }));
        using var api = new ApiClient(Configuration, new MemoryVault(), http);
        using var response = await api.SendAsync("files/uploads/test", () => new ByteArrayContent([0, 255, 1, 42]), HttpMethod.Put);
        Assert.Equal(2, bodies.Count); Assert.Equal(bodies[0], bodies[1]);
    }
    [Theory]
    [InlineData("ftp://example.com")]
    [InlineData("https://owner:password@example.com")]
    [InlineData("https://example.com/?token=secret")]
    [InlineData("https://example.com/#fragment")]
    public void UnsafeInstanceConfigurationsAreRejected(string url) =>
        Assert.Throws<InvalidDataException>(() => (Configuration with { ApiBaseUrl = new(url) }).Validate());
    [Fact] public void DirectHttpConnectionsToRemoteHostsAreSupported()
    {
        (Configuration with { ApiBaseUrl = new("http://192.0.2.1:8787") }).Validate();
    }
    [Fact] public void MutationWireNamesMatchTheExistingBackend()
    {
        var json = Wire.Encode(Mutation.From(new CompanionRecord()));
        Assert.Contains("\"operationID\"", json); Assert.Contains("\"expectedRevision\"", json);
        var imported = Wire.Decode<InstanceConfiguration>("""
            {"configurationVersion":1,"instanceName":"Test","instanceID":"10000000-0000-0000-0000-000000000001","apiBaseURL":"http://127.0.0.1:8787","apiVersion":1}
            """);
        imported.Validate(); Assert.Equal(Configuration.InstanceId, imported.InstanceId);
    }
}
