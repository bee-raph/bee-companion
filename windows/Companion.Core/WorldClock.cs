using System.Globalization;

namespace BeeCompanion.Core;

public sealed record ClockReading(string Name, string Time, string Date, string Offset);
public static class WorldClock
{
    public static ClockReading Read(string ianaZone, DateTimeOffset instant, CultureInfo? culture = null)
    {
        var name = ianaZone.Trim();
        var zone = TimeZoneInfo.FindSystemTimeZoneById(name);
        var local = TimeZoneInfo.ConvertTime(instant, zone);
        var offset = local.Offset;
        return new(name.Split('/').Last().Replace('_', ' '), local.ToString("HH:mm", culture),
            local.ToString("ddd, d MMM", culture), $"UTC{(offset < TimeSpan.Zero ? "−" : "+")}{offset.Duration():hh\\:mm}");
    }
}
