import XCTest

@testable import Companion

final class LocalizationCompletenessTests: XCTestCase {
  func testEveryLanguageResolvesAllCatalogEntries() throws {
    let english = try XCTUnwrap(L10n.catalog["en"])
    XCTAssertGreaterThan(english.count, 400)
    for language in AppLanguage.allCases {
      let catalog = try XCTUnwrap(L10n.catalog[language.rawValue])
      XCTAssertEqual(Set(catalog.keys), Set(english.keys))
      for (key, value) in catalog {
        XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(L10n.text(key, language: language), value)
      }
    }
  }

  func testDynamicLabelsMessagesAndFallbacksRespectLanguage() {
    let original = L10n.language
    defer { L10n.language = original }
    for language in AppLanguage.allCases {
      L10n.language = language
      XCTAssertEqual(Item(kind: "notes").title, L10n.text("Untitled", language: language))
      XCTAssertEqual(
        L10n.message("Invalid credentials"), L10n.text("Invalid credentials", language: language))
      XCTAssertEqual(
        L10n.message("RSS: Feed download timed out"),
        L10n.text("RSS: ", language: language)
          + L10n.text("Feed download timed out", language: language))
      XCTAssertEqual(
        L10n.format("%@ copy", "Example")
          .replacingOccurrences(of: "\u{2068}", with: "")
          .replacingOccurrences(of: "\u{2069}", with: ""),
        L10n.text("%@ copy", language: language).replacingOccurrences(of: "%@", with: "Example"))
      XCTAssertEqual(L10n.message("User-written text"), "User-written text")
      XCTAssertEqual(language.direction == .rightToLeft, language == .hebrew)
    }
  }
  func testDatesUseTheSelectedInterfaceLanguage() {
    let original = L10n.language
    defer { L10n.language = original }
    let date = Date(timeIntervalSince1970: 946_728_000)
    let months: [AppLanguage: String] = [
      .english: "January", .hebrew: "ינואר", .french: "janvier", .russian: "января",
      .spanish: "enero",
    ]
    for (language, month) in months {
      L10n.language = language
      XCTAssertTrue(date.localizedFormatted(date: .complete, time: .omitted).contains(month))
    }
  }

}
