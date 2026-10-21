using System.Net;
using System.Security.Cryptography;
using BeeCompanion.Core;
using Xunit;

namespace BeeCompanion.Tests;
public sealed class FileTests : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "bee-file-tests-" + Guid.NewGuid());
    [Fact] public async Task RestartedUploadUsesServerOffsetAndKeepsAttachmentIdentity()
    {
        Directory.CreateDirectory(directory);
        using var store = new LocalStore(Path.Combine(directory, "library.sqlite"));
        var data = new byte[4 * 1024 * 1024 + 17]; Random.Shared.NextBytes(data);
        var source = Path.Combine(directory, "source.bin"); await File.WriteAllBytesAsync(source, data);
        var uploadId = Guid.NewGuid().ToString(); var versionId = uploadId;
        var offsets = new List<long>(); byte[]? sent = null;
        using var http = new HttpClient(new ApiTests.Handler(async request =>
        {
            if (request.Method == HttpMethod.Put)
            {
                offsets.Add(long.Parse(request.RequestUri!.Query.Split('=')[1]));
                sent = await request.Content!.ReadAsByteArrayAsync(); return ApiTests.Json(new { offset = data.Length });
            }
            return request.RequestUri!.AbsolutePath.EndsWith("complete")
                ? ApiTests.Json(new { versionID = versionId })
                : ApiTests.Json(new { id = uploadId, offset = 4 * 1024 * 1024, complete = false });
        }));
        using var api = new ApiClient(ApiTests.Configuration, new ApiTests.MemoryVault(), http);
        var files = new FileTransfers(store, api, Path.Combine(directory, "cache"));
        var owner = new CompanionRecord { Kind = "notes" };
        await files.QueueAsync(source, owner: owner);
        var transfer = store.Transfers().Single();
        store.SaveTransfer(transfer with { UploadId = uploadId });
        // The original file is no longer needed once the managed copy is durable.
        File.Delete(source);
        await new FileTransfers(store, api, Path.Combine(directory, "cache")).UploadPendingAsync();
        Assert.Equal([4 * 1024 * 1024L], offsets); Assert.Equal(data[^17..], sent);
        Assert.Empty(store.Transfers());
        var record = store.Get(transfer.Record.Id)!;
        Assert.Equal(versionId, record.Get("versionID")); Assert.Equal("false", record.Get("uploadPending"));
        var link = store.Get(transfer.Id)!; Assert.Equal(owner.Id, link.Get("ownerID")); Assert.Equal(record.Id, link.Get("fileID"));
        Assert.Equal(Convert.ToHexStringLower(SHA256.HashData(data)), await FileTransfers.ChecksumAsync(Path.Combine(directory, "cache", versionId)));
    }
    [Fact] public async Task CorruptDownloadNeverPublishesAnOfflineCopy()
    {
        Directory.CreateDirectory(directory);
        using var store = new LocalStore(Path.Combine(directory, "library.sqlite"));
        using var http = new HttpClient(new ApiTests.Handler(_ =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent([1, 2, 3]) };
            response.Headers.Add("X-Content-SHA256", new string('0', 64)); return Task.FromResult(response);
        }));
        using var api = new ApiClient(ApiTests.Configuration, new ApiTests.MemoryVault(), http);
        var cache = Path.Combine(directory, "cache"); var version = Guid.NewGuid().ToString();
        await Assert.ThrowsAsync<InvalidDataException>(() => new FileTransfers(store, api, cache).DownloadAsync(new()
            { Kind = "files", Body = new() { ["versionID"] = version, ["checksum"] = new string('0', 64) } }));
        Assert.Empty(Directory.GetFiles(cache));
    }
    public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
}
