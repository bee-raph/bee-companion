import AppKit
import EventKit
import XCTest

@testable import Companion

final class CompanionTests: XCTestCase {
  func store() throws -> LocalStore {
    try LocalStore(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"))
  }
  func testAtomicOfflineAndSearch() throws {
    let local = try store()
    let item = Item(kind: "notes", body: ["title": "שלום", "text": "alpha beta"])
    try local.save(item)
    XCTAssertEqual(try local.all(), [item])
    XCTAssertEqual(try local.pending().count, 1)
    XCTAssertTrue(try local.search("alpha").contains(item.id))
    XCTAssertTrue(try local.search("שלום").contains(item.id))
    XCTAssertTrue(try local.search("alpha beta").contains(item.id))
  }
  func testPreserveEditDuringSyncAndRebase() throws {
    let local = try store()
    var item = Item(kind: "notes", body: ["title": "First"])
    try local.save(item)
    let operation = try XCTUnwrap(local.nextMutation())
    item.body["title"] = "Later"
    try local.save(item)
    var server = item
    server.body["title"] = "First"
    server.revision = 1
    try local.accept(.init(operationID: operation.operationID, status: "applied", record: server))
    XCTAssertEqual(try local.all()[0].title, "Later")
    XCTAssertEqual(try local.pending()[0].expectedRevision, 1)
    try local.apply(.init(changes: [server], cursor: 1, hasMore: false))
    XCTAssertEqual(try local.all()[0].title, "Later")
  }
  func testConflictsSurvivePull() throws {
    let local = try store()
    let item = Item(kind: "notes", body: ["title": "Mine"])
    try local.save(item)
    let operation = try XCTUnwrap(local.nextMutation())
    var server = item
    server.body["title"] = "Theirs"
    server.revision = 2
    try local.accept(.init(operationID: operation.operationID, status: "conflict", server: server))
    try local.apply(.init(changes: [server], cursor: 2, hasMore: false))
    XCTAssertEqual(try local.all()[0].title, "Mine")
    XCTAssertEqual(try local.conflicts().count, 1)
    try local.resolve(local.conflicts()[0], keepLocal: true)
    XCTAssertEqual(try local.pending()[0].expectedRevision, 2)
  }
  func testRejectRemoteHTTP() throws {
    let config = InstanceConfiguration(
      configurationVersion: 1, instanceName: "Test", instanceID: UUID().uuidString,
      apiBaseURL: URL(string: "http://example.com")!, apiVersion: 1)
    XCTAssertThrowsError(try config.validate())
  }
  func testMonthlySkipsMissingDays() {
    let formatter = ISO8601DateFormatter()
    let item = Item(
      kind: "reminders",
      body: ["date": "2026-01-31T10:00:00Z", "timezone": "UTC", "recurrence": "Monthly"])
    let dates = Recurrence.occurrences(
      item, after: formatter.date(from: "2026-01-30T00:00:00Z")!,
      until: formatter.date(from: "2026-04-01T00:00:00Z")!)
    XCTAssertEqual(
      dates.map { formatter.string(from: $0) }, ["2026-01-31T10:00:00Z", "2026-03-31T10:00:00Z"])
  }
  func testDraftCoalescingAndStaleEditorRevision() throws {
    let local = try store()
    var item = Item(kind: "notes", body: ["title": "First"])
    try local.save(item)
    item.body["title"] = "Second"
    try local.save(item)
    XCTAssertEqual(try local.pending().count, 1)
    let operation = try XCTUnwrap(local.nextMutation())
    var server = item
    server.revision = 1
    try local.accept(.init(operationID: operation.operationID, status: "applied", record: server))
    item.body["title"] = "Third"
    try local.save(item)
    XCTAssertEqual(try local.pending()[0].expectedRevision, 1)
  }
  func testDailyWallClockAcrossDST() {
    let formatter = ISO8601DateFormatter()
    let item = Item(
      kind: "reminders",
      body: ["date": "2026-03-07T14:00:00Z", "timezone": "America/New_York", "recurrence": "Daily"])
    let dates = Recurrence.occurrences(
      item, after: formatter.date(from: "2026-03-07T00:00:00Z")!,
      until: formatter.date(from: "2026-03-09T23:00:00Z")!)
    XCTAssertEqual(
      dates.map { formatter.string(from: $0) },
      ["2026-03-07T14:00:00Z", "2026-03-08T13:00:00Z", "2026-03-09T13:00:00Z"])
  }

  @MainActor func testAlarmWindowRepeatedCloseDoesNotOverRelease() async {
    _ = NSApplication.shared
    for _ in 0..<25 {
      autoreleasepool {
        let window = AlarmWindow.make(title: "Lifecycle regression")
        XCTAssertFalse(window.isReleasedWhenClosed)
        window.close()
        // Swift still owns the closed window until this scope ends.
        XCTAssertEqual(window.title, "Reminder · Lifecycle regression")
      }
    }
  }
  func testCalendarSelectionPreservesExplicitEmptyAndIgnoresOldIDs() {
    XCTAssertEqual(
      CalendarSelection.resolve(available: ["work", "home"], stored: nil), Set(["work", "home"]))
    XCTAssertEqual(CalendarSelection.resolve(available: ["work", "home"], stored: []), [])
    XCTAssertEqual(
      CalendarSelection.resolve(available: ["work", "home"], stored: ["work", "removed"]), ["work"])
  }
  @MainActor func testCalendarPermissionFailureShowsActionableState() async {
    let denied = AgendaService(authorization: { .denied })
    denied.refresh(Date())
    XCTAssertTrue(denied.calendars.isEmpty)
    XCTAssertTrue(denied.events.isEmpty)
    XCTAssertTrue(denied.message.contains("System Settings"))
    let undecided = AgendaService(authorization: { .notDetermined })
    undecided.refresh(Date())
    XCTAssertTrue(undecided.message.contains("Enable Apple Calendar"))
  }
  func testNextZmanUsesChronologyAndAbsoluteTime() {
    let entries = ZmanimEntry.sorted([
      "sunset": "2026-10-20T18:00:00+03:00",
      "dawn": "2026-10-20T05:00:00+03:00",
      "midday": "2026-10-20T12:00:00+03:00",
      "invalid": "unavailable",
    ])
    XCTAssertEqual(entries.map(\.id), ["dawn", "midday", "sunset"])
    let clock = ISO8601DateFormatter()
    XCTAssertEqual(
      ZmanimEntry.next(in: entries, now: clock.date(from: "2026-10-20T08:00:00Z")!), "midday")
    XCTAssertEqual(
      ZmanimEntry.next(in: entries, now: clock.date(from: "2026-10-20T15:00:00Z")!), "sunset")
    XCTAssertNil(ZmanimEntry.next(in: entries, now: clock.date(from: "2026-10-20T16:00:00Z")!))
  }
  func testStockSearchIDsDistinguishProviderDatasets() throws {
    let json =
      #"{"instruments":[{"symbol":"AAPL","name":"Apple","category":"Stocks","dataset":"stocks"},{"symbol":"AAPL","name":"Apple options","category":"Options","dataset":"options"}]}"#
    let response = try JSONDecoder().decode(SearchResponse.self, from: Data(json.utf8))
    XCTAssertEqual(response.instruments.count, 2)
    XCTAssertEqual(Set(response.instruments.map(\.id)).count, 2)
    XCTAssertEqual(response.instruments[0].id, "stocks:AAPL")
    XCTAssertEqual(response.instruments[1].id, "options:AAPL")
  }
  func testReaderSettingsValidateAndRoundTripOffline() throws {
    let feeds = (0..<3).map {
      FeedConfiguration(id: "feed-\($0)", title: "Feed \($0)", url: "https://example.com/\($0).xml")
    }
    try ReaderPreferences.validate(feeds)
    XCTAssertThrowsError(
      try ReaderPreferences.validate(feeds + [FeedConfiguration(url: "https://example.com/extra")]))
    XCTAssertThrowsError(
      try ReaderPreferences.validate([FeedConfiguration(url: "file:///etc/passwd")]))
    XCTAssertThrowsError(
      try ReaderPreferences.validate([
        FeedConfiguration(url: "https://user:password@example.com/feed")
      ]))
    let local = try store()
    let item = Item(
      id: "00000000-0000-0000-0000-000000000001", kind: "user_settings",
      body: [
        "rssFeeds": String(decoding: try JSONEncoder().encode(feeds), as: UTF8.self),
        "shabbatRefreshSeconds": "120", "shabbatStocks": "[\"stock-id\"]",
      ])
    try local.save(item)
    XCTAssertEqual(try local.pending()[0].body, item.body)
    let restored = try JSONDecoder().decode(
      [FeedConfiguration].self, from: Data(local.all()[0].body["rssFeeds"]!.utf8))
    XCTAssertEqual(restored, feeds)
    XCTAssertEqual(ReaderPreferences.refreshSeconds(item.body), 120)
    XCTAssertEqual(ReaderPreferences.selectedStocks(item.body), ["stock-id"])
    XCTAssertEqual(ReaderPreferences.refreshSeconds(["shabbatRefreshSeconds": "0"]), 60)
  }
}

final class LocalizationTests: XCTestCase {
  func testLanguagesAndCatalog() throws {
    XCTAssertEqual(AppLanguage.resolve(nil), .english)
    XCTAssertEqual(AppLanguage.resolve("unknown"), .english)
    XCTAssertEqual(AppLanguage.hebrew.direction, .rightToLeft)
    let english = try XCTUnwrap(L10n.catalog["en"])
    XCTAssertGreaterThan(english.count, 250)
    let format = try NSRegularExpression(pattern: "%[-+0-9.]*[@df]|%%")
    func placeholders(_ value: String) -> [String] {
      format.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
        String(value[Range($0.range, in: value)!])
      }
    }
    for language in AppLanguage.allCases {
      let translated = try XCTUnwrap(L10n.catalog[language.rawValue])
      XCTAssertEqual(Set(english.keys), Set(translated.keys))
      for (key, value) in translated {
        XCTAssertFalse(value.isEmpty, key)
        XCTAssertEqual(placeholders(key), placeholders(value), "\(language.rawValue): \(key)")
      }
    }
    XCTAssertEqual(L10n.text("Settings", language: .french), "Réglages")
  }
  func testLanguageSurvivesOfflineStoreAndIncomingSync() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".sqlite")
    let local = try LocalStore(url: url)
    let item = Item(
      id: "00000000-0000-0000-0000-000000000001", kind: "user_settings", body: ["language": "he"])
    try local.save(item)
    XCTAssertEqual(try local.pending().first?.body["language"], "he")
    let reopened = try LocalStore(url: url)
    XCTAssertEqual(try reopened.all().first?.body["language"], "he")
    let operation = try XCTUnwrap(local.nextMutation())
    var server = item
    server.revision = 1
    try local.accept(.init(operationID: operation.operationID, status: "applied", record: server))
    server.body["language"] = "fr"
    server.revision = 2
    try local.apply(.init(changes: [server], cursor: 2, hasMore: false))
    XCTAssertEqual(try local.all().first?.body["language"], "fr")
    XCTAssertEqual(try local.pending().count, 0)
  }
}

