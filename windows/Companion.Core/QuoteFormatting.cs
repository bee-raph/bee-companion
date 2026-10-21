using System.Globalization;

namespace BeeCompanion.Core;

public static class QuoteFormatting
{
    public static string Percentage(string? value) =>
        decimal.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)
            ? number.ToString("0.00", CultureInfo.InvariantCulture) + "%" : "—";
}
