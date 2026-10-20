import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

struct FileAppearance {
  let symbol: String
  let color: Color
  init(_ item: Item) {
    if item.kind == "folders" {
      symbol = "folder.fill"
      color = .blue
      return
    }
    let type = UTType(filenameExtension: (item.title as NSString).pathExtension)
    if type?.conforms(to: .image) == true {
      symbol = "photo.fill"
      color = .purple
    } else if type?.conforms(to: .pdf) == true {
      symbol = "doc.richtext.fill"
      color = .red
    } else if type?.conforms(to: .audio) == true {
      symbol = "waveform"
      color = .pink
    } else if type?.conforms(to: .movie) == true {
      symbol = "film.fill"
      color = .indigo
    } else if type?.conforms(to: .archive) == true {
      symbol = "archivebox.fill"
      color = .orange
    } else if type?.conforms(to: .spreadsheet) == true {
      symbol = "tablecells.fill"
      color = .green
    } else if type?.conforms(to: .presentation) == true {
      symbol = "rectangle.stack.fill"
      color = .orange
    } else if type?.conforms(to: .sourceCode) == true {
      symbol = "chevron.left.forwardslash.chevron.right"
      color = .teal
    } else {
      symbol = "doc.text.fill"
      color = .blue
    }
  }
}
struct FileIcon: View {
  let item: Item
  var body: some View {
    let appearance = FileAppearance(item)
    Image(systemName: appearance.symbol).foregroundStyle(appearance.color)
      .frame(width: 20).accessibilityHidden(true)
  }
}
struct TaskCompletionButton: View {
  @EnvironmentObject var model: AppModel
  let item: Item
  private var task: Item { model.items.first { $0.id == item.id } ?? item }
  var body: some View {
    Button {
      model.save(TaskCompletion.toggled(task))
    } label: {
      Image(systemName: task.body["status"] == "Done" ? "checkmark.circle.fill" : "circle")
        .font(.system(size: 17, weight: .regular))
        .foregroundStyle(task.body["status"] == "Done" ? BeeTheme.mint : BeeTheme.accent)
        .frame(width: 24, height: 24).contentShape(Rectangle())
    }.buttonStyle(.plain)
      .help(L10n.text(task.body["status"] == "Done" ? "Mark as to do" : "Mark as done"))
      .accessibilityLabel(
        L10n.text(task.body["status"] == "Done" ? "Mark as to do" : "Mark as done"))
  }
}
enum TaskCompletion {
  static func normalized(_ input: Item, previous: Item?) -> Item {
    guard input.kind == "tasks" else { return input }
    var task = input
    if task.body["status"] == "Done" {
      task.body["archived"] = "true"
    } else if previous?.body["status"] == "Done" {
      task.body["archived"] = "false"
    }
    return task
  }
  static func toggled(_ task: Item) -> Item {
    guard task.kind == "tasks", !task.deleted else { return task }
    var changed = task
    changed.body["status"] = task.body["status"] == "Done" ? "To do" : "Done"
    changed.body["archived"] = changed.body["status"] == "Done" ? "true" : "false"
    return changed
  }
}
enum AttachmentFile {
  static func link(owner: Item, fileID: String) -> Item {
    let kind = ["crm_contacts", "crm_actions"].contains(owner.kind) ? "crm_attachments" :
      owner.kind == "tasks"
      ? "task_attachments" : owner.kind == "notes" ? "note_attachments" : "reminder_attachments"
    return Item(kind: kind, body: ["ownerID": owner.id, "fileID": fileID])
  }
}
struct ImportedFile: Sendable {
  let checksum: String
  let size: UInt64
  static func prepare(_ source: URL, target: URL) throws -> ImportedFile {
    if source != target {
      if FileManager.default.fileExists(atPath: target.path) {
        try FileManager.default.removeItem(at: target)
      }
      try FileManager.default.copyItem(at: source, to: target)
    }
    let handle = try FileHandle(forReadingFrom: target)
    defer { try? handle.close() }
    var digest = SHA256()
    var size: UInt64 = 0
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
      digest.update(data: chunk)
      size += UInt64(chunk.count)
    }
    return ImportedFile(
      checksum: digest.finalize().map { String(format: "%02x", $0) }.joined(), size: size)
  }
}