final class LocationTests: XCTestCase {
  func testSharedLocationQueryValidationAndCacheIsolation() throws {
    let location = CompanionLocation([
      "latitude": " 31.78 ", "longitude": "35.23", "timezone": "Asia/Jerusalem",
    ])
    let query = try XCTUnwrap(location.query)
    XCTAssertTrue(query.contains("latitude=31.78"))
    XCTAssertTrue(query.contains("longitude=35.23"))
    XCTAssertEqual(
      location.cacheKey("instance"), CompanionLocation(location.body).cacheKey("instance"))
    XCTAssertNotEqual(location.cacheKey("instance"), location.cacheKey("other"))
    XCTAssertNotEqual(
      location.identity, CompanionLocation(["latitude": "0", "longitude": "0"]).identity)
    XCTAssertNil(CompanionLocation(["latitude": "NaN", "longitude": "0"]).query)
    XCTAssertNil(CompanionLocation(["latitude": "91", "longitude": "0"]).query)
  }
  func testProviderDateIsGregorianInSelectedZone() {
    let instant = ISO8601DateFormatter().date(from: "2026-10-20T22:30:00Z")!
    XCTAssertEqual(CompanionLocation(["timezone": "Asia/Jerusalem"]).day(instant), "2026-10-21")
    XCTAssertEqual(CompanionLocation(["timezone": "America/New_York"]).day(instant), "2026-10-20")
  }
}

