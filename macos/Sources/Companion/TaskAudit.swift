import Foundation
import SwiftUI

struct TaskAuditEntry: Codable, Equatable, Identifiable {
  var id: String = UUID().uuidString.lowercased()
  var date: Date
  var from: String?
  var status: String
}

enum TaskAudit {
  static func entries(_ item: Item) -> [TaskAuditEntry] {
    guard let data = item.body["taskAudit"]?.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([TaskAuditEntry].self, from: data)) ?? []
  }

  static func merging(_ item: Item, with other: Item) -> Item {
    guard item.kind == "tasks", other.kind == "tasks", item.id == other.id else { return item }
    var merged = item
    var seen = Set<String>()
    let history = (entries(item) + entries(other)).filter { seen.insert($0.id).inserted }
      .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    if let data = try? JSONEncoder().encode(history) {
      merged.body["taskAudit"] = String(data: data, encoding: .utf8)
    }
    merged.body["taskCreatedAt"] = item.body["taskCreatedAt"] ?? other.body["taskCreatedAt"]
    return merged
  }

  static func recording(_ input: Item, previous: Item?, now: Date = Date()) -> Item {
    guard input.kind == "tasks" else { return input }
    var item = input
    var history = entries(previous ?? input)
    let status = input.body["status"] ?? "To do"
    let oldStatus = previous?.body["status"] ?? "To do"
    if let previous {
      item.body["taskCreatedAt"] = previous.body["taskCreatedAt"]
      if !input.deleted && oldStatus != status {
        history.append(TaskAuditEntry(date: now, from: oldStatus, status: status))
      }
    } else if input.revision == 0 && history.isEmpty && !input.deleted {
      item.body["taskCreatedAt"] = ISO8601DateFormatter().string(from: now)
      history.append(TaskAuditEntry(date: now, from: nil, status: status))
    }
    if let data = try? JSONEncoder().encode(history) {
      item.body["taskAudit"] = String(data: data, encoding: .utf8)
    }
    return item
  }
}

struct TaskAuditView: View {
  let item: Item
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(L10n.text("Task history")).font(.headline)
      if let date = item.body["taskCreatedAt"].flatMap({ ItemTimestamp.date($0) }) {
        HStack {
          Text(L10n.text("Created"))
          Text(date, format: .dateTime.year().month().day().hour().minute().second())
        }
      } else {
        Text(L10n.text("Creation date unavailable")).foregroundStyle(.secondary)
      }
      ForEach(TaskAudit.entries(item).reversed()) { entry in
        HStack(alignment: .top) {
          VStack(alignment: .leading) {
            if let from = entry.from {
              Text(L10n.text(from) + " → " + L10n.text(entry.status))
            } else {
              Text(L10n.text(entry.status))
            }
            Text(entry.date, format: .dateTime.year().month().day().hour().minute().second())
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
        }
      }
    }.textSelection(.enabled)
  }
}
