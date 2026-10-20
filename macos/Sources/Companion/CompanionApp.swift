import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
@main struct CompanionApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject var model = AppModel()
  @StateObject var alarms = AlarmService()
  @StateObject var shabbat = ShabbatController()
  func configureAlarms() {
    alarms.configure(
      instance: model.configuration?.instanceID ?? "local", save: { model.save($0) },
      open: { id in if let item = model.items.first(where: { $0.id == id }) { model.openFile(item) }
      })
    alarms.update(model.items)
  }
  var body: some Scene {
    WindowGroup(L10n.text("Bee Companion")) {
      ContentView().environmentObject(model).environmentObject(alarms)
        .environment(\.locale, model.language.locale)
        .environment(\.layoutDirection, model.language.direction)
        .frame(minWidth: 1100, minHeight: 740)
        .tint(BeeTheme.accent)
        .environmentObject(shabbat)
        .onAppear { configureAlarms() }
        .onChange(of: model.configuration?.instanceID) { _, _ in configureAlarms() }
        .onReceive(
          model.$items.map {
            $0.filter {
              ["reminders", "reminder_attachments", "reminder_occurrences"].contains($0.kind)
            }
          }.removeDuplicates()
        ) { values in
          alarms.configure(
            instance: model.configuration?.instanceID ?? "local", save: { model.save($0) },
            open: { id in
              if let item = model.items.first(where: { $0.id == id }) { model.openFile(item) }
            })
          alarms.update(values)
        }
        .onReceive(
          NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in model.checkWorkingCopies() }
        .alert(
          "Bee Companion",
          isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
        ) {
          Button(L10n.text("OK")) { model.error = nil }
        } message: {
          Text(L10n.message(model.error ?? ""))
        }
    }
    .commands {
      CommandGroup(after: .toolbar) {
        Button(L10n.text("Open Shabbat Mode")) { shabbat.show(model) }.keyboardShortcut(
          "s", modifiers: [.command, .shift])
      }
      TextEditingCommands()
      TextFormattingCommands()
      CommandGroup(after: .newItem) {
        Button(L10n.text("New Task")) { _ = model.add("tasks") }.keyboardShortcut(
          "t", modifiers: [.command, .shift])
        Button(L10n.text("New Note")) { _ = model.add("notes") }.keyboardShortcut(
          "n", modifiers: [.command, .shift])
      }
      CommandGroup(after: .saveItem) {
        Button(L10n.text("Synchronize")) { Task { await model.sync() } }.keyboardShortcut(
          "r", modifiers: [.command, .shift])
      }
    }
  }
}
struct ContentView: View {
  @EnvironmentObject var model: AppModel
  @EnvironmentObject var shabbat: ShabbatController
  @State var section: Section? = .today
  @State var query = ""
  var isOnline: Bool { model.message.hasPrefix("Up to date") }
  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high)
            .frame(width: 40, height: 40)
          VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text("Bee Companion")).font(.system(size: 15, weight: .semibold))
            Text(L10n.text("A little space for your day")).font(.system(size: 10)).foregroundStyle(
              .secondary)
          }
          Spacer(minLength: 0)
        }.padding(.horizontal, 18).padding(.top, 20).padding(.bottom, 23)
        List(selection: $section) {
          SwiftUI.Section(L10n.text("Workspace")) {
            ForEach([Section.today, .tasks, .notes, .files, .agenda, .alarms, .stocks, .rss]) {
              item in
              sidebarRow(item)
            }
          }
          SwiftUI.Section(L10n.text("Library")) {
            sidebarRow(.archive)
            sidebarRow(.settings)
          }
        }.listStyle(.sidebar)
        VStack(alignment: .leading, spacing: 10) {
          Divider()
          HStack(spacing: 7) {
            Circle().fill(isOnline ? BeeTheme.mint : Color.secondary.opacity(0.6)).frame(
              width: 6, height: 6)
            Text(
              model.syncing
                ? L10n.text("Syncing your work…")
                : isOnline ? L10n.text("Everything is up to date") : L10n.text("Saved on this Mac")
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button {
              Task { await model.sync() }
            } label: {
              Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11))
            }
            .buttonStyle(.plain).disabled(model.syncing).help(
              L10n.text("Synchronize with your backend"))
          }
          HStack {
            Label(
              model.configuration?.instanceName ?? L10n.text("Offline library"),
              systemImage: "externaldrive"
            )
            .lineLimit(1)
            Spacer()
            if model.pending > 0 {
              Text(L10n.format("%d pending", model.pending)).monospacedDigit()
            }
          }.font(.system(size: 10)).foregroundStyle(.tertiary)
          if !model.conflicts.isEmpty {
            Button(L10n.format("%d conflicts to review", model.conflicts.count)) {
              section = .settings
            }
            .font(.caption).foregroundStyle(BeeTheme.amber).buttonStyle(.plain)
          }
        }.padding(16)
      }.navigationSplitViewColumnWidth(min: 220, ideal: 242, max: 290)
        .navigationTitle("")
    } detail: {
      Group {
        switch section ?? .today {
        case .today: TodayView()
        case .tasks: ItemListView(kind: "tasks", query: query)
        case .notes: ItemListView(kind: "notes", query: query)
        case .files: FilesView(query: query)
        case .alarms: ItemListView(kind: "reminders", query: query)
        case .archive: ItemListView(kind: nil, query: query, archived: true)
        case .agenda: AgendaView()
        case .stocks: StocksView()
        case .rss: RSSReaderView()
        case .settings: SettingsView()
        }
      }.id(section ?? .today).background(BeeTheme.canvas)
        .navigationTitle((section ?? .today).title())
        .searchable(text: $query, prompt: L10n.text("Search your workspace"))
        .toolbar {
          ToolbarItemGroup(placement: .primaryAction) {
            Button {
              shabbat.show(model)
            } label: {
              Label(L10n.text("Shabbat mode"), systemImage: "moon.stars")
            }.labelStyle(.titleAndIcon).help(L10n.text("Open Shabbat mode · ⌘⇧S"))
            Menu {
              Button(L10n.text("New task"), systemImage: "checklist") {
                _ = model.add("tasks")
                section = .tasks
              }
              Button(L10n.text("New note"), systemImage: "note.text") {
                _ = model.add("notes")
                section = .notes
              }
              Button(L10n.text("New reminder"), systemImage: "alarm") {
                _ = model.add("reminders")
                section = .alarms
              }
              Divider()
              Button(L10n.text("Upload files"), systemImage: "square.and.arrow.up") {
                model.importFile()
                section = .files
              }
            } label: {
              Label(L10n.text("Create"), systemImage: "plus")
            }.help(L10n.text("Create something new"))
          }
        }
    }.navigationSplitViewStyle(.balanced)
  }
  func sidebarRow(_ item: Section) -> some View {
    HStack(spacing: 10) {
      Image(systemName: item.symbol).font(.system(size: 14, weight: .medium))
        .foregroundStyle(section == item ? BeeTheme.accent : Color.secondary).frame(width: 20)
      Text(item.title()).font(
        .system(size: 13, weight: section == item ? .semibold : .regular))
      Spacer()
      let count = model.items.filter {
        !$0.deleted && !$0.archived
          && $0.kind
            == (item == .tasks
              ? "tasks" : item == .notes ? "notes" : item == .alarms ? "reminders" : "")
      }.count
      if count > 0 {
        Text("\(count)").font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(
          .tertiary)
      }
    }.padding(.vertical, 5).tag(item)
  }
}
struct ItemListView: View {
  @EnvironmentObject var model: AppModel
  var kind: String?
  var query: String
  var archived = false
  @State var selected: String?
  @State var filter = "All"
  var rows: [Item] {
    let ids = query.isEmpty ? nil : (try? model.store.search(query))
    return model.items.filter { item in
      guard WorkListScope(kind: kind, archived: archived).contains(item),
        ids == nil || ids!.contains(item.id)
      else { return false }
      if kind == "tasks", filter != "All" {
        guard let date = item.date else { return false }
        if filter == "Today" { return Calendar.current.isDateInToday(date) }
        if filter == "Upcoming" { return date > Date() }
        return
          (item.body["dateOnly"] == "true"
          ? Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date())
          : date < Date()) && !["Done", "Cancelled"].contains(item.body["status"] ?? "")
      }
      return true
    }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
  }
  var body: some View {
    HSplitView {
      VStack(spacing: 0) {
        if kind == "tasks" {
          Picker(L10n.text("View"), selection: $filter) {
            ForEach(["All", "Today", "Upcoming", "Overdue"], id: \.self) {
              Text(L10n.text($0)).tag($0)
            }
          }.pickerStyle(.segmented).padding(8)
        }
        List(rows, selection: $selected) { item in
          HStack(alignment: .top, spacing: 11) {
            if item.kind == "tasks" {
              TaskCompletionButton(item: item)
            } else {
              Image(systemName: item.kind == "notes" ? "doc.text" : "alarm")
                .font(.system(size: 17)).foregroundStyle(BeeTheme.accent).padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 5) {
              Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
              if let description = item.body["description"], !description.isEmpty {
                Text(description).font(.system(size: 12)).lineLimit(2).foregroundStyle(.secondary)
              }
              HStack(spacing: 8) {
                if let date = item.date {
                  Label(date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if item.kind == "tasks" {
                  Text(L10n.text(item.body["status"] ?? "To do")).font(
                    .system(size: 10, weight: .medium)
                  )
                  .foregroundStyle(BeeTheme.accent).padding(.horizontal, 6).padding(.vertical, 2)
                  .background(BeeTheme.accent.opacity(0.08), in: Capsule())
                }
              }
            }
          }.tag(item.id).padding(.vertical, 4)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        CollectionControls(
          addTitle: kind == "tasks" ? "Add task" : kind == "notes" ? "Add note" : "Add alarm",
          removeTitle: "Trash", canAdd: kind != nil,
          canRemove: rows.contains { $0.id == selected },
          add: { if let kind { selected = model.add(kind).id } },
          remove: {
            guard let item = rows.first(where: { $0.id == selected }) else { return }
            if model.trash(item) { selected = nil }
          }
        ) {
          if kind == "notes" {
            Button(L10n.text("Import Markdown / RTF")) { model.importNotes() }
          }
        }
      }.frame(minWidth: 270, idealWidth: 330).background(BeeTheme.surface)
      if let item = CollectionSelection.item(selected, in: rows) {
        ItemEditor(item: item).id(item.id).frame(minWidth: 400)
      } else {
        BeeEmptyState(
          title: "Room for your next idea",
          detail: "Choose an item from the list, or create something new.",
          symbol: kind == "notes" ? "square.and.pencil" : "rectangle.and.pencil.and.ellipsis")
      }
    }
  }
}
struct ItemEditor: View {
  @EnvironmentObject var model: AppModel
  @EnvironmentObject var alarms: AlarmService
  @State var item: Item
  @State var dateEnabled = false
  @StateObject private var noteEditing = NoteEditing()
  func text(_ key: String, default value: String = "") -> Binding<String> {
    Binding(get: { item.body[key] ?? value }, set: { item.body[key] = $0 })
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        HStack(spacing: 6) {
          Image(
            systemName: item.kind == "notes"
              ? "note.text" : item.kind == "tasks" ? "checklist" : "alarm")
          Text(
            L10n.text(item.kind == "notes" ? "NOTE" : item.kind == "tasks" ? "TASK" : "REMINDER")
          ).tracking(
            1.5)
        }.font(.system(size: 10, weight: .semibold)).foregroundStyle(BeeTheme.accent)
        TextField(L10n.text("Title"), text: text("title")).font(
          .system(size: 29, weight: .semibold)
        )
        .textFieldStyle(.plain)
        TextField(L10n.text("Description"), text: text("description"), axis: .vertical).lineLimit(
          3...8)
        if item.kind == "tasks" {
          Picker(L10n.text("Status"), selection: text("status", default: "To do")) {
            ForEach(["To do", "In progress", "Done", "Cancelled"], id: \.self) {
              Text(L10n.text($0)).tag($0)
            }
          }
        }
        if item.kind == "tasks" || item.kind == "reminders" {
          Toggle(L10n.text("Scheduled date"), isOn: $dateEnabled)
          if dateEnabled {
            DatePicker(
              L10n.text("When"),
              selection: Binding(
                get: { item.date ?? Date() },
                set: { item.body["date"] = ISO8601DateFormatter().string(from: $0) }),
              displayedComponents: item.body["dateOnly"] == "true"
                ? [.date] : [.date, .hourAndMinute])
            if item.kind == "tasks" {
              Toggle(
                L10n.text("Date only"),
                isOn: Binding(
                  get: { item.body["dateOnly"] == "true" },
                  set: { item.body["dateOnly"] = String($0) }))
            }
          }
        }
        if item.kind == "reminders" {
          Picker(L10n.text("Repeat"), selection: text("recurrence", default: "Once")) {
            ForEach(["Once", "Daily", "Weekdays", "Weekly", "Monthly"], id: \.self) {
              Text(L10n.text($0)).tag($0)
            }
          }
          TextField(
            L10n.text("Time zone"), text: text("timezone", default: TimeZone.current.identifier))
          if item.body["recurrence"] == "Weekdays" {
            TextField(
              L10n.text("Weekdays (1=Sunday … 7=Saturday)"),
              text: text("weekdays", default: "2,3,4,5,6"))
          }
          Button(L10n.text("Enable notifications")) { Task { await alarms.requestPermission() } }
        }
        if item.kind == "notes" {
          Text(L10n.text("Rich text")).font(.headline)
          NoteToolbar(editor: noteEditing)
          NoteTextEditor(
            text: text("text"), rtf: text("rtf"), rtfd: text("rtfd"), rich: true,
            editor: noteEditing, commit: commitNote,
            initialMarkdown: item.body["format"] == "rtf" ? nil : item.body["text"]
          ).frame(minHeight: 360)

        }
        if ["tasks", "notes", "reminders"].contains(item.kind) { attachments }
        Divider()
        HStack {
          Button(L10n.text("Share with attachments")) { model.shareWithAttachments(item) }
          Menu(L10n.text("Export")) {
            Button(L10n.text("Text")) { Sharing.export(item, format: "txt") }
            Button(L10n.text("Rich text")) {
              NotificationCenter.default.post(name: .flushNoteEdits, object: nil)
              Sharing.export(model.items.first(where: { $0.id == item.id }) ?? item, format: "rtf")
            }
            if item.body["rtfd"]?.isEmpty == false {
              Button(L10n.text("Rich text with images")) { Sharing.export(item, format: "rtfd") }
            }
            if item.kind == "notes" {
              Button(L10n.text("Markdown")) {
                NotificationCenter.default.post(name: .flushNoteEdits, object: nil)
                Sharing.export(model.items.first(where: { $0.id == item.id }) ?? item, format: "md")
              }
            }
          }
          Button(L10n.text("WhatsApp")) { Sharing.whatsApp(item) }
          Spacer()
          Button(L10n.text(item.archived ? "Restore" : "Archive")) {
            item.body["archived"] = String(!item.archived)
          }
          Button(L10n.text("Trash"), role: .destructive) { model.trash(item) }
        }
      }.padding(32)
    }
    .onAppear { dateEnabled = item.date != nil }
    .onChange(of: dateEnabled) { _, enabled in
      if enabled {
        item.body["date"] = item.body["date"] ?? ISO8601DateFormatter().string(from: Date())
      } else {
        item.body.removeValue(forKey: "date")
      }
    }
    .onChange(of: model.items.first(where: { $0.id == item.id })?.body["status"]) { _, status in
      if item.kind == "tasks", let status { item.body["status"] = status }
    }
    .onChange(of: item) { _, new in
      if model.items.first(where: { $0.id == new.id }) != new { model.save(new) }
    }
  }
  func commitNote(_ text: String, _ rtf: String, _ rtfd: String) {
    var updated = item
    updated.revision = model.items.first(where: { $0.id == item.id })?.revision ?? item.revision
    updated.body["text"] = text
    updated.body["format"] = "rtf"
    updated.body["rtf"] = rtf
    updated.body["rtfd"] = rtfd
    item = updated
    model.save(updated)
  }
  var attachments: some View {
    VStack(alignment: .leading) {
      Text(L10n.text("Attachments")).font(.headline)
      ForEach(
        model.items.filter {
          !$0.deleted && $0.kind == attachmentKind && $0.body["ownerID"] == item.id
        }
      ) { link in
        HStack {
          if let file = model.items.first(where: { $0.id == link.body["fileID"] }) {
            Button(file.deleted ? file.title + L10n.text(" (trashed)") : file.title) {
              model.openFile(file)
            }
            .disabled(file.deleted)
          } else {
            Text(L10n.text("Unavailable attachment"))
          }
          Spacer()
          Button(L10n.text("Remove")) {
            var removed = link
            removed.deleted = true
            model.save(removed)
          }
        }
      }
      HStack {
        Button(L10n.text("Attach files…"), systemImage: "paperclip") {
          model.attachFiles(to: item)
        }
        Button(L10n.text("Add reminder")) {
          model.save(
            Item(
              kind: "reminders",
              body: [
                "title": item.title, "description": item.body["description"] ?? "",
                "ownerID": item.id,
                "date": ISO8601DateFormatter().string(
                  from: item.date ?? Date().addingTimeInterval(3600)),
                "timezone": TimeZone.current.identifier,
              ]))
        }
      }
    }
  }
  var attachmentKind: String {
    item.kind == "tasks"
      ? "task_attachments" : item.kind == "notes" ? "note_attachments" : "reminder_attachments"
  }
}