final class PageIsolationTests: XCTestCase {
  func testSidebarIncludesEveryWorkspaceFeature() {
    XCTAssertTrue(Section.workspace.contains(.crm))
    XCTAssertEqual(Set(Section.workspace), Set(Section.allCases).subtracting([.archive, .settings]))
    XCTAssertEqual(Set(Section.workspace).count, Section.workspace.count)
  }

  func testEveryPageTitleInEveryLanguage() {
    let titles: [AppLanguage: [String]] = [
      .english: [
        "Today", "Tasks", "Files", "CRM", "Notes", "Agenda", "Alarms", "Stocks", "RSS Reader", "Archive",
        "Settings",
      ],
      .hebrew: [
        "היום", "משימות", "קבצים", "CRM", "הערות", "סדר יום", "תזכורות", "מניות", "קורא RSS", "ארכיון",
        "הגדרות",
      ],
      .french: [
        "Aujourd’hui", "Tâches", "Fichiers", "CRM", "Notes", "Agenda", "Rappels", "Marchés", "Lecteur RSS",
        "Archives", "Réglages",
      ],
      .russian: [
        "Сегодня", "Задачи", "Файлы", "CRM", "Заметки", "Календарь", "Напоминания", "Акции", "RSS-лента",
        "Архив", "Настройки",
      ],
      .spanish: [
        "Hoy", "Tareas", "Archivos", "CRM", "Notas", "Agenda", "Recordatorios", "Acciones", "Lector RSS",
        "Archivo", "Configuración",
      ],
    ]
    for language in AppLanguage.allCases {
      XCTAssertEqual(Section.allCases.map { $0.title(language: language) }, titles[language])
    }
  }
  func testNotesPreserveUserTitleAndRejectSelectionsFromOtherPages() {
    let note = Item(kind: "notes", body: ["title": "Stocks to watch"])
    let task = Item(kind: "tasks", body: ["title": "Task"])
    let alarm = Item(kind: "reminders", body: ["title": "Alarm"])
    let stock = Item(kind: "watchlist_items", body: ["title": "Stock"])
    let file = Item(kind: "files", body: ["title": "File"])
    let settings = Item(kind: "user_settings")
    let items = [note, task, alarm, stock, file, settings]
    for (kind, expected) in [("notes", note), ("tasks", task), ("reminders", alarm)] {
      let rows = items.filter { WorkListScope(kind: kind).contains($0) }
      XCTAssertEqual(rows, [expected])
      XCTAssertEqual(CollectionSelection.item(expected.id, in: rows), expected)
      for other in items where other.id != expected.id {
        XCTAssertNil(CollectionSelection.item(other.id, in: rows))
      }
    }
    XCTAssertEqual(note.title, "Stocks to watch")
    XCTAssertEqual(Section.notes.title(language: .english), "Notes")
  }
  func testHiddenDeletedAndArchivedSelectionsCannotOpenEditors() {
    let original = Item(kind: "notes", body: ["title": "Note"])
    var archived = original
    archived.body["archived"] = "true"
    var deleted = original
    deleted.deleted = true
    XCTAssertFalse(WorkListScope(kind: "notes").contains(archived))
    XCTAssertFalse(WorkListScope(kind: "notes").contains(deleted))
    XCTAssertTrue(WorkListScope(kind: nil, archived: true).contains(archived))
    XCTAssertFalse(WorkListScope(kind: nil, archived: true).contains(deleted))
    // Includes switching folders, Trash, filters or pages with an old selection.
    XCTAssertNil(CollectionSelection.item(original.id, in: []))
    XCTAssertNil(CollectionSelection.item(nil, in: [original]))
  }
}

