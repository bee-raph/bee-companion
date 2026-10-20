import AppKit
import CryptoKit
import SwiftUI

@MainActor final class AppModel: ObservableObject {
  @Published private(set) var contentRevision = 0
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
  private let workingCopyScanner = WorkingCopyScanner()
  private var checkingWorkingCopies = false
  private var editGeneration = 0
  private var scheduledSync: Task<Void, Never>?
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
  deinit {
    syncTask?.cancel()
    scheduledSync?.cancel()
    for task in transfers.values { task.cancel() }
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
    editGeneration += 1
    do {
      let loaded = try store.all()
      if items != loaded {
        items = loaded
        contentRevision += 1
      }
      L10n.language = language
      pending = try store.pendingCount()
      conflicts = try store.conflicts()
    } catch { self.error = error.localizedDescription }
  }
  private func reloadInBackground() async {
    let activeStore = store!
    do {
      while true {
        let generation = editGeneration
        let snapshot = try await BackgroundWork.run {
          (try activeStore.all(), try activeStore.pendingCount(), try activeStore.conflicts())
        }
        guard activeStore === store else { return }
        guard generation == editGeneration else { continue }
        if items != snapshot.0 {
          items = snapshot.0
          contentRevision += 1
        }
        pending = snapshot.1
        conflicts = snapshot.2
        L10n.language = language
        return
      }
    } catch { self.error = error.localizedDescription }
  }
  func save(_ input: Item) {
    editGeneration += 1
    let previous = items.first { $0.id == input.id }
    let item = TaskAudit.recording(
      TaskCompletion.normalized(input, previous: previous), previous: previous)
    do {
      try store.save(item)
      var saved = item
      if let index = items.firstIndex(where: { $0.id == item.id }) {
        saved.revision = items[index].revision
        items[index] = saved
      } else {
        items.append(saved)
      }
      contentRevision += 1
      if item.kind == "user_settings" { L10n.language = language }
      pending = try store.pendingCount()
      if !conflicts.isEmpty { conflicts = try store.conflicts() }
      scheduleSynchronization()
    } catch { self.error = error.localizedDescription }
  }
  private func scheduleSynchronization() {
    scheduledSync?.cancel()
    scheduledSync = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      guard let self else { return }
      self.scheduledSync = nil
      await self.sync()
    }
  }
  func setPreference(_ key: String, _ value: String) {
    var settings = preferences
    settings.body[key] = value
    save(settings)
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
        "title": L10n.text(
          kind == "tasks" ? "New task" : kind == "notes" ? "New note" : "New alarm"),
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
      guard !syncing, transfers.isEmpty, configuration == nil || (pending == 0 && conflicts.isEmpty)
      else {
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
    defer { syncing = false }
    let activeStore = store!
    var changed = false
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
      while let mutation = try await BackgroundWork.run({ try activeStore.nextMutation() }) {
        let response: PushResult = try await api.request(
          "sync/push", method: "POST",
          body: try await BackgroundWork.run {
            try JSONEncoder().encode(PushRequest(mutations: [mutation]))
          })
        try await BackgroundWork.run {
          for result in response.results { try activeStore.accept(result) }
        }
        changed = changed || !response.results.isEmpty
      }
      var more = true
      while more {
        let cursor = try await BackgroundWork.run { try activeStore.cursor() }
        let result: PullResult = try await api.request("sync/pull?cursor=\(cursor)")
        try await BackgroundWork.run { try activeStore.apply(result) }
        changed = changed || !result.changes.isEmpty
        more = result.hasMore
      }
      message = "Up to date · " + Date().formatted(date: .omitted, time: .shortened)
    } catch { message = "Offline / sync paused: " + error.localizedDescription }
    if changed { await reloadInBackground() }
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
  func attachFiles(to owner: Item) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      let file = Item(kind: "files", body: ["title": url.lastPathComponent, "parent": ""])
      transfers[file.id] = Task {
        await uploadFile(url, existing: file, attachmentOwner: owner)
        transfers.removeValue(forKey: file.id)
      }
    }
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
  func uploadFile(
    _ url: URL, parent: String = "", existing: Item? = nil, attachmentOwner: Item? = nil
  ) async {
    do {
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let activeStore = store
      var item =
        existing ?? Item(kind: "files", body: ["title": url.lastPathComponent, "parent": parent])
      let target = cache.appendingPathComponent(item.id)
      let prepared = try await Task.detached(priority: .userInitiated) {
        try ImportedFile.prepare(url, target: target)
      }.value
      guard activeStore === store else { return }
      item.body["checksum"] = prepared.checksum
      item.body["modified"] = ISO8601DateFormatter().string(from: Date())
      item.body["size"] = String(prepared.size)
      item.body["uploadPending"] = "true"
      save(item)
      if let owner = attachmentOwner {
        save(AttachmentFile.link(owner: owner, fileID: item.id))
      }
      try await sendFile(item)
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
    let source = cache.appendingPathComponent(item.id)
    let size = try await BackgroundWork.run {
      try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
    let stateURL = cache.appendingPathComponent(item.id + ".transfer.json")
    let checksum = item.body["checksum"] ?? ""
    var start: Upload?
    if let stored = try? await BackgroundWork.run({ try Data(contentsOf: stateURL) }),
      let state = try? JSONDecoder().decode(State.self, from: stored), state.checksum == checksum
    {
      start = try? await api.request("files/uploads/\(state.upload.id)")
    }
    if start == nil {
      let created: Upload = try await api.request(
        "files/uploads", method: "POST",
        body: JSONSerialization.data(withJSONObject: [
          "fileID": item.id, "size": size, "checksum": checksum,
        ]))
      start = created
      try await BackgroundWork.run {
        try JSONEncoder().encode(State(checksum: checksum, upload: created)).write(
          to: stateURL, options: .atomic)
      }
    }
    guard let start else { throw CompanionError.message("Cannot start upload") }
    var offset = start.offset
    while offset < size {
      try Task.checkCancellation()
      let startOffset = offset
      let chunk = try await BackgroundWork.run {
        try FileWork.chunk(source, offset: startOffset, count: 4 * 1024 * 1024)
      }
      guard !chunk.isEmpty else { throw CompanionError.message("Invalid server response") }
      let end = offset + chunk.count
      let next: Offset = try JSONDecoder().decode(
        Offset.self,
        from: await api.raw(
          "files/uploads/\(start.id)?offset=\(offset)", method: "PUT",
          body: chunk, contentType: "application/octet-stream"))
      guard next.offset > offset, next.offset <= end else {
        throw CompanionError.message("Invalid server response")
      }
      offset = next.offset
      transferProgress[item.id] = size == 0 ? 1 : Double(offset) / Double(size)
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
      try await api.download(
        "files/\(item.id)/content", to: target, checksum: item.body["checksum"] ?? "")
    }
    return target
  }
  func openFile(_ item: Item, export: Bool = false) {
    Task {
      do {
        let activeStore = store
        let source = try await localFile(item)
        guard activeStore === store else { return }
        if export {
          let panel = NSSavePanel()
          panel.nameFieldStringValue = item.title
          if panel.runModal() == .OK, let target = panel.url {
            try await BackgroundWork.run { try FileWork.copy(source, to: target) }
          }
        } else {
          let working = cache.appendingPathComponent("working").appendingPathComponent(item.id)
          guard item.title != "..", !item.title.contains("/"), !item.title.contains("\\") else {
            throw CompanionError.message("Invalid file name")
          }
          let target = working.appendingPathComponent(item.title)
          try await BackgroundWork.run { try FileWork.copy(source, to: target, overwrite: false) }
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
        let activeStore = store
        var payload: [Any] = [Sharing.plain(item)]
        for link in links {
          if let file = items.first(where: { $0.id == link.body["fileID"] && !$0.deleted }) {
            let source = try await localFile(file)
            guard activeStore === store else { return }
            let folder = cache.appendingPathComponent("sharing").appendingPathComponent(file.id)
            let target = folder.appendingPathComponent(file.title)
            try await BackgroundWork.run { try FileWork.copy(source, to: target) }
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
    let urls = panel.urls
    let activeStore = store
    Task {
      for url in urls {
        do {
          let item = try await BackgroundWork.run { try NoteFileWork.read(url) }
          guard activeStore === store else { return }
          save(item)
        } catch { self.error = error.localizedDescription }
      }
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
    guard !checkingWorkingCopies else { return }
    checkingWorkingCopies = true
    let originalStore = store
    let candidates = items
    let root = cache
    Task {
      defer { checkingWorkingCopies = false }
      let changed = await workingCopyScanner.changes(in: candidates, cache: root)
      guard originalStore === store else { return }
      for change in changed {
        guard let item = items.first(where: { $0.id == change.item.id }), !item.deleted,
          item.body["checksum"] == change.item.body["checksum"]
        else { continue }
        let alert = NSAlert()
        alert.messageText = L10n.format("Upload changes to %@?", item.title)
        alert.addButton(withTitle: L10n.text("Upload new version"))
        alert.addButton(withTitle: L10n.text("Later"))
        if alert.runModal() == .alertFirstButtonReturn {
          await uploadFile(change.url, existing: item)
        }
      }
    }
  }
}
