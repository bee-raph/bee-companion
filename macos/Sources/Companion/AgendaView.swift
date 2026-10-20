import EventKit
import SwiftUI

enum CalendarSelection {
  static func resolve(available: [String], stored: [String]?) -> Set<String> {
    let known = Set(available)
    return stored.map { Set($0).intersection(known) } ?? known
  }
}

@MainActor final class AgendaService: ObservableObject {
  lazy var store = EKEventStore()
  private let reader = CalendarReader()
  private var refreshTask: Task<Void, Never>?
  private let authorization: () -> EKAuthorizationStatus
  @Published var events: [CalendarEvent] = []
  @Published var calendars: [CalendarDescriptor] = []
  @Published var access: EKAuthorizationStatus = .notDetermined
  @Published var requesting = false
  var storedCalendarIDs: [String]?
  var selectionChanged: (([String]) -> Void)?
  @Published var message = "Enable Apple Calendar to show local appointments."
  init(
    authorization: @escaping () -> EKAuthorizationStatus = {
      EKEventStore.authorizationStatus(for: .event)
    }
  ) {
    self.authorization = authorization
  }
  var selectedIDs: Set<String> {
    CalendarSelection.resolve(
      available: calendars.map(\.calendarIdentifier),
      stored: storedCalendarIDs)
  }
  func refresh(_ date: Date, days: Int = 7) {
    refreshTask?.cancel()
    access = authorization()
    guard access == .fullAccess else {
      calendars = []
      events = []
      switch access {
      case .denied:
        message =
          "Calendar access is off. Allow Bee Companion in System Settings → Privacy & Security → Calendars."
      case .restricted:
        message = "Calendar access is restricted on this Mac. App tasks remain available."
      case .writeOnly: message = "Full Calendar access is needed to read your appointments."
      default: message = "Enable Apple Calendar to choose the calendars shown here."
      }
      return
    }
    let selected = storedCalendarIDs
    refreshTask = Task { [weak self] in
      guard let self else { return }
      let snapshot = await reader.snapshot(date: date, days: days, selected: selected)
      guard !Task.isCancelled else { return }
      calendars = snapshot.calendars
      events = snapshot.events
      if calendars.isEmpty {
        message =
          "No calendars are available. Add a calendar or account in the Calendar app, then refresh."
      } else if selectedIDs.isEmpty {
        message = "No calendars selected. Choose calendars from the menu below."
      } else {
        message = "Apple Calendar data stays on this Mac."
      }
    }
  }