final class NoteEditingTests: XCTestCase {
  func testListsAndMarkdownSyntax() {
    XCTAssertEqual(NoteFormatting.list("First\nSecond\n", numbered: true), "1. First\n2. Second\n")
    XCTAssertEqual(NoteFormatting.list("שלום\nWorld", numbered: false), "• שלום\n• World")
    XCTAssertEqual(
      NoteFormatting.list("First\nSecond", numbered: false, markdown: true), "- First\n- Second")
  }
  @MainActor func testSelectionFormattingAndMarkdownWrapping() throws {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    view.isRichText = true
    view.string = "Hello שלום"
    view.font = .systemFont(ofSize: 14)
    view.setSelectedRange(NSRange(location: 0, length: 5))
    let editor = NoteEditing()
    editor.view = view
    editor.rich = true
    editor.trait(.boldFontMask, markdown: "**")
    editor.trait(.italicFontMask, markdown: "*")
    editor.underline()
    let attrs = try XCTUnwrap(view.textStorage?.attributes(at: 0, effectiveRange: nil))
    let font = try XCTUnwrap(attrs[.font] as? NSFont)
    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
    XCTAssertEqual(attrs[.underlineStyle] as? Int, NSUnderlineStyle.single.rawValue)
    XCTAssertEqual(view.string, "Hello שלום")
    XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 5))
    editor.rich = false
    editor.wrap("**")
    XCTAssertEqual(view.string, "**Hello** שלום")
    XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 5))
  }
  @MainActor func testImageAndFormattingSurviveDocumentAndOfflineStoreRoundTrip() throws {
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ))
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let wrapper = FileWrapper(regularFileWithContents: png)
    wrapper.preferredFilename = "image.png"
    let document = NSMutableAttributedString(
      string: "שלום", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
    document.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
    let data = try document.data(
      from: NSRange(location: 0, length: document.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".sqlite")
    let store = try LocalStore(url: url)
    try store.save(
      Item(
        kind: "notes",
        body: ["format": "rtf", "rtfd": data.base64EncodedString(), "text": document.string]))
    let stored = try XCTUnwrap(store.all().first)
    let decoded = try XCTUnwrap(NoteDocument.decode(rtf: "", rtfd: stored.body["rtfd"] ?? ""))
    XCTAssertEqual(decoded.string, document.string)
    XCTAssertNotNil(decoded.attribute(.attachment, at: decoded.length - 1, effectiveRange: nil))
    XCTAssertEqual((decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 24)
    XCTAssertEqual(try store.pending().count, 1)
  }
}

final class EditorRegressionTests: XCTestCase {
  @MainActor func testEveryFormattingActionPreservesUnselectedText() throws {
    for action in 0..<5 {
      let view = NSTextView(frame: .zero)
      view.isRichText = true
      let original = NSAttributedString(
        string: "left middle right",
        attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.systemRed])
      view.textStorage?.setAttributedString(original)
      let editor = NoteEditing()
      editor.view = view
      editor.rich = true
      // Simulate a popup taking focus after the user selected 'middle'.
      editor.selection = NSRange(location: 5, length: 6)
      view.setSelectedRange(NSRange(location: 0, length: original.length))
      switch action {
      case 0: editor.trait(.boldFontMask, markdown: "**")
      case 1: editor.trait(.italicFontMask, markdown: "*")
      case 2: editor.underline()
      case 3:
        editor.family = "Courier"
        editor.fontFamily()
      default:
        editor.size = 32
        editor.fontSize()
      }
      let storage = try XCTUnwrap(view.textStorage)
      for range in [NSRange(location: 0, length: 5), NSRange(location: 11, length: 6)] {
        XCTAssertTrue(
          storage.attributedSubstring(from: range).isEqual(
            to: original.attributedSubstring(from: range)),
          "Action \(action) changed unselected text")
      }
      XCTAssertEqual(view.string, original.string)
      XCTAssertEqual(view.selectedRange(), NSRange(location: 5, length: 6))
    }
  }
  @MainActor func testCaretFormattingChangesOnlyFutureTyping() throws {
    let view = NSTextView(frame: .zero)
    view.isRichText = true
    let original = NSAttributedString(
      string: "BeforeAfter", attributes: [.font: NSFont.systemFont(ofSize: 13)])
    view.textStorage?.setAttributedString(original)
    view.setSelectedRange(NSRange(location: 6, length: 0))
    let editor = NoteEditing()
    editor.view = view
    editor.rich = true
    editor.trait(.boldFontMask, markdown: "**")
    editor.trait(.italicFontMask, markdown: "*")
    editor.underline()
    editor.family = "Courier"
    editor.fontFamily()
    editor.size = 28
    editor.fontSize()
    XCTAssertTrue(try XCTUnwrap(view.textStorage).isEqual(to: original))
    view.insertText("X", replacementRange: view.selectedRange())
    XCTAssertEqual(view.string, "BeforeXAfter")
    let font = try XCTUnwrap(
      view.textStorage?.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
    XCTAssertEqual(font.pointSize, 28)
    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.italicFontMask))
    XCTAssertEqual(
      view.textStorage?.attribute(.underlineStyle, at: 6, effectiveRange: nil) as? Int,
      NSUnderlineStyle.single.rawValue)
  }
  @MainActor func testTypingBurstCommitsOnceAndFlushesLatestText() {
    let view = NSTextView(frame: .zero)
    view.isRichText = true
    let editor = NoteEditing()
    editor.view = view
    editor.rich = true
    var commits = 0
    var saved = ""
    var imageData = ""
    let parent = NoteTextEditor(
      text: .constant(""), rtf: .constant(""), rtfd: .constant(""), rich: true, editor: editor,
      commit: { text, _, rtfd in
        commits += 1
        saved = text
        imageData = rtfd
      })
    let coordinator = NoteTextEditor.Coordinator(parent)
    coordinator.textView = view
    for index in 0..<100 {
      view.string = "Draft \(index)"
      coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
    }
    XCTAssertEqual(commits, 0)
    coordinator.flush()
    XCTAssertEqual(commits, 1)
    XCTAssertEqual(saved, "Draft 99")
    XCTAssertEqual(imageData, "", "Text-only notes should not serialize duplicate RTFD data")
    coordinator.flush()
    XCTAssertEqual(commits, 1)
    view.string = "Final unsaved text"
    coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
    coordinator.textDidEndEditing(
      Notification(name: NSText.didEndEditingNotification, object: view))
    XCTAssertEqual(commits, 2)
    XCTAssertEqual(saved, "Final unsaved text")
  }
}

