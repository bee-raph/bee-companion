import AppKit
import SwiftUI

/// A contact owns one rich document in its synchronized record.
enum CRMNoteDocument {
  static let fields = ["text", "format", "rtf", "rtfd", "notes"]

  static func text(_ contact: Item) -> String {
    contact.body["text"] ?? contact.body["notes"] ?? ""
  }

  static func updating(_ contact: Item, text: String, rtf: String, rtfd: String) -> Item {
    var updated = contact
    updated.body["text"] = text
    updated.body["format"] = "rtf"
    updated.body["rtf"] = rtf
    updated.body["rtfd"] = rtfd
    updated.body.removeValue(forKey: "notes")
    return updated
  }

  static func preservingNote(in draft: Item, from latest: Item) -> Item {
    var updated = draft
    for key in fields { updated.body[key] = latest.body[key] }
    return updated
  }
}

final class CRMLoadedNote: @unchecked Sendable {
  let document: NSAttributedString
  init(_ contact: Item) {
    document =
      NoteDocument.decode(rtf: contact.body["rtf"] ?? "", rtfd: contact.body["rtfd"] ?? "")
      ?? NSAttributedString(string: CRMNoteDocument.text(contact))
  }

  static func load(_ contact: Item) async -> CRMLoadedNote {
    await withCheckedContinuation { continuation in
      NoteSnapshot.queue.async {
        continuation.resume(returning: CRMLoadedNote(contact))
      }
    }
  }
}

struct CRMContactNote: View {
  @EnvironmentObject var model: AppModel
  let contact: Item
  @StateObject private var editing = NoteEditing()
  @State private var loaded: CRMLoadedNote?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.text("Contact note")).font(.headline)
      if let loaded {
        NoteToolbar(editor: editing)
        NoteTextEditor(
          text: .constant(CRMNoteDocument.text(contact)),
          rtf: .constant(contact.body["rtf"] ?? ""),
          rtfd: .constant(contact.body["rtfd"] ?? ""),
          rich: true, editor: editing, commit: commit, initialDocument: loaded.document
        ).frame(minHeight: 360)
      } else {
        ProgressView(L10n.text("Loading contact note…"))
          .frame(maxWidth: .infinity, minHeight: 360)
      }
    }
    .task(id: contact.id) {
      let result = await CRMLoadedNote.load(contact)
      guard !Task.isCancelled else { return }
      loaded = result
    }
  }

  private func commit(_ text: String, _ rtf: String, _ rtfd: String) {
    guard let latest = model.items.first(where: { $0.id == contact.id }), !latest.deleted else {
      return
    }
    model.save(CRMNoteDocument.updating(latest, text: text, rtf: rtf, rtfd: rtfd))
  }
}