  func select(_ calendar: CalendarDescriptor, enabled: Bool, date: Date, days: Int) {
    var ids = selectedIDs
    if enabled {
      ids.insert(calendar.calendarIdentifier)
    } else {
      ids.remove(calendar.calendarIdentifier)
    }
    storedCalendarIDs = Array(ids).sorted()
    selectionChanged?(storedCalendarIDs ?? [])
    refresh(date, days: days)
  }
  func selectAll(_ enabled: Bool, date: Date, days: Int) {
    storedCalendarIDs = enabled ? calendars.map(\.calendarIdentifier).sorted() : []
    selectionChanged?(storedCalendarIDs ?? [])
    refresh(date, days: days)
  }
  func enable(date: Date, days: Int) async {
    guard !requesting else { return }
    requesting = true
    defer { requesting = false }
    do {
      if try await store.requestFullAccessToEvents() {
        // Discard objects cached before authorization was granted.
        store.reset()
      }
      refresh(date, days: days)
    } catch { message = error.localizedDescription }
  }
}
struct AgendaView: View {
  @EnvironmentObject var model: AppModel
  @StateObject var agenda = AgendaService()
  @StateObject private var hebrewAgenda = HebrewAgendaData()
  @State var date = Date()
  @State var range = "Day"
  var days: Int {
    range == "Day"
      ? 1 : range == "Week" ? 7 : Calendar.current.range(of: .day, in: .month, for: date)!.count
  }
  var start: Date {
    range == "Month"
      ? Calendar.current.dateInterval(of: .month, for: date)!.start
      : range == "Week"
        ? Calendar.current.dateInterval(of: .weekOfYear, for: date)!.start
        : Calendar.current.startOfDay(for: date)
  }
  func configurePreferences() {
    agenda.selectionChanged = { ids in
      guard let data = try? JSONEncoder().encode(ids) else { return }
      model.setPreference("selectedCalendars", String(decoding: data, as: UTF8.self))
    }
    if let raw = model.preferences.body["selectedCalendars"], let data = raw.data(using: .utf8) {
      agenda.storedCalendarIDs = try? JSONDecoder().decode([String].self, from: data)
    } else if let legacy = UserDefaults.standard.stringArray(forKey: "selectedCalendars") {
      agenda.storedCalendarIDs = legacy
      agenda.selectionChanged?(legacy)
    }
    range = model.preferences.body["agendaRange"] ?? "Day"
  }
  var entries: [AgendaEntry] {
    let apple = agenda.events.map { event in
      AgendaEntry(
        id: "apple:" + (event.eventIdentifier ?? UUID().uuidString) + ":"
          + String(event.startDate.timeIntervalSince1970), title: event.title ?? L10n.text("Event"),
        start: event.startDate, end: event.endDate, allDay: event.isAllDay,
        color: Color(nsColor: event.calendar.color), source: event.calendar.title, item: nil)
    }
    let work = model.items.filter {
      ["tasks", "reminders"].contains($0.kind) && !$0.deleted && !$0.archived && $0.date != nil
        && $0.body["status"] != "Cancelled"
    }.map { item in
      AgendaEntry(
        id: item.id, title: item.title, start: item.date!, end: item.date!.addingTimeInterval(1800),
        allDay: item.body["dateOnly"] == "true",
        color: item.kind == "tasks" ? BeeTheme.mint : BeeTheme.amber,
        source: L10n.text(item.kind == "tasks" ? "Tasks" : "Alarms"), item: item)
    }
    return apple + work
  }
  var visibleDays: [Date] {
    range == "Week"
      ? (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
      : [Calendar.current.startOfDay(for: date)]
  }
  var hebrewDays: [Date] {
    range == "Month" ? AgendaCalendarDays.grid(date: date, range: range) : visibleDays
  }
  var hebrewRequestKey: String {
    HebrewAgendaData.requestKey(
      days: hebrewDays, settings: model.preferences.body,
      instance: model.configuration?.instanceID ?? "local", language: model.language)
  }
  func step(_ direction: Int) {
    date =
      Calendar.current.date(
        byAdding: range == "Month" ? .month : .day, value: direction * (range == "Week" ? 7 : 1),
        to: date) ?? date
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text(date.formatted(.dateTime.month(.wide).year().locale(model.language.locale))).font(
            .title2.weight(.semibold))
          Text(TimeZone.current.identifier.replacingOccurrences(of: "_", with: " ")).font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button(L10n.text("Today")) { date = Date() }
        Button {
          step(-1)
        } label: {
          Image(systemName: "chevron.left")
        }.help(L10n.text("Previous"))
        Button {
          step(1)
        } label: {
          Image(systemName: "chevron.right")
        }.help(L10n.text("Next"))
        DatePicker(L10n.text("Date"), selection: $date, displayedComponents: .date).labelsHidden()
          .fixedSize()
        Picker(L10n.text("Range"), selection: $range) {
          ForEach(["Day", "Week", "Month"], id: \.self) { Text(L10n.text($0)).tag($0) }
        }.pickerStyle(.segmented).frame(width: 210)
      }.padding(18)
      Divider()
      HStack {
        Menu {
          if agenda.calendars.isEmpty {
            if agenda.access == .fullAccess {
              Text(L10n.text("No calendars found")).disabled(true)
              Button(L10n.text("Open Calendar")) {
                NSWorkspace.shared.open(URL(string: "ical://")!)
              }
            } else if agenda.access == .denied || agenda.access == .restricted {
              Text(L10n.text("Calendar access is unavailable")).disabled(true)
              Button(L10n.text("Open System Settings")) {
                NSWorkspace.shared.open(
                  URL(fileURLWithPath: "/System/Applications/System Settings.app"))
              }
            } else {
              Text(L10n.text("Calendar access is required")).disabled(true)
              Button(L10n.text("Enable Apple Calendar")) {
                Task { await agenda.enable(date: start, days: days) }
              }.disabled(agenda.requesting)
            }
          } else {
            ForEach(agenda.calendars, id: \.calendarIdentifier) { calendar in
              Toggle(
                isOn: Binding(
                  get: { agenda.selectedIDs.contains(calendar.calendarIdentifier) },
                  set: { agenda.select(calendar, enabled: $0, date: start, days: days) })
              ) {
                Text(calendar.title + " · " + calendar.sourceTitle)
              }
            }
            Divider()
            Button(L10n.text("Select all")) { agenda.selectAll(true, date: start, days: days) }
            Button(L10n.text("Deselect all")) { agenda.selectAll(false, date: start, days: days) }
          }
          Divider()
          Button(L10n.text("Refresh calendars")) { agenda.refresh(start, days: days) }
        } label: {
          Label(
            agenda.calendars.isEmpty
              ? L10n.text("Choose calendars")
              : L10n.format(
                "Calendars (%d of %d)", agenda.selectedIDs.count, agenda.calendars.count),
            systemImage: "calendar.badge.checkmark")
        }

        Spacer()
        if agenda.access != .fullAccess {
          Button(
            agenda.requesting ? L10n.text("Requesting access…") : L10n.text("Enable Apple Calendar")
          ) {
            Task { await agenda.enable(date: start, days: days) }
          }.disabled(agenda.requesting)
        }
      }.controlSize(.small).padding(.horizontal, 18).padding(.vertical, 8)
      Text(L10n.message(agenda.message)).font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(
          .bottom, 8)
      if range == "Month" {
        AgendaGrid(
          date: $date, range: range, events: agenda.events, items: model.items,
          hebrewDays: hebrewAgenda.days
        ).padding(
          .horizontal, 18
        ).padding(.bottom, 12)
      }
      Divider()
      if let message = hebrewAgenda.message {
        Text(L10n.text(message)).font(.caption).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(
            .vertical, 4)
      }
      AgendaTimeline(
        days: visibleDays, selectedDay: $date, entries: entries, hebrewDays: hebrewAgenda.days)
    }.background(Color(nsColor: .windowBackgroundColor))
      .task(id: hebrewRequestKey) { await hebrewAgenda.load(dates: hebrewDays, model: model) }
      .onAppear {
        configurePreferences()
        agenda.refresh(start, days: days)
      }
      .onChange(of: date) { _, _ in agenda.refresh(start, days: days) }
      .onChange(of: range) { _, value in
        if model.preferences.body["agendaRange"] != value {
          model.setPreference("agendaRange", value)
        }
        agenda.refresh(start, days: days)
      }
      .onChange(of: model.preferences.body["selectedCalendars"]) { _, _ in
        configurePreferences()
        agenda.refresh(start, days: days)
      }
      .onChange(of: model.preferences.body["agendaRange"]) { _, value in range = value ?? "Day" }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in agenda.refresh(start, days: days) }
      .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
        agenda.refresh(start, days: days)
      }
  }
}
struct HebrewCalendarView: View {
  var followNextZman = false
  @EnvironmentObject var model: AppModel
  @State var events: [HebrewResponse.Event] = []
  @State var message = ""
  @State var zmanim: [String: String] = [:]
  var hebrewDate: String {
    let format = DateFormatter()
    format.locale = L10n.locale
    format.calendar = Calendar(identifier: .hebrew)
    format.locale = Locale(identifier: "he_IL")
    format.dateStyle = .full
    return format.string(from: Date())
  }
  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        Text(hebrewDate).font(.title2)
        Spacer()
        Button(L10n.text("Refresh calendar")) { Task { await load() } }
      }
      Text(L10n.message(message)).font(.caption).foregroundStyle(.secondary)
      if !zmanim.isEmpty {
        ZmanimStrip(
          times: zmanim, followNext: followNextZman,
          timeZoneID: model.items.first { $0.kind == "user_settings" && !$0.deleted }?.body[
            "timezone"] ?? "Asia/Jerusalem")
      }
      List(
        events.filter {
          String($0.date.prefix(10))
            >= String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        }.prefix(40)
      ) { event in
        HStack {
          Text(event.title)
          Spacer()
          Text(event.hebrew ?? "")
          Text(BeeDisplayTime.timestamp(event.date)).font(.caption)
        }
      }
    }.padding().task(
      id: (model.configuration?.instanceID ?? "local")
        + CompanionLocation(model.preferences.body).identity
    ) {
      while !Task.isCancelled {
        await load()
        try? await Task.sleep(
          for: .seconds(ReaderPreferences.refreshSeconds(model.preferences.body)))
        if Task.isCancelled { break }
      }
    }
  }
  func load() async {
    let key = "hebrew." + (model.configuration?.instanceID ?? "local")
    if let data = UserDefaults.standard.data(forKey: key),
      let saved = try? JSONDecoder().decode(HebrewResponse.self, from: data)
    {
      events = saved.items
    }
    let location = CompanionLocation(model.preferences.body)
    let date = location.day()
    let timesKey = location.cacheKey(model.configuration?.instanceID ?? "local") + ".zmanim." + date
    zmanim = UserDefaults.standard.dictionary(forKey: timesKey) as? [String: String] ?? [:]
    guard let api = model.api else {
      message = "Connect backend to load holidays and location times."
      return
    }
    let settings = model.items.first { $0.kind == "user_settings" && !$0.deleted }
    let year = Calendar.current.component(.year, from: Date())
    struct Zmanim: Decodable { var times: [String: String] }
    if let query = location.query {
      if let result: Zmanim = try? await api.request("calendar/zmanim?date=\(date)&" + query) {
        zmanim = result.times
        UserDefaults.standard.set(result.times, forKey: timesKey)
      }
    }
    var path = "calendar/hebrew?year=\(year)&israel=\(settings?.body["israel"] != "false")"
    if let query = location.query { path += "&" + query }
    do {
      let result: HebrewResponse = try await api.request(path)
      events = result.items
      UserDefaults.standard.set(try JSONEncoder().encode(result), forKey: key)
      message = "Hebcal · cached for offline access"
    } catch { message = error.localizedDescription }
  }
}
struct TodayView: View {
  @EnvironmentObject var model: AppModel
  @EnvironmentObject var shabbat: ShabbatController
  var tasks: [Item] { model.items.filter { !$0.deleted && !$0.archived && $0.kind == "tasks" } }
  var upcoming: [Item] {
    model.items.filter {
      !$0.deleted && !$0.archived && ["tasks", "reminders"].contains($0.kind) && $0.date != nil
        && !["Done", "Cancelled"].contains($0.body["status"] ?? "")
    }
    .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
  }
  var greeting: String {
    let hour = Calendar.current.component(.hour, from: Date())
    return hour < 12 ? "Good morning." : hour < 18 ? "Good afternoon." : "Good evening."
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack(alignment: .bottom) {
          VStack(alignment: .leading, spacing: 8) {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased()).font(
              .system(size: 10, weight: .semibold)
            ).tracking(1.7).foregroundStyle(.secondary)
            Text(L10n.text(greeting)).font(.system(size: 34, weight: .semibold))
            Text(L10n.text("A clear view of everything that matters today.")).font(
              .system(size: 14)
            )
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            shabbat.show(model)
          } label: {
            Label(L10n.text("Shabbat mode"), systemImage: "moon.stars")
          }.buttonStyle(.bordered).controlSize(.large)
          Button {
            _ = model.add("tasks")
          } label: {
            Label(L10n.text("New task"), systemImage: "plus")
          }.buttonStyle(.borderedProminent).controlSize(.large)
        }.padding(.bottom, 4)
        HStack(spacing: 16) {
          BeeMetric(
            title: "Open tasks",
            value: String(
              tasks.filter { !["Done", "Cancelled"].contains($0.body["status"] ?? "") }.count),
            symbol: "checklist", color: BeeTheme.accent)
          BeeMetric(
            title: "Completed", value: String(tasks.filter { $0.body["status"] == "Done" }.count),
            symbol: "checkmark.circle", color: BeeTheme.mint)
          BeeMetric(
            title: "In your library",
            value: String(
              model.items.filter {
                !$0.deleted && !$0.archived && ["notes", "files"].contains($0.kind)
              }.count), symbol: "square.stack", color: BeeTheme.amber)
        }
        WorldClocksView()
        WeatherView()
        HStack(alignment: .top, spacing: 20) {
          BeeCard {
            VStack(alignment: .leading, spacing: 20) {
              BeeSectionHeading(
                title: "On your horizon", subtitle: "Tasks and reminders, in order",
                symbol: "sun.horizon")
              if upcoming.isEmpty {
                VStack(spacing: 10) {
                  Image(systemName: "checkmark.seal").font(.system(size: 28, weight: .light))
                    .foregroundStyle(BeeTheme.mint)
                  Text(L10n.text("A little breathing room")).font(
                    .system(size: 14, weight: .medium))
                  Text(L10n.text("Add a due date or reminder and it will appear here.")).font(
                    .system(size: 12)
                  ).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 30)
              } else {
                ForEach(upcoming.prefix(7)) { item in
                  HStack(spacing: 11) {
                    if item.kind == "tasks" {
                      TaskCompletionButton(item: item)
                    } else {
                      Image(systemName: "alarm").foregroundStyle(BeeTheme.accent)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                      Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                      Text(item.body["description"] ?? "").font(.system(size: 11)).foregroundStyle(
                        .secondary
                      ).lineLimit(1)
                    }
                    Spacer()
                    Text(
                      item.date!.formatted(
                        date: .abbreviated,
                        time: item.body["dateOnly"] == "true" ? .omitted : .shortened)
                    ).font(.system(size: 11)).foregroundStyle(.secondary)
                  }.padding(.vertical, 5)
                }
              }
            }
          }.frame(maxWidth: .infinity)
          BeeCard(padding: 8) { HebrewCalendarView(followNextZman: true).frame(height: 285) }.frame(
            maxWidth: .infinity)
        }
        BeeCard(padding: 8) { StocksView(compact: true).frame(minHeight: 130) }
      }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
    }.background(BeeTheme.canvas)
  }
}
struct WorldClocksView: View {
  @EnvironmentObject var model: AppModel
  var zones: [String] {
    let value =
      model.items.first { $0.kind == "user_settings" && !$0.deleted }?.body["clocks"]
      ?? "Asia/Jerusalem,Europe/London,America/New_York"
    return Array(
      value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
        TimeZone(identifier: $0) != nil
      }.prefix(3))
  }
  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      HStack(spacing: 16) {
        ForEach(zones, id: \.self) { name in
          if let zone = TimeZone(identifier: name) {
            BeeCard(padding: 18) {
              HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                  HStack(spacing: 6) {
                    Circle().fill(isDay(context.date, zone) ? BeeTheme.amber : BeeTheme.accent)
                      .frame(width: 5, height: 5)
                    Text(
                      name.split(separator: "/").last?.replacingOccurrences(of: "_", with: " ")
                        ?? name
                    ).font(.system(size: 12, weight: .medium))
                  }
                  Text(formatted(context.date, zone)).font(
                    .system(size: 27, weight: .medium, design: .rounded)
                  ).monospacedDigit()
                  Text(dayLabel(context.date, zone) + " · " + offset(context.date, zone)).font(
                    .system(size: 10)
                  ).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isDay(context.date, zone) ? "sun.max" : "moon.stars").font(
                  .system(size: 23, weight: .ultraLight)
                ).foregroundStyle(isDay(context.date, zone) ? BeeTheme.amber : BeeTheme.accent)
                  .opacity(0.8)
              }
            }
          }
        }
      }
    }
  }
  func formatted(_ date: Date, _ zone: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = L10n.locale
    f.timeZone = zone
    f.dateFormat = "HH:mm"
    return f.string(from: date)
  }
  func dayLabel(_ date: Date, _ zone: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = L10n.locale
    f.timeZone = zone
    f.dateFormat = "EEE, d MMM"
    return f.string(from: date)
  }
  func offset(_ date: Date, _ zone: TimeZone) -> String {
    let minutes = zone.secondsFromGMT(for: date) / 60
    return String(
      format: "UTC%@%02d:%02d", minutes >= 0 ? "+" : "−", abs(minutes) / 60, abs(minutes) % 60)
  }
  func isDay(_ date: Date, _ zone: TimeZone) -> Bool {
    var c = Calendar.current
    c.timeZone = zone
    return (7..<19).contains(c.component(.hour, from: date))
  }
}

