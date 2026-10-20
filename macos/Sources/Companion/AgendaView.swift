import EventKit
import SwiftUI

enum CalendarSelection {
  static func resolve(available: [String], stored: [String]?) -> Set<String> {
    let known = Set(available)
    return stored.map { Set($0).intersection(known) } ?? known
  }
}

@MainActor final class AgendaService: ObservableObject {
  let store = EKEventStore()
  private let authorization: () -> EKAuthorizationStatus
  @Published var events: [EKEvent] = []
  @Published var calendars: [EKCalendar] = []
  @Published var access: EKAuthorizationStatus = .notDetermined
  @Published var requesting = false
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
      stored: UserDefaults.standard.stringArray(forKey: "selectedCalendars"))
  }
  func refresh(_ date: Date, days: Int = 7) {
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
    calendars = store.calendars(for: .event).sorted {
      $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }
    guard !calendars.isEmpty else {
      events = []
      message =
        "No calendars are available. Add a calendar or account in the Calendar app, then refresh."
      return
    }
    let chosen = calendars.filter { selectedIDs.contains($0.calendarIdentifier) }
    guard !chosen.isEmpty else {
      events = []
      message = "No calendars selected. Choose calendars from the menu below."
      return
    }
    let start = Calendar.current.startOfDay(for: date)
    let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
    events = store.events(
      matching: store.predicateForEvents(withStart: start, end: end, calendars: chosen)
    ).sorted { $0.startDate < $1.startDate }
    message = "Apple Calendar data stays on this Mac."
  }
  func select(_ calendar: EKCalendar, enabled: Bool, date: Date, days: Int) {
    var ids = selectedIDs
    if enabled {
      ids.insert(calendar.calendarIdentifier)
    } else {
      ids.remove(calendar.calendarIdentifier)
    }
    UserDefaults.standard.set(Array(ids), forKey: "selectedCalendars")
    refresh(date, days: days)
  }
  func selectAll(_ enabled: Bool, date: Date, days: Int) {
    UserDefaults.standard.set(
      enabled ? calendars.map(\.calendarIdentifier) : [], forKey: "selectedCalendars")
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
  @State var date = Date()
  @State var range = "Week"
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
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        DatePicker(L10n.text("Date"), selection: $date, displayedComponents: .date)
        Picker(L10n.text("Range"), selection: $range) {
          ForEach(["Day", "Week", "Month"], id: \.self) { Text(L10n.text($0)).tag($0) }
        }.pickerStyle(.segmented)
        if agenda.access != .fullAccess {
          Button(
            agenda.requesting ? L10n.text("Requesting access…") : L10n.text("Enable Apple Calendar")
          ) {
            Task { await agenda.enable(date: start, days: days) }
          }.disabled(agenda.requesting)
        }
      }.padding(.horizontal)
      if range != "Day" {
        AgendaGrid(date: $date, range: range, events: agenda.events, items: model.items).padding(
          .horizontal)
      }
      Text(L10n.message(agenda.message)).font(.caption).foregroundStyle(.secondary).padding(
        .horizontal)
      Menu {
        if agenda.calendars.isEmpty {
          if agenda.access == .fullAccess {
            Text(L10n.text("No calendars found")).disabled(true)
            Button(L10n.text("Open Calendar")) { NSWorkspace.shared.open(URL(string: "ical://")!) }
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
              Text(calendar.title + " · " + calendar.source.title)
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
            : L10n.format("Calendars (%d of %d)", agenda.selectedIDs.count, agenda.calendars.count),
          systemImage: "calendar.badge.checkmark")
      }.padding(.horizontal)
      List {
        ForEach(agenda.events, id: \.eventIdentifier) { event in
          HStack {
            Circle().fill(Color(nsColor: event.calendar.color)).frame(width: 8)
            VStack(alignment: .leading) {
              Text(event.title ?? L10n.text("Event")).font(.headline)
              Text(event.startDate.formatted() + " · " + event.calendar.title).font(.caption)
            }
            Spacer()
            Button(L10n.text("Open Calendar")) { NSWorkspace.shared.open(URL(string: "ical://")!) }
          }
        }
        ForEach(
          model.items.filter {
            ["tasks", "reminders"].contains($0.kind) && !$0.deleted && !$0.archived
              && ($0.date ?? .distantPast) >= Calendar.current.startOfDay(for: date)
              && ($0.date ?? .distantFuture) < date.addingTimeInterval(Double(days) * 86400)
          }
        ) { item in
          Label(
            item.title + " · " + (item.date?.formatted() ?? ""),
            systemImage: item.kind == "tasks" ? "checklist" : "alarm")
        }
      }
      HebrewCalendarView().environmentObject(model).frame(maxHeight: 260)
    }.padding(.vertical).onAppear { agenda.refresh(start, days: days) }.onChange(of: date) { _, _ in
      agenda.refresh(start, days: days)
    }.onChange(of: range) { _, _ in agenda.refresh(start, days: days) }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        agenda.refresh(start, days: days)
      }
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
    }.padding().task {
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
    guard let api = model.api else {
      message = "Connect backend to load holidays and location times."
      return
    }
    let settings = model.items.first { $0.kind == "user_settings" && !$0.deleted }
    let year = Calendar.current.component(.year, from: Date())
    struct Zmanim: Decodable { var times: [String: String] }
    if let lat = settings?.body["latitude"], let lon = settings?.body["longitude"], !lat.isEmpty,
      !lon.isEmpty
    {
      let date = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
      if let result: Zmanim = try? await api.request(
        "calendar/zmanim?date=\(date)&latitude=\(lat)&longitude=\(lon)&timezone="
          + (settings?.body["timezone"] ?? "Asia/Jerusalem"))
      {
        zmanim = result.times
        UserDefaults.standard.set(result.times, forKey: key + ".zmanim." + date)
      } else {
        zmanim =
          UserDefaults.standard.dictionary(forKey: key + ".zmanim." + date) as? [String: String]
          ?? [:]
      }
    }
    var path = "calendar/hebrew?year=\(year)&israel=\(settings?.body["israel"] != "false")"
    if let lat = settings?.body["latitude"], let lon = settings?.body["longitude"], !lat.isEmpty,
      !lon.isEmpty
    {
      path +=
        "&latitude=\(lat)&longitude=\(lon)&timezone="
        + (settings?.body["timezone"] ?? "Asia/Jerusalem")
    }
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
                    Image(systemName: item.kind == "tasks" ? "circle" : "alarm").foregroundStyle(
                      BeeTheme.accent)
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

struct AgendaGrid: View {
  @Binding var date: Date
  var range: String
  var events: [EKEvent]
  var items: [Item]
  var dates: [Date] {
    let calendar = Calendar.current
    let interval = calendar.dateInterval(of: range == "Month" ? .month : .weekOfYear, for: date)!
    let first =
      range == "Month"
      ? calendar.dateInterval(of: .weekOfYear, for: interval.start)!.start : interval.start
    let count = range == "Month" ? 42 : 7
    return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
  }
  var body: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 5) {
      ForEach(dates, id: \.self) { day in
        Button {
          date = day
        } label: {
          VStack(spacing: 3) {
            Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundStyle(
              .secondary)
            Text(day.formatted(.dateTime.day())).font(.headline)
            let count =
              events.filter { Calendar.current.isDate($0.startDate, inSameDayAs: day) }.count
              + items.filter {
                !$0.deleted && !$0.archived
                  && $0.date.map { Calendar.current.isDate($0, inSameDayAs: day) } == true
              }.count
            Text(count == 0 ? " " : L10n.format("%d items", count)).font(.caption2)
          }.frame(maxWidth: .infinity).padding(5)
            .background(
              Calendar.current.isDate(date, inSameDayAs: day)
                ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.06),
              in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
      }
    }
  }
}
