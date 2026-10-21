using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using BeeCompanion.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace BeeCompanion.Windows;

public sealed partial class MainWindow : Window
{
    private readonly WorkspaceViewModel model = new();
    private readonly NavigationView navigation = new() { IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
        PaneDisplayMode = NavigationViewPaneDisplayMode.Auto, IsSettingsVisible = true, IsPaneToggleButtonVisible = false, OpenPaneLength = 232, IsTitleBarAutoPaddingEnabled = true };
    private readonly StackPanel content = new() { Spacing = 20, Padding = new Thickness(32, 24, 32, 36), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly InfoBar status = new() { IsOpen = false, IsClosable = true, Severity = InfoBarSeverity.Informational };
    private readonly TextBox search = new() { PlaceholderText = "Search your companion", Width = 300 };
    private readonly DispatcherTimer syncTimer = new() { Interval = TimeSpan.FromSeconds(30) };
    private readonly DispatcherTimer clockTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly List<(string Zone, TextBlock Time, TextBlock Detail)> clocks = [];
    private readonly TextBlock syncLabel = Muted("Ready to synchronize", 11);
    private string page = "Today", folder = "", taskFilter = "All";
    private bool archived, editing, closed;
    private DateTime agendaDay = DateTime.Today;
    private static readonly Dictionary<string, string> Collections = new()
    { ["Tasks"] = "tasks", ["Notes"] = "notes", ["Files"] = "files", ["CRM"] = "crm_contacts", ["Reminders"] = "reminders", ["Stocks"] = "watchlist_items" };
    public MainWindow()
    {
        Diagnostics.Write("Main window constructor started");
        Title = "Bee Companion";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new global::Windows.Graphics.SizeInt32(1200, 850));
        foreach (var name in new[] { "Today", "Tasks", "Notes", "Files", "CRM", "Agenda", "Reminders", "Stocks", "RSS Reader", "Archive" })
            navigation.MenuItems.Add(new NavigationViewItem { Content = name == "CRM" ? "Contacts" : name, Tag = name, Icon = new FontIcon { Glyph = Glyph(name), FontSize = 17 } });
        navigation.SelectionChanged += (_, e) =>
        { page = e.IsSettingsSelected ? "Settings" : (e.SelectedItem as NavigationViewItem)?.Tag?.ToString() ?? "Today"; archived = false; search.Text = ""; Render(); };
        var root = new Grid();
        root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        root.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
        navigation.PaneHeader = Brand();
        navigation.SelectedItem = navigation.MenuItems[0];
        var top = new StackPanel { Spacing = 8, Padding = new Thickness(32, 16, 32, 0) };
        var toolbar = new Grid { ColumnSpacing = 12 };
        toolbar.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        search.HorizontalAlignment = HorizontalAlignment.Left;
        toolbar.Children.Add(search);
        toolbar.SizeChanged += (_, _) => search.Width = Math.Max(150, Math.Min(300, toolbar.ActualWidth - 230));
        var sync = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, VerticalAlignment = VerticalAlignment.Center };
        sync.Children.Add(syncLabel);
        sync.Children.Add(Button("↻  Sync", async () => { await model.SynchronizeAsync(); if (!editing && page != "Settings") Render(); }));
        Grid.SetColumn(sync, 1); toolbar.Children.Add(sync);
        top.Children.Add(toolbar); top.Children.Add(status); root.Children.Add(top);
        // Explicitly stretch the scroll presenter so it measures page content against the viewport.
        var scroll = new ScrollViewer { Content = content, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Disabled, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Top };
        scroll.SizeChanged += (_, e) => content.Width = Math.Max(0, e.NewSize.Width - 16);
        var layoutLogged = false;
        content.SizeChanged += (_, _) =>
        {
            if (layoutLogged || model.Store is null || content.ActualWidth <= 0) return;
            layoutLogged = true;
            var origin = content.TransformToVisual(root).TransformPoint(new global::Windows.Foundation.Point(0, 0));
            Diagnostics.Write($"Page layout: left={origin.X:F0}, width={content.ActualWidth:F0}, viewport={scroll.ActualWidth:F0}");
        };
        Grid.SetRow(scroll, 1); root.Children.Add(scroll); navigation.Content = root; Content = navigation;
        model.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(model.Status)) syncLabel.Text = model.Status; };
        search.TextChanged += (_, _) => { if (!editing) Render(); };
        syncTimer.Tick += async (_, _) => { if (!closed) await Run(async () => { await model.SynchronizeAsync(); if (!editing && page != "Settings") Render(); }); };
        clockTimer.Tick += (_, _) => UpdateClocks();
        Activated += async (_, e) =>
        { if (e.WindowActivationState != WindowActivationState.Deactivated && model.Store is not null) await Run(model.SynchronizeAsync); };
        Closed += (_, _) => { closed = true; syncTimer.Stop(); clockTimer.Stop(); /* in-flight requests finish before process exit */ };
        navigation.Loaded += async (_, _) =>
        {
            Diagnostics.Write("Navigation loaded");
            await Run(async () =>
            {
                await model.InitializeAsync(); Diagnostics.Write("Local library initialized");
                Render(); Diagnostics.Write("Initial page rendered");
                await model.SynchronizeAsync(); Render(); syncTimer.Start(); clockTimer.Start();
                Diagnostics.Write("Startup completed");
            });
        };
        Diagnostics.Write("Main window constructor completed");
    }
    private async Task Run(Func<Task> work)
    { try { await work(); } catch (Exception error) { Diagnostics.Write("Operation failed: " + error); status.Severity = InfoBarSeverity.Error; status.Message = error.Message; status.IsOpen = true; } }
    private Button Button(string label, Func<Task> action)
    { var button = new Button { Content = label, CornerRadius = new CornerRadius(8), Padding = new Thickness(14, 8, 14, 8) }; button.Click += async (_, _) => await Run(action); return button; }
    private static TextBlock Text(string text, double size = 14) => new()
    { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private void Render()
    {
        if (editing || closed) return;
        content.Children.Clear(); clocks.Clear();
        if (page != "Today") PageHeading(page == "CRM" ? "Contacts" : page, Subtitle(page));
        if (model.Store is null && page != "Settings")
        { Empty("Welcome to Bee Companion", "Connect your workspace in Settings to bring your tasks, notes, and files to this PC.", "\uE8D4"); return; }
        if (!string.IsNullOrWhiteSpace(search.Text) && model.Store is not null)
        { foreach (var record in model.Store.Search(search.Text)) AddRecord(record); return; }
        if (page == "Settings") { RenderSettings(); return; }
        if (page == "Today") { RenderToday(); return; }
        if (page == "Agenda") { RenderAgenda(); return; }
        if (page == "RSS Reader") { _ = Run(() => RenderFeedsAsync(content)); return; }
        if (page == "Archive")
        { foreach (var record in model.Records.Where(r => !r.Deleted && r.Archived)) AddRecord(record); return; }
        if (!Collections.TryGetValue(page, out var kind)) return;
        var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        controls.Children.Add(Button(page == "Files" ? "↑  Upload files" : "+  New " + (page == "CRM" ? "contact" : page == "Stocks" ? "symbol" : page.TrimEnd('s').ToLowerInvariant()), async () =>
        { if (page == "Files") await UploadAsync(); else await EditAsync(NewRecord(kind)); }));
        if (kind is "tasks" or "notes" or "reminders")
        {
            var toggle = new ToggleSwitch { Header = "Archived", IsOn = archived };
            toggle.Toggled += (_, _) => { archived = toggle.IsOn; Render(); }; controls.Children.Add(toggle);
        }
        if (kind == "tasks")
        {
            var filter = new ComboBox { ItemsSource = new[] { "All", "Today", "Upcoming", "Overdue" }, SelectedItem = taskFilter };
            filter.SelectionChanged += (_, _) => { taskFilter = (string)filter.SelectedItem; Render(); }; controls.Children.Add(filter);
        }
        if (kind == "files")
        {
            controls.Children.Add(Button("All files", () => { folder = ""; Render(); return Task.CompletedTask; }));
            controls.Children.Add(Button("New folder", () => EditAsync(NewRecord("folders"))));
            controls.Children.Add(Button("Trash", async () => await ShowTrashAsync()));
        }
        content.Children.Add(controls);
        var records = model.Active(kind).AsEnumerable();
        if (kind is "tasks" or "notes" or "reminders") records = records.Where(r => r.Archived == archived);
        if (kind == "tasks" && taskFilter != "All") records = records.Where(r => r.Date is { } d && (taskFilter switch
        { "Today" => d.LocalDateTime.Date == DateTime.Today, "Upcoming" => d > DateTimeOffset.Now, _ => d < DateTimeOffset.Now }));
        if (kind == "files") records = model.Active("folders").Concat(records).Where(r => r.Get("parent") == folder);
        var count = 0; foreach (var record in records.OrderBy(r => r.Title)) { AddRecord(record); count++; }
        if (count == 0) Empty("A little room to begin", "Create your first item and keep everything that matters in one place.", Glyph(page));
        if (kind == "watchlist_items")
        { RenderMarketSearch(); _ = Run(() => RenderQuotesAsync(content)); }
    }
    private CompanionRecord NewRecord(string kind) => new()
    { Kind = kind, Body = new() { ["title"] = "", ["status"] = "To do", ["parent"] = folder,
        ["identityType"] = "Individual", ["contactType"] = "Prospect", ["recurrence"] = "Once",
        ["timezone"] = model.Settings.Get("timezone", "Asia/Jerusalem") } };
    private void AddRecord(CompanionRecord record, Panel? parent = null)
    {
        var panel = new StackPanel { Spacing = 10 };
        var heading = new Grid { ColumnSpacing = 14 };
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        heading.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        heading.Children.Add(IconTile(Glyph(record.Kind), record.Kind == "tasks" ? Lavender : Mint));
        var labels = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        var title = Text(record.Title, 16); title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; labels.Children.Add(title);
        var metadata = record.Date is { } date ? date.ToLocalTime().ToString("ddd, MMM d · HH:mm") : record.Kind switch
        { "tasks" => record.Get("status", "To do"), "crm_contacts" => record.Get("contactType", "Contact"), "folders" => "Folder", "notes" => "Note", "files" => "File", _ => "" };
        if (metadata.Length > 0) labels.Children.Add(Muted(metadata, 12));
        Grid.SetColumn(labels, 1); heading.Children.Add(labels); panel.Children.Add(heading);
        var detail = record.Get("description", record.Get("text", record.Get("contactType")));
        if (detail.Length > 0) { var preview = Muted(detail.Length > 180 ? detail[..180] + "…" : detail); preview.MaxLines = 3; panel.Children.Add(preview); }
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        actions.Children.Add(Button(record.Kind == "folders" ? "Open folder" : "Edit", async () =>
        { if (record.Kind == "folders") { folder = record.Id; page = "Files"; Render(); } else await EditAsync(record); }));
        if (record.Kind == "tasks") actions.Children.Add(Button(record.Archived ? "Restore" : "✓  Complete", async () =>
        { var next = record.Copy(); next.Body["status"] = record.Archived ? "To do" : "Done"; await model.SaveAsync(next); Render(); await model.SynchronizeAsync(); }));
        if (record.Kind == "files") actions.Children.Add(Button("Open file", () => OpenFileAsync(record)));
        panel.Children.Add(actions);
        (parent ?? content).Children.Add(Card(panel));
    }
    private void RenderToday()
    {
        content.Children.Add(Muted(DateTime.Now.ToString("dddd, MMMM d").ToUpperInvariant(), 11));
        var hour = DateTime.Now.Hour;
        PageHeading(hour < 12 ? "Good morning." : hour < 18 ? "Good afternoon." : "Good evening.", "A clear view of everything that matters today.", Button("+  New task", () => EditAsync(NewRecord("tasks"))));
        var tasks = model.Active("tasks").ToList();
        var metrics = Columns(3);
        AddColumn(metrics, Metric("Open tasks", tasks.Count(r => !r.Archived).ToString(), "\uE73A", Lavender), 0);
        AddColumn(metrics, Metric("Completed", tasks.Count(r => r.Archived).ToString(), "\uE930", Mint), 1);
        AddColumn(metrics, Metric("In your library", model.Active("notes").Count().ToString(), "\uE8A5", Amber), 2);
        content.Children.Add(metrics);
        var clockRow = Columns(3); var index = 0;
        foreach (var zone in model.Settings.Get("clocks", "Asia/Jerusalem,Europe/London,America/New_York").Split(',').Where(z => !string.IsNullOrWhiteSpace(z)).Take(3))
        {
            var stack = new StackPanel { Spacing = 9 };
            stack.Children.Add(Muted(zone.Trim().Split('/').Last().Replace('_', ' '), 12));
            var time = Text("", 30); time.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            var detail = Muted("", 11); stack.Children.Add(time); stack.Children.Add(detail);
            clocks.Add((zone.Trim(), time, detail)); AddColumn(clockRow, Card(stack), index++);
        }
        content.Children.Add(clockRow); UpdateClocks();
        var body = Columns(2); content.Children.Add(body);
        var horizon = new StackPanel { Spacing = 12 }; var providers = new StackPanel { Spacing = 16 };
        AddColumn(body, horizon, 0); AddColumn(body, providers, 1);
        horizon.Children.Add(Section("Your horizon", "Tasks to keep your day moving", "\uE787"));
        var upcoming = tasks.Where(r => !r.Archived).OrderBy(r => r.Date ?? DateTimeOffset.MaxValue).Take(6).ToList();
        if (upcoming.Count == 0) horizon.Children.Add(Card(new StackPanel { Spacing = 8, Children = { Text("All clear for now", 18), Muted("Enjoy a little breathing room. Your next task can start here.") } }));
        foreach (var task in upcoming) AddRecord(task, horizon);
        _ = Run(() => Task.WhenAll(RenderWeatherAsync(providers), RenderQuotesAsync(providers)));
    }
    private void UpdateClocks()
    {
        var instant = DateTimeOffset.UtcNow;
        foreach (var (zone, time, detail) in clocks)
            try { var c = WorldClock.Read(zone, instant, CultureInfo.CurrentCulture); time.Text = c.Time; detail.Text = c.Date + " · " + c.Offset; }
            catch (TimeZoneNotFoundException) { time.Text = "—"; detail.Text = "Check this time zone in Settings"; }
    }
    private void RenderAgenda()
    {
        var layout = Columns(2);
        var calendar = new CalendarView { SelectionMode = CalendarViewSelectionMode.Single,
            IsTodayHighlighted = true, HorizontalAlignment = HorizontalAlignment.Stretch, MinHeight = 350 };
        var schedule = new StackPanel { Spacing = 12 };
        void ShowDay(DateTime day)
        {
            agendaDay = day.Date;
            schedule.Children.Clear();
            schedule.Children.Add(Section(day.ToString("dddd, MMMM d"), "Tasks, reminders, and contact activity", "\uE787"));
            var items = model.Records.Where(r => !r.Deleted && !r.Archived && r.Date is { } date
                && date.LocalDateTime.Date == day.Date && r.Kind is "tasks" or "reminders" or "crm_actions")
                .OrderBy(r => r.Date).ToList();
            if (items.Count == 0) schedule.Children.Add(Card(new StackPanel { Spacing = 10, Children =
                { Text("A clear day", 20), Muted("Nothing scheduled for this day. Choose another date or plan something new.") } }));
            foreach (var item in items) AddRecord(item, schedule);
            schedule.Children.Add(Button("+  Plan a task", () =>
            {
                var task = NewRecord("tasks");
                task.Body["date"] = new DateTimeOffset(day.Date.AddHours(9)).ToUniversalTime().ToString("O");
                return EditAsync(task);
            }));
        }
        calendar.SelectedDates.Add(new DateTimeOffset(agendaDay));
        calendar.SetDisplayDate(new DateTimeOffset(agendaDay));
        calendar.SelectedDatesChanged += (_, _) => ShowDay(calendar.SelectedDates.FirstOrDefault(DateTimeOffset.Now).LocalDateTime);
        AddColumn(layout, Card(calendar), 0); AddColumn(layout, schedule, 1); content.Children.Add(layout);
        ShowDay(agendaDay);
    }
    private async Task EditAsync(CompanionRecord record)
    {
        editing = true;
        try
        {
            var dialog = new RecordEditor(record, model, navigation.XamlRoot);
            await dialog.ShowAsync();
        }
        finally { editing = false; Render(); }
        await model.SynchronizeAsync();
    }
    private async Task UploadAsync(CompanionRecord? owner = null)
    {
        if (model.Files is null) return;
        var picker = new FileOpenPicker(); InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add("*");
        var files = await picker.PickMultipleFilesAsync();
        foreach (var file in files) await model.Files.QueueAsync(file.Path, folder, owner: owner);
        await model.SynchronizeAsync(); Render();
    }
    private async Task OpenFileAsync(CompanionRecord record)
    {
        var path = await model.Files!.DownloadAsync(record);
        // Never use a record title as a directory path.
        var name = Path.GetFileName(record.Title);
        var directory = Path.Combine(model.AppDirectory, "opened", record.Id); Directory.CreateDirectory(directory);
        var working = Path.Combine(directory, name); File.Copy(path, working, true);
        Process.Start(new ProcessStartInfo(working) { UseShellExecute = true });
    }
    private async Task ShowTrashAsync()
    {
        editing = true;
        try
        {
            var list = new StackPanel { Spacing = 12 };
            foreach (var record in model.Records.Where(r => r.Deleted && r.Kind is "files" or "folders" && r.Get("purged") != "true"))
                list.Children.Add(Button("Restore " + record.Title, async () => { var r = record.Copy(); r.Deleted = false; await model.SaveAsync(r); }));
            await new ContentDialog { Title = "File trash", Content = new ScrollViewer { Content = list }, CloseButtonText = "Close", XamlRoot = navigation.XamlRoot }.ShowAsync();
        }
        finally { editing = false; Render(); }
    }
    private void RenderSettings()
    {
        var settings = new StackPanel { Spacing = 18, MaxWidth = 620, HorizontalAlignment = HorizontalAlignment.Left };
        content.Children.Add(Card(settings));
        settings.Children.Add(Section("Your workspace", "Connection, account, and personal preferences", "\uE713"));
        settings.Children.Add(Text(model.Configuration?.InstanceName ?? "No instance configured", 20));
        settings.Children.Add(Button("Import instance configuration", async () =>
        {
            var picker = new FileOpenPicker(); InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
            picker.FileTypeFilter.Add(".json"); var file = await picker.PickSingleFileAsync(); if (file is null) return;
            await model.ConfigureAsync(Wire.Decode<InstanceConfiguration>(await File.ReadAllTextAsync(file.Path))); Render();
        }));
        if (model.Api is null) return;
        var login = new TextBox { Header = "Owner login" };
        var password = new PasswordBox { Header = "Password" };
        settings.Children.Add(login); settings.Children.Add(password);
        settings.Children.Add(Button("Sign in", async () =>
        { try { await model.Api.LoginAsync(login.Text, password.Password); } finally { password.Password = ""; } await model.SynchronizeAsync(); }));
        settings.Children.Add(Button("Sign out", async () =>
        {
            if (model.Store!.PendingCount > 0 || model.Store.Conflicts().Count > 0 || model.Store.Transfers().Count > 0)
                throw new InvalidOperationException("Synchronize pending changes and resolve conflicts before signing out.");
            await model.Api.LogoutAsync(); model.Status = "Signed out";
        }));
        settings.Children.Add(Button("Edit preferences", () => EditAsync(model.Settings)));
        foreach (var conflict in model.Store!.Conflicts())
        {
            settings.Children.Add(Text("Conflict: " + conflict.Local.Title, 20));
            settings.Children.Add(Text("Local: " + conflict.Local.Get("description", conflict.Local.Get("text"))));
            settings.Children.Add(Text("Server: " + (conflict.Server?.Get("description", conflict.Server.Get("text")) ?? "Deleted")));
            settings.Children.Add(Button("Keep local version", async () => { model.Store.Resolve(conflict.Id, true); await model.ReloadAsync(); Render(); }));
            settings.Children.Add(Button("Use server version", async () => { model.Store.Resolve(conflict.Id, false); await model.ReloadAsync(); Render(); }));
        }
    }
    private string LocationQuery()
    {
        var s = model.Settings;
        return "latitude=" + Uri.EscapeDataString(s.Get("latitude", "31.78")) + "&longitude=" + Uri.EscapeDataString(s.Get("longitude", "35.22"))
            + "&timezone=" + Uri.EscapeDataString(s.Get("timezone", "Asia/Jerusalem"));
    }
    private static string Value(JsonElement element, string key) => element.TryGetProperty(key, out var value) ? value.ToString() : "";
    private async Task RenderWeatherAsync(Panel parent)
    {
        var surface = new StackPanel { Spacing = 12 }; parent.Children.Add(Card(surface)); parent = surface;

        parent.Children.Add(Section("Outside & observances", "Weather and local prayer times", "\uE706"));
        try
        {
            using var document = JsonDocument.Parse(await model.CachedAsync("weather?" + LocationQuery()));
            var weather = document.RootElement;
            parent.Children.Add(Text($"{model.Settings.Get("city")}  {Value(weather, "temperature")}°C · High {Value(weather, "high")}° · Low {Value(weather, "low")}°", 20));
            parent.Children.Add(Text($"Feels like {Value(weather, "feelsLike")}° · Humidity {Value(weather, "humidity")}% · Wind {Value(weather, "wind")} km/h · Open-Meteo"));
            var zone = TimeZoneInfo.FindSystemTimeZoneById(model.Settings.Get("timezone", "Asia/Jerusalem"));
            var day = TimeZoneInfo.ConvertTime(DateTimeOffset.Now, zone).ToString("yyyy-MM-dd");
            using var zmanim = JsonDocument.Parse(await model.CachedAsync("calendar/zmanim?" + LocationQuery() + "&date=" + day));
            if (zmanim.RootElement.TryGetProperty("times", out var times)) foreach (var time in times.EnumerateObject())
                if (DateTimeOffset.TryParse(time.Value.GetString(), out var instant))
                    parent.Children.Add(Text(time.Name + "   " + TimeZoneInfo.ConvertTime(instant, zone).ToString("HH:mm")));
        }
        catch (Exception error) { parent.Children.Add(Text(error.Message)); }
    }
    private async Task RenderQuotesAsync(Panel parent)
    {
        var surface = new StackPanel { Spacing = 12 }; parent.Children.Add(Card(surface)); parent = surface;

        var symbols = model.Active("watchlist_items").Select(r => r.Get("symbol")).Where(s => s.Length > 0).ToArray();
        parent.Children.Add(Section("Stocks", "Your watchlist at a glance", "\uE9D9"));
        parent.Children.Add(Button("Manage watchlist", () =>
        {
            navigation.SelectedItem = navigation.MenuItems.OfType<NavigationViewItem>().First(item => item.Tag?.ToString() == "Stocks");
            return Task.CompletedTask;
        }));
        if (symbols.Length == 0)
        {
            parent.Children.Add(Muted("Add companies or symbols to your watchlist to see their latest prices here."));
            return;
        }
        try
        {
            using var data = JsonDocument.Parse(await model.CachedAsync("market/quotes?symbols=" + Uri.EscapeDataString(string.Join(',', symbols))));
            foreach (var quote in data.RootElement.GetProperty("quotes").EnumerateArray())
            {
                var row = Columns(2, false);
                var name = Text(Value(quote, "symbol"), 15); name.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
                row.Children.Add(name);
                var price = new StackPanel { Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right };
                price.Children.Add(Text(Value(quote, "price"), 18));
                var change = Value(quote, "changePercent");
                var movement = Text(QuoteFormatting.Percentage(change), 12);
                if (double.TryParse(change, NumberStyles.Float, CultureInfo.InvariantCulture, out var percent)) movement.Foreground = percent >= 0 ? Mint : Amber;
                price.Children.Add(movement); AddColumn(row, price, 1); parent.Children.Add(row);
            }
            parent.Children.Add(Text("Latest available minute-candle close; not a live tick quote."));
        }
        catch (Exception error) { parent.Children.Add(Text(error.Message)); }
    }
    private async Task RenderFeedsAsync(Panel parent)
    {
        var surface = new StackPanel { Spacing = 12 }; parent.Children.Add(Card(surface)); parent = surface;

        parent.Children.Add(Section("Reading room", "Updates from your favorite sources", "\uE8A1"));
        try
        {
            using var data = JsonDocument.Parse(await model.CachedAsync("rss/feeds"));
            foreach (var feed in data.RootElement.GetProperty("feeds").EnumerateArray())
            {
                parent.Children.Add(Text(Value(feed, "title"), 20));
                if (!feed.TryGetProperty("articles", out var articles)) continue;
                foreach (var article in articles.EnumerateArray().Take(10))
                {
                    parent.Children.Add(Text(Value(article, "title"), 17)); parent.Children.Add(Text(Value(article, "summary")));
                    parent.Children.Add(Text(Value(article, "published")));
                    if (Uri.TryCreate(Value(article, "url"), UriKind.Absolute, out var url) && url.Scheme is "https" or "http")
                    { var link = new HyperlinkButton { Content = "Read original", NavigateUri = url }; parent.Children.Add(link); }
                }
            }
        }
        catch (Exception error) { parent.Children.Add(Text(error.Message)); }
    }
    private void RenderMarketSearch()
    {
        var query = new TextBox { Header = "Find a company or symbol" }; content.Children.Add(query);
        content.Children.Add(Button("Search market", async () =>
        {
            using var data = JsonDocument.Parse(await model.CachedAsync("market/search?q=" + Uri.EscapeDataString(query.Text)));
            foreach (var instrument in data.RootElement.GetProperty("instruments").EnumerateArray())
            {
                var symbol = Value(instrument, "symbol"); var name = Value(instrument, "name");
                content.Children.Add(Button("Add " + name + " · " + symbol, async () =>
                { await model.SaveAsync(new() { Kind = "watchlist_items", Body = new() { ["title"] = name, ["symbol"] = symbol, ["tradingView"] = symbol } }); Render(); await model.SynchronizeAsync(); }));
            }
        }));
    }
}
