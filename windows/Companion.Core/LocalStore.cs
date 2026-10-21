using Microsoft.Data.Sqlite;

namespace BeeCompanion.Core;

/// One connection and transaction lock keep records/outbox/cursor changes atomic.
public sealed class LocalStore : IDisposable
{
    private readonly SqliteConnection connection;
    private readonly object gate = new();
    private SqliteTransaction? currentTransaction;
    public LocalStore(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        connection = new(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
        connection.Open();
        Execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;");
        Execute("""
            CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, payload TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS outbox(sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL, operation TEXT NOT NULL UNIQUE, payload TEXT NOT NULL, sent INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX IF NOT EXISTS outbox_record ON outbox(id,sequence);
            CREATE TABLE IF NOT EXISTS conflicts(id TEXT PRIMARY KEY, local TEXT NOT NULL, server TEXT);
            CREATE TABLE IF NOT EXISTS preferences(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS transfers(id TEXT PRIMARY KEY, payload TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS cache(key TEXT PRIMARY KEY, payload TEXT NOT NULL);
            """);
    }
    private SqliteCommand Command(string sql, params object?[] args)
    {
        var command = connection.CreateCommand();
        command.CommandText = sql;
        command.Transaction = currentTransaction;
        for (var i = 0; i < args.Length; i++) command.Parameters.AddWithValue("$p" + i, args[i] ?? DBNull.Value);
        return command;
    }
    private void Execute(string sql, params object?[] args)
    { using var c = Command(sql, args); c.ExecuteNonQuery(); }
    private string? Scalar(string sql, params object?[] args)
    { using var c = Command(sql, args); return c.ExecuteScalar() as string; }
    private List<T> Query<T>(string sql, Func<SqliteDataReader, T> map, params object?[] args)
    {
        using var c = Command(sql, args); using var reader = c.ExecuteReader();
        List<T> results = []; while (reader.Read()) results.Add(map(reader)); return results;
    }
    private T Atomic<T>(Func<T> work)
    {
        lock (gate)
        {
            using var transaction = connection.BeginTransaction();
            currentTransaction = transaction;
            try { var result = work(); transaction.Commit(); return result; }
            catch { transaction.Rollback(); throw; }
            finally { currentTransaction = null; }
        }
    }
    private CompanionRecord? GetUnlocked(string id) =>
        Scalar("SELECT payload FROM records WHERE id=$p0", id) is { } data ? Wire.Decode<CompanionRecord>(data) : null;
    private void Put(CompanionRecord record) => Execute(
        "INSERT OR REPLACE INTO records VALUES($p0,$p1)", record.Id, Wire.Encode(record));
    private bool Has(string table, string id) => Scalar($"SELECT id FROM {table} WHERE id=$p0 LIMIT 1", id) is not null;
    public List<CompanionRecord> All()
    { lock (gate) return Query("SELECT payload FROM records", r => Wire.Decode<CompanionRecord>(r.GetString(0))); }
    public CompanionRecord? Get(string id) { lock (gate) return GetUnlocked(id); }
    public int PendingCount { get { lock (gate) { using var c = Command("SELECT COUNT(*) FROM outbox"); return Convert.ToInt32(c.ExecuteScalar()); } } }
    public long Cursor { get { lock (gate) return long.Parse(Scalar("SELECT value FROM preferences WHERE key='cursor'") ?? "0"); } }
    public CompanionRecord Save(CompanionRecord input, DateTimeOffset? now = null) => Atomic(() =>
    {
        var previous = GetUnlocked(input.Id);
        var r = RecordPolicy.Stamp(input, previous, now ?? DateTimeOffset.UtcNow);
        Put(r);
        // A modal editor can stay open across a pull or another edit. Never silently
        // overwrite the newer accepted revision with its older form snapshot.
        if (previous is not null && input.Revision < previous.Revision && !Has("conflicts", r.Id))
        {
            Execute("INSERT OR REPLACE INTO conflicts VALUES($p0,$p1,$p2)", r.Id, Wire.Encode(r), Wire.Encode(previous));
            Execute("DELETE FROM outbox WHERE id=$p0", r.Id);
            return r;
        }
        if (Has("conflicts", r.Id))
        { Execute("UPDATE conflicts SET local=$p0 WHERE id=$p1", Wire.Encode(r), r.Id); return r; }
        Queue(r); return r;
    });
    private void Queue(CompanionRecord record)
    {
        Execute("DELETE FROM outbox WHERE id=$p0 AND sent=0", record.Id);
        var m = Mutation.From(record);
        Execute("INSERT INTO outbox(id,operation,payload) VALUES($p0,$p1,$p2)", m.Id, m.OperationId, Wire.Encode(m));
    }
    public Mutation? NextMutation() => Atomic(() =>
    {
        var payload = Scalar("SELECT payload FROM outbox ORDER BY sequence LIMIT 1");
        if (payload is null) return null;
        var m = Wire.Decode<Mutation>(payload);
        Execute("UPDATE outbox SET sent=1 WHERE operation=$p0", m.OperationId);
        return m;
    });
    public void Accept(PushResult result) => Atomic(() =>
    {
        var payload = Scalar("SELECT payload FROM outbox WHERE operation=$p0", result.OperationId);
        if (payload is null) return false;
        var mutation = Wire.Decode<Mutation>(payload);
        if (result.Status == "conflict")
        {
            var local = GetUnlocked(mutation.Id) ?? throw new InvalidDataException("Missing local draft.");
            Execute("INSERT OR REPLACE INTO conflicts VALUES($p0,$p1,$p2)", local.Id,
                Wire.Encode(local), result.Server is null ? null : Wire.Encode(result.Server));
            Execute("DELETE FROM outbox WHERE id=$p0", local.Id);
        }
        else if (result.Status == "applied" && result.Record is { } server)
        {
            Execute("DELETE FROM outbox WHERE operation=$p0", result.OperationId);
            var later = Query("SELECT operation,payload FROM outbox WHERE id=$p0 ORDER BY sequence",
                r => (Operation: r.GetString(0), Mutation: Wire.Decode<Mutation>(r.GetString(1))), server.Id);
            if (later.Count == 0) Put(server);
            else
            {
                var local = GetUnlocked(server.Id)!; local.Revision = server.Revision; Put(local);
                var revision = server.Revision;
                foreach (var entry in later)
                    Execute("UPDATE outbox SET payload=$p0 WHERE operation=$p1",
                        Wire.Encode(entry.Mutation with { ExpectedRevision = revision++ }), entry.Operation);
            }
        }
        else throw new InvalidDataException("Unknown sync response; the operation remains pending.");
        return true;
    });
    public void Apply(PullPage page) => Atomic(() =>
    {
        if (page.Cursor < Cursor) throw new InvalidDataException("The server cursor moved backwards.");
        foreach (var r in page.Changes)
            if (!Has("outbox", r.Id) && !Has("conflicts", r.Id)) Put(r);
        Execute("INSERT OR REPLACE INTO preferences VALUES('cursor',$p0)", page.Cursor.ToString());
        return true;
    });
    public List<SyncConflict> Conflicts()
    {
        lock (gate) return Query("SELECT id,local,server FROM conflicts", r => new SyncConflict(
            r.GetString(0), Wire.Decode<CompanionRecord>(r.GetString(1)),
            r.IsDBNull(2) ? null : Wire.Decode<CompanionRecord>(r.GetString(2))));
    }
    public void Resolve(string id, bool keepLocal) => Atomic(() =>
    {
        var conflict = Conflicts().First(c => c.Id == id);
        var chosen = (keepLocal ? conflict.Local : conflict.Server ?? conflict.Local).Copy();
        if (conflict.Server is { } server)
            chosen = RecordPolicy.MergeTaskHistory(chosen, keepLocal ? server : conflict.Local);
        chosen.Revision = conflict.Server?.Revision ?? 0;
        if (!keepLocal && conflict.Server is null) chosen.Deleted = true;
        Execute("DELETE FROM conflicts WHERE id=$p0", id);
        Put(chosen);
        if (keepLocal) Queue(chosen);
        return true;
    });
    public List<CompanionRecord> Search(string query) => All().Where(r => !r.Deleted
        && new[] { "tasks", "notes", "reminders", "crm_contacts", "crm_actions" }.Contains(r.Kind)
        && r.Body.Where(p => p.Key is not ("rtf" or "rtfd" or "taskAudit"))
            .Any(p => p.Value.Contains(query, StringComparison.OrdinalIgnoreCase))).Take(200).ToList();
    public void SetCache(string key, string payload)
    { lock (gate) Execute("INSERT OR REPLACE INTO cache VALUES($p0,$p1)", key, payload); }
    public string? GetCache(string key)
    { lock (gate) return Scalar("SELECT payload FROM cache WHERE key=$p0", key); }
    public void SaveTransfer(FileTransfer transfer)
    { lock (gate) Execute("INSERT OR REPLACE INTO transfers VALUES($p0,$p1)", transfer.Id, Wire.Encode(transfer)); }
    public List<FileTransfer> Transfers()
    { lock (gate) return Query("SELECT payload FROM transfers", r => Wire.Decode<FileTransfer>(r.GetString(0))); }
    public void FinishTransfer(string id) { lock (gate) Execute("DELETE FROM transfers WHERE id=$p0", id); }
    public void Dispose() { lock (gate) connection.Dispose(); }
}
