import AppKit
import CryptoKit
import SwiftUI

@MainActor final class AppModel: ObservableObject {
  @Published var items: [Item] = []
  @Published var conflicts: [Conflict] = []
  @Published var configuration: InstanceConfiguration?
  @Published var message = "Offline library"
  @Published var pending = 0
  @Published var error: String?
  @Published var syncing = false
  @Published var transferProgress: [String: Double] = [:]
  var transfers: [String: Task<Void, Never>] = [:]
  var store: LocalStore!
  var api: API?
  var directory: URL
  private var syncTask: Task<Void, Never>?
  init() {
    directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("WorkCompanion")
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      if let data = UserDefaults.standard.data(forKey: "configuration") {
        let config = try JSONDecoder().decode(InstanceConfiguration.self, from: data)
        try config.validate()
        configuration = config
        api = API(config)
      }
      try openStore()
      reload()
    } catch { self.error = error.localizedDescription }
    syncTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.sync()
        try? await Task.sleep(for: .seconds(30))
      }
    }
  }
  func openStore() throws {
    let instance = directory.appendingPathComponent(configuration?.instanceID ?? "local")
    try FileManager.default.createDirectory(at: instance, withIntermediateDirectories: true)
    store = try LocalStore(url: instance.appendingPathComponent("library.sqlite"))
  }
  var cache: URL {
    let url = directory.appendingPathComponent(configuration?.instanceID ?? "local")
      .appendingPathComponent("files")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  func reload() {
    do {
      items = try store.all()
      L10n.language = language
      pending = try store.pendingCount()
      conflicts = try store.conflicts()
    } catch { self.error = error.localizedDescription }
  }
  func save(_ item: Item) {
    do {
      try store.save(item)
      var saved = item
      if let index = items.firstIndex(where: { $0.id == item.id }) {
        saved.revision = items[index].revision
        items[index] = saved
      } else {
        items.append(saved)
      }
      if item.kind == "user_settings" { L10n.language = language }
      pending = try store.pendingCount()
      if !conflicts.isEmpty { conflicts = try store.conflicts() }
    } catch { self.error = error.localizedDescription }
  }
  @discardableResult func trash(_ item: Item) -> Bool {
    NotificationCenter.default.post(name: .flushNoteEdits, object: nil)
    if DeletionPolicy.requiresConfirmation(item) {
      let alert = NSAlert()
      alert.messageText = L10n.format(
        item.kind == "notes" ? "Delete note %@?" : "Delete reminder %@?", item.title)
      alert.informativeText = L10n.text(
        "This item will be moved to Trash. Its attached library files will be kept.")
      alert.alertStyle = .warning
      alert.addButton(withTitle: L10n.text("Cancel"))
      alert.addButton(withTitle: L10n.text("Trash"))
      guard alert.runModal() == .alertSecondButtonReturn else { return false }
    }
    var latest = items.first(where: { $0.id == item.id }) ?? item
    latest.deleted = true
    save(latest)
    return true
  }
  func add(_ kind: String) -> Item {
    let item = Item(
      kind: kind,
      body: [
        "title": kind == "tasks" ? "New task" : kind == "notes" ? "New note" : "New alarm",
        "status": "To do", "format": kind == "notes" ? "rtf" : "markdown",
      ])
    save(item)
    return item
  }
  func importConfiguration() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      guard !syncing, configuration == nil || (pending == 0 && conflicts.isEmpty) else {
        throw CompanionError.message(
          "Resolve conflicts and synchronize pending changes before switching instances")
      }
      let config = try JSONDecoder().decode(InstanceConfiguration.self, from: Data(contentsOf: url))
      try config.validate()
      let adoptingLocal = configuration == nil
      let localItems = adoptingLocal ? items : []
      let previousCache = cache
      configuration = config
      api = API(config)
      UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: "configuration")
      try openStore()
      for item in localItems {
        try store.save(item)
        if item.kind == "files" {
          let old = previousCache.appendingPathComponent(item.id)
          let new = cache.appendingPathComponent(item.id)
          if FileManager.default.fileExists(atPath: old.path),
            !FileManager.default.fileExists(atPath: new.path)
          {
            try FileManager.default.copyItem(at: old, to: new)
          }
        }
      }
      reload()
      message = "Sign in to " + config.instanceName
    } catch { self.error = error.localizedDescription }
  }
  func sync() async {
    guard !syncing, let api else { return }
    syncing = true
    defer {
      syncing = false
      reload()
    }
    do {
      let remote: RemoteInstance = try await api.request("instance", authorized: false)
      guard remote.instanceID == configuration?.instanceID, remote.apiVersion == 1 else {
        throw CompanionError.message("Backend instance identity mismatch")
      }
      for item in items
      where item.kind == "files" && !item.deleted && item.body["uploadPending"] == "true"
        && transfers[item.id] == nil
      {
        try await sendFile(item)
      }
      // Send one mutation at a time: accepting a revision rebases later queued edits.
      while let mutation = try store.nextMutation() {
        let response: PushResult = try await api.request(
          "sync/push", method: "POST",
          body: JSONEncoder().encode(PushRequest(mutations: [mutation])))
        for result in response.results { try store.accept(result) }
      }
      var more = true
      while more {
        let result: PullResult = try await api.request("sync/pull?cursor=\(try store.cursor())")
        try store.apply(result)
        more = result.hasMore
      }
      message = "Up to date · " + Date().formatted(date: .omitted, time: .shortened)
    } catch { message = "Offline / sync paused: " + error.localizedDescription }
  }
  func resolve(_ conflict: Conflict, keepLocal: Bool) {
    do {
      try store.resolve(conflict, keepLocal: keepLocal)
      reload()
    } catch { self.error = error.localizedDescription }
  }
  func importFile(parent: String = "") {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    for url in panel.urls { startImport(url, parent: parent) }
  }
  func startImport(_ url: URL, parent: String = "") {
    let item = Item(kind: "files", body: ["title": url.lastPathComponent, "parent": parent])
    transfers[item.id] = Task {
      await uploadFile(url, parent: parent, existing: item)
      transfers.removeValue(forKey: item.id)
    }
  }
  func retryUpload(_ item: Item) {
    transfers[item.id] = Task {
      do { try await sendFile(item) } catch is CancellationError {} catch {
        self.error = error.localizedDescription
      }
      transfers.removeValue(forKey: item.id)
    }
  }
  func uploadFile(_ url: URL, parent: String = "", existing: Item? = nil) async {
    do {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      var item =
        existing ?? Item(kind: "files", body: ["title": url.lastPathComponent, "parent": parent])
      let target = cache.appendingPathComponent(item.id)
      if url != target {
        if FileManager.default.fileExists(atPath: target.path) {
          try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: url, to: target)
      }
      let data = try Data(contentsOf: target, options: .mappedIfSafe)
      item.body["checksum"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      item.body["modified"] = ISO8601DateFormatter().string(from: Date())
      item.body["size"] = String(data.count)
      item.body["uploadPending"] = "true"
      save(item)
      try await sendFile(item)
      reload()
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
  func sendFile(_ item: Item) async throws {
    guard let api else { return }
    struct Upload: Codable {
      var id: String
      var offset: Int
    }
    struct State: Codable {
      var checksum: String
      var upload: Upload
    }
    struct Offset: Decodable { var offset: Int }
    struct Complete: Decodable { var versionID: String }
    let data = try Data(contentsOf: cache.appendingPathComponent(item.id), options: .mappedIfSafe)
    let stateURL = cache.appendingPathComponent(item.id + ".transfer.json")
    let checksum = item.body["checksum"] ?? ""
    var start: Upload?
    if let stored = try? Data(contentsOf: stateURL),
      let state = try? JSONDecoder().decode(State.self, from: stored), state.checksum == checksum
    {
      start = try? await api.request("files/uploads/\(state.upload.id)")
    }
    if start == nil {
      let created: Upload = try await api.request(
        "files/uploads", method: "POST",
        body: JSONSerialization.data(withJSONObject: [
          "fileID": item.id, "size": data.count, "checksum": checksum,
        ]))
      start = created
      try JSONEncoder().encode(State(checksum: checksum, upload: created)).write(
        to: stateURL, options: .atomic)
    }
    guard let start else { throw CompanionError.message("Cannot start upload") }
    var offset = start.offset
    while offset < data.count {
      try Task.checkCancellation()
      let end = min(offset + 4 * 1024 * 1024, data.count)
      let next: Offset = try JSONDecoder().decode(
        Offset.self,
        from: await api.raw(
          "files/uploads/\(start.id)?offset=\(offset)", method: "PUT",
          body: data.subdata(in: offset..<end), contentType: "application/octet-stream"))
      offset = next.offset
      transferProgress[item.id] = data.isEmpty ? 1 : Double(offset) / Double(data.count)
    }
    let result: Complete = try await api.request(
      "files/uploads/\(start.id)/complete", method: "POST")
    try? FileManager.default.removeItem(at: stateURL)
    transferProgress[item.id] = 1
    guard let current = items.first(where: { $0.id == item.id }),
      current.body["checksum"] == checksum
    else { return }
    var updated = current
    updated.body["versionID"] = result.versionID
    updated.body["uploadPending"] = "false"
    save(updated)
  }
  func localFile(_ item: Item) async throws -> URL {
    let target = cache.appendingPathComponent(item.id)
    if !FileManager.default.fileExists(atPath: target.path) {
      guard let api else { throw CompanionError.message("File is not cached offline") }
      let data = try await api.raw("files/\(item.id)/content")
      let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      guard checksum == item.body["checksum"] else {
        throw CompanionError.message("Downloaded file checksum mismatch")
      }
      try data.write(to: target, options: .atomic)
    }
    return target
  }
  func openFile(_ item: Item, export: Bool = false) {
    Task {
      do {
        let source = try await localFile(item)
        if export {
          let panel = NSSavePanel()
          panel.nameFieldStringValue = item.title
          if panel.runModal() == .OK, let target = panel.url {
            try Data(contentsOf: source).write(to: target, options: .atomic)
          }
        } else {
          let working = cache.appendingPathComponent("working").appendingPathComponent(item.id)
          try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
          guard item.title != "..", !item.title.contains("/"), !item.title.contains("\\") else {
            throw CompanionError.message("Invalid file name")
          }
          let target = working.appendingPathComponent(item.title)
          if !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.copyItem(at: source, to: target)
          }
          NSWorkspace.shared.open(target)
        }
      } catch { self.error = error.localizedDescription }
    }
  }
  func shareWithAttachments(_ item: Item) {
    Task {
      do {
        let kind =
          item.kind == "tasks"
          ? "task_attachments" : item.kind == "notes" ? "note_attachments" : "reminder_attachments"
        let links = items.filter { !$0.deleted && $0.kind == kind && $0.body["ownerID"] == item.id }
        var payload: [Any] = [Sharing.plain(item)]
        for link in links {
          if let file = items.first(where: { $0.id == link.body["fileID"] && !$0.deleted }) {
            let source = try await localFile(file)
            let folder = cache.appendingPathComponent("sharing").appendingPathComponent(file.id)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(file.title)
            try Data(contentsOf: source).write(to: target, options: .atomic)
            payload.append(target)
          }
        }
        Sharing.present(payload)
      } catch { self.error = error.localizedDescription }
    }
  }
  func importNotes() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      do {
        var item = Item(
          kind: "notes", body: ["title": url.deletingPathExtension().lastPathComponent])
        if url.pathExtension.lowercased() == "rtfd" {
          let rich = try NSAttributedString(
            url: url, options: [.documentType: NSAttributedString.DocumentType.rtfd],
            documentAttributes: nil)
          item.body["format"] = "rtf"
          item.body["rtfd"] = try rich.data(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
          ).base64EncodedString()
          item.body["text"] = rich.string
          save(item)
          continue
        }
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "rtf" {
          guard let rich = NSAttributedString(rtf: data, documentAttributes: nil) else {
            throw CompanionError.message("Invalid RTF")
          }
          item.body["format"] = "rtf"
          item.body["rtf"] = data.base64EncodedString()
          item.body["text"] = rich.string
        } else {
          item.body["format"] = "markdown"
          item.body["text"] = String(decoding: data, as: UTF8.self)
        }
        save(item)
      } catch { self.error = error.localizedDescription }
    }
  }
  func purge(_ item: Item) {
    Task {
      do {
        guard let api else {
          throw CompanionError.message("Connect to backend to permanently delete")
        }
        let alert = NSAlert()
        alert.messageText = L10n.format("Permanently delete %@?", item.title)
        alert.informativeText =
          L10n.text(
            "This removes all stored versions. Existing attachments will become unavailable.")
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.addButton(withTitle: L10n.text("Delete permanently"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        await sync()
        guard pending == 0 else {
          throw CompanionError.message("Resolve pending synchronization first")
        }
        let _: [String: Bool] = try await api.request(
          "files/\(item.id)?confirm=true", method: "DELETE")
        try? FileManager.default.removeItem(at: cache.appendingPathComponent(item.id))
        await sync()
      } catch { self.error = error.localizedDescription }
    }
  }
  func checkWorkingCopies() {
    for item in items where item.kind == "files" && !item.deleted {
      let target = cache.appendingPathComponent("working").appendingPathComponent(item.id)
        .appendingPathComponent(item.title)
      guard let data = try? Data(contentsOf: target),
        SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
          != item.body["checksum"]
      else { continue }
      let alert = NSAlert()
      alert.messageText = L10n.format("Upload changes to %@?", item.title)
      alert.addButton(withTitle: L10n.text("Upload new version"))
      alert.addButton(withTitle: L10n.text("Later"))
      if alert.runModal() == .alertFirstButtonReturn {
        Task { await uploadFile(target, existing: item) }
      }
    }
  }
}
