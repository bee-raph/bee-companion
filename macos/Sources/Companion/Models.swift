import Foundation

struct InstanceConfiguration: Codable {
  var configurationVersion: Int
  var instanceName: String
  var instanceID: String
  var apiBaseURL: URL
  var apiVersion: Int
  func validate() throws {
    let local = ["localhost", "127.0.0.1", "::1"].contains(apiBaseURL.host ?? "")
    guard configurationVersion == 1, apiVersion == 1, UUID(uuidString: instanceID) != nil,
      apiBaseURL.scheme == "https" || (apiBaseURL.scheme == "http" && local),
      apiBaseURL.user == nil, apiBaseURL.password == nil,
      apiBaseURL.query == nil, apiBaseURL.fragment == nil
    else { throw CompanionError.message("Invalid or insecure instance configuration") }
  }
}
enum CompanionError: LocalizedError {
  case message(String)
  var errorDescription: String? {
    if case .message(let text) = self { return L10n.message(text) }
    return nil
  }
}
struct Item: Identifiable, Codable, Equatable {
  var id: String = UUID().uuidString.lowercased()
  var kind: String
  var revision: Int = 0
  var body: [String: String] = [:]
  var deleted = false
  var title: String { body["title"] ?? "Untitled" }
  var archived: Bool { body["archived"] == "true" || (kind == "tasks" && body["status"] == "Done") }
  var date: Date? { body["date"].flatMap { ISO8601DateFormatter().date(from: $0) } }
}
struct Mutation: Codable {
  var operationID: String = UUID().uuidString.lowercased()
  var id: String
  var kind: String
  var expectedRevision: Int
  var body: [String: String]
  var deleted: Bool
  init(_ item: Item) {
    id = item.id
    kind = item.kind
    expectedRevision = item.revision
    body = item.body
    deleted = item.deleted
  }
}
struct PushRequest: Codable { var mutations: [Mutation] }
struct PushResult: Codable {
  struct Result: Codable {
    var operationID: String
    var status: String
    var record: Item?
    var server: Item?
  }
  var results: [Result]
}
struct PullResult: Codable {
  var changes: [Item]
  var cursor: Int
  var hasMore: Bool
}
struct Tokens: Codable {
  var accessToken: String
  var refreshToken: String
}
struct RemoteInstance: Codable {
  var instanceID: String
  var apiVersion: Int
}
struct Conflict: Identifiable {
  var id: String
  var local: Item
  var server: Item?
}
struct HebrewResponse: Codable {
  struct Event: Codable, Identifiable {
    var title: String
    var date: String
    var hebrew: String?
    var category: String?
    var id: String { title + date }
  }
  var items: [Event]
}
enum Section: String, CaseIterable, Identifiable {
  case today = "Today"
  case tasks = "Tasks"
  case files = "Files"
  case notes = "Notes"
  case agenda = "Agenda"
  case alarms = "Alarms"
  case stocks = "Stocks"
  case rss = "RSS Reader"
  case archive = "Archive"
  case settings = "Settings"
  var id: String { rawValue }
  func title(language: AppLanguage? = nil) -> String { L10n.text(rawValue, language: language) }
  var symbol: String {
    switch self {
    case .today: return "sun.max"
    case .tasks: return "checklist"
    case .files: return "folder"
    case .notes: return "note.text"
    case .agenda: return "calendar"
    case .alarms: return "alarm"
    case .stocks: return "chart.line.uptrend.xyaxis"
    case .rss: return "newspaper"
    case .archive: return "archivebox"
    case .settings: return "gear"
    }
  }
}

/// Only records in the visible collection may supply its editor selection.
enum CollectionSelection {
  static func item(_ id: String?, in rows: [Item]) -> Item? {
    guard let id else { return nil }
    return rows.first { $0.id == id }
  }
}

struct WorkListScope {
  let kind: String?
  var archived = false
  func contains(_ item: Item) -> Bool {
    !item.deleted && item.archived == archived
      && ["tasks", "notes", "reminders"].contains(item.kind)
      && (kind == nil || item.kind == kind)
  }
}

enum DeletionPolicy {
  static func requiresConfirmation(_ item: Item) -> Bool {
    ["notes", "reminders"].contains(item.kind)
  }
}
extension Notification.Name {
  static let flushNoteEdits = Notification.Name("BeeCompanion.flushNoteEdits")
}
