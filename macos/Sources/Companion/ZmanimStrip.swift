import SwiftUI

struct ZmanimEntry: Identifiable, Equatable {
  let id: String
  let date: Date
  var title: String {
    let spaced = id.replacingOccurrences(
      of: "([a-z])([A-Z0-9])", with: "$1 $2", options: .regularExpression)
    let labels = [
      "alotHaShachar": "Dawn", "sunrise": "Sunrise", "sunset": "Sunset",
      "tzeit7083deg": "Nightfall", "chatzot": "Solar noon", "candleLighting": "Candle lighting",
      "havdalah": "Havdalah",
    ]
    return L10n.text(labels[id] ?? (spaced.prefix(1).uppercased() + spaced.dropFirst()))
  }
  static func sorted(_ times: [String: String]) -> [ZmanimEntry] {
    return times.compactMap { key, value in
      ItemTimestamp.date(value).map {
        ZmanimEntry(id: key, date: $0)
      }
    }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
  }
  static func next(in entries: [ZmanimEntry], now: Date) -> String? {
    entries.first { $0.date >= now }?.id
  }
}

struct ZmanimStrip: View {
  var times: [String: String]
  var followNext: Bool
  var timeZoneID: String
  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { clock in
      let entries = ZmanimEntry.sorted(times)
      let nextID = ZmanimEntry.next(in: entries, now: clock.date)
      ScrollViewReader { strip in
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(entries) { entry in
              VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                  Text(entry.title).font(.system(size: 11, weight: .medium))
                  if entry.id == nextID {
                    Text(L10n.text("Next")).font(.system(size: 9, weight: .semibold))
                      .foregroundStyle(
                        BeeTheme.accent)
                  }
                }
                Text(display(entry.date)).font(.system(size: 17, weight: .medium, design: .rounded))
                  .monospacedDigit()
              }
              .padding(.horizontal, 12).padding(.vertical, 10)
              .background(
                entry.id == nextID ? BeeTheme.accent.opacity(0.10) : Color.secondary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10)
              )
              .id(entry.id)
            }
          }.padding(.vertical, 2)
        }
        .task(id: followNext ? nextID : nil) {
          guard followNext, let nextID else { return }
          // Only the horizontal strip owns these IDs; the outer Today page stays put.
          await Task.yield()
          withAnimation(.easeInOut(duration: 0.3)) { strip.scrollTo(nextID, anchor: .leading) }
        }
      }
    }
  }
  func display(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }
}