final class RichNotesWorkflowTests: XCTestCase {
  func testNoteAndReminderDeletionRequireConfirmation() {
    XCTAssertTrue(DeletionPolicy.requiresConfirmation(Item(kind: "notes")))
    XCTAssertTrue(DeletionPolicy.requiresConfirmation(Item(kind: "reminders")))
    XCTAssertFalse(DeletionPolicy.requiresConfirmation(Item(kind: "tasks")))
    XCTAssertFalse(DeletionPolicy.requiresConfirmation(Item(kind: "note_attachments")))
  }
  @MainActor func testRichTextExportsRealMarkdownAndReopensRich() throws {
    let bold = NSFont.boldSystemFont(ofSize: 14)
    let italic = NSFontManager.shared.convert(
      NSFont.systemFont(ofSize: 14), toHaveTrait: .italicFontMask)
    let document = NSMutableAttributedString(string: "Hello ")
    document.append(NSAttributedString(string: "bold", attributes: [.font: bold]))
    document.append(NSAttributedString(string: " and "))
    document.append(NSAttributedString(string: "italic", attributes: [.font: italic]))
    document.append(NSAttributedString(string: "\n• First\n• Second\n────────────────\n"))
    let markdown = NoteMarkdown.export(document)
    XCTAssertTrue(markdown.contains("**bold**"))
    XCTAssertTrue(markdown.contains("*italic*"))
    XCTAssertTrue(markdown.contains("- First\n- Second"))
    XCTAssertTrue(markdown.contains("\n---\n"))
    let reopened = NoteMarkdown.importText("**שלום** and *world*")
    XCTAssertEqual(reopened.string, "שלום and world")
    let font = try XCTUnwrap(reopened.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
  }
  @MainActor func testMarkdownEmbeddedImageSurvivesRichImportAndExport() throws {
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ))
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let source = "Before ![image](data:image/png;base64," + png.base64EncodedString() + ") after"
    let document = NoteMarkdown.importText(source)
    XCTAssertNotNil(document.attribute(.attachment, at: 7, effectiveRange: nil))
    XCTAssertEqual(NoteMarkdown.export(document), source)
  }
  @MainActor func testBackgroundSnapshotDoesNotReadLaterEditorChanges() async throws {
    let storage = NSMutableAttributedString(
      string: "Saved snapshot", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
    let snapshot = NoteSnapshot(storage, rich: true)
    storage.mutableString.setString("Later typing")
    let done = expectation(description: "Encoded off the main thread")
    NoteSnapshot.queue.async {
      XCTAssertFalse(Thread.isMainThread)
      do {
        let encoded = try snapshot.encode()
        XCTAssertEqual(encoded.text, "Saved snapshot")
        XCTAssertFalse(encoded.rtf.isEmpty)
      } catch { XCTFail(error.localizedDescription) }
      done.fulfill()
    }
    await fulfillment(of: [done], timeout: 5)
  }
}

