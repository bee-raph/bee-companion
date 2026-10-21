using System.Net.Http.Json;
using System.Security.Cryptography;

namespace BeeCompanion.Core;

public sealed record FileTransfer(string Id, CompanionRecord Record, string LocalPath,
    long Size, string Checksum, string? UploadId = null, string? OwnerId = null, string? OwnerKind = null);
public sealed record UploadSession(string Id, long Offset, bool Complete = false);
public sealed record CompletedUpload([property: System.Text.Json.Serialization.JsonPropertyName("versionID")] string VersionId);

public sealed class FileTransfers(LocalStore store, ApiClient api, string cacheDirectory)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    public event Action<string, double>? Progress;
    public static async Task<string> ChecksumAsync(string path, CancellationToken cancellation = default)
    {
        await using var stream = File.OpenRead(path);
        return Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, cancellation));
    }
    public async Task<CompanionRecord> QueueAsync(string source, string parent = "", CompanionRecord? existing = null,
        CompanionRecord? owner = null, CancellationToken cancellation = default)
    {
        Directory.CreateDirectory(cacheDirectory);
        var record = existing?.Copy() ?? new CompanionRecord { Kind = "files", Body = new()
            { ["title"] = Path.GetFileName(source), ["parent"] = parent } };
        var transferId = Guid.NewGuid().ToString();
        var target = Path.Combine(cacheDirectory, transferId + ".upload");
        try
        {
            await using (var input = File.OpenRead(source))
            await using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write))
            { await input.CopyToAsync(output, cancellation); await output.FlushAsync(cancellation); output.Flush(true); }
            var checksum = await ChecksumAsync(target, cancellation);
            var size = new FileInfo(target).Length;
            if (size > 10L * 1024 * 1024 * 1024) throw new InvalidDataException("Maximum file size is 10 GiB.");
            record.Body["uploadPending"] = "true";
            // Persist the transfer before exposing its record. A restart can replay this step.
            store.SaveTransfer(new(transferId, record, target, size, checksum,
                OwnerId: owner?.Id, OwnerKind: owner?.Kind));
            return record;
        }
        catch { File.Delete(target); throw; }
    }
    public async Task UploadPendingAsync(CancellationToken cancellation = default)
    {
        if (!await gate.WaitAsync(0, cancellation)) return;
        try
        {
            foreach (var original in store.Transfers())
            {
                var transfer = original;
                if (transfer.UploadId is null)
                {
                    var session = await api.PostAsync<UploadSession>("files/uploads", new
                    { fileID = transfer.Record.Id, size = transfer.Size, checksum = transfer.Checksum }, cancellation);
                    transfer = transfer with { UploadId = session.Id }; store.SaveTransfer(transfer);
                }
                var status = await api.GetAsync<UploadSession>("files/uploads/" + transfer.UploadId, cancellation: cancellation);
                if (status.Offset < 0 || status.Offset > transfer.Size) throw new InvalidDataException("Invalid upload offset.");
                await using (var stream = File.OpenRead(transfer.LocalPath))
                {
                    stream.Position = status.Offset;
                    var bytes = new byte[4 * 1024 * 1024];
                    var offset = status.Offset;
                    while (offset < transfer.Size)
                    {
                        var count = await stream.ReadAsync(bytes, cancellation);
                        if (count == 0) throw new EndOfStreamException("The managed upload copy changed.");
                        var chunk = bytes.AsMemory(0, count).ToArray();
                        using var response = await api.SendAsync($"files/uploads/{transfer.UploadId}?offset={offset}",
                            () => new ByteArrayContent(chunk), HttpMethod.Put, cancellation: cancellation);
                        offset += count; Progress?.Invoke(transfer.Record.Id, (double)offset / Math.Max(1, transfer.Size));
                    }
                } // Close the source handle before Windows copies/deletes the managed file.
                var completed = await api.PostAsync<CompletedUpload>("files/uploads/" + transfer.UploadId + "/complete", new { }, cancellation);
                var record = (store.Get(transfer.Record.Id) ?? transfer.Record).Copy();
                record.Body["versionID"] = completed.VersionId;
                record.Body["checksum"] = transfer.Checksum;
                record.Body["size"] = transfer.Size.ToString();
                record.Body["uploadPending"] = "false";
                store.Save(record);
                if (transfer.OwnerId is { } ownerId)
                {
                    var kind = transfer.OwnerKind switch
                    { "tasks" => "task_attachments", "notes" => "note_attachments", "reminders" => "reminder_attachments", _ => "crm_attachments" };
                    if (store.Get(transfer.Id) is null) store.Save(new()
                    { Id = transfer.Id, Kind = kind, Body = new() { ["ownerID"] = ownerId, ["fileID"] = record.Id } });
                }
                var verified = Path.Combine(cacheDirectory, completed.VersionId);
                // Keep the source until metadata and the verified copy are both durable.
                File.Copy(transfer.LocalPath, verified, true);
                store.FinishTransfer(transfer.Id); File.Delete(transfer.LocalPath);
            }
        }
        finally { gate.Release(); }
    }
    public async Task<string> DownloadAsync(CompanionRecord record, CancellationToken cancellation = default)
    {
        var version = record.Get("versionID");
        if (!Guid.TryParse(version, out _)) throw new InvalidDataException("No uploaded file version is available.");
        Directory.CreateDirectory(cacheDirectory);
        var target = Path.Combine(cacheDirectory, version);
        if (File.Exists(target) && await ChecksumAsync(target, cancellation) == record.Get("checksum")) return target;
        var temporary = target + "." + Guid.NewGuid() + ".part";
        try
        {
            using var response = await api.SendAsync("files/" + record.Id + "/content", cancellation: cancellation);
            var checksum = response.Headers.TryGetValues("X-Content-SHA256", out var values) ? values.Single() : null;
            if (checksum is null) throw new InvalidDataException("The server did not provide a file checksum.");
            await using (var input = await response.Content.ReadAsStreamAsync(cancellation))
            await using (var output = File.Create(temporary))
            { await input.CopyToAsync(output, cancellation); await output.FlushAsync(cancellation); output.Flush(true); }
            if (await ChecksumAsync(temporary, cancellation) != checksum)
                throw new InvalidDataException("Downloaded file checksum mismatch.");
            // The content endpoint returns the newest version; avoid caching newer bytes under an old version ID.
            if (checksum != record.Get("checksum")) throw new InvalidDataException("This file changed on another client. Synchronize and download again.");
            File.Move(temporary, target, true); return target;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
