import AppKit
import SwiftUI
import UserNotifications

struct Recurrence {
  static func occurrences(_ item: Item, after start: Date, until end: Date) -> [Date] {
    guard let first = item.date else { return [] }
    let rule = item.body["recurrence"] ?? "Once"
    if rule == "Once" { return first > start && first <= end ? [first] : [] }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: item.body["timezone"] ?? "") ?? .current
    let anchor = calendar.dateComponents([.hour, .minute, .second, .weekday, .day], from: first)
    let weekdays = Set(
      (item.body["weekdays"] ?? "2,3,4,5,6").split(separator: ",").compactMap { Int($0) })
    var dates: [Date] = []
    var day = calendar.startOfDay(for: max(first, start))
    while day <= end {
      let components = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
      let matches =
        rule == "Daily" || (rule == "Weekdays" && weekdays.contains(components.weekday!))
        || (rule == "Weekly" && components.weekday == anchor.weekday)
        || (rule == "Monthly" && components.day == anchor.day)
      if matches,
        let date = calendar.date(
          bySettingHour: anchor.hour!, minute: anchor.minute!, second: anchor.second!, of: day,
          matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
        date >= first, date > start, date <= end
      {
        dates.append(date)
      }
      guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return dates
  }
}
/// AlarmService owns these windows; AppKit does not release them on close.
@MainActor enum AlarmWindow {
  static func make(title: String) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 340), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = L10n.format("Reminder · %@", title)
    window.level = .floating
    return window
  }
}

@MainActor final class AlarmService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
  private var scheduleTask: Task<Void, Never>?
  var items: [Item] = []
  var timer: Timer?
  var windows: [String: NSWindow] = [:]
  var previous = Date().addingTimeInterval(-86400)
  var instanceID = "local"
  var saveItem: ((Item) -> Void)?
  var openAttachment: ((String) -> Void)?
  var links: [Item] = []
  var completed = Set<String>()
  var pendingWindows: [String: String] = [:]
  func configure(instance: String, save: @escaping (Item) -> Void, open: @escaping (String) -> Void)
  {
    guard instanceID != instance || saveItem == nil else { return }
    for window in windows.values { window.close() }
    windows.removeAll()
    instanceID = instance
    saveItem = save
    openAttachment = open
    previous =
      (UserDefaults.standard.object(forKey: "alarm.lastCheck." + instance) as? Date)
      ?? Date().addingTimeInterval(-86400)
    pendingWindows =
      UserDefaults.standard.dictionary(forKey: "alarm.pending." + instance) as? [String: String]
      ?? [:]
  }
  override init() {
    super.init()
    UNUserNotificationCenter.current().delegate = self
    timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in self?.tick() } }
  }
  func requestPermission() async {
    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [
      .alert, .sound, .badge,
    ])
    await queueSchedule().value
  }
  func update(_ values: [Item]) {
    links = values.filter { !$0.deleted && $0.kind == "reminder_attachments" }
    completed = Set(
      values.filter { !$0.deleted && $0.kind == "reminder_occurrences" }.compactMap {
        $0.body["occurrenceID"]
      })
    items = values.filter { $0.kind == "reminders" && !$0.deleted && !$0.archived }
    for (id, itemID) in pendingWindows {
      if let item = items.first(where: { $0.id == itemID }), !handled(id) { show(item, id: id) }
    }
    _ = queueSchedule()
    tick()
  }
  func occurrenceID(_ item: Item, _ date: Date) -> String {
    item.id + ":" + String(Int(date.timeIntervalSince1970))
  }
  func handled(_ id: String) -> Bool {
    completed.contains(id) || UserDefaults.standard.bool(forKey: "alarm." + instanceID + "." + id)
  }
  func tick() {
    let now = Date()
    for item in items {
      for date in Recurrence.occurrences(item, after: previous, until: now) {
        let id = occurrenceID(item, date)
        if !handled(id) && windows[id] == nil { show(item, id: id) }
      }
    }
    previous = now.addingTimeInterval(-5)
    UserDefaults.standard.set(previous, forKey: "alarm.lastCheck." + instanceID)
  }
  private func queueSchedule() -> Task<Void, Never> {
    let previous = scheduleTask
    previous?.cancel()
    let next = Task { [weak self] in
      await previous?.value
      do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
      guard !Task.isCancelled else { return }
      await self?.schedule()
    }
    scheduleTask = next
    return next
  }
  func schedule() async {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    guard !Task.isCancelled, settings.authorizationStatus == .authorized else { return }
    center.removeAllPendingNotificationRequests()
    let now = Date()
    let end = now.addingTimeInterval(86400 * 30)
    let occurrences = items.flatMap { item in
      Recurrence.occurrences(item, after: now, until: end).map { (item, $0) }
    }.sorted { $0.1 < $1.1 }.prefix(60)
    for (item, date) in occurrences {
      guard !Task.isCancelled else { return }
      let id = occurrenceID(item, date)
      guard !handled(id) else { continue }
      let content = UNMutableNotificationContent()
      content.title = item.title
      content.body = item.body["description"] ?? ""
      content.sound = .default
      content.userInfo = ["itemID": item.id, "occurrenceID": id]
      let trigger = UNTimeIntervalNotificationTrigger(
        timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
      try? await center.add(
        UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
  }
  func show(_ item: Item, id: String) {
    guard windows[id] == nil, !handled(id) else { return }
    pendingWindows[id] = item.id
    UserDefaults.standard.set(pendingWindows, forKey: "alarm.pending." + instanceID)
    let window = AlarmWindow.make(title: item.title)
    let attachmentLinks = links.filter { $0.body["ownerID"] == item.id }
    window.center()
    window.contentView = NSHostingView(
      rootView: VStack(alignment: .leading, spacing: 20) {
        Text(item.title).font(.largeTitle)
        ScrollView {
          Text(item.body["description"] ?? "").frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        ForEach(attachmentLinks) { link in
          Button(L10n.text("Open attachment")) { [weak self] in
            if let fileID = link.body["fileID"] { self?.openAttachment?(fileID) }
          }
        }
        HStack {
          Button(L10n.text("Snooze 10 minutes")) { [weak self] in
            self?.finish(id)
            var snoozed = item
            snoozed.id = UUID().uuidString.lowercased()
            snoozed.revision = 0
            snoozed.body["date"] = ISO8601DateFormatter().string(
              from: Date().addingTimeInterval(600))
            snoozed.body["recurrence"] = "Once"
            self?.saveItem?(snoozed)
          }
          Spacer()
          Button(L10n.text("Dismiss")) { [weak self] in self?.finish(id) }.keyboardShortcut(
            .defaultAction)
        }
      }.padding(24)
        .environment(\.locale, L10n.language.locale)
        .environment(\.layoutDirection, L10n.language.direction))
    windows[id] = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func finish(_ id: String) {
    UserDefaults.standard.set(true, forKey: "alarm." + instanceID + "." + id)
    pendingWindows.removeValue(forKey: id)
    UserDefaults.standard.set(pendingWindows, forKey: "alarm.pending." + instanceID)
    windows[id]?.close()
    windows.removeValue(forKey: id)
    saveItem?(
      Item(
        kind: "reminder_occurrences",
        body: [
          "occurrenceID": id, "status": "dismissed",
          "date": ISO8601DateFormatter().string(from: Date()),
        ]))
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions { [] }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    let info = response.notification.request.content.userInfo
    let itemID = info["itemID"] as? String
    let occurrence = info["occurrenceID"] as? String
    await MainActor.run {
      if let item = self.items.first(where: { $0.id == itemID }), let id = occurrence {
        self.show(item, id: id)
      }
    }
  }
}