final class WorkInteractionsTests: XCTestCase {
  func testTaskIconTogglesOnlyCompletionStatus() {
    let task = Item(
      kind: "tasks",
      body: [
        "title": "Task", "description": "Keep this", "status": "In progress",
        "date": "2026-10-20T10:00:00Z",
      ])
    let completed = TaskCompletion.toggled(task)
    XCTAssertEqual(completed.body["status"], "Done")
    XCTAssertEqual(completed.body["description"], task.body["description"])
    XCTAssertEqual(completed.body["date"], task.body["date"])
    XCTAssertEqual(completed.id, task.id)
    XCTAssertEqual(TaskCompletion.toggled(completed).body["status"], "To do")
    let note = Item(kind: "notes")
    XCTAssertEqual(TaskCompletion.toggled(note), note)
  }
  func testAnyLocalFileCanBeCopiedAndAttachedOfflineForEveryOwnerKind() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("שלום.custom-extension")
    let bytes = Data(repeating: 42, count: 1_100_000)
    try bytes.write(to: source)
    for kind in ["tasks", "notes", "reminders"] {
      let owner = Item(kind: kind)
      let file = Item(
        kind: "files", body: ["title": source.lastPathComponent, "uploadPending": "true"])
      let target = root.appendingPathComponent(file.id)
      let prepared = try ImportedFile.prepare(source, target: target)
      XCTAssertEqual(prepared.size, UInt64(bytes.count))
      XCTAssertEqual(prepared.checksum.count, 64)
      XCTAssertEqual(try Data(contentsOf: target), bytes)
      let store = try LocalStore(url: root.appendingPathComponent(kind + ".sqlite"))
      try store.save(owner)
      try store.save(file)
      let link = AttachmentFile.link(owner: owner, fileID: file.id)
      try store.save(link)
      XCTAssertEqual(
        link.kind,
        kind == "tasks"
          ? "task_attachments" : kind == "notes" ? "note_attachments" : "reminder_attachments")
      XCTAssertEqual(link.body["ownerID"], owner.id)
      XCTAssertEqual(link.body["fileID"], file.id)
      XCTAssertEqual(try store.pendingCount(), 3)
    }
  }
  func testFileIconsDistinguishFolderImagePDFAndArchive() {
    XCTAssertEqual(FileAppearance(Item(kind: "folders")).symbol, "folder.fill")
    XCTAssertEqual(
      FileAppearance(Item(kind: "files", body: ["title": "photo.png"])).symbol, "photo.fill")
    XCTAssertEqual(
      FileAppearance(Item(kind: "files", body: ["title": "document.pdf"])).symbol,
      "doc.richtext.fill")
    XCTAssertEqual(
      FileAppearance(Item(kind: "files", body: ["title": "bundle.zip"])).symbol, "archivebox.fill")
  }
}
final class AgendaLayoutTests: XCTestCase {
  let parser = ISO8601DateFormatter()
  var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
  func date(_ text: String) -> Date { parser.date(from: text)! }
  func testOverlapsUseSeparateColumnsAndAdjacentEventsReuseSpace() {
    let day = date("2026-10-20T00:00:00Z")
    let spans = [
      AgendaSpan(
        id: "a", start: day.addingTimeInterval(9 * 3600), end: day.addingTimeInterval(10 * 3600)),
      AgendaSpan(
        id: "b", start: day.addingTimeInterval(9.5 * 3600), end: day.addingTimeInterval(10.5 * 3600)
      ),
      AgendaSpan(
        id: "c", start: day.addingTimeInterval(11 * 3600), end: day.addingTimeInterval(12 * 3600)),
    ]
    let placements = AgendaLayout.placements(spans, day: day, calendar: utc)
    XCTAssertEqual(placements.map(\.columns), [2, 2, 1])
    XCTAssertNotEqual(placements[0].column, placements[1].column)
    XCTAssertEqual(placements[0].start, 540)
    XCTAssertEqual(placements[0].end, 600)
  }
  func testCrossMidnightEventsAreClippedAndOtherDaysExcluded() {
    let day = date("2026-10-20T00:00:00Z")
    let spans = [
      AgendaSpan(
        id: "overnight", start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(3600)),
      AgendaSpan(
        id: "late", start: day.addingTimeInterval(23 * 3600), end: day.addingTimeInterval(25 * 3600)
      ),
      AgendaSpan(
        id: "tomorrow", start: day.addingTimeInterval(25 * 3600),
        end: day.addingTimeInterval(26 * 3600)),
    ]
    let placed = AgendaLayout.placements(spans, day: day, calendar: utc)
    XCTAssertEqual(placed.count, 2)
    XCTAssertEqual(placed[0].start, 0)
    XCTAssertEqual(placed[0].end, 60)
    XCTAssertEqual(placed[1].start, 1380)
    XCTAssertEqual(placed[1].end, 1440)
  }
  func testDSTDaysUseWallClockHoursRatherThanElapsedHours() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    let morning = date("2026-03-08T13:00:00Z")  // 09:00 after the clock change.
    let result = AgendaLayout.placements(
      [AgendaSpan(id: "morning", start: morning, end: morning.addingTimeInterval(3600))],
      day: morning, calendar: calendar)
    XCTAssertEqual(result.first?.start, 540)
    XCTAssertEqual(result.first?.end, 600)
  }
}

