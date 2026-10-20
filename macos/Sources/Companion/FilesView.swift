import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
  @EnvironmentObject var model: AppModel
  var query: String
  @State var parent = ""
  @State var trash = false
  @State var selected: String?
  @State var name = ""
  @State var moveTo = ""
  var rows: [Item] {
    model.items.filter {
      ["files", "folders"].contains($0.kind) && $0.deleted == trash && $0.body["purged"] != "true"
        && (trash || $0.body["parent", default: ""] == parent)
        && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query))
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Button(L10n.text("Root")) { parent = "" }
        if !parent.isEmpty { Text(model.items.first { $0.id == parent }?.title ?? "Folder") }
        Spacer()
        Toggle(L10n.text("Trash"), isOn: $trash)

      }.padding()
      Table(rows, selection: $selected) {
        TableColumn(L10n.text("Name")) { item in
          Button {
            if item.kind == "folders" {
              parent = item.id
              selected = nil
            } else {
              selected = item.id
              model.openFile(item)
            }
          } label: {
            HStack(spacing: 6) {
              FileIcon(item: item)
              Text(item.title).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }.buttonStyle(.plain).help(L10n.text("Open"))
        }
        TableColumn(L10n.text("Size")) {
          Text(
            $0.body["size"].flatMap(Int64.init).map {
              ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? L10n.text("—"))
        }
        TableColumn(L10n.text("Created")) { item in
          Text(
            item.body["createdAt"].map(BeeDisplayTime.timestamp) ?? L10n.text("Date unavailable")
          )
          .foregroundStyle(.secondary)
        }
        TableColumn(L10n.text("Last updated")) { item in
          Text(
            item.body["updatedAt"].map(BeeDisplayTime.timestamp) ?? L10n.text("Date unavailable")
          )
          .foregroundStyle(
            .secondary)
        }
        TableColumn(L10n.text("Availability")) { item in
          Text(
            item.body["uploadPending"] == "true"
              ? L10n.text("Upload pending")
              : FileManager.default.fileExists(
                atPath: model.cache.appendingPathComponent(item.id).path)
                ? L10n.text("On this Mac") : L10n.text("On server"))
        }
      }
      .tableStyle(.inset(alternatesRowBackgrounds: true))
      CollectionControls(
        addTitle: "Upload files", removeTitle: "Trash", canAdd: !trash,
        canRemove: !trash && rows.contains { $0.id == selected },
        add: { model.importFile(parent: parent) },
        remove: {
          guard var item = rows.first(where: { $0.id == selected }) else { return }
          item.deleted = true
          model.save(item)
          selected = nil
        }
      ) {
        Button(L10n.text("New folder")) {
          let folder = Item(
            kind: "folders", body: ["title": L10n.text("New folder"), "parent": parent])
          model.save(folder)
          selected = folder.id
          name = folder.title
        }.disabled(trash)
      }

      if let item = CollectionSelection.item(selected, in: rows) {
        VStack(alignment: .leading) {
          RecordDatesView(item: item)
          HStack {
            TextField(L10n.text("Name"), text: $name)
            Button(L10n.text("Rename")) {
              var updated = item
              updated.body["title"] = name
              model.save(updated)
            }.disabled(name.isEmpty || name.contains("/") || name == "..")
          }
          HStack {
            Picker(L10n.text("Move to"), selection: $moveTo) {
              Text(L10n.text("Root")).tag("")
              ForEach(
                model.items.filter { $0.kind == "folders" && !$0.deleted && $0.id != item.id }
              ) { Text($0.title).tag($0.id) }
            }
            Button(L10n.text("Move")) { move(item) }
            Button(L10n.text("Duplicate")) {
              var copy = item
              copy.id = UUID().uuidString.lowercased()
              copy.revision = 0
              copy.body["title"] = item.title + " copy"
              if item.kind == "files" {
                Task {
                  do {
                    let source = try await model.localFile(item)
                    await model.uploadFile(source, parent: parent, existing: copy)
                  } catch { model.error = error.localizedDescription }
                }
              } else {
                model.save(copy)
              }
            }
            Button(trash ? L10n.text("Restore") : L10n.text("Trash")) {
              var copy = item
              copy.deleted.toggle()
              model.save(copy)
            }
          }
          if trash {
            Button(L10n.text("Delete permanently"), role: .destructive) { model.purge(item) }
          }
          if item.kind == "files" {
            if let progress = model.transferProgress[item.id], progress < 1 {
              HStack {
                ProgressView(value: progress)
                Button(L10n.text("Cancel transfer")) { model.transfers[item.id]?.cancel() }
              }
            }
            HStack {
              Button(L10n.text("Open")) { model.openFile(item) }
              Button(L10n.text("Download")) { model.openFile(item, export: true) }
              Button(L10n.text("Quick Look")) {
                Task {
                  do {
                    let url = try await model.localFile(item)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
                    process.arguments = ["-p", url.path]
                    try process.run()
                  } catch { model.error = error.localizedDescription }
                }
              }
              Button(L10n.text("Share file")) { share(item) }
              Button(L10n.text("LocalSend")) { share(item, localSend: true) }
              Button(L10n.text("Retry upload")) { model.retryUpload(item) }.disabled(
                item.body["uploadPending"] != "true")
              Toggle(
                L10n.text("Keep offline"),
                isOn: Binding(
                  get: { item.body["pinned"] == "true" },
                  set: { value in
                    var copy = item
                    copy.body["pinned"] = String(value)
                    model.save(copy)
                    if value { Task { _ = try? await model.localFile(item) } }
                  }))
            }
          }
        }.padding()
      }
    }
    .onChange(of: selected) { _, id in name = model.items.first { $0.id == id }?.title ?? "" }
    .dropDestination(for: URL.self) { urls, _ in
      for url in urls { model.startImport(url, parent: parent) }
      return true
    }
  }
  func move(_ item: Item) {
    var ancestor = moveTo
    var seen = Set<String>()
    while !ancestor.isEmpty {
      if ancestor == item.id || seen.contains(ancestor) {
        model.error = "A folder cannot be moved inside itself"
        return
      }
      seen.insert(ancestor)
      ancestor = model.items.first { $0.id == ancestor }?.body["parent"] ?? ""
    }
    var updated = item
    updated.body["parent"] = moveTo
    model.save(updated)
  }
  func share(_ item: Item, localSend: Bool = false) {
    Task {
      do {
        let source = try await model.localFile(item)
        let destination = model.cache.appendingPathComponent("sharing").appendingPathComponent(
          item.id)
        let url = destination.appendingPathComponent(item.title)
        try await BackgroundWork.run { try FileWork.copy(source, to: url) }
        if localSend {
          guard
            let app = NSWorkspace.shared.urlForApplication(
              withBundleIdentifier: "org.localsend.localsendApp")
          else { throw CompanionError.message("Install LocalSend first") }
          let config = NSWorkspace.OpenConfiguration()
          config.arguments = [url.path]
          _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
        } else {
          Sharing.present([url])
        }
      } catch { model.error = error.localizedDescription }
    }
  }
}
@MainActor enum Sharing {
  static func plain(_ item: Item) -> String { NoteFileWork.plain(item) }

  static func present(_ items: [Any]) {
    guard let view = NSApp.keyWindow?.contentView else { return }
    NSSharingServicePicker(items: items).show(
      relativeTo: NSRect(x: 20, y: view.bounds.height - 40, width: 1, height: 1), of: view,
      preferredEdge: .minY)
  }
  static func share(_ item: Item) { present([plain(item)]) }
  static func whatsApp(_ item: Item) {
    var parts = URLComponents(string: "https://wa.me/")!
    parts.queryItems = [URLQueryItem(name: "text", value: plain(item))]
    if let url = parts.url { NSWorkspace.shared.open(url) }
  }
  static func export(_ item: Item, format: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = item.title + "." + format
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        try await BackgroundWork.run { try NoteFileWork.write(item, format: format, to: url) }
      } catch { NSAlert(error: error).runModal() }
    }
  }
}
