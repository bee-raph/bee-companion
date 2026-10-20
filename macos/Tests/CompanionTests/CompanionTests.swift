import AppKit
import EventKit
import XCTest

@testable import Companion

final class CompanionTests: XCTestCase {
  func store() throws -> LocalStore {
    try LocalStore(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"))
  }
  func testAtomicOfflineAndSearch() throws {
    let local = try store()
    let item = Item(kind: "notes", body: ["title": "שלום", "text": "alpha beta"])
    try local.save(item)
    XCTAssertEqual(try local.all(), [item])
    XCTAssertEqual(try local.pending().count, 1)
    XCTAssertTrue(try local.search("alpha").contains(item.id))
    XCTAssertTrue(try local.search("שלום").contains(item.id))
    XCTAssertTrue(try local.search("alpha beta").contains(item.id))
  }
  func testPreserveEditDuringSyncAndRebase() throws {
    let local = try store()
    var item = Item(kind: "notes", body: ["title": "First"])
    try local.save(item)
    let operation = try XCTUnwrap(local.nextMutation())
    item.body["title"] = "Later"
    try local.save(item)
    var server = item
    server.body["title"] = "First"
    server.revision = 1
    try local.accept(.init(operationID: operation.operationID, status: "applied", record: server))
    XCTAssertEqual(try local.all()[0].title, "Later")
    XCTAssertEqual(try local.pending()[0].expectedRevision, 1)
    try local.apply(.init(changes: [server], cursor: 1, hasMore: false))
    XCTAssertEqual(try local.all()[0].title, "Later")
  }
  func testConflictsSurvivePull() throws {
    let local = try store()
    let item = Item(kind: "notes", body: ["title": "Mine"])
    try local.save(item)
    let operation = try XCTUnwrap(local.nextMutation())
    var server = item
    server.body["title"] = "Theirs"
    server.revision = 2
    try local.accept(.init(operationID: operation.operationID, status: "conflict", server: server))
    try local.apply(.init(changes: [server], cursor: 2, hasMore: false))
    XCTAssertEqual(try local.all()[0].title, "Mine")
    XCTAssertEqual(try local.conflicts().count, 1)
    try local.resolve(local.conflicts()[0], keepLocal: true)
    XCTAssertEqual(try local.pending()[0].expectedRevision, 2)
  }
  func testRejectRemoteHTTP() throws {
    let config = InstanceConfiguration(
      configurationVersion: 1, instanceName: "Test", instanceID: UUID().uuidString,
      apiBaseURL: URL(string: "http://example.com")!, apiVersion: 1)
    XCTAssertThrowsError(try config.validate())
  }
  func testMonthlySkipsMissingDays() {
    let formatter = ISO8601DateFormatter()
    let item = Item(
      kind: "reminders",
      body: ["date": "2026-01-31T10:00:00Z", "timezone": "UTC", "recurrence": "Monthly"])
    let dates = Recurrence.occurrences(
      item, after: formatter.date(from: "2026-01-30T00:00:00Z")!,
      until: formatter.date(from: "2026-04-01T00:00:00Z")!)
    XCTAssertEqual(
      dates.map { formatter.string(from: $0) }, ["2026-01-31T10:00:00Z", "2026-03-31T10:00:00Z"])
  }
  func testDraftCoalescingAndStaleEditorRevision() throws {
    let local = try store()
    var item = Item(kind: "notes", body: ["title": "First"])
    try local.save(item)
    item.body["title"] = "Second"
    try local.save(item)
    XCTAssertEqual(try local.pending().count, 1)
    let operation = try XCTUnwrap(local.nextMutation())
    var server = item
    server.revision = 1
    try local.accept(.init(operationID: operation.operationID, status: "applied", record: server))
    item.body["title"] = "Third"
    try local.save(item)
    XCTAssertEqual(try local.pending()[0].expectedRevision, 1)
  }
  func testDailyWallClockAcrossDST() {
    let formatter = ISO8601DateFormatter()
    let item = Item(
      kind: "reminders",
      body: ["date": "2026-03-07T14:00:00Z", "timezone": "America/New_York", "recurrence": "Daily"])
    let dates = Recurrence.occurrences(
      item, after: formatter.date(from: "2026-03-07T00:00:00Z")!,
      until: formatter.date(from: "2026-03-09T23:00:00Z")!)
    XCTAssertEqual(
      dates.map { formatter.string(from: $0) },
      ["2026-03-07T14:00:00Z", "2026-03-08T13:00:00Z", "2026-03-09T13:00:00Z"])
  }

  @MainActor func testAlarmWindowRepeatedCloseDoesNotOverRelease() async {
    _ = NSApplication.shared
    for _ in 0..<25 {
      autoreleasepool {
        let window = AlarmWindow.make(title: "Lifecycle regression")
        XCTAssertFalse(window.isReleasedWhenClosed)
        window.close()
        // Swift still owns the closed window until this scope ends.
        XCTAssertEqual(window.title, "Reminder · Lifecycle regression")
      }
    }
  }
  func testCalendarSelectionPreservesExplicitEmptyAndIgnoresOldIDs() {
    XCTAssertEqual(
      CalendarSelection.resolve(available: ["work", "home"], stored: nil), Set(["work", "home"]))
    XCTAssertEqual(CalendarSelection.resolve(available: ["work", "home"], stored: []), [])
    XCTAssertEqual(
      CalendarSelection.resolve(available: ["work", "home"], stored: ["work", "removed"]), ["work"])
  }
  @MainActor func testCalendarPermissionFailureShowsActionableState() async {
    let denied = AgendaService(authorization: { .denied })
    denied.refresh(Date())
    XCTAssertTrue(denied.calendars.isEmpty)
    XCTAssertTrue(denied.events.isEmpty)
    XCTAssertTrue(denied.message.contains("System Settings"))
    let undecided = AgendaService(authorization: { .notDetermined })
    undecided.refresh(Date())
    XCTAssertTrue(undecided.message.contains("Enable Apple Calendar"))
  }
  func testNextZmanUsesChronologyAndAbsoluteTime() {
    let entries = ZmanimEntry.sorted([
      "sunset": "2026-10-20T18:00:00+03:00",
      "dawn": "2026-10-20T05:00:00+03:00",
      "midday": "2026-10-20T12:00:00+03:00",
      "invalid": "unavailable",
    ])
    XCTAssertEqual(entries.map(\.id), ["dawn", "midday", "sunset"])
    let clock = ISO8601DateFormatter()
    XCTAssertEqual(
      ZmanimEntry.next(in: entries, now: clock.date(from: "2026-10-20T08:00:00Z")!), "midday")
    XCTAssertEqual(
      ZmanimEntry.next(in: entries, now: clock.date(from: "2026-10-20T15:00:00Z")!), "sunset")
    XCTAssertNil(ZmanimEntry.next(in: entries, now: clock.date(from: "2026-10-20T16:00:00Z")!))
  }
  func testStockSearchIDsDistinguishProviderDatasets() throws {
    let json =
      #"{"instruments":[{"symbol":"AAPL","name":"Apple","category":"Stocks","dataset":"stocks"},{"symbol":"AAPL","name":"Apple options","category":"Options","dataset":"options"}]}"#
    let response = try JSONDecoder().decode(SearchResponse.self, from: Data(json.utf8))
    XCTAssertEqual(response.instruments.count, 2)
    XCTAssertEqual(Set(response.instruments.map(\.id)).count, 2)
    XCTAssertEqual(response.instruments[0].id, "stocks:AAPL")
    XCTAssertEqual(response.instruments[1].id, "options:AAPL")
  }
  func testReaderSettingsValidateAndRoundTripOffline() throws {
    let feeds = (0..<3).map {
      FeedConfiguration(id: "feed-\($0)", title: "Feed \($0)", url: "https://example.com/\($0).xml")
    }
    try ReaderPreferences.validate(feeds)
    XCTAssertThrowsError(
      try ReaderPreferences.validate(feeds + [FeedConfiguration(url: "https://example.com/extra")]))
    XCTAssertThrowsError(
      try ReaderPreferences.validate([FeedConfiguration(url: "file:///etc/passwd")]))
    XCTAssertThrowsError(
      try ReaderPreferences.validate([
        FeedConfiguration(url: "https://user:password@example.com/feed")
      ]))
    let local = try store()
    let item = Item(
      id: "00000000-0000-0000-0000-000000000001", kind: "user_settings",
      body: [
        "rssFeeds": String(decoding: try JSONEncoder().encode(feeds), as: UTF8.self),
        "shabbatRefreshSeconds": "120", "shabbatStocks": "[\"stock-id\"]",
      ])
    try local.save(item)
    XCTAssertEqual(try local.pending()[0].body, item.body)
    let restored = try JSONDecoder().decode(
      [FeedConfiguration].self, from: Data(local.all()[0].body["rssFeeds"]!.utf8))
    XCTAssertEqual(restored, feeds)
    XCTAssertEqual(ReaderPreferences.refreshSeconds(item.body), 120)
    XCTAssertEqual(ReaderPreferences.selectedStocks(item.body), ["stock-id"])
    XCTAssertEqual(ReaderPreferences.refreshSeconds(["shabbatRefreshSeconds": "0"]), 60)
  }
}

final class LocalizationTests: XCTestCase {
  func testLanguagesAndCatalog() throws {
    XCTAssertEqual(AppLanguage.resolve(nil), .english)
    XCTAssertEqual(AppLanguage.resolve("unknown"), .english)
    XCTAssertEqual(AppLanguage.hebrew.direction, .rightToLeft)
    let english = try XCTUnwrap(L10n.catalog["en"])
    XCTAssertGreaterThan(english.count, 250)
    let format = try NSRegularExpression(pattern: "%[-+0-9.]*[@df]|%%")
    func placeholders(_ value: String) -> [String] {
      format.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
        String(value[Range($0.range, in: value)!])
      }
    }
    for language in AppLanguage.allCases {
      let translated = try XCTUnwrap(L10n.catalog[language.rawValue])
      XCTAssertEqual(Set(english.keys), Set(translated.keys))
      for (key, value) in translated {
        XCTAssertFalse(value.isEmpty, key)
        XCTAssertEqual(placeholders(key), placeholders(value), "\(language.rawValue): \(key)")
      }
    }
    XCTAssertEqual(L10n.text("Settings", language: .french), "Réglages")
  }
  func testLanguageSurvivesOfflineStoreAndIncomingSync() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".sqlite")
    let local = try LocalStore(url: url)
    let item = Item(
      id: "00000000-0000-0000-0000-000000000001", kind: "user_settings", body: ["language": "he"])
    try local.save(item)
    XCTAssertEqual(try local.pending().first?.body["language"], "he")
    let reopened = try LocalStore(url: url)
    XCTAssertEqual(try reopened.all().first?.body["language"], "he")
    let operation = try XCTUnwrap(local.nextMutation())
    var server = item
    server.revision = 1
    try local.accept(.init(operationID: operation.operationID, status: "applied", record: server))
    server.body["language"] = "fr"
    server.revision = 2
    try local.apply(.init(changes: [server], cursor: 2, hasMore: false))
    XCTAssertEqual(try local.all().first?.body["language"], "fr")
    XCTAssertEqual(try local.pending().count, 0)
  }
}