final class TaskArchiveTests: XCTestCase {
  func testCompletingMovesTaskToArchiveAndReopeningReturnsItToActive() throws {
    let task = Item(kind: "tasks", body: ["title": "Work", "status": "To do"])
    let done = TaskCompletion.toggled(task)
    XCTAssertEqual(done.body["status"], "Done")
    XCTAssertEqual(done.body["archived"], "true")
    XCTAssertFalse(WorkListScope(kind: "tasks").contains(done))
    XCTAssertTrue(WorkListScope(kind: "tasks", archived: true).contains(done))
    let reopened = TaskCompletion.toggled(done)
    XCTAssertEqual(reopened.body["status"], "To do")
    XCTAssertEqual(reopened.body["archived"], "false")
    XCTAssertTrue(WorkListScope(kind: "tasks").contains(reopened))
    let store = try LocalStore(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"))
    try store.save(done)
    XCTAssertEqual(try store.pending().first?.body["archived"], "true")
    XCTAssertTrue(try XCTUnwrap(store.all().first).archived)
  }
  func testStatusPickerAndLegacyCompletedTasksUseSameArchiveRules() {
    let legacy = Item(kind: "tasks", body: ["status": "Done", "archived": "false"])
    XCTAssertTrue(legacy.archived)
    XCTAssertTrue(WorkListScope(kind: "tasks", archived: true).contains(legacy))
    XCTAssertEqual(TaskCompletion.normalized(legacy, previous: nil).body["archived"], "true")
    var reopened = legacy
    reopened.body["status"] = "In progress"
    XCTAssertFalse(TaskCompletion.normalized(reopened, previous: legacy).archived)
    let note = Item(kind: "notes", body: ["status": "Done"])
    XCTAssertFalse(note.archived)
    XCTAssertEqual(TaskCompletion.normalized(note, previous: nil), note)
  }
}

final class SyncedPreferencesTests: XCTestCase {
  func testCalendarSettingsSurviveOfflineStorageAndIncomingPull() throws {
    let local = try LocalStore(
      url: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString + ".sqlite"))
    var settings = Item(
      id: "00000000-0000-0000-0000-000000000001", kind: "user_settings",
      body: ["language": "he", "selectedCalendars": "[\"work\"]", "agendaRange": "Week"])
    try local.save(settings)
    let mutation = try XCTUnwrap(local.nextMutation())
    XCTAssertEqual(mutation.body["selectedCalendars"], "[\"work\"]")
    settings.revision = 1
    try local.accept(.init(operationID: mutation.operationID, status: "applied", record: settings))
    settings.body["agendaRange"] = "Month"
    settings.body["selectedCalendars"] = "[]"
    settings.revision = 2
    try local.apply(.init(changes: [settings], cursor: 2, hasMore: false))
    let stored = try XCTUnwrap(local.all().first)
    XCTAssertEqual(stored.body["agendaRange"], "Month")
    XCTAssertEqual(stored.body["selectedCalendars"], "[]")
    XCTAssertEqual(try local.pendingCount(), 0)
  }
}
