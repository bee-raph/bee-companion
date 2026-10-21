using BeeCompanion.Core;
using System.Globalization;
using Xunit;

namespace BeeCompanion.Tests;
public sealed class ClockTests
{
    [Theory]
    [InlineData("Asia/Jerusalem", "2026-03-26T23:59Z", "01:59", "UTC+02:00")]
    [InlineData("Asia/Jerusalem", "2026-03-27T00:00Z", "03:00", "UTC+03:00")]
    [InlineData("Asia/Jerusalem", "2026-10-24T22:59Z", "01:59", "UTC+03:00")]
    [InlineData("Asia/Jerusalem", "2026-10-24T23:00Z", "01:00", "UTC+02:00")]
    [InlineData("Europe/London", "2026-03-29T00:59Z", "00:59", "UTC+00:00")]
    [InlineData("Europe/London", "2026-03-29T01:00Z", "02:00", "UTC+01:00")]
    [InlineData("Europe/London", "2026-10-25T00:59Z", "01:59", "UTC+01:00")]
    [InlineData("Europe/London", "2026-10-25T01:00Z", "01:00", "UTC+00:00")]
    [InlineData("America/New_York", "2026-03-08T06:59Z", "01:59", "UTC−05:00")]
    [InlineData("America/New_York", "2026-03-08T07:00Z", "03:00", "UTC−04:00")]
    [InlineData("America/New_York", "2026-11-01T05:59Z", "01:59", "UTC−04:00")]
    [InlineData("America/New_York", "2026-11-01T06:00Z", "01:00", "UTC−05:00")]
    public void EachZoneUsesItsOwnDstRules(string zone, string instant, string time, string offset)
    {
        var reading = WorldClock.Read(zone, DateTimeOffset.Parse(instant), CultureInfo.InvariantCulture);
        Assert.Equal(time, reading.Time); Assert.Equal(offset, reading.Offset);
    }
    [Fact] public void DifferentTransitionDatesAndLocalDatesAreIndependent()
    {
        var instant = DateTimeOffset.Parse("2026-03-15T12:00Z");
        Assert.Equal("UTC−04:00", WorldClock.Read("America/New_York", instant).Offset);
        Assert.Equal("UTC+00:00", WorldClock.Read("Europe/London", instant).Offset);
        Assert.Equal("UTC+02:00", WorldClock.Read("Asia/Jerusalem", instant).Offset);
        instant = DateTimeOffset.Parse("2026-07-01T00:30Z");
        Assert.Contains("30 Jun", WorldClock.Read("America/New_York", instant, CultureInfo.InvariantCulture).Date);
        Assert.Contains("1 Jul", WorldClock.Read("Asia/Jerusalem", instant, CultureInfo.InvariantCulture).Date);
    }
}
