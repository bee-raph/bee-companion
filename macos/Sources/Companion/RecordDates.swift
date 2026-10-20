import Foundation
import SwiftUI

enum RecordDates {
  static let kinds: Set<String> = [
    "notes", "files", "folders", "crm_contacts", "crm_actions", "reminders",
  ]

  static func recording(_ input: Item, previous: Item?, now: Date = Date()) -> Item {
    guard kinds.contains(input.kind) else { return input }
    var item = input
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: now)
    if let previous {
      item.body["createdAt"] = previous.body["createdAt"]
      item.body["updatedAt"] = previous.body["updatedAt"]
      if content(item) != content(previous) || item.deleted != previous.deleted {
        item.body["updatedAt"] = timestamp
      }
    } else if item.revision == 0 {
      item.body["createdAt"] = timestamp
      item.body["updatedAt"] = timestamp
    }
    return item
  }

  private static func content(_ item: Item) -> [String: String] {
    item.body.filter { !["createdAt", "updatedAt"].contains($0.key) }
  }
}

struct RecordDatesView: View {
  let item: Item
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      row("Created", key: "createdAt")
      row("Last updated", key: "updatedAt")
    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
  }

  private func row(_ label: String, key: String) -> some View {
    HStack {
      Text(L10n.text(label))
      if let date = item.body[key].flatMap({ ItemTimestamp.date($0) }) {
        Text(date, format: .dateTime.year().month().day().hour().minute().second())
      } else {
        Text(L10n.text("Date unavailable"))
      }
    }
  }
}
