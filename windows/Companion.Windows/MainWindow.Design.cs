using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace BeeCompanion.Windows;

public sealed partial class MainWindow
{
    private static readonly SolidColorBrush Lavender = new(ColorHelper.FromArgb(255, 100, 94, 204));
    private static readonly SolidColorBrush Mint = new(ColorHelper.FromArgb(255, 59, 156, 135));
    private static readonly SolidColorBrush Amber = new(ColorHelper.FromArgb(255, 199, 135, 56));
    private static Brush Resource(string key) => (Brush)Application.Current.Resources[key];
    private static TextBlock Muted(string value, double size = 13)
    { var text = Text(value, size); text.Foreground = Resource("TextFillColorSecondaryBrush"); return text; }
    private static string Glyph(string name) => name switch
    {
        "Today" => "\uE80F", "Tasks" or "tasks" => "\uE73A", "Notes" or "notes" => "\uE8A5",
        "Files" or "files" => "\uE8B7", "folders" => "\uE8B7", "CRM" or "crm_contacts" => "\uE716",
        "Agenda" => "\uE787", "Reminders" or "reminders" => "\uE823", "Stocks" or "watchlist_items" => "\uE9D9",
        "RSS Reader" => "\uE8A1", "Archive" => "\uE7B8", _ => "\uE8A5"
    };
    private static Border Card(UIElement child) => new()
    {
        Child = child, Padding = new Thickness(20), CornerRadius = new CornerRadius(16),
        Background = Resource("CardBackgroundFillColorDefaultBrush"), BorderBrush = Resource("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1)
    };
    private static Border IconTile(string glyph, SolidColorBrush color) => new()
    {
        Width = 38, Height = 38, CornerRadius = new CornerRadius(11), VerticalAlignment = VerticalAlignment.Top,
        Background = new SolidColorBrush(ColorHelper.FromArgb(24, color.Color.R, color.Color.G, color.Color.B)),
        Child = new FontIcon { Glyph = glyph, FontSize = 17, Foreground = color }
    };
    private static StackPanel Brand()
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Margin = new Thickness(12, 22, 0, 24) };
        panel.Children.Add(IconTile("\uE80F", Lavender));
        var labels = new StackPanel { Spacing = 2 };
        var title = Text("Bee Companion", 16); title.FontWeight = FontWeights.SemiBold;
        labels.Children.Add(title); labels.Children.Add(Muted("A little more organized.", 11)); panel.Children.Add(labels); return panel;
    }
    private static Grid Columns(int count, bool adaptive = true)
    {
        var grid = new Grid { ColumnSpacing = 16 };
        for (var i = 0; i < count; i++) grid.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        grid.SizeChanged += (_, _) =>
        {
            var compact = adaptive && grid.ActualWidth < (count == 3 ? 560 : 620);
            grid.RowSpacing = compact ? 12 : 0;
            while (grid.RowDefinitions.Count < count) grid.RowDefinitions.Add(new() { Height = GridLength.Auto });
            for (var i = 0; i < count; i++) grid.ColumnDefinitions[i].Width = compact && i > 0 ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
            foreach (FrameworkElement child in grid.Children)
            {
                var originalColumn = child.Tag is int position ? position : Grid.GetColumn(child);
                child.Tag = originalColumn; Grid.SetColumn(child, compact ? 0 : originalColumn); Grid.SetRow(child, compact ? originalColumn : 0);
            }
        };
        return grid;
    }
    private static void AddColumn(Grid grid, FrameworkElement element, int column) { Grid.SetColumn(element, column); grid.Children.Add(element); }
    private void PageHeading(string title, string subtitle, Button? action = null)
    {
        var row = Columns(2); row.Margin = new Thickness(0, 0, 0, 8);
        var labels = new StackPanel { Spacing = 8 };
        var heading = Text(title, 34); heading.FontWeight = FontWeights.SemiBold;
        labels.Children.Add(heading); labels.Children.Add(Muted(subtitle, 14)); row.Children.Add(labels);
        if (action is not null)
        {
            action.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            action.HorizontalAlignment = HorizontalAlignment.Right; action.VerticalAlignment = VerticalAlignment.Center;
            AddColumn(row, action, 1);
        }
        content.Children.Add(row);
    }
    private static Grid Section(string title, string subtitle, string glyph)
    {
        var row = new Grid { ColumnSpacing = 12 };
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(IconTile(glyph, Lavender));
        var labels = new StackPanel { Spacing = 4 }; var heading = Text(title, 16); heading.FontWeight = FontWeights.SemiBold;
        labels.Children.Add(heading); labels.Children.Add(Muted(subtitle, 12)); AddColumn(row, labels, 1); return row;
    }
    private static Border Metric(string label, string value, string glyph, SolidColorBrush color)
    {
        var row = Columns(2, false); var labels = new StackPanel { Spacing = 8 };
        labels.Children.Add(Muted(label, 12)); var number = Text(value, 32); number.FontWeight = FontWeights.SemiBold; labels.Children.Add(number);
        row.Children.Add(labels); var icon = IconTile(glyph, color); icon.HorizontalAlignment = HorizontalAlignment.Right; AddColumn(row, icon, 1); return Card(row);
    }
    private void Empty(string title, string detail, string glyph)
    {
        var stack = new StackPanel { Spacing = 16, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 330, Margin = new Thickness(24, 64, 24, 64) };
        var icon = IconTile(glyph, Lavender); icon.Width = 72; icon.Height = 72; icon.CornerRadius = new CornerRadius(23); icon.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(icon); var heading = Text(title, 21); heading.FontWeight = FontWeights.SemiBold; heading.TextAlignment = TextAlignment.Center; stack.Children.Add(heading);
        var description = Muted(detail); description.TextAlignment = TextAlignment.Center; stack.Children.Add(description); content.Children.Add(stack);
    }
    private static string Subtitle(string section) => section switch
    {
        "Tasks" => "Make space for what matters. One task at a time.", "Notes" => "Ideas, thoughts, and everything worth keeping.",
        "Files" => "Your documents, together in one place.", "CRM" => "Keep your relationships close.", "Agenda" => "A thoughtful view of the days ahead.",
        "Reminders" => "A little help remembering the important things.", "Stocks" => "Follow the companies on your radar.",
        "RSS Reader" => "A quiet place to catch up.", "Archive" => "Finished, saved, and easy to find.", "Settings" => "Make your companion feel like yours.", _ => ""
    };
}
