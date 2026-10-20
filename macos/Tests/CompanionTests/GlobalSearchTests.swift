import Foundation
import XCTest

@testable import Companion

final class GlobalSearchTests: XCTestCase {
  func store() throws -> LocalStore {
    try LocalStore(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"))
  }
  func testSearchFindsFullBodiesAndAllWorkspaceKinds() throws {
    let store = try store()
    let note = Item(
      kind: "notes",
      body: [
        "title": "Note",
        "text": String(repeating: "earlier content ", count: 3000) + "Needlemark deep content",
      ])
    let reminder = Item(
      kind: "reminders",
      body: ["title": "Reminder", "description": "Needlemark reminder description"])
    let task = Item(
      kind: "tasks", body: ["title": "Task", "description": "Needlemark task description"])
    let contact = Item(
      kind: "crm_contacts",
      body: [
        "title": "Client", "company": "Needlemark company", "text": "Contact rich note plain text",
      ])
    for item in [note, reminder, task, contact] { try store.save(item) }
    let matches = try store.globalSearch("Needlemark")
    XCTAssertEqual(Set(matches.map(\.id)), Set([note.id, reminder.id, task.id, contact.id]))
    XCTAssertTrue(try XCTUnwrap(matches.first { $0.id == note.id }).excerpt.contains("Needlemark"))
    XCTAssertEqual(try store.globalSearch("Needlema").count, 4)
    XCTAssertEqual(try store.globalSearch("rich note").map(\.id), [contact.id])
  }

  func testContactIdentityEmailPhoneSuffixAndUnicodeSearch() throws {
    let store = try store()
    let contact = Item(
      kind: "crm_contacts",
      body: [
        "title": "Élodie שלום", "firstName": "Élodie", "lastName": "Иванова",
        "emails": "billing@example.com", "mobiles": "+972502345678", "addresses": "Rue des Lilas",
      ])
    try store.save(contact)
    for query in ["elodie", "שלום", "иванова", "example.com", "345678", "Lilas", "billing@"] {
      XCTAssertEqual(try store.globalSearch(query).map(\.id), [contact.id], query)
    }
    XCTAssertNoThrow(try store.globalSearch("\" OR *"))
    XCTAssertNoThrow(try store.globalSearch("@"))
    XCTAssertTrue(try store.globalSearch("   ").isEmpty)
  }

  func testResultsExcludeTrashFilesAndEncodedDocumentsAndIncludeArchives() throws {
    let store = try store()
    let archived = Item(kind: "tasks", body: ["title": "Needlemark", "status": "Done"])
    let deleted = Item(kind: "notes", body: ["title": "Needlemark"], deleted: true)
    let file = Item(kind: "files", body: ["title": "Needlemark.pdf"])
    let rich = Item(
      kind: "notes",
      body: ["title": "Visible", "rtf": "Needlemark hiddenrtftoken", "rtfd": "hiddenimagetoken"])
    for item in [archived, deleted, file, rich] { try store.save(item) }
    let matches = try store.globalSearch("Needlemark")
    XCTAssertEqual(matches.map(\.id), [archived.id])
    XCTAssertTrue(try store.globalSearch("hiddenrtftoken").isEmpty)
    XCTAssertTrue(try store.globalSearch("hiddenimagetoken").isEmpty)
    XCTAssertEqual(
      WorkspaceSearchIndex.resolve(matches, items: [archived]).first?.destination, .archive)
  }

  func testMatchingCRMActionsOpenTheirContactOnce() throws {
    let contact = Item(kind: "crm_contacts", body: ["title": "Client"])
    let action = Item(
      kind: "crm_actions",
      body: ["title": "Invoice", "contactID": contact.id, "description": "Payment needlemark"])
    let store = try store()
    try store.save(contact)
    try store.save(action)
    let matches = try store.globalSearch("needlemark")
    let results = WorkspaceSearchIndex.resolve(matches + matches, items: [contact, action])
    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first?.id, contact.id)
    XCTAssertEqual(results.first?.destination, .crm)
    XCTAssertTrue(results.first?.excerpt.contains("Invoice") == true)
    var deleted = contact
    deleted.deleted = true
    XCTAssertTrue(WorkspaceSearchIndex.resolve(matches, items: [deleted, action]).isEmpty)
  }

  func testSearchUpdatesAfterLocalEditsAndRemotePullAndRoutesEveryKind() throws {
    let store = try store()
    var note = Item(kind: "notes", body: ["title": "Draft", "text": "oldsearchtoken"])
    try store.save(note)
    note.body["text"] = "newsearchtoken"
    try store.save(note)
    XCTAssertTrue(try store.globalSearch("oldsearchtoken").isEmpty)
    XCTAssertEqual(try store.globalSearch("newsearchtoken").map(\.id), [note.id])
    let remote = Item(
      kind: "crm_contacts", revision: 3, body: ["title": "Remote", "emails": "remote@example.net"])
    try store.apply(PullResult(changes: [remote], cursor: 1, hasMore: false))
    XCTAssertEqual(try store.globalSearch("remote@example.net").map(\.id), [remote.id])
    for (kind, section) in [
      ("notes", Section.notes), ("tasks", .tasks), ("reminders", .alarms), ("crm_contacts", .crm),
    ] {
      let item = Item(kind: kind)
      XCTAssertEqual(WorkspaceSearchResult(item: item, excerpt: "").destination, section)
    }
  }

  func testSearchMigrationReindexesExistingContactIdentity() throws {
    let store = try store()
    let contact = Item(
      kind: "crm_contacts", body: ["title": "Existing", "emails": "existing@search.example"])
    try store.save(contact)
    try store.db.write { db in
      try db.execute(sql: "UPDATE search SET body='' WHERE id=?", arguments: [contact.id])
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v5-workspace-search'")
    }
    XCTAssertTrue(try store.globalSearch("existing@search.example").isEmpty)
    let migrated = try LocalStore(url: URL(fileURLWithPath: store.db.path))
    XCTAssertEqual(try migrated.globalSearch("existing@search.example").map(\.id), [contact.id])
  }
}
