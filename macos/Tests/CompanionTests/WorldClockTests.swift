import Foundation
import XCTest

@testable import Companion

final class WorldClockTests: XCTestCase {
  func testTodayClocksUseEachZonesSpringAndAutumnTransitions() throws {
    let view = WorldClocksView()
    let cases: [(String, String, String, String)] = [
      ("Asia/Jerusalem", "2026-03-26T23:59:00Z", "01:59", "UTC+02:00"),
      ("Asia/Jerusalem", "2026-03-27T00:00:00Z", "03:00", "UTC+03:00"),
      ("Asia/Jerusalem", "2026-10-24T22:59:00Z", "01:59", "UTC+03:00"),
      ("Asia/Jerusalem", "2026-10-24T23:00:00Z", "01:00", "UTC+02:00"),
      ("Europe/London", "2026-03-29T00:59:00Z", "00:59", "UTC+00:00"),
      ("Europe/London", "2026-03-29T01:00:00Z", "02:00", "UTC+01:00"),
      ("Europe/London", "2026-10-25T00:59:00Z", "01:59", "UTC+01:00"),
      ("Europe/London", "2026-10-25T01:00:00Z", "01:00", "UTC+00:00"),
      ("America/New_York", "2026-03-08T06:59:00Z", "01:59", "UTC−05:00"),
      ("America/New_York", "2026-03-08T07:00:00Z", "03:00", "UTC−04:00"),
      ("America/New_York", "2026-11-01T05:59:00Z", "01:59", "UTC−04:00"),
      ("America/New_York", "2026-11-01T06:00:00Z", "01:00", "UTC−05:00"),
    ]
    for (name, instant, time, offset) in cases {
      let zone = try XCTUnwrap(TimeZone(identifier: name))
      let date = try XCTUnwrap(ItemTimestamp.date(instant))
      XCTAssertEqual(view.formatted(date, zone), time, "\(name) at \(instant)")
      XCTAssertEqual(view.offset(date, zone), offset, "\(name) at \(instant)")
    }
  }
}
