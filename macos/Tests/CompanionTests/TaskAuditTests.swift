import Foundation
import XCTest

@testable import Companion

final class TaskAuditTests: XCTestCase {
  func testCreationTransitionsAndStaleEditorPreserveHistory() throws {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let draft = Item(kind: "tasks", body: ["title": "Task", "status": "To do"])
    let created = TaskAudit.recording(draft, previous: nil, now: start)
    XCTAssertEqual(TaskAudit.entries(created).count, 1)
    XCTAssertEqual(TaskAudit.entries(created).first?.date, start)
    XCTAssertNil(TaskAudit.entries(created).first?.from)
    var edited = draft
    edited.body["title"] = "Edited"
    let unchanged = TaskAudit.recording(edited, previous: created, now: start.addingTimeInterval(1))
    XCTAssertEqual(TaskAudit.entries(unchanged), TaskAudit.entries(created))
    edited.body["status"] = "In progress"
    let progress = TaskAudit.recording(
      edited, previous: unchanged, now: start.addingTimeInterval(2))
    let done = TaskAudit.recording(
      TaskCompletion.toggled(progress), previous: progress, now: start.addingTimeInterval(3))
    let reopened = TaskAudit.recording(
      TaskCompletion.toggled(done), previous: done, now: start.addingTimeInterval(4))
    XCTAssertEqual(
      TaskAudit.entries(reopened).map(\.status), ["To do", "In progress", "Done", "To do"])
    XCTAssertEqual(TaskAudit.entries(reopened).map(\.from), [nil, "To do", "In progress", "Done"])
    XCTAssertEqual(reopened.body["taskCreatedAt"], created.body["taskCreatedAt"])
  }

  func testConflictResolutionPreservesBothStatusHistories() throws {
    let store = try LocalStore(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"))
    let original = TaskAudit.recording(Item(kind: "tasks"), previous: nil)
    var local = original
    local.body["status"] = "In progress"
    local = TaskAudit.recording(local, previous: original)
    var server = original
    server.body["status"] = "Cancelled"
    server = TaskAudit.recording(server, previous: original)
    server.revision = 1
    try store.resolve(Conflict(id: original.id, local: local, server: server), keepLocal: false)
    let resolved = try XCTUnwrap(store.all().first)
    XCTAssertEqual(resolved.body["status"], "Cancelled")
    XCTAssertEqual(
      Set(TaskAudit.entries(resolved).map(\.status)), ["To do", "In progress", "Cancelled"])
    XCTAssertEqual(TaskAudit.entries(resolved).count, 3)
    XCTAssertEqual(try store.pending().first?.body, resolved.body)
  }

  func testLegacyTaskDoesNotInventCreationDate() {
    let old = Item(kind: "tasks", revision: 4, body: ["title": "Old task"])
    let edited = TaskAudit.recording(old, previous: old)
    XCTAssertNil(edited.body["taskCreatedAt"])
    XCTAssertTrue(TaskAudit.entries(edited).isEmpty)
    var changed = old
    changed.body["status"] = "Cancelled"
    let recorded = TaskAudit.recording(changed, previous: old)
    XCTAssertNil(recorded.body["taskCreatedAt"])
    XCTAssertEqual(TaskAudit.entries(recorded).first?.from, "To do")
    XCTAssertEqual(TaskAudit.entries(recorded).first?.status, "Cancelled")
  }

  func testOfflineTransitionsSurviveCoalescingAndSync() throws {
    let store = try LocalStore(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"))
    var task = TaskAudit.recording(Item(kind: "tasks"), previous: nil)
    try store.save(task)
    for status in ["In progress", "Done", "To do", "Cancelled"] {
      var changed = task
      changed.body["status"] = status
      task = TaskAudit.recording(changed, previous: task)
      try store.save(task)
    }
    let mutation = try XCTUnwrap(store.nextMutation())
    XCTAssertEqual(mutation.body["taskAudit"], task.body["taskAudit"])
    var remote = task
    remote.revision = 1
    try store.accept(
      .init(operationID: mutation.operationID, status: "applied", record: remote, server: nil))
    XCTAssertEqual(TaskAudit.entries(try XCTUnwrap(store.all().first)), TaskAudit.entries(task))
  }
}
