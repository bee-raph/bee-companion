import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
  case english = "en"
  case hebrew = "he"
  case french = "fr"
  case russian = "ru"
  case spanish = "es"
  var id: String { rawValue }
  var name: String {
    switch self {
    case .english: return "English"
    case .hebrew: return "עברית"
    case .french: return "Français"
    case .russian: return "Русский"
    case .spanish: return "Español"
    }
  }
  var locale: Locale { Locale(identifier: rawValue) }
  var direction: LayoutDirection { self == .hebrew ? .rightToLeft : .leftToRight }
  static func resolve(_ code: String?) -> AppLanguage {
    AppLanguage(rawValue: code ?? "en") ?? .english
  }
}

enum L10n {
  private static let lock = NSLock()
  private static var selected: AppLanguage = .english
  static var language: AppLanguage {
    get {
      lock.lock()
      defer { lock.unlock() }
      return selected
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      selected = newValue
    }
  }
  static var locale: Locale { language.locale }
  static let catalog: [String: [String: String]] = {
    let url =
      Bundle.main.url(forResource: "Translations", withExtension: "json")
      ?? Bundle.module.url(forResource: "Translations", withExtension: "json")
    guard let url, let data = try? Data(contentsOf: url),
      let values = try? JSONDecoder().decode([String: [String: String]].self, from: data)
    else { return [:] }
    return values
  }()
  static func text(_ key: String, language: AppLanguage? = nil) -> String {
    catalog[(language ?? self.language).rawValue]?[key] ?? key
  }
  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), locale: locale, arguments: arguments)
  }
  static func message(_ value: String) -> String {
    if catalog["en"]?[value] != nil { return text(value) }
    for prefix in [
      "Up to date · ", "Offline / sync paused: ", "Weather: ", "Stocks: ", "RSS: ", "Sign in to ",
    ] {
      if value.hasPrefix(prefix) {
        return text(prefix) + message(String(value.dropFirst(prefix.count)))
      }
    }
    return value
  }
}

extension AppModel {
  var language: AppLanguage { AppLanguage.resolve(preferences.body["language"]) }
  func setLanguage(_ language: AppLanguage) {
    var settings = preferences
    settings.body["language"] = language.rawValue
    save(settings)
    Task { await sync() }
  }
}

extension Date {
  func localizedFormatted(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle)
    -> String
  {
    formatted(Date.FormatStyle(date: date, time: time).locale(L10n.locale))
  }
}
