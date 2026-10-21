using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Security.Cryptography;
using BeeCompanion.Core;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;

namespace BeeCompanion.Windows;

public sealed class RecordEditor : ContentDialog
{
    private readonly CompanionRecord record;
    private readonly WorkspaceViewModel model;
    private readonly StackPanel fields = new() { Spacing = 18, MinWidth = 400, MaxWidth = 560, Padding = new Thickness(0, 4, 12, 12) };
    private readonly Dictionary<string, Func<string>> values = [];
    private readonly InfoBar error = new() { IsOpen = false, IsClosable = true, Severity = InfoBarSeverity.Error };
    private RichEditBox? note;
    private string originalRtf = "";
    private bool noteChanged;
    public RecordEditor(CompanionRecord input, WorkspaceViewModel workspace, XamlRoot root)
    {
        record = input.Copy(); model = workspace; XamlRoot = root;
        Title = input.Revision == 0 ? "New " + RecordKindName(input.Kind) : "Edit " + RecordKindName(input.Kind);
        PrimaryButtonText = "Save"; CloseButtonText = "Cancel"; DefaultButton = ContentDialogButton.Primary;
        var close = new Button { Content = "×", FontSize = 22, Padding = new Thickness(10, 0, 10, 4), CornerRadius = new CornerRadius(8), HorizontalAlignment = HorizontalAlignment.Right };
        AutomationProperties.SetName(close, "Close popup"); close.Click += (_, _) => Hide(); fields.Children.Add(close);
        fields.Children.Add(error);
        if (record.Kind == "user_settings") BuildPreferences(); else BuildRecord();
        Content = new ScrollViewer { Content = fields, MaxHeight = 620 };
        PrimaryButtonClick += SaveClicked;
    }
    private static string RecordKindName(string kind) => kind switch
    { "tasks" => "task", "notes" => "note", "files" => "file", "folders" => "folder", "crm_contacts" => "contact", "crm_actions" => "activity", "reminders" => "reminder", "user_settings" => "preferences", _ => "watchlist item" };
    private void Field(string key, string label, bool multiline = false, string fallback = "")
    {
        var input = new TextBox { Header = label, Text = record.Get(key, fallback), AcceptsReturn = multiline,
            TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap, MinHeight = multiline ? 90 : 0 };
        fields.Children.Add(input); values[key] = () => input.Text;
    }
    private void Select(string key, string label, string[] options, string fallback = "")
    {
        var select = new ComboBox { Header = label, ItemsSource = options, SelectedItem = record.Get(key, fallback), HorizontalAlignment = HorizontalAlignment.Stretch };
        if (select.SelectedIndex < 0) select.SelectedIndex = 0;
        fields.Children.Add(select); values[key] = () => select.SelectedItem?.ToString() ?? "";
    }
    private void DateField(string key, string label)
    {
        var enabled = new CheckBox { Content = label, IsChecked = record.Get(key).Length > 0 };
        var date = new CalendarDatePicker { Date = DateTimeOffset.TryParse(record.Get(key), out var instant) ? instant.ToLocalTime() : DateTimeOffset.Now };
        var time = new TimePicker { ClockIdentifier = "24HourClock", Time = instant == default ? DateTime.Now.TimeOfDay : instant.LocalDateTime.TimeOfDay };
        var group = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        group.Children.Add(date); group.Children.Add(time); fields.Children.Add(enabled); fields.Children.Add(group);
        values[key] = () =>
        {
            if (enabled.IsChecked != true) return "";
            if (date.Date is null) throw new InvalidDataException("Choose a date.");
            var local = DateTime.SpecifyKind(date.Date.Value.Date + time.Time, DateTimeKind.Unspecified);
            if (TimeZoneInfo.Local.IsInvalidTime(local)) throw new InvalidDataException("This time does not exist because of a daylight-saving transition. Choose another time.");
            return new DateTimeOffset(local, TimeZoneInfo.Local.GetUtcOffset(local)).ToUniversalTime().ToString("O");
        };
    }
    private void BuildRecord()
    {
        Field("title", "Title");
        if (record.Kind is not ("files" or "folders" or "watchlist_items")) Field("description", "Description", true);
        if (record.Kind == "tasks")
        { Select("status", "Status", ["To do", "In progress", "Done", "Cancelled"], "To do"); Select("dateOnly", "All-day task", ["false", "true"], "false"); }
        if (record.Kind is "tasks" or "reminders" or "crm_actions") DateField("date", "Has a date and time");
        if (record.Kind == "reminders")
        { Select("recurrence", "Repeat", ["Once", "Daily", "Weekdays", "Weekly", "Monthly"], "Once"); Field("timezone", "IANA time zone", fallback: "Asia/Jerusalem"); Field("weekdays", "Weekdays (Sunday=1, Saturday=7)", fallback: "2,3,4,5,6"); }
        if (record.Kind is "notes" or "crm_contacts") BuildNote();
        if (record.Kind == "crm_contacts")
        {
            Select("identityType", "Identity", ["Individual", "Company"], "Individual");
            Select("contactType", "Category", ["Client", "Prospect", "Provider", "Simple contact"], "Prospect");
            foreach (var (key, label) in new[] { ("firstName", "First name"), ("lastName", "Last name"), ("company", "Company"), ("jobTitle", "Job title"),
                ("birthday", "Birthday"), ("registration", "Registration"), ("taxID", "Tax ID"), ("website", "Website"), ("emails", "Emails"),
                ("phones", "International phone numbers"), ("mobiles", "International mobile numbers"), ("whatsapp", "WhatsApp numbers"), ("addresses", "Addresses") })
                Field(key, label, key is "emails" or "phones" or "mobiles" or "whatsapp" or "addresses");
        }
        if (record.Kind == "crm_actions")
        { Select("actionType", "Activity type", ["Phone call", "Email sent", "WhatsApp sent", "Invoice sent"], "Phone call"); DateField("reminderDate", "Desktop reminder"); }
        if (record.Kind is "files" or "folders")
        {
            var choices = model.Active("folders").Where(r => r.Id != record.Id).ToList();
            var parent = new ComboBox { Header = "Folder", HorizontalAlignment = HorizontalAlignment.Stretch };
            parent.Items.Add(new ComboBoxItem { Content = "All files", Tag = "" });
            foreach (var choice in choices) parent.Items.Add(new ComboBoxItem { Content = choice.Title, Tag = choice.Id });
            parent.SelectedItem = parent.Items.Cast<ComboBoxItem>().FirstOrDefault(x => (string)x.Tag == record.Get("parent")) ?? parent.Items[0];
            fields.Children.Add(parent); values["parent"] = () => (string)((ComboBoxItem)parent.SelectedItem).Tag;
        }
        if (record.Kind == "watchlist_items")
        { Field("symbol", "Provider symbol"); Field("tradingView", "TradingView symbol"); Field("order", "Watchlist order", fallback: "0"); }
        if (model.Store?.Get(record.Id) is not null)
        {
            var archive = new CheckBox { Content = "Archived", IsChecked = record.Archived };
            if (record.Kind is "notes" or "reminders") { fields.Children.Add(archive); values["archived"] = () => (archive.IsChecked == true).ToString().ToLowerInvariant(); }
            foreach (var key in new[] { "createdAt", "updatedAt" }) fields.Children.Add(new TextBlock { Text = (key == "createdAt" ? "Created " : "Updated ") + (DateTimeOffset.TryParse(record.Get(key), out var stamp) ? stamp.ToLocalTime().ToString("f") : "Unavailable"), FontSize = 11, Opacity = 0.6 });
            if (record.Kind == "tasks") foreach (var audit in RecordPolicy.History(record)) fields.Children.Add(new TextBlock
                { Text = audit.Status + " · " + new DateTimeOffset(2001, 1, 1, 0, 0, 0, TimeSpan.Zero).AddSeconds(audit.Date).ToLocalTime().ToString("g") });
            BuildAttachments(); BuildActivities();
            var delete = new Button { Content = "Move to Trash" };
            delete.Click += (_, _) =>
            {
                // A visible confirmation avoids nesting ContentDialogs.
                var confirm = new Button { Content = "Confirm deletion" };
                confirm.Click += async (_, _) => { try { await DeleteAsync(record); Hide(); } catch (Exception e) { ShowError(e); } };
                fields.Children.Add(confirm); delete.IsEnabled = false;
            };
            fields.Children.Add(delete);
        }
    }
    private void BuildNote()
    {
        note = new RichEditBox { MinHeight = 250, AcceptsReturn = true, Header = "Note" };
        if (record.Get("rtfd").Length > 0)
        {
            fields.Children.Add(new TextBlock { Text = "This note contains a macOS RTFD image document. Windows can read its text; editing its note content is disabled until portable image interchange is available.", TextWrapping = TextWrapping.Wrap });
            note.IsReadOnly = true;
        }
        try
        {
            if (record.Get("rtf").Length > 0)
                note.Document.SetText(TextSetOptions.FormatRtf, Encoding.Latin1.GetString(Convert.FromBase64String(record.Get("rtf"))));
            else note.Document.SetText(TextSetOptions.None, record.Get("text", record.Get("notes")));
        }
        catch { note.Document.SetText(TextSetOptions.None, record.Get("text", record.Get("notes"))); }
        note.Document.GetText(TextGetOptions.FormatRtf, out originalRtf);
        note.TextChanged += (_, _) => { note.Document.GetText(TextGetOptions.FormatRtf, out var current); noteChanged = current != originalRtf; };
        var toolbar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var label in new[] { "Bold", "Italic", "Underline" })
        {
            var button = new Button { Content = label, IsEnabled = !note.IsReadOnly };
            button.Click += (_, _) =>
            {
                note.Focus(FocusState.Programmatic); var format = note.Document.Selection.CharacterFormat;
                if (label == "Bold") format.Bold = FormatEffect.Toggle;
                else if (label == "Italic") format.Italic = FormatEffect.Toggle;
                else format.Underline = format.Underline == UnderlineType.None ? UnderlineType.Single : UnderlineType.None;
            };
            toolbar.Children.Add(button);
        }
        fields.Children.Add(toolbar); fields.Children.Add(note);
    }
    private void BuildPreferences()
    {
        Select("language", "Language", ["en", "he", "fr", "ru", "es"], "en");
        Field("clocks", "Up to three IANA world-clock zones", fallback: "Asia/Jerusalem,Europe/London,America/New_York");
        Field("city", "City"); Field("latitude", "Latitude"); Field("longitude", "Longitude");
        Field("timezone", "Location time zone", fallback: "Asia/Jerusalem"); Select("israel", "Israel observances", ["true", "false"], "true");
        List<JsonElement> feeds;
        try { feeds = Wire.Decode<List<JsonElement>>(record.Get("rssFeeds", "[]")); } catch { feeds = []; }
        var inputs = new List<(string Id, TextBox Name, TextBox Url)>();
        for (var i = 0; i < 3; i++)
        {
            var feed = i < feeds.Count ? feeds[i] : default;
            string Get(string key) => feed.ValueKind == JsonValueKind.Object && feed.TryGetProperty(key, out var v) ? v.GetString() ?? "" : "";
            var name = new TextBox { Header = $"Feed {i + 1} name", Text = Get("title") };
            var url = new TextBox { Header = $"Feed {i + 1} URL", Text = Get("url") };
            inputs.Add((Get("id") is { Length: > 0 } id ? id : Guid.NewGuid().ToString(), name, url));
            fields.Children.Add(name); fields.Children.Add(url);
        }
        values["rssFeeds"] = () => Wire.Encode(inputs.Where(x => !string.IsNullOrWhiteSpace(x.Url.Text))
            .Select(x => new { id = x.Id, title = x.Name.Text, url = x.Url.Text.Trim() }));
    }
    private void BuildAttachments()
    {
        foreach (var link in model.Records.Where(r => !r.Deleted && r.Kind.EndsWith("_attachments") && r.Get("ownerID") == record.Id).ToList())
        {
            var file = model.Records.FirstOrDefault(r => r.Id == link.Get("fileID") && !r.Deleted);
            if (file is null) continue;
            fields.Children.Add(new TextBlock { Text = "Attachment: " + file.Title });
            var remove = new Button { Content = "Remove attachment link" };
            remove.Click += async (_, _) => { try { var deleted = link.Copy(); deleted.Deleted = true; await model.SaveAsync(deleted); remove.IsEnabled = false; } catch (Exception e) { ShowError(e); } };
            fields.Children.Add(remove);
        }
    }
    private void BuildActivities()
    {
        if (record.Kind != "crm_contacts") return;
        foreach (var activity in model.Active("crm_actions").Where(r => r.Get("contactID") == record.Id))
            fields.Children.Add(new TextBlock { Text = activity.Get("actionType") + " · " + activity.Title + " · " + activity.Get("date"), TextWrapping = TextWrapping.Wrap });
    }
    private async void SaveClicked(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral(); IsPrimaryButtonEnabled = false;
        try
        {
            foreach (var (key, read) in values) record.Body[key] = read();
            if (record.Kind != "user_settings" && string.IsNullOrWhiteSpace(record.Title)) throw new InvalidDataException("Enter a title.");
            if (record.Kind == "crm_actions" && record.Date is null) throw new InvalidDataException("Choose an activity date.");
            foreach (var key in new[] { "phones", "mobiles", "whatsapp" })
                if (record.Kind == "crm_contacts" && record.Get(key).Split('\n').Any(number => number.Trim().Length > 0
                    && !System.Text.RegularExpressions.Regex.IsMatch(number.Trim(), @"^\+[1-9][0-9]{6,14}$")))
                    throw new InvalidDataException("Use international phone numbers with + and the country calling code, one per line.");
            if (record.Kind == "user_settings")
            {
                foreach (var zone in record.Get("clocks").Split(',').Where(s => !string.IsNullOrWhiteSpace(s))) TimeZoneInfo.FindSystemTimeZoneById(zone.Trim());
                TimeZoneInfo.FindSystemTimeZoneById(record.Get("timezone"));
                if (!double.TryParse(record.Get("latitude"), NumberStyles.Float, CultureInfo.InvariantCulture, out var latitude) || !double.IsFinite(latitude) || Math.Abs(latitude) > 90
                    || !double.TryParse(record.Get("longitude"), NumberStyles.Float, CultureInfo.InvariantCulture, out var longitude) || !double.IsFinite(longitude) || Math.Abs(longitude) > 180)
                    throw new InvalidDataException("Enter valid latitude and longitude coordinates.");
            }
            if (note is not null && noteChanged && !note.IsReadOnly)
            {
                note.Document.GetText(TextGetOptions.None, out var text); note.Document.GetText(TextGetOptions.FormatRtf, out var rich);
                record.Body["text"] = text; record.Body["rtf"] = Convert.ToBase64String(Encoding.Latin1.GetBytes(rich));
                record.Body["rtfd"] = ""; record.Body["format"] = "rtf";
                if (record.Kind == "crm_contacts") record.Body["notes"] = text;
            }
            await model.SaveAsync(record);
            if (record.Kind == "crm_actions") await SyncReminderAsync();
        }
        catch (Exception e) { args.Cancel = true; ShowError(e); }
        finally { IsPrimaryButtonEnabled = true; deferral.Complete(); }
    }
    private async Task SyncReminderAsync()
    {
        var hex = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("crm-reminder:" + record.Id)))[..32];
        var id = $"{hex[..8]}-{hex[8..12]}-{hex[12..16]}-{hex[16..20]}-{hex[20..]}";
        var reminder = model.Store!.Get(id) ?? new CompanionRecord { Id = id, Kind = "reminders" };
        reminder = reminder.Copy();
        if (record.Get("reminderDate").Length == 0) { if (model.Store.Get(id) is null) return; reminder.Deleted = true; }
        else
        {
            reminder.Deleted = false; reminder.Body["title"] = record.Title; reminder.Body["description"] = record.Get("description");
            reminder.Body["date"] = record.Get("reminderDate"); reminder.Body["recurrence"] = "Once";
            reminder.Body["contactID"] = record.Get("contactID"); reminder.Body["actionID"] = record.Id;
        }
        await model.SaveAsync(reminder);
    }
    private async Task DeleteAsync(CompanionRecord input)
    {
        var r = input.Copy();
        if (r.Kind == "crm_contacts") foreach (var child in model.Active("crm_actions").Where(x => x.Get("contactID") == r.Id).ToList()) await DeleteAsync(child);
        if (r.Kind is "crm_contacts" or "crm_actions")
        {
            foreach (var reminder in model.Active("reminders").Where(x => r.Kind == "crm_contacts" ? x.Get("contactID") == r.Id : x.Get("actionID") == r.Id).ToList()) await DeleteAsync(reminder);
            foreach (var link in model.Active("crm_attachments").Where(x => x.Get("ownerID") == r.Id).ToList()) await DeleteAsync(link);
        }
        r.Deleted = true; await model.SaveAsync(r);
    }
    private void ShowError(Exception e) { error.Message = e.Message; error.IsOpen = true; }
}
