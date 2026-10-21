using BeeCompanion.Core;
using Xunit;

namespace BeeCompanion.Tests;

public sealed class QuoteFormattingTests
{
    [Theory]
    [InlineData("0", "0.00%")]
    [InlineData("1.23456789", "1.23%")]
    [InlineData("-2.789", "-2.79%")]
    [InlineData("1e-3", "0.00%")]
    [InlineData(null, "—")]
    [InlineData("NaN", "—")]
    public void PercentagesUseTwoDecimalPlaces(string? value, string expected) =>
        Assert.Equal(expected, QuoteFormatting.Percentage(value));
}
