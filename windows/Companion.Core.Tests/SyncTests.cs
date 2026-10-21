using BeeCompanion.Core;
using Xunit;

namespace BeeCompanion.Tests;

public sealed class SyncTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "bee-win-tests-" + Guid.NewGuid());
    private LocalStore NewStore(string name = "library") => new(Path.Combine(directory, name + ".sqlite"));
    private static CompanionRecord TaskRecord(string title = "A") => new() { Kind = "tasks", Body = new() { ["title"] = title, ["status"] = "To do" } };
    private static PushResult Applied(Mutation mutation, int revision) => new(mutation.OperationId, "applied",
        new() { Id = mutation.Id, Kind = mutation.Kind, Revision = revision, Body = new(mutation.Body), Deleted = mutation.Deleted }, null);
    [Fact] public void UnsentDraftsCoalesceButStatusHistorySurvives()
    {
        using var store = NewStore();
        var task = store.Save(TaskRecord()); task.Body["status"] = "Done"; store.Save(task);
        Assert.Equal(1, store.PendingCount);
        Assert.True(store.Get(task.Id)!.Archived);
        Assert.Equal(2, RecordPolicy.History(store.Get(task.Id)!).Count);
        Assert.True(RecordPolicy.History(task)[0].Date > 700_000_000); // native 2001 epoch, not Unix seconds
    }
    [Fact] public void SentOperationSurvivesRestartAndRebasesLaterEdits()
    {
        string id, operation;
        using (var store = NewStore())
        {
            var task = store.Save(TaskRecord()); id = task.Id;
            var first = store.NextMutation()!; operation = first.OperationId;
            task.Body["title"] = "Later draft"; store.Save(task);
            Assert.Equal(2, store.PendingCount);
        }
        using var reopened = NewStore();
        var replay = reopened.NextMutation()!;
        Assert.Equal(operation, replay.OperationId); Assert.Equal("A", replay.Body["title"]);
        reopened.Accept(Applied(replay, 1));
        var later = reopened.NextMutation()!;
        Assert.Equal(1, later.ExpectedRevision); Assert.Equal("Later draft", later.Body["title"]);
        Assert.Equal("Later draft", reopened.Get(id)!.Title);
        reopened.Accept(Applied(later, 2)); Assert.Equal(0, reopened.PendingCount);
    }
    [Fact] public void PullCursorAndRecordsAreAtomicAndDoNotOverwriteDrafts()
    {
        using var store = NewStore();
        var local = store.Save(TaskRecord("Local"));
        var remote = local.Copy(); remote.Body["title"] = "Remote"; remote.Revision = 2;
        var clean = TaskRecord("Clean") with { Revision = 1 };
        store.Apply(new([remote, clean], 7, false));
        Assert.Equal(7, store.Cursor); Assert.Equal("Local", store.Get(local.Id)!.Title);
        Assert.Equal("Clean", store.Get(clean.Id)!.Title);
        Assert.Throws<InvalidDataException>(() => store.Apply(new([remote], 6, false)));
        Assert.Equal(7, store.Cursor);
    }
    [Fact] public void ConflictRetainsLatestDraftAndMergesBothTaskHistories()
    {
        using var store = NewStore();
        var local = store.Save(TaskRecord()); var mutation = store.NextMutation()!;
        var server = RecordPolicy.Stamp(local, local, DateTimeOffset.UtcNow); server.Body["status"] = "In progress";
        server = RecordPolicy.Stamp(server, local, DateTimeOffset.UtcNow); server.Revision = 3;
        store.Accept(new(mutation.OperationId, "conflict", null, server));
        Assert.Equal(0, store.PendingCount);
        local.Body["title"] = "Latest conflicted draft"; store.Save(local);
        Assert.Equal("Latest conflicted draft", store.Conflicts().Single().Local.Title);
        store.Resolve(local.Id, true);
        Assert.Empty(store.Conflicts()); Assert.Equal(3, store.NextMutation()!.ExpectedRevision);
        Assert.Contains(RecordPolicy.History(store.Get(local.Id)!), x => x.Status == "In progress");
    }
    [Fact] public void EditorOpenedBeforeRemotePullPreservesBothVersions()
    {
        using var store = NewStore();
        var server = TaskRecord("Original") with { Revision = 1 };
        store.Apply(new([server], 1, false));
        var editor = store.Get(server.Id)!.Copy();
        var newer = server.Copy(); newer.Revision = 2; newer.Body["title"] = "Remote change";
        store.Apply(new([newer], 2, false));
        editor.Body["title"] = "Unsaved form change"; store.Save(editor);
        Assert.Equal(0, store.PendingCount);
        var conflict = store.Conflicts().Single();
        Assert.Equal("Unsaved form change", conflict.Local.Title);
        Assert.Equal("Remote change", conflict.Server!.Title);
    }
    [Fact] public void ChoosingDeletedServerDoesNotResurrectLocalDraft()
    {
        using var store = NewStore(); var local = store.Save(TaskRecord());
        store.Accept(new(store.NextMutation()!.OperationId, "conflict", null, null));
        store.Resolve(local.Id, false); Assert.True(store.Get(local.Id)!.Deleted); Assert.Equal(0, store.PendingCount);
    }
    [Fact] public void SearchIncludesArchivedCrmAndExcludesDeletedRecords()
    {
        using var store = NewStore();
        var crm = store.Save(new() { Kind = "crm_contacts", Body = new() { ["title"] = "Ada", ["emails"] = "ada@example.com" } });
        Assert.Single(store.Search("example.com")); crm.Deleted = true; store.Save(crm); Assert.Empty(store.Search("example.com"));
    }
    [Fact] public void RecordDatesPreserveCreationAndLegacyAbsence()
    {
        using var store = NewStore(); var initial = DateTimeOffset.Parse("2026-01-01T00:00Z");
        var note = store.Save(new() { Kind = "notes" }, initial);
        var changed = store.Save(note, initial.AddDays(1)); Assert.Equal(note.Get("createdAt"), changed.Get("createdAt"));
        Assert.NotEqual(note.Get("updatedAt"), changed.Get("updatedAt"));
        var legacy = new CompanionRecord { Kind = "notes", Revision = 3 };
        store.Apply(new([legacy], 1, false)); Assert.False(store.Save(legacy).Body.ContainsKey("createdAt"));
    }
    [Fact] public async Task EnginePushesThenPullsAndReplaysAfterLostResponse()
    {
        using var store = NewStore(); store.Save(TaskRecord()); var api = new FakeSyncApi(); var engine = new SyncEngine(store, api);
        api.LoseFirstResponse = true;
        await Assert.ThrowsAsync<IOException>(() => engine.SyncAsync());
        var operation = store.NextMutation()!.OperationId;
        await engine.SyncAsync();
        Assert.Equal(operation, api.LastOperation); Assert.Equal(0, store.PendingCount); Assert.Equal(1, store.Cursor);
        Assert.Equal(1, api.Writes); // receipt replay did not duplicate the write
    }
    [Fact] public async Task InvalidIdentityPreventsAllWrites()
    {
        using var store = NewStore(); store.Save(TaskRecord()); var api = new FakeSyncApi { WrongIdentity = true };
        await Assert.ThrowsAsync<InvalidDataException>(() => new SyncEngine(store, api).SyncAsync());
        Assert.Equal(0, api.Writes); Assert.Equal(1, store.PendingCount);
    }
    public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    private sealed class FakeSyncApi : ISyncApi
    {
        public bool LoseFirstResponse, WrongIdentity;
        public string? LastOperation;
        public int Writes;
        private PushResponse? receipt;
        public Task VerifyInstanceAsync(CancellationToken cancellation = default) => WrongIdentity
            ? Task.FromException(new InvalidDataException("Wrong instance")) : Task.CompletedTask;
        public Task<PushResponse> PushAsync(Mutation mutation, CancellationToken cancellation = default)
        {
            LastOperation = mutation.OperationId;
            if (receipt is null) { Writes++; receipt = new([Applied(mutation, 1)]); }
            if (LoseFirstResponse) { LoseFirstResponse = false; throw new IOException("Response lost"); }
            return Task.FromResult(receipt);
        }
        public Task<PullPage> PullAsync(long cursor, CancellationToken cancellation = default) =>
            Task.FromResult(new PullPage(cursor == 0 ? [receipt!.Results[0].Record!] : [], 1, false));
    }
}
