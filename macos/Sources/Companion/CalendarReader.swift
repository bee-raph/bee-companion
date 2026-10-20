import AppKit
import EventKit
import Foundation

struct CalendarDescriptor: Sendable {
  let calendarIdentifier: String
  let title: String
  let sourceTitle: String
  private let red: Double
  private let green: Double
  private let blue: Double
  private let alpha: Double
  var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
  init(_ calendar: EKCalendar) {
    calendarIdentifier = calendar.calendarIdentifier
    title = calendar.title
    sourceTitle = calendar.source.title
    let rgb =
      calendar.color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.2, green: 0.5, blue: 1, alpha: 1)
    red = rgb.redComponent
    green = rgb.greenComponent
    blue = rgb.blueComponent
    alpha = rgb.alphaComponent
  }
}

struct CalendarEvent: Sendable {
  let eventIdentifier: String?
  let title: String?
  let startDate: Date
  let endDate: Date
  let isAllDay: Bool
  let calendar: CalendarDescriptor
}

struct CalendarSnapshot: Sendable {
  let calendars: [CalendarDescriptor]
  let events: [CalendarEvent]
}

/// EventKit objects stay on this actor; views receive immutable value snapshots.
actor CalendarReader {
  private var store: EKEventStore?
  func snapshot(date: Date, days: Int, selected: [String]?) -> CalendarSnapshot {
    if store == nil { store = EKEventStore() }
    let store = store!
    store.reset()
    let calendars = store.calendars(for: .event).sorted {
      $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
    let selectedIDs = CalendarSelection.resolve(
      available: calendars.map(\.calendarIdentifier), stored: selected)
    let descriptors = calendars.map(CalendarDescriptor.init)
    let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.calendarIdentifier, $0) })
    let chosen = calendars.filter { selectedIDs.contains($0.calendarIdentifier) }
    guard !Task.isCancelled, !chosen.isEmpty else {
      return CalendarSnapshot(calendars: descriptors, events: [])
    }
    let start = Calendar.current.startOfDay(for: date)
    let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
    let events = store.events(
      matching: store.predicateForEvents(withStart: start, end: end, calendars: chosen)
    )
    .sorted { $0.startDate < $1.startDate }.compactMap { event -> CalendarEvent? in
      guard let calendar = byID[event.calendar.calendarIdentifier] else { return nil }
      return CalendarEvent(
        eventIdentifier: event.eventIdentifier, title: event.title,
        startDate: event.startDate, endDate: event.endDate, isAllDay: event.isAllDay,
        calendar: calendar)
    }
    return CalendarSnapshot(calendars: descriptors, events: events)
  }
}
