import AppKit
import CryptoKit
import Foundation
import XCTest

@testable import Companion

final class ResponsivenessTests: XCTestCase {
  func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @MainActor func testBackgroundWorkDoesNotRunOnUIThread() async throws {
    let onMain = try await BackgroundWork.run { Thread.isMainThread }
    XCTAssertFalse(onMain)
  }

  func testChunkedReadsAndChecksumPreserveFileBytes() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("large.bin")
    let data = Data((0..<2_300_007).map { UInt8($0 % 251) })
    try data.write(to: file)
    var copied = Data()
    while copied.count < data.count {
      let chunk = try FileWork.chunk(file, offset: copied.count, count: 1024 * 1024)
      XCTAssertLessThanOrEqual(chunk.count, 1024 * 1024)
      copied.append(chunk)
    }
    XCTAssertEqual(copied, data)
    XCTAssertTrue(try FileWork.chunk(file, offset: data.count, count: 1024).isEmpty)
    XCTAssertEqual(
      try FileWork.checksum(file),
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
  }

  func testStagedCopyKeepsExistingWorkingEditsAndSupportsReplacement() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let target = root.appendingPathComponent("subfolder/working")
    try Data("original".utf8).write(to: source)
    try FileWork.copy(source, to: target)
    try Data("user edits".utf8).write(to: target)
    try FileWork.copy(source, to: target, overwrite: false)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "user edits")
    try FileWork.copy(source, to: target)
    XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path),
      ["working"])
  }

  func testWorkingCopyScannerDetectsEditsAfterRepeatedScans() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let item = Item(kind: "files", body: ["title": "document.txt"])
    let file = root.appendingPathComponent("working").appendingPathComponent(item.id)
      .appendingPathComponent(item.title)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("original".utf8).write(to: file)
    var stored = item
    stored.body["checksum"] = try FileWork.checksum(file)
    let scanner = WorkingCopyScanner()
    let initial = await scanner.changes(in: [stored], cache: root)
    XCTAssertTrue(initial.isEmpty)
    try Data("edited document".utf8).write(to: file)
    let edited = await scanner.changes(in: [stored], cache: root)
    XCTAssertEqual(edited.map(\.item.id), [item.id])
    let repeated = await scanner.changes(in: [stored], cache: root)
    XCTAssertEqual(repeated.map(\.item.id), [item.id])
    stored.body["checksum"] = try FileWork.checksum(file)
    let uploaded = await scanner.changes(in: [stored], cache: root)
    XCTAssertTrue(uploaded.isEmpty)
  }

  func testAgendaDayCountsExcludeNonAgendaAndInactiveRecords() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
    let date = "2026-10-20T23:00:00Z"
    let items = [
      Item(kind: "tasks", body: ["date": date]),
      Item(kind: "reminders", body: ["date": date]),
      Item(kind: "tasks", body: ["date": date, "status": "Done"]),
      Item(kind: "tasks", body: ["date": date, "status": "Cancelled"]),
      Item(kind: "crm_actions", body: ["date": date]),
      Item(kind: "notes", body: ["date": date]),
      Item(kind: "reminders", body: ["date": date], deleted: true),
    ]
    let counts = AgendaDayCounts.values(events: [], items: items, calendar: calendar)
    let day = calendar.startOfDay(for: try XCTUnwrap(ItemTimestamp.date(date)))
    XCTAssertEqual(counts, [day: 2])
    XCTAssertEqual(calendar.component(.day, from: day), 21)
  }

  @MainActor func testEditingAgainAfterBackgroundAcknowledgementKeepsRevisionAndDraft() async throws
  {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalStore(url: root.appendingPathComponent("library.sqlite"))
    var item = Item(kind: "notes", body: ["title": "Note", "text": "First"])
    try store.save(item)
    let operation = try XCTUnwrap(store.nextMutation())
    item.body["text"] = "During sync"
    try store.save(item)
    var server = item
    server.body["text"] = "First"
    server.revision = 1
    let acknowledged = server
    try await BackgroundWork.run {
      try store.accept(
        .init(operationID: operation.operationID, status: "applied", record: acknowledged))
    }
    item.body["text"] = "Latest edit"
    try store.save(item)
    let pending = try XCTUnwrap(store.pending().first)
    XCTAssertEqual(pending.expectedRevision, 1)
    XCTAssertEqual(pending.body["text"], "Latest edit")
    XCTAssertEqual(try store.all().first?.body["text"], "Latest edit")
    XCTAssertEqual(try store.all().first?.revision, 1)
  }

  @MainActor func testImagePreparationDownsamplesOffMainThread() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2400, pixelsHigh: 1200,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let source = root.appendingPathComponent("image.png")
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)
    let prepared = try await BackgroundWork.run { try NoteImageWork.prepare(source) }
    let resized = try XCTUnwrap(NSBitmapImageRep(data: prepared))
    XCTAssertEqual(resized.pixelsWide, 1200)
    XCTAssertEqual(resized.pixelsHigh, 600)
    let invalid = root.appendingPathComponent("invalid.png")
    try Data("not an image".utf8).write(to: invalid)
    XCTAssertThrowsError(try NoteImageWork.prepare(invalid))
  }

  func testTimestampOffsetsFractionsAndInvalidValues() throws {
    let utc = try XCTUnwrap(ItemTimestamp.date("2026-10-20T10:00:00Z"))
    XCTAssertEqual(ItemTimestamp.date("2026-10-20T13:00:00+03:00"), utc)
    XCTAssertEqual(
      try XCTUnwrap(ItemTimestamp.date("2026-10-20T10:00:00.125Z")).timeIntervalSince(utc), 0.125,
      accuracy: 0.001)
    XCTAssertNil(ItemTimestamp.date("invalid"))
    XCTAssertNil(ItemTimestamp.date(""))
    XCTAssertEqual(
      Item(kind: "reminders", body: ["date": "2026-10-20T10:00:00.125Z"]).date,
      utc.addingTimeInterval(0.125))
  }

  func testLargeAgendaAndReminderDateParsingPerformance() {
    let parser = TimestampParser()
    let values = (0..<1000).map {
      String(format: "2026-10-20T%02d:%02d:00Z", ($0 / 60) % 24, $0 % 60)
    }
    for value in values { XCTAssertNotNil(parser.date(value)) }
    measure { for value in values { _ = parser.date(value) } }
  }

  @MainActor func testNoteImportExportAndBackgroundMarkdownLoad() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let rich = NSAttributedString(
      string: "Styled note", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
    let encoded = try NoteSnapshot(rich, rich: true).encode()
    let item = Item(
      kind: "notes",
      body: ["title": "Note", "format": "rtf", "text": encoded.text, "rtf": encoded.rtf])
    let file = root.appendingPathComponent("note.rtf")
    try await BackgroundWork.run { try NoteFileWork.write(item, format: "rtf", to: file) }
    let imported = try await BackgroundWork.run { try NoteFileWork.read(file) }
    let loaded = await LoadedNoteDocument.load(imported)
    XCTAssertEqual(loaded.document.string, rich.string)
    let font = try XCTUnwrap(
      loaded.document.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    XCTAssertEqual(font.pointSize, 20)
    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    let markdown = await LoadedNoteDocument.load(
      Item(kind: "notes", body: ["text": "**Bold** text", "format": "markdown"]))
    XCTAssertEqual(markdown.document.string, "Bold text")
    let bold = try XCTUnwrap(
      markdown.document.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
  }

  func testReaderCacheHandlesMissingCorruptAndSavedContent() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("rss.json")
    let missing = await ReaderCache.read(RSSResponse.self, from: url)
    XCTAssertNil(missing)
    try Data("broken JSON".utf8).write(to: url)
    let corrupt = await ReaderCache.read(RSSResponse.self, from: url)
    XCTAssertNil(corrupt)
    try await ReaderCache.write(RSSResponse(feeds: []), to: url)
    let saved = await ReaderCache.read(RSSResponse.self, from: url)
    XCTAssertEqual(saved?.feeds.count, 0)
  }
}
