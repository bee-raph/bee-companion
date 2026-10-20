import AppKit
import Foundation
import XCTest

@testable import Companion

final class CRMTests: XCTestCase {
  @MainActor func testContactRichNotePreservesFormattingImagesAndOneRecord() throws {
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let wrapper = FileWrapper(regularFileWithContents: png)
    wrapper.preferredFilename = "image.png"
    let document = NSMutableAttributedString(
      string: "Contact note\n",
      attributes: [
        .font: NSFont.boldSystemFont(ofSize: 24),
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ])
    document.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
    let encoded = try NoteSnapshot(document, rich: true).encode()
    let contact = Item(
      kind: "crm_contacts", body: ["title": "Client", "emails": "client@example.com"])
    let updated = CRMNoteDocument.updating(
      contact, text: encoded.text, rtf: encoded.rtf, rtfd: encoded.rtfd)
    let local = try LocalStore(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"))
    try local.save(contact)
    try local.save(updated)
    XCTAssertEqual(try local.all().count, 1)
    XCTAssertEqual(try local.pendingCount(), 1)
    let saved = try XCTUnwrap(try local.all().first)
    XCTAssertEqual(saved.id, contact.id)
    XCTAssertEqual(saved.body["emails"], contact.body["emails"])
    let reopened = try XCTUnwrap(
      NoteDocument.decode(rtf: saved.body["rtf"] ?? "", rtfd: saved.body["rtfd"] ?? ""))
    XCTAssertEqual(reopened.string, document.string)
    let font = try XCTUnwrap(reopened.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    XCTAssertEqual(font.pointSize, 24)
    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    XCTAssertEqual(
      reopened.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
      NSUnderlineStyle.single.rawValue)
    XCTAssertNotNil(reopened.attribute(.attachment, at: reopened.length - 1, effectiveRange: nil))
    let mutation = try XCTUnwrap(local.nextMutation())
    let server = Item(id: saved.id, kind: saved.kind, revision: 1, body: mutation.body)
    let otherDevice = try LocalStore(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"))
    try otherDevice.apply(PullResult(changes: [server], cursor: 1, hasMore: false))
    XCTAssertEqual(try otherDevice.all().first?.body, saved.body)
  }

  func testContactDetailsPreserveLatestNoteAndLegacyText() {
    let contact = Item(kind: "crm_contacts", body: ["title": "Client", "notes": "Existing note"])
    XCTAssertEqual(CRMNoteDocument.text(contact), "Existing note")
    var draft = contact
    draft.body["title"] = "Updated client"
    let latest = CRMNoteDocument.updating(
      contact, text: "New note", rtf: "rtf-data", rtfd: "image-data")
    let merged = CRMNoteDocument.preservingNote(in: draft, from: latest)
    XCTAssertEqual(merged.body["title"], "Updated client")
    XCTAssertEqual(merged.body["text"], "New note")
    XCTAssertEqual(merged.body["rtf"], "rtf-data")
    XCTAssertEqual(merged.body["rtfd"], "image-data")
    XCTAssertNil(merged.body["notes"])
    let cleared = CRMNoteDocument.updating(latest, text: "", rtf: "", rtfd: "")
    XCTAssertEqual(CRMNoteDocument.text(cleared), "")
  }

  func testInternationalNumbersAndLinks() throws {
    let french = try XCTUnwrap(CRMPhone.parse("+33 6 89 01 73 83"))
    XCTAssertEqual(french.e164, "+33689017383")
    XCTAssertEqual(french.formatted, "+33 6 89 01 73 83")
    XCTAssertEqual(french.flag, "🇫🇷")
    XCTAssertEqual(french.whatsapp?.absoluteString, "https://wa.me/33689017383")
    XCTAssertEqual(french.telephone?.absoluteString, "tel:+33689017383")
    XCTAssertEqual(CRMPhone.parse("+44 20 7031 3000")?.flag, "🇬🇧")
    XCTAssertEqual(CRMPhone.parse("+1 416 555 0123")?.flag, "🇨🇦")
    XCTAssertNil(CRMPhone.parse("0501234567"))
    XCTAssertNil(CRMPhone.parse("+123"))
    XCTAssertNil(CRMPhone.parse("not a number"))
  }
  func testActionReminderLookupIncludesSnoozesAndExcludesOtherActions() {
    let action = Item(kind: "crm_actions")
    let alarm = Item(id: CRM.reminderID(action), kind: "reminders")
    let snooze = Item(kind: "reminders", body: ["actionID": action.id])
    var deleted = snooze
    deleted.id = UUID().uuidString.lowercased()
    deleted.deleted = true
    let other = Item(kind: "reminders", body: ["actionID": UUID().uuidString.lowercased()])
    XCTAssertEqual(
      CRM.reminders(for: action, in: [alarm, snooze, deleted, other]), [alarm, snooze])
  }
  func testCRMOfflinePersistenceAndAttachmentOwnership() throws {
    let store = try LocalStore(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"))
    let contact = Item(
      kind: "crm_contacts",
      body: ["title": "שלום", "identityType": "Individual", "contactType": "Client"])
    let action = Item(kind: "crm_actions", body: ["title": "Call", "contactID": contact.id])
    let file = Item(kind: "files", body: ["title": "invoice.pdf"])
    for owner in [contact, action] {
      let link = AttachmentFile.link(owner: owner, fileID: file.id)
      XCTAssertEqual(link.kind, "crm_attachments")
      XCTAssertEqual(link.body["ownerID"], owner.id)
      try store.save(owner)
      try store.save(link)
    }
    XCTAssertEqual(try store.pendingCount(), 4)
    XCTAssertEqual(try store.all().filter { $0.kind == "crm_contacts" }.first, contact)
    XCTAssertNotEqual(CRM.reminderID(action), action.id)
    XCTAssertEqual(CRM.reminderID(action), CRM.reminderID(action))
    XCTAssertNotNil(UUID(uuidString: CRM.reminderID(action)))
  }
}
