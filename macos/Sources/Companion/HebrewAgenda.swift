import Foundation
import SwiftUI

struct HebrewDayInfo: Sendable, Equatable {
  let date: String
  let events: [String]
  var summary: String { ([date] + events).joined(separator: "\n") }
}

enum AgendaCalendarDays {
  static func grid(date: Date, range: String, calendar: Calendar = .current) -> [Date] {
    let interval = calendar.dateInterval(of: range == "Month" ? .month : .weekOfYear, for: date)!
    let first =
      range == "Month"
      ? calendar.dateInterval(of: .weekOfYear, for: interval.start)!.start : interval.start
    return (0..<(range == "Month" ? 42 : 7)).compactMap {
      calendar.date(byAdding: .day, value: $0, to: first)
    }
  }
}

enum HebrewAgendaPresentation {
  static func key(_ date: Date, timeZone: TimeZone = .current) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }

  static func years(_ dates: [Date], timeZone: TimeZone = .current) -> [Int] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return Set(dates.map { calendar.component(.year, from: $0) }).sorted()
  }

  static func title(_ event: HebrewResponse.Event, language: AppLanguage) -> String {
    if language == .hebrew {
      return event.hebrew.flatMap { $0.isEmpty ? nil : $0 }
        ?? L10n.text("Hebrew calendar", language: .hebrew)
    }
    let title = event.date.contains("T") ? (event.originalTitle ?? event.title) : event.title
    return title.applyingTransform(.toLatin, reverse: false)?
      .applyingTransform(.stripDiacritics, reverse: false) ?? title
  }

  static func build(
    days: [Date], events: [HebrewResponse.Event], language: AppLanguage,
    timeZone: TimeZone = .current
  ) -> [String: HebrewDayInfo] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: language == .hebrew ? "he_IL" : "en_US")
    formatter.calendar = Calendar(identifier: .hebrew)
    formatter.timeZone = timeZone
    formatter.dateFormat = "d MMMM y"
    let clock = DateFormatter()
    clock.locale = language.locale
    clock.timeZone = timeZone
    clock.dateFormat = "HH:mm"
    let grouped = Dictionary(grouping: events, by: { String($0.date.prefix(10)) })
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var result: [String: HebrewDayInfo] = [:]
    for day in days {
      let dayKey = key(day, timeZone: timeZone)
      let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
      var seen = Set<String>()
      let labels = (grouped[dayKey] ?? []).compactMap { event -> String? in
        var label = title(event, language: language)
        if event.date.contains("T"), let date = ItemTimestamp.date(event.date) {
          label += " · " + clock.string(from: date)
        }
        return seen.insert(label).inserted ? label : nil
      }
      result[dayKey] = HebrewDayInfo(date: formatter.string(from: noon), events: labels)
    }
    return result
  }
}

private struct CachedHebrewYear: Codable, Sendable {
  let response: HebrewResponse
  let fetchedAt: Date
}
private struct HebrewYearResult: Sendable {
  let items: [HebrewResponse.Event]
  let unavailable: Bool
}

@MainActor final class HebrewAgendaData: ObservableObject {
  @Published private(set) var days: [String: HebrewDayInfo] = [:]
  @Published private(set) var message: String?
  private var generation = 0

  nonisolated static func requestKey(
    days: [Date], settings: [String: String], instance: String,
    language: AppLanguage
  ) -> String {
    [
      instance, TimeZone.current.identifier, CompanionLocation(settings).identity,
      settings["israel"] ?? "true",
      language.rawValue,
      days.map { HebrewAgendaPresentation.key($0) }.joined(separator: ","),
    ].joined(separator: "|")
  }

  func load(dates: [Date], model: AppModel) async {
    generation += 1
    let request = generation
    let language = model.language
    let settings = model.preferences.body
    let location = CompanionLocation(settings)
    let israel = settings["israel"] != "false"
    let api = model.api
    let root = model.cache
    let timeZone = TimeZone.current
    let years = HebrewAgendaPresentation.years(dates, timeZone: timeZone)
    message = nil
    let initial = try? await BackgroundWork.run {
      HebrewAgendaPresentation.build(
        days: dates, events: [], language: language, timeZone: timeZone)
    }
    guard request == generation, !Task.isCancelled else { return }
    days = initial ?? [:]
    let requests = years.map { year -> (Int, URL, String) in
      let url = root.appendingPathComponent(
        "hebrew-agenda-\(year)-\(israel)-\(location.identity).json")
      var path = "calendar/hebrew?year=\(year)&israel=\(israel)"
      if let query = location.query { path += "&" + query }
      return (year, url, path)
    }
    let cached = await withTaskGroup(
      of: (Int, CachedHebrewYear?).self, returning: [Int: CachedHebrewYear].self
    ) { group in
      for (year, url, _) in requests {
        group.addTask { (year, await ReaderCache.read(CachedHebrewYear.self, from: url)) }
      }
      var restored: [Int: CachedHebrewYear] = [:]
      for await (year, value) in group { restored[year] = value }
      return restored
    }
    guard request == generation, !Task.isCancelled else { return }
    var byYear = cached.mapValues { $0.response.items }
    let saved = byYear.values.flatMap { $0 }
    let cachedDays = try? await BackgroundWork.run {
      HebrewAgendaPresentation.build(
        days: dates, events: saved, language: language, timeZone: timeZone)
    }
    guard request == generation, !Task.isCancelled else { return }
    days = cachedDays ?? days
    await withTaskGroup(of: (Int, HebrewYearResult).self) { group in
      for (year, url, path) in requests {
        let previous = cached[year]
        if let previous, Date().timeIntervalSince(previous.fetchedAt) < 86400 { continue }
        group.addTask { (year, await Self.year(url: url, path: path, api: api, cached: previous)) }
      }
      for await (year, result) in group {
        guard request == generation, !Task.isCancelled else {
          group.cancelAll()
          return
        }
        byYear[year] = result.items
        if result.unavailable {
          message =
            api == nil
            ? "Connect your backend to load Hebrew calendar events."
            : "Hebrew calendar details unavailable; showing saved information."
        }
        let snapshot = byYear.values.flatMap { $0 }
        let rendered = try? await BackgroundWork.run {
          HebrewAgendaPresentation.build(
            days: dates, events: snapshot, language: language, timeZone: timeZone)
        }
        guard request == generation, !Task.isCancelled else {
          group.cancelAll()
          return
        }
        days = rendered ?? days
      }
    }
  }

  private nonisolated static func year(url: URL, path: String, api: API?, cached: CachedHebrewYear?)
    async -> HebrewYearResult
  {
    guard let api, !Task.isCancelled else {
      return HebrewYearResult(items: cached?.response.items ?? [], unavailable: true)
    }
    do {
      let response: HebrewResponse = try await api.request(path)
      try? await ReaderCache.write(CachedHebrewYear(response: response, fetchedAt: Date()), to: url)
      return HebrewYearResult(items: response.items, unavailable: false)
    } catch {
      return HebrewYearResult(items: cached?.response.items ?? [], unavailable: true)
    }
  }
}
