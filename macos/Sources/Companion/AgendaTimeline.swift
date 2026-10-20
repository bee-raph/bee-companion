import AppKit
import SwiftUI

struct AgendaEntry: Identifiable {
  let id: String
  let title: String
  let start: Date
  let end: Date
  let allDay: Bool
  let color: Color
  let source: String
  let item: Item?
}
struct AgendaSpan {
  let id: String
  let start: Date
  let end: Date
}
struct AgendaPlacement: Identifiable {
  let id: String
  let start: Double
  let end: Double
  var column = 0
  var columns = 1
}
enum AgendaLayout {
  static func placements(_ spans: [AgendaSpan], day: Date, calendar: Calendar = .current)
    -> [AgendaPlacement]
  {
    let start = calendar.startOfDay(for: day)
    guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
    func minute(_ date: Date) -> Double {
      let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
      return Double(parts.hour ?? 0) * 60 + Double(parts.minute ?? 0) + Double(parts.second ?? 0)
        / 60
    }
    var clipped: [AgendaPlacement] = []
    for span in spans where span.start < end && span.end > start {
      let lower: Double = span.start <= start ? 0 : minute(span.start)
      let upper: Double = span.end >= end ? 1440 : minute(span.end)
      clipped.append(
        AgendaPlacement(id: span.id, start: lower, end: min(1440, max(lower + 15, upper))))
    }
    clipped.sort { left, right in
      if left.start != right.start { return left.start < right.start }
      if left.end != right.end { return left.end < right.end }
      return left.id < right.id
    }
    var result: [AgendaPlacement] = []
    var cluster: [AgendaPlacement] = []
    var columnEnds: [Double] = []
    var clusterEnd = -1.0
    func finish() {
      for var placement in cluster {
        placement.columns = columnEnds.count
        result.append(placement)
      }
      cluster = []
      columnEnds = []
    }
    for var placement in clipped {
      if placement.start >= clusterEnd { finish() }
      let index = columnEnds.firstIndex { $0 <= placement.start } ?? columnEnds.count
      if index == columnEnds.count {
        columnEnds.append(placement.end)
      } else {
        columnEnds[index] = placement.end
      }
      placement.column = index
      cluster.append(placement)
      clusterEnd = max(clusterEnd, placement.end)
    }
    finish()
    return result
  }
}

