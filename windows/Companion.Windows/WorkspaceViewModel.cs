using System.Collections.ObjectModel;
using BeeCompanion.Core;
using CommunityToolkit.Mvvm.ComponentModel;

namespace BeeCompanion.Windows;

public sealed partial class WorkspaceViewModel : ObservableObject, IDisposable
{
    private string status = "Import an instance configuration in Settings to get started.";
    public string Status { get => status; set => SetProperty(ref status, value); }
    private string section = "Today";
    public string Section { get => section; set => SetProperty(ref section, value); }
    private bool busy;
    public bool Busy { get => busy; set => SetProperty(ref busy, value); }
    public ObservableCollection<CompanionRecord> Records { get; } = [];
    public InstanceConfiguration? Configuration { get; private set; }
    public LocalStore? Store { get; private set; }
    public ApiClient? Api { get; private set; }
    public FileTransfers? Files { get; private set; }
    private SyncEngine? sync;
    private readonly SemaphoreSlim work = new(1, 1);
    public string AppDirectory { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BeeCompanion");
    public async Task InitializeAsync()
    {
        var path = Path.Combine(AppDirectory, "instance.json");
        // A deployed configuration seeds a new installation; existing instance choices win.
        if (!File.Exists(path)) path = Path.Combine(AppContext.BaseDirectory, "instance.json");
        if (File.Exists(path)) await ConfigureAsync(Wire.Decode<InstanceConfiguration>(await File.ReadAllTextAsync(path)));
    }
    public async Task ConfigureAsync(InstanceConfiguration config)
    {
        config.Validate();
        if (Store is not null && (Store.PendingCount > 0 || Store.Conflicts().Count > 0 || Store.Transfers().Count > 0))
            throw new InvalidOperationException("Synchronize pending changes and resolve conflicts before switching instances.");
        await work.WaitAsync();
        try
        {
            Configuration = config; Api?.Dispose(); Store?.Dispose();
            var directory = Path.Combine(AppDirectory, config.InstanceId);
            Directory.CreateDirectory(directory);
            Store = await Task.Run(() => new LocalStore(Path.Combine(directory, "library.sqlite")));
            Api = new(config, new SessionVault()); sync = new(Store, Api);
            Files = new(Store, Api, Path.Combine(directory, "files"));
            Directory.CreateDirectory(AppDirectory);
            var temporary = Path.Combine(AppDirectory, "instance.json.tmp");
            await File.WriteAllTextAsync(temporary, Wire.Encode(config));
            File.Move(temporary, Path.Combine(AppDirectory, "instance.json"), true);
            await ReloadAsync(); Status = "Local library ready · " + config.InstanceName;
        }
        finally { work.Release(); }
    }
    public async Task ReloadAsync()
    {
        if (Store is null) return;
        var records = await Task.Run(Store.All);
        Records.Clear(); foreach (var record in records) Records.Add(record);
    }
    public async Task SaveAsync(CompanionRecord record)
    {
        if (Store is null) throw new InvalidOperationException("Import an instance configuration first.");
        await Task.Run(() => Store.Save(record)); await ReloadAsync();
        Status = $"Saved on this PC · {Store.PendingCount} pending";
    }
    public async Task SynchronizeAsync()
    {
        if (sync is null || !await work.WaitAsync(0)) return;
        Busy = true;
        try
        {
            Status = "Synchronizing…";
            await Api!.VerifyInstanceAsync();
            await Files!.UploadPendingAsync();
            await sync.SyncAsync();
            Status = Store!.Conflicts().Count > 0 ? "Conflicts need review in Settings" : "Up to date · " + DateTime.Now.ToShortTimeString();
        }
        catch (Exception error) { Status = "Sync paused · " + error.Message; }
        finally { await ReloadAsync(); Busy = false; work.Release(); }
    }
    public IEnumerable<CompanionRecord> Active(string kind) => Records.Where(r => !r.Deleted && r.Kind == kind);
    public CompanionRecord Settings => Records.FirstOrDefault(r => r.Id == RecordPolicy.SettingsId && !r.Deleted)
        ?? new() { Id = RecordPolicy.SettingsId, Kind = "user_settings" };
    public async Task<string> CachedAsync(string path)
    {
        if (Api is null || Store is null) throw new InvalidOperationException("Configure the instance first.");
        try
        {
            var data = await Api.GetAsync<System.Text.Json.JsonElement>(path);
            var text = data.GetRawText(); Store.SetCache(path, text); return text;
        }
        catch { var cached = Store.GetCache(path); if (cached is null) throw; return cached; }
    }
    public void Dispose() { Api?.Dispose(); Store?.Dispose(); work.Dispose(); }
}
