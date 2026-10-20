import Foundation
import SwiftUI

struct WorkspaceSearchMatch: Sendable {
  let id: String
  let excerpt: String
}

struct WorkspaceSearchResult: Identifiable, Sendable {
  let item: Item
  let excerpt: String
  var id: String { item.id }
  var label: String {
    switch item.kind {
    case "notes": return "Notes"
    case "tasks": return "Tasks"
    case "reminders": return "Alarms"
    default: return "CRM"
    }
  }
  var symbol: String {
    switch item.kind {
    case "notes": return "note.text"
    case "tasks": return "checklist"
    case "reminders": return "alarm"
    default: return "person.crop.circle"
    }
  }
  var destination: Section {
    if item.archived && item.kind != "crm_contacts" { return .archive }
    switch item.kind {
    case "notes": return .notes
    case "tasks": return .tasks
    case "reminders": return .alarms
    default: return .crm
    }
  }
}

enum WorkspaceSearchIndex {
  static let fields = [
    "text", "notes", "firstName", "lastName", "company", "jobTitle",
    "birthday", "registration", "taxID", "website", "emails", "phones", "mobiles", "whatsapp",
    "addresses", "contactType", "identityType", "actionType", "status", "date",
  ]
  static let kinds = ["notes", "tasks", "reminders", "crm_contacts", "crm_actions"]

  static func text(_ item: Item) -> String {
    fields.compactMap { item.body[$0] }.joined(separator: "\n")
  }

  static func expression(_ query: String) -> String? {
    let words = query.split(whereSeparator: { $0.isWhitespace })
      .filter { $0.contains { $0.isLetter || $0.isNumber } }
    guard !words.isEmpty else { return nil }
    return words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
      .joined(separator: " AND ")
  }

  static func excerpt(_ text: String, query: String) -> String {
    let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    let anchor = range?.lowerBound ?? text.startIndex
    let start = text.index(anchor, offsetBy: -55, limitedBy: text.startIndex) ?? text.startIndex
    let end = text.index(start, offsetBy: 220, limitedBy: text.endIndex) ?? text.endIndex
    let value = text[start..<end].split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return (start == text.startIndex ? "" : "… ") + value + (end == text.endIndex ? "" : " …")
  }

  static func resolve(_ matches: [WorkspaceSearchMatch], items: [Item]) -> [WorkspaceSearchResult] {
    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var seen = Set<String>()
    return matches.compactMap { match in
      guard let source = byID[match.id], !source.deleted else { return nil }
      let target: Item
      if source.kind == "crm_actions" {
        guard let contactID = source.body["contactID"], let contact = byID[contactID],
          !contact.deleted, contact.kind == "crm_contacts"
        else { return nil }
        target = contact
      } else {
        guard ["notes", "tasks", "reminders", "crm_contacts"].contains(source.kind) else {
          return nil
        }
        target = source
      }
      guard seen.insert(target.id).inserted else { return nil }
      let excerpt = source.id == target.id ? match.excerpt : source.title + ": " + match.excerpt
      return WorkspaceSearchResult(item: target, excerpt: excerpt)
    }
  }
}

struct GlobalSearchView: View {
  @EnvironmentObject var model: AppModel
  let query: String
  let open: (WorkspaceSearchResult) -> Void
  @State private var results: [WorkspaceSearchResult] = []
  @State private var loading = true
  @State private var limited = false
  private let columns = [
    GridItem(.adaptive(minimum: 240, maximum: 440), spacing: 16, alignment: .top)
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(L10n.text("Search results")).font(.title2.bold())
          Text(L10n.text("Notes, reminders, tasks, and CRM contacts")).font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if loading {
          ProgressView().controlSize(.small)
        } else {
          Text(L10n.format("%d results", results.count)).foregroundStyle(.secondary)
        }
      }
      if limited {
        Text(L10n.text("Showing the first matches. Refine your search for more specific results."))
          .font(.caption).foregroundStyle(.secondary)
      }
      if results.isEmpty && !loading {
        ContentUnavailableView(
          L10n.text("No matching records"), systemImage: "magnifyingglass",
          description: Text(L10n.text("Try another word, name, email address, or phone number."))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(results) { result in
              Button {
                open(result)
              } label: {
                VStack(alignment: .leading, spacing: 10) {
                  HStack {
                    Label(L10n.text(result.label), systemImage: result.symbol)
                      .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if result.item.archived {
                      Text(L10n.text("Archived")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                  }
                  Text(result.item.title).font(.headline).lineLimit(2)
                  if !result.excerpt.isEmpty {
                    Text(result.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                  }
                  if result.item.kind == "crm_contacts" {
                    Text(L10n.text(result.item.body["contactType"] ?? "Simple contact"))
                      .font(.caption).foregroundStyle(.secondary)
                  }
                }.padding(16).frame(maxWidth: .infinity, minHeight: 145, alignment: .topLeading)
                  .background(BeeTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                  .overlay(
                    RoundedRectangle(cornerRadius: 12).strokeBorder(
                      Color(nsColor: .separatorColor).opacity(0.5))
                  )
                  .contentShape(RoundedRectangle(cornerRadius: 12))
              }.buttonStyle(.plain).help(L10n.text("Open matching record"))
            }
          }.padding(1)
        }
      }
    }.padding(24)
      .task(id: "\(model.configuration?.instanceID ?? "local"):\(model.contentRevision):" + query) {
        loading = true
        do {
          try await Task.sleep(for: .milliseconds(150))
          let activeStore = model.store!
          let snapshot = model.items
          let response = try await BackgroundWork.run {
            let matches = try activeStore.globalSearch(query)
            return (WorkspaceSearchIndex.resolve(matches, items: snapshot), matches.count >= 200)
          }
          guard !Task.isCancelled, activeStore === model.store else { return }
          results = response.0
          limited = response.1
          loading = false
        } catch is CancellationError {} catch {
          guard !Task.isCancelled else { return }
          loading = false
          model.error = error.localizedDescription
        }
      }
  }
}