struct AgendaTimeline: View {
  let days: [Date]
  @Binding var selectedDay: Date
  let entries: [AgendaEntry]
  var hebrewDays: [String: HebrewDayInfo] = [:]
  @State private var detail: AgendaEntry?
  private let hourHeight: CGFloat = 68
  private let gutter: CGFloat = 58
  private var calendar: Calendar { .current }
  func belongs(_ entry: AgendaEntry, to day: Date) -> Bool {
    let start = calendar.startOfDay(for: day)
    let end = calendar.date(byAdding: .day, value: 1, to: start)!
    return entry.start < end && entry.end > start
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        Text(TimeZone.current.abbreviation() ?? "").font(.caption2).foregroundStyle(.secondary)
          .frame(width: gutter)
        ForEach(days, id: \.self) { day in
          Button {
            selectedDay = day
          } label: {
            VStack(spacing: 3) {
              Text(day.formatted(.dateTime.weekday(.abbreviated).locale(L10n.locale))).font(
                .caption
              ).foregroundStyle(.secondary)
              Text(day.formatted(.dateTime.day().month(.abbreviated).locale(L10n.locale))).font(
                .headline
              )
              .foregroundStyle(calendar.isDateInToday(day) ? Color.accentColor : Color.primary)
              if let hebrew = hebrewDays[HebrewAgendaPresentation.key(day)] {
                Text(hebrew.date).font(.caption).foregroundStyle(.secondary)
                  .lineLimit(2).multilineTextAlignment(.center)
              }
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
              .background(
                calendar.isDate(day, inSameDayAs: selectedDay)
                  ? Color.accentColor.opacity(0.07) : Color.clear)
          }.buttonStyle(.plain)
        }
      }
      Divider()
      HStack(alignment: .top, spacing: 0) {
        Text(L10n.text("All-day")).font(.caption).foregroundStyle(.secondary).frame(width: gutter)
          .padding(.top, 8)
        ForEach(days, id: \.self) { day in
          let allDay = entries.filter { $0.allDay && belongs($0, to: day) }
          let hebrewEvents = hebrewDays[HebrewAgendaPresentation.key(day)]?.events ?? []
          ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 4) {
              if allDay.isEmpty && hebrewEvents.isEmpty {
                Text("—").foregroundStyle(.tertiary).font(.caption)
              }
              ForEach(hebrewEvents, id: \.self) { event in
                Text(event).font(.caption).lineLimit(2).help(event)
                  .frame(maxWidth: .infinity, alignment: .leading).padding(5)
                  .background(BeeTheme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
              }
              ForEach(allDay) { entry in eventCard(entry, compact: true).frame(height: 28) }
            }.padding(6).frame(maxWidth: .infinity, alignment: .topLeading)
          }.frame(
            height: min(
              120,
              CGFloat(max(1, allDay.count + hebrewEvents.count)) * 32 + 12)
          )
        }
      }.frame(maxHeight: 120)
      Divider()
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
              ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour)).font(.system(size: 11)).monospacedDigit()
                  .foregroundStyle(.secondary).frame(
                    width: gutter, height: hourHeight, alignment: .top
                  )
                  .id(hour)
              }
            }
            ForEach(days, id: \.self) { day in
              GeometryReader { space in
                ZStack(alignment: .topLeading) {
                  ForEach(0..<24, id: \.self) { hour in
                    VStack(spacing: 0) {
                      Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 0.5)
                      Spacer()
                      Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.35)).frame(
                        height: 0.5)
                      Spacer()
                    }.frame(height: hourHeight).offset(y: CGFloat(hour) * hourHeight)
                  }
                  let timed = entries.filter { !$0.allDay && belongs($0, to: day) }
                  let timedByID = Dictionary(
                    timed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                  let placements = AgendaLayout.placements(
                    timed.map { AgendaSpan(id: $0.id, start: $0.start, end: $0.end) }, day: day)
                  ForEach(placements) { placement in
                    if let entry = timedByID[placement.id] {
                      let width = space.size.width / CGFloat(placement.columns)
                      eventCard(entry, compact: (placement.end - placement.start) < 35)
                        .frame(
                          width: max(1, width - 5),
                          height: max(
                            16, CGFloat(placement.end - placement.start) / 60 * hourHeight - 2),
                          alignment: .topLeading
                        )
                        .clipped()
                        .offset(
                          x: CGFloat(placement.column) * width + 2,
                          y: CGFloat(placement.start) / 60 * hourHeight)
                    }
                  }
                  if calendar.isDateInToday(day) {
                    TimelineView(.periodic(from: .now, by: 60)) { clock in
                      let parts = calendar.dateComponents([.hour, .minute], from: clock.date)
                      let y =
                        CGFloat((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / 60 * hourHeight
                      Rectangle().fill(.red).frame(height: 1).offset(y: y)
                        .allowsHitTesting(false)
                    }
                  }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                  .background(Color(nsColor: .textBackgroundColor))
                  .overlay(alignment: .leading) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5)
                  }
              }.frame(height: hourHeight * 24)
            }
          }.padding(.top, 8)
        }.task(id: days.first) {
          let hour =
            days.contains(where: { calendar.isDateInToday($0) })
            ? max(0, calendar.component(.hour, from: Date()) - 1) : 8
          proxy.scrollTo(hour, anchor: .top)
        }
      }
    }.popover(item: $detail) { entry in
      VStack(alignment: .leading, spacing: 12) {
        Text(entry.title).font(.headline)
        Text(entry.source).foregroundStyle(.secondary)
        if !entry.allDay {
          Text(
            entry.start.formatted(date: .abbreviated, time: .shortened) + " – "
              + entry.end.formatted(date: .omitted, time: .shortened))
        }
        if let item = entry.item {
          Text(item.body["description"] ?? "").textSelection(.enabled)
          if item.kind == "tasks" { TaskCompletionButton(item: item) }
        } else {
          Button(L10n.text("Open Calendar")) { NSWorkspace.shared.open(URL(string: "ical://")!) }
        }
      }.padding(18).frame(width: 290)
    }
  }
  func eventCard(_ entry: AgendaEntry, compact: Bool) -> some View {
    HStack(alignment: .top, spacing: 4) {
      Rectangle().fill(entry.color).frame(width: 3)
      if let item = entry.item, item.kind == "tasks" { TaskCompletionButton(item: item) }
      Button {
        detail = entry
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.title).font(.system(size: 12, weight: .medium)).lineLimit(compact ? 1 : 3)
            .strikethrough(entry.item?.body["status"] == "Done")
          if !compact {
            Text(entry.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 10))
              .foregroundStyle(.secondary)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
      }.buttonStyle(.plain)
    }.padding(.vertical, compact ? 2 : 5).padding(.trailing, 4)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(entry.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
  }
}