enum AgendaDayCounts {
  static func values(events: [CalendarEvent], items: [Item], calendar: Calendar = .current)
    -> [Date: Int]
  {
    var counts: [Date: Int] = [:]
    for event in events { counts[calendar.startOfDay(for: event.startDate), default: 0] += 1 }
    for item in items
    where !item.deleted && !item.archived
      && ["tasks", "reminders"].contains(item.kind) && item.body["status"] != "Cancelled"
    {
      if let date = item.date { counts[calendar.startOfDay(for: date), default: 0] += 1 }
    }
    return counts
  }
}

struct AgendaGrid: View {
  @Binding var date: Date
  var range: String
  var events: [CalendarEvent]
  var items: [Item]
  var hebrewDays: [String: HebrewDayInfo] = [:]
  var dates: [Date] {
    AgendaCalendarDays.grid(date: date, range: range)
  }

  var body: some View {
    let counts = AgendaDayCounts.values(events: events, items: items)
    return VStack(spacing: 4) {
      HStack(spacing: 1) {
        ForEach(Array(dates.prefix(7)), id: \.self) { day in
          Text(day.formatted(.dateTime.weekday(.abbreviated).locale(L10n.locale)))
            .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
      }
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 1
      ) {
        ForEach(dates, id: \.self) { day in
          Button {
            date = day
          } label: {
            VStack(spacing: 2) {
              Text(day.formatted(.dateTime.day())).font(.headline)
              if let hebrew = hebrewDays[HebrewAgendaPresentation.key(day)] {
                Text(hebrew.date).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.75)
                if !hebrew.events.isEmpty {
                  Text(hebrew.events.joined(separator: " · ")).font(.system(size: 9)).lineLimit(1)
                    .help(hebrew.summary)
                }
              }
              let count = counts[Calendar.current.startOfDay(for: day)] ?? 0
              Text(count == 0 ? " " : L10n.format("%d items", count)).font(.caption2)
            }.frame(maxWidth: .infinity).padding(4)
              .foregroundStyle(
                Calendar.current.isDate(date, inSameDayAs: day) ? Color.white : Color.primary
              )
              .background(
                Calendar.current.isDate(date, inSameDayAs: day)
                  ? Color(nsColor: .selectedContentBackgroundColor)
                  : Color(nsColor: .controlBackgroundColor)
              )
              .contentShape(Rectangle())
          }.buttonStyle(.plain)
            .accessibilityAddTraits(
              Calendar.current.isDate(date, inSameDayAs: day) ? .isSelected : [])
        }
      }.padding(1).background(.separator)
    }
  }
}
