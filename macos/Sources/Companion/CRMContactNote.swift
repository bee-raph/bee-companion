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

struct CRMContactNote: View {
  @EnvironmentObject var model: AppModel
  let contact: Item
  @StateObject private var editing = NoteEditing()

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(L10n.text("Contact note")).font(.headline)
      NoteToolbar(editor: editing)
      NoteTextEditor(
        text: .constant(CRMNoteDocument.text(contact)),
        rtf: .constant(contact.body["rtf"] ?? ""),
        rtfd: .constant(contact.body["rtfd"] ?? ""),
        rich: true, editor: editing, commit: commit
      ).frame(minHeight: 360)
    }
  }

  private func commit(_ text: String, _ rtf: String, _ rtfd: String) {
    guard let latest = model.items.first(where: { $0.id == contact.id }), !latest.deleted else {
      return
    }
    model.save(CRMNoteDocument.updating(latest, text: text, rtf: rtf, rtfd: rtfd))
  }
}