final class LocationTests: XCTestCase {
  func testSharedLocationQueryValidationAndCacheIsolation() throws {
    let location = CompanionLocation([
      "latitude": " 31.78 ", "longitude": "35.23", "timezone": "Asia/Jerusalem",
    ])
    let query = try XCTUnwrap(location.query)
    XCTAssertTrue(query.contains("latitude=31.78"))
    XCTAssertTrue(query.contains("longitude=35.23"))
    XCTAssertEqual(
      location.cacheKey("instance"), CompanionLocation(location.body).cacheKey("instance"))
    XCTAssertNotEqual(location.cacheKey("instance"), location.cacheKey("other"))
    XCTAssertNotEqual(
      location.identity, CompanionLocation(["latitude": "0", "longitude": "0"]).identity)
    XCTAssertNil(CompanionLocation(["latitude": "NaN", "longitude": "0"]).query)
    XCTAssertNil(CompanionLocation(["latitude": "91", "longitude": "0"]).query)
  }
  func testProviderDateIsGregorianInSelectedZone() {
    let instant = ISO8601DateFormatter().date(from: "2026-10-20T22:30:00Z")!
    XCTAssertEqual(CompanionLocation(["timezone": "Asia/Jerusalem"]).day(instant), "2026-10-21")
    XCTAssertEqual(CompanionLocation(["timezone": "America/New_York"]).day(instant), "2026-10-20")
  }
}
