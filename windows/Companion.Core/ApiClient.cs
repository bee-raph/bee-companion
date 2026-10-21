using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace BeeCompanion.Core;

public interface ISessionVault
{
    Task<SessionTokens?> LoadAsync(string instanceId);
    Task SaveAsync(string instanceId, SessionTokens? tokens);
}
public interface ISyncApi
{
    Task VerifyInstanceAsync(CancellationToken cancellation = default);
    Task<PushResponse> PushAsync(Mutation mutation, CancellationToken cancellation = default);
    Task<PullPage> PullAsync(long cursor, CancellationToken cancellation = default);
}
public sealed class ApiException(HttpStatusCode statusCode, string message) : Exception(message)
{ public HttpStatusCode StatusCode { get; } = statusCode; }

public sealed class ApiClient : ISyncApi, IDisposable
{
    private readonly HttpClient client;
    private readonly InstanceConfiguration config;
    private readonly ISessionVault vault;
    private readonly SemaphoreSlim sessionGate = new(1, 1);
    private SessionTokens? tokens;
    private bool loaded;
    public ApiClient(InstanceConfiguration configuration, ISessionVault sessionVault, HttpClient? http = null)
    {
        configuration.Validate(); config = configuration; vault = sessionVault;
        client = http ?? new HttpClient(new HttpClientHandler { AllowAutoRedirect = false });
        client.Timeout = TimeSpan.FromMinutes(2);
    }
    private Uri Url(string path) => new(config.ApiBaseUrl.AbsoluteUri.TrimEnd('/') + "/api/v1/" + path);
    public async Task VerifyInstanceAsync(CancellationToken cancellation = default)
    {
        var remote = await GetAsync<RemoteInstance>("instance", false, cancellation);
        if (remote.InstanceId != config.InstanceId || remote.ApiVersion != 1)
            throw new InvalidDataException("The server does not match the imported instance configuration.");
    }
    public async Task LoginAsync(string login, string password, CancellationToken cancellation = default)
    {
        await sessionGate.WaitAsync(cancellation);
        try
        {
            await VerifyInstanceAsync(cancellation);
            using var request = new HttpRequestMessage(HttpMethod.Post, Url("auth/login"))
                { Content = JsonContent.Create(new { login, password }, options: Wire.Json) };
            using var response = await client.SendAsync(request, cancellation);
            await CheckAsync(response, cancellation);
            var result = (await response.Content.ReadFromJsonAsync<SessionTokens>(Wire.Json, cancellation))!;
            await vault.SaveAsync(config.InstanceId, result); tokens = result; loaded = true;
        }
        finally { sessionGate.Release(); }
    }
    private async Task<SessionTokens> LoadAsync(CancellationToken cancellation)
    {
        await sessionGate.WaitAsync(cancellation);
        try
        {
            if (!loaded) { tokens = await vault.LoadAsync(config.InstanceId); loaded = true; }
            return tokens ?? throw new InvalidOperationException("Sign in in Settings.");
        }
        finally { sessionGate.Release(); }
    }
    private async Task RefreshAsync(string usedAccessToken, CancellationToken cancellation)
    {
        await sessionGate.WaitAsync(cancellation);
        try
        {
            if (tokens is null) throw new InvalidOperationException("Sign in in Settings.");
            if (tokens.AccessToken != usedAccessToken) return;
            using var request = new HttpRequestMessage(HttpMethod.Post, Url("auth/refresh"))
                { Content = JsonContent.Create(new { token = tokens.RefreshToken }, options: Wire.Json) };
            using var response = await client.SendAsync(request, cancellation);
            if (response.StatusCode == HttpStatusCode.Unauthorized)
            { await vault.SaveAsync(config.InstanceId, null); tokens = null; }
            await CheckAsync(response, cancellation);
            var result = (await response.Content.ReadFromJsonAsync<SessionTokens>(Wire.Json, cancellation))!;
            await vault.SaveAsync(config.InstanceId, result); tokens = result;
        }
        finally { sessionGate.Release(); }
    }
    public async Task<HttpResponseMessage> SendAsync(string path, Func<HttpContent?>? content = null,
        HttpMethod? method = null, bool authorized = true, CancellationToken cancellation = default)
    {
        for (var attempt = 0; ; attempt++)
        {
            var session = authorized ? await LoadAsync(cancellation) : null;
            using var request = new HttpRequestMessage(method ?? HttpMethod.Get, Url(path)) { Content = content?.Invoke() };
            if (session is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", session.AccessToken);
            var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
            if (response.StatusCode == HttpStatusCode.Unauthorized && session is not null && attempt == 0)
            { response.Dispose(); await RefreshAsync(session.AccessToken, cancellation); continue; }
            try { await CheckAsync(response, cancellation); return response; }
            catch { response.Dispose(); throw; }
        }
    }
    private static async Task CheckAsync(HttpResponseMessage response, CancellationToken cancellation)
    {
        if (response.IsSuccessStatusCode) return;
        var message = $"Server returned {(int)response.StatusCode}.";
        try
        {
            using var body = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellation));
            if (body.RootElement.TryGetProperty("detail", out var detail) && detail.ValueKind == JsonValueKind.String)
                message = detail.GetString()!;
        }
        catch (JsonException) { }
        throw new ApiException(response.StatusCode, message);
    }
    public async Task<T> GetAsync<T>(string path, bool authorized = true, CancellationToken cancellation = default)
    {
        using var response = await SendAsync(path, authorized: authorized, cancellation: cancellation);
        return await response.Content.ReadFromJsonAsync<T>(Wire.Json, cancellation)
            ?? throw new InvalidDataException("Empty server response.");
    }
    public async Task<T> PostAsync<T>(string path, object body, CancellationToken cancellation = default)
    {
        using var response = await SendAsync(path, () => JsonContent.Create(body, options: Wire.Json), HttpMethod.Post,
            cancellation: cancellation);
        return await response.Content.ReadFromJsonAsync<T>(Wire.Json, cancellation)
            ?? throw new InvalidDataException("Empty server response.");
    }
    public Task<PushResponse> PushAsync(Mutation mutation, CancellationToken cancellation = default) =>
        PostAsync<PushResponse>("sync/push", new { mutations = new[] { mutation } }, cancellation);
    public Task<PullPage> PullAsync(long cursor, CancellationToken cancellation = default) =>
        GetAsync<PullPage>("sync/pull?cursor=" + cursor, cancellation: cancellation);
    public async Task LogoutAsync(CancellationToken cancellation = default)
    {
        using var response = await SendAsync("auth/logout", () => null, HttpMethod.Post, cancellation: cancellation);
        await sessionGate.WaitAsync(cancellation);
        try { await vault.SaveAsync(config.InstanceId, null); tokens = null; loaded = true; }
        finally { sessionGate.Release(); }
    }
    public void Dispose() { client.Dispose(); sessionGate.Dispose(); }
}

public sealed class SyncEngine(LocalStore store, ISyncApi api)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    public event Action? Changed;
    public async Task SyncAsync(CancellationToken cancellation = default)
    {
        if (!await gate.WaitAsync(0, cancellation)) return;
        try
        {
            await api.VerifyInstanceAsync(cancellation);
            while (await Task.Run(store.NextMutation, cancellation) is { } mutation)
            {
                var response = await api.PushAsync(mutation, cancellation);
                if (response.Results.Count != 1 || response.Results[0].OperationId != mutation.OperationId)
                    throw new InvalidDataException("The sync response did not identify the pending operation.");
                await Task.Run(() => store.Accept(response.Results[0]), cancellation);
                Changed?.Invoke();
            }
            PullPage page;
            do
            {
                var cursor = await Task.Run(() => store.Cursor, cancellation);
                page = await api.PullAsync(cursor, cancellation);
                if (page.HasMore && page.Cursor <= cursor) throw new InvalidDataException("The server cursor did not advance.");
                await Task.Run(() => store.Apply(page), cancellation);
                if (page.Changes.Count > 0) Changed?.Invoke();
            } while (page.HasMore);
        }
        finally { gate.Release(); }
    }
}
