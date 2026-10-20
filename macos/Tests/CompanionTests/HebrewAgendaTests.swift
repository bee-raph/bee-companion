import Foundation
import XCTest

@testable import Companion

final class HebrewAgendaTests: XCTestCase {
  let zone = TimeZone(identifier: "Asia/Jerusalem")!
  func date(_ value: String) -> Date { ItemTimestamp.date(value)! }
  func hasHebrew(_ value: String) -> Bool {
    value.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) }
  }

  func testEveryNonHebrewLanguageUsesSameLatinDateAndHolidayNames() throws {
    let day = date("2015-05-24T09:00:00Z")
    let event = HebrewResponse.Event(
      title: "Shavuot I", date: "2015-05-24", hebrew: "שבועות א׳", category: "holiday")
    let english = try XCTUnwrap(
      HebrewAgendaPresentation.build(
        days: [day], events: [event], language: .english, timeZone: zone)["2015-05-24"])
    XCTAssertTrue(english.date.contains("Sivan"))
    XCTAssertTrue(english.date.contains("5775"))
    XCTAssertEqual(english.events, ["Shavuot I"])
    for language in AppLanguage.allCases where language != .hebrew {
      let value = try XCTUnwrap(
        HebrewAgendaPresentation.build(
          days: [day], events: [event], language: language, timeZone: zone)["2015-05-24"])
      XCTAssertEqual(value, english)
      XCTAssertFalse(hasHebrew(value.summary))
    }
    let hebrew = try XCTUnwrap(
      HebrewAgendaPresentation.build(
        days: [day], events: [event], language: .hebrew, timeZone: zone)["2015-05-24"])
    XCTAssertTrue(hasHebrew(hebrew.date))
    XCTAssertEqual(hebrew.events, ["שבועות א׳"])
    XCTAssertFalse(hebrew.date.contains("Sivan"))
  }

  func testAllDaysHaveDatesOfflineAndEventsBelongOnlyToTheirDay() throws {
    let days = [
      date("2015-05-23T09:00:00Z"), date("2015-05-24T09:00:00Z"), date("2015-05-25T09:00:00Z"),
    ]
    let event = HebrewResponse.Event(
      title: "Shavuot I", date: "2015-05-24", hebrew: "שבועות א׳", category: "holiday")
    let offline = HebrewAgendaPresentation.build(
      days: days, events: [], language: .english, timeZone: zone)
    XCTAssertEqual(offline.count, 3)
    XCTAssertTrue(offline.values.allSatisfy { !$0.date.isEmpty && $0.events.isEmpty })
    let loaded = HebrewAgendaPresentation.build(
      days: days, events: [event, event], language: .english, timeZone: zone)
    XCTAssertEqual(loaded["2015-05-24"]?.events, ["Shavuot I"])
    XCTAssertEqual(loaded["2015-05-23"]?.events, [])
    XCTAssertEqual(loaded["2015-05-25"]?.events, [])
  }

  func testTimedEventsUseOriginalTitleAndOneLocalTime() throws {
    let payload = Data(
      #"{"items":[{"title":"Candle lighting: 5:11pm","title_orig":"Candle lighting","date":"2015-05-22T17:11:00+03:00","category":"candles","hebrew":"הדלקת נרות"}]}"#
        .utf8)
    let response = try JSONDecoder().decode(HebrewResponse.self, from: payload)
    let day = date("2015-05-22T09:00:00Z")
    let latin = HebrewAgendaPresentation.build(
      days: [day], events: response.items, language: .russian, timeZone: zone)
    XCTAssertEqual(latin["2015-05-22"]?.events, ["Candle lighting · 17:11"])
    let hebrew = HebrewAgendaPresentation.build(
      days: [day], events: response.items, language: .hebrew, timeZone: zone)
    XCTAssertEqual(hebrew["2015-05-22"]?.events, ["הדלקת נרות · 17:11"])
  }

  func testMonthGridIncludesAdjacentYearsAndCacheIdentityTracksSettings() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    calendar.firstWeekday = 1
    let days = AgendaCalendarDays.grid(
      date: date("2027-01-10T09:00:00Z"), range: "Month", calendar: calendar)
    XCTAssertEqual(days.count, 42)
    XCTAssertEqual(HebrewAgendaPresentation.years(days, timeZone: zone), [2026, 2027])
    XCTAssertEqual(Set(days.map { HebrewAgendaPresentation.key($0, timeZone: zone) }).count, 42)
    let settings = ["israel": "true", "timezone": "Asia/Jerusalem"]
    let base = HebrewAgendaData.requestKey(
      days: days, settings: settings, instance: "one", language: .english)
    XCTAssertNotEqual(
      base,
      HebrewAgendaData.requestKey(
        days: days, settings: settings, instance: "two", language: .english))
    XCTAssertNotEqual(
      base,
      HebrewAgendaData.requestKey(
        days: days, settings: ["israel": "false"], instance: "one", language: .english))
    XCTAssertNotEqual(
      base,
      HebrewAgendaData.requestKey(
        days: days, settings: settings, instance: "one", language: .hebrew))
  }
}
