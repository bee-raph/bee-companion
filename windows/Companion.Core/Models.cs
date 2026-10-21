using System.Text.Json;
using System.Text.Json.Serialization;

namespace BeeCompanion.Core;

public static class Wire
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    { PropertyNameCaseInsensitive = true };
    public static string Encode<T>(T value) => JsonSerializer.Serialize(value, Json);
    public static T Decode<T>(string text) => JsonSerializer.Deserialize<T>(text, Json)
        ?? throw new InvalidDataException("The saved data is empty.");
}

public sealed record InstanceConfiguration(
    int ConfigurationVersion, string InstanceName,
    [property: JsonPropertyName("instanceID")] string InstanceId,
    Uri ApiBaseUrl, int ApiVersion)
{
    public void Validate()
    {
        if (ConfigurationVersion != 1 || ApiVersion != 1 || !Guid.TryParse(InstanceId, out _)
            || !ApiBaseUrl.IsAbsoluteUri || !string.IsNullOrEmpty(ApiBaseUrl.UserInfo)
            || !string.IsNullOrEmpty(ApiBaseUrl.Query) || !string.IsNullOrEmpty(ApiBaseUrl.Fragment)
            || !(ApiBaseUrl.Scheme is "https" or "http"))
            throw new InvalidDataException("Import a valid instance configuration using HTTP or HTTPS.");
    }
}

public sealed record CompanionRecord
{
    public string Id { get; init; } = Guid.NewGuid().ToString();
    public string Kind { get; init; } = "tasks";
    public int Revision { get; set; }
    public Dictionary<string, string> Body { get; set; } = [];
    public bool Deleted { get; set; }
    [JsonIgnore] public string Title => Get("title", "Untitled");
    [JsonIgnore] public bool Archived => Get("archived") == "true" || (Kind == "tasks" && Get("status") == "Done");
    [JsonIgnore] public DateTimeOffset? Date => DateTimeOffset.TryParse(Get("date"), out var d) ? d : null;
    public string Get(string key, string fallback = "") => Body.GetValueOrDefault(key, fallback);
    public CompanionRecord Copy() => this with { Body = new(Body) };
    public override string ToString() => Title;
}

public sealed record Mutation(
    [property: JsonPropertyName("operationID")] string OperationId,
    string Id, string Kind, int ExpectedRevision, Dictionary<string, string> Body, bool Deleted)
{
    public static Mutation From(CompanionRecord r) => new(Guid.NewGuid().ToString(), r.Id, r.Kind,
        r.Revision, new(r.Body), r.Deleted);
}
public sealed record PushResponse(List<PushResult> Results);
public sealed record PushResult(
    [property: JsonPropertyName("operationID")] string OperationId,
    string Status, CompanionRecord? Record, CompanionRecord? Server);
public sealed record PullPage(List<CompanionRecord> Changes, long Cursor, bool HasMore);
public sealed record SyncConflict(string Id, CompanionRecord Local, CompanionRecord? Server);
public sealed record SessionTokens(string AccessToken, string RefreshToken);
public sealed record RemoteInstance(
    [property: JsonPropertyName("instanceID")] string InstanceId, string InstanceName, int ApiVersion);
public sealed record TaskAuditEntry(string Id, double Date, string? From, string Status);

public static class RecordPolicy
{
    public static readonly string[] Kinds = ["tasks", "notes", "folders", "files", "crm_contacts",
        "crm_actions", "crm_attachments", "task_attachments", "note_attachments", "reminder_attachments",
        "reminders", "reminder_occurrences", "user_settings", "watchlist_items"];
    public const string SettingsId = "00000000-0000-0000-0000-000000000001";
    private static readonly DateTimeOffset AppleEpoch = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public static CompanionRecord Stamp(CompanionRecord input, CompanionRecord? previous, DateTimeOffset now)
    {
        if (!Kinds.Contains(input.Kind)) throw new InvalidDataException("Unknown record type.");
        var r = input.Copy();
        r.Revision = previous?.Revision ?? r.Revision;
        if (previous is not null)
        {
            // A record with no creation date must not acquire an invented one.
            r.Body.Remove("createdAt");
            if (previous.Body.TryGetValue("createdAt", out var created)) r.Body["createdAt"] = created;
        }
        else r.Body["createdAt"] = now.ToString("O");
        r.Body["updatedAt"] = now.ToString("O");
        if (r.Kind == "tasks")
        {
            var status = r.Get("status", "To do");
            r.Body["archived"] = (status == "Done").ToString().ToLowerInvariant();
            var history = History(previous ?? r);
            if (previous is null || (!r.Deleted && status != previous.Get("status", "To do")))
            {
                history.Add(new(Guid.NewGuid().ToString(), (now - AppleEpoch).TotalSeconds,
                    previous?.Get("status", "To do"), status));
                if (previous is null) r.Body["taskCreatedAt"] = now.ToString("O");
            }
            r.Body["taskAudit"] = Wire.Encode(history);
        }
        return r;
    }
    public static List<TaskAuditEntry> History(CompanionRecord r) =>
        Wire.Decode<List<TaskAuditEntry>>(r.Get("taskAudit", "[]"));
    public static CompanionRecord MergeTaskHistory(CompanionRecord chosen, CompanionRecord other)
    {
        var result = chosen.Copy();
        if (chosen.Kind == "tasks")
        {
            result.Body["taskAudit"] = Wire.Encode(History(chosen).Concat(History(other))
                .DistinctBy(x => x.Id).OrderBy(x => x.Date).ToList());
            if (!result.Body.ContainsKey("taskCreatedAt") && other.Body.TryGetValue("taskCreatedAt", out var created))
                result.Body["taskCreatedAt"] = created;
        }
        return result;
    }
}
