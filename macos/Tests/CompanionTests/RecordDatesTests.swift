import Foundation
import XCTest

@testable import Companion

final class RecordDatesTests: XCTestCase {
  func testCreationEditsAndStaleDraftsForEverySupportedKind() {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    for kind in RecordDates.kinds {
      let draft = Item(kind: kind, body: ["title": "Original"])
      let created = RecordDates.recording(draft, previous: nil, now: start)
      XCTAssertEqual(created.body["createdAt"].flatMap(ItemTimestamp.date), start)
      XCTAssertEqual(created.body["updatedAt"], created.body["createdAt"])
      var edited = draft
      edited.body["title"] = "Edited"
      let saved = RecordDates.recording(
        edited, previous: created, now: start.addingTimeInterval(60))
      XCTAssertEqual(saved.body["createdAt"], created.body["createdAt"])
      XCTAssertEqual(
        saved.body["updatedAt"].flatMap(ItemTimestamp.date), start.addingTimeInterval(60))
      let noChange = RecordDates.recording(
        edited, previous: saved, now: start.addingTimeInterval(120))
      XCTAssertEqual(noChange, saved)
      var duplicate = saved
      duplicate.id = UUID().uuidString
      duplicate.revision = 0
      XCTAssertNotEqual(
        RecordDates.recording(duplicate, previous: nil, now: start.addingTimeInterval(180)).body[
          "createdAt"], saved.body["createdAt"])
    }
  }

  func testExistingDatesAreNotInventedAndDeletesCountAsUpdates() {
    let old = Item(kind: "notes", revision: 3, body: ["title": "Old"])
    XCTAssertEqual(RecordDates.recording(old, previous: old), old)
    var edited = old
    edited.body["text"] = "New content"
    let recorded = RecordDates.recording(edited, previous: old)
    XCTAssertNil(recorded.body["createdAt"])
    XCTAssertNotNil(recorded.body["updatedAt"])
    edited = recorded
    edited.deleted = true
    let deleted = RecordDates.recording(
      edited, previous: recorded, now: Date().addingTimeInterval(60))
    XCTAssertNotEqual(deleted.body["updatedAt"], recorded.body["updatedAt"])
  }

  func testDatesPersistThroughOutboxAndPullWithoutChanging() throws {
    let first = try LocalStore(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"))
    let second = try LocalStore(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"))
    let item = RecordDates.recording(
      Item(kind: "crm_contacts", body: ["title": "Contact"]), previous: nil)
    try first.save(item)
    let pending = try XCTUnwrap(first.nextMutation())
    XCTAssertEqual(pending.body, item.body)
    var remote = item
    remote.revision = 1
    try first.accept(
      .init(operationID: pending.operationID, status: "applied", record: remote, server: nil))
    try second.apply(PullResult(changes: [remote], cursor: 1, hasMore: false))
    XCTAssertEqual(try first.all().first?.body, item.body)
    XCTAssertEqual(try second.all().first?.body, item.body)
  }
}
