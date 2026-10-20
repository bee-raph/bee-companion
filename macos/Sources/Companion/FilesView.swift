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
    VStack(alignment: .leading) {
      HStack {
        Button("Root") { parent = "" }
        if !parent.isEmpty { Text(model.items.first { $0.id == parent }?.title ?? "Folder") }
        Spacer()
        Toggle("Trash", isOn: $trash)
        Button("New folder") {
          let folder = Item(kind: "folders", body: ["title": "New folder", "parent": parent])
          model.save(folder)
          selected = folder.id
          name = folder.title
        }
        Button("Upload") { model.importFile(parent: parent) }
      }.padding()
      Table(rows, selection: $selected) {
        TableColumn("Name") { item in
          Label(item.title, systemImage: item.kind == "folders" ? "folder" : "doc").onTapGesture(
            count: 2
          ) { if item.kind == "folders" { parent = item.id } else { model.openFile(item) } }
        }
        TableColumn("Size") {
          Text(
            $0.body["size"].flatMap(Int64.init).map {
              ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "—")
        }
        TableColumn("Modified") { item in
          Text(item.body["modified"].map(BeeDisplayTime.timestamp) ?? "—").foregroundStyle(
            .secondary)
        }
        TableColumn("Availability") { item in
          Text(
            item.body["uploadPending"] == "true"
              ? "Upload pending"
              : FileManager.default.fileExists(
                atPath: model.cache.appendingPathComponent(item.id).path)
                ? "On this Mac" : "On server")
        }
      }
      if let item = model.items.first(where: { $0.id == selected }) {
        VStack(alignment: .leading) {
          HStack {
            TextField("Name", text: $name)
            Button("Rename") {
              var updated = item
              updated.body["title"] = name
              model.save(updated)
            }.disabled(name.isEmpty || name.contains("/") || name == "..")
          }
          HStack {
            Picker("Move to", selection: $moveTo) {
              Text("Root").tag("")
              ForEach(
                model.items.filter { $0.kind == "folders" && !$0.deleted && $0.id != item.id }
              ) { Text($0.title).tag($0.id) }
            }
            Button("Move") { move(item) }
            Button("Duplicate") {
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
            Button(trash ? "Restore" : "Trash") {
              var copy = item
              copy.deleted.toggle()
              model.save(copy)
            }
          }
          if trash { Button("Delete permanently", role: .destructive) { model.purge(item) } }
          if item.kind == "files" {
            if let progress = model.transferProgress[item.id], progress < 1 {
              HStack {
                ProgressView(value: progress)
                Button("Cancel transfer") { model.transfers[item.id]?.cancel() }
              }
            }
            HStack {
              Button("Open") { model.openFile(item) }
              Button("Download") { model.openFile(item, export: true) }
              Button("Quick Look") {
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
              Button("Share file") { share(item) }
              Button("LocalSend") { share(item, localSend: true) }
              Button("Retry upload") { model.retryUpload(item) }.disabled(
                item.body["uploadPending"] != "true")
              Toggle(
                "Keep offline",
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
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let url = destination.appendingPathComponent(item.title)
        try Data(contentsOf: source).write(to: url, options: .atomic)
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
  static func plain(_ item: Item) -> String {
    [
      item.title, item.body["description"], item.body["text"], item.body["date"],
      item.body["status"],
    ].compactMap { $0 }.joined(separator: "\n\n")
  }
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
    do {
      let data: Data
      if format == "rtf" {
        if item.kind == "notes", let stored = item.body["rtf"],
          let rich = Data(base64Encoded: stored)
        {
          data = rich
        } else {
          let text = NSAttributedString(string: plain(item))
          data = try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }
      } else {
        data = Data(plain(item).utf8)
      }
      try data.write(to: url, options: .atomic)
    } catch { NSAlert(error: error).runModal() }
  }
}
