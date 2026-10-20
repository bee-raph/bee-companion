import AppKit
import IOKit.pwr_mgt
import SwiftUI

@MainActor final class ShabbatController: NSObject, ObservableObject, NSWindowDelegate {
  private var window: NSWindow?
  private var assertion: IOPMAssertionID = 0
  func show(_ model: AppModel) {
    if let window {
      window.makeKeyAndOrderFront(nil)
      return
    }
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let panel = NSWindow(
      contentRect: screen, styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.title = L10n.text("Bee Companion · Shabbat")
    panel.collectionBehavior = [.fullScreenPrimary]
    panel.delegate = self
    panel.contentView = NSHostingView(
      rootView: ShabbatView(close: { [weak self] in self?.window?.close() }).environmentObject(
        model))
    window = panel
    _ = IOPMAssertionCreateWithName(
      kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn), "Bee Companion Shabbat display" as CFString,
      &assertion)
    panel.makeKeyAndOrderFront(nil)
    DispatchQueue.main.async { [weak panel] in panel?.toggleFullScreen(nil) }
  }
  func windowWillClose(_ notification: Notification) {
    if assertion != 0 {
      IOPMAssertionRelease(assertion)
      assertion = 0
    }
    window = nil
  }
}

struct ShabbatView: View {
  @EnvironmentObject var model: AppModel
  @StateObject var data = ReaderData()
  var close: () -> Void
  var body: some View {
    GeometryReader { geometry in
      let scale = max(0.8, min(1.35, geometry.size.height / 1000))
      TimelineView(.periodic(from: .now, by: 15)) { clock in
        VStack(alignment: .leading, spacing: 18 * scale) {
          HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
              Text(L10n.text("BEE COMPANION · SHABBAT")).font(
                .system(size: 13 * scale, weight: .semibold)
              )
              .tracking(3).foregroundStyle(.white.opacity(0.6))
              Text(
                model.preferences.body["city"].flatMap { $0.isEmpty ? nil : $0 }
                  ?? L10n.text("Your Shabbat screen")
              ).font(.system(size: 30 * scale, weight: .medium))
              Text(hebrew(clock.date)).font(.system(size: 19 * scale)).foregroundStyle(
                .white.opacity(0.75))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
              Text(time(clock.date)).font(
                .system(size: 48 * scale, weight: .light, design: .rounded)
              ).monospacedDigit()
              Text(clock.date.formatted(date: .complete, time: .omitted)).font(
                .system(size: 14 * scale)
              ).foregroundStyle(.white.opacity(0.6))
            }
            Button(L10n.text("Exit · Esc"), action: close).buttonStyle(.bordered).padding(
              .leading, 16)
          }
          HStack(alignment: .top, spacing: 18 * scale) {
            panel {
              VStack(alignment: .leading, spacing: 15 * scale) {
                heading(L10n.text("Zmanim"), symbol: "sun.horizon", scale: scale)
                let next = ZmanimEntry.next(in: data.zmanim, now: clock.date)
                let first =
                  next.flatMap { id in data.zmanim.firstIndex { $0.id == id } }
                  ?? max(0, data.zmanim.count - 6)
                if data.zmanim.isEmpty {
                  Text(L10n.text("Configure your location in Settings.")).foregroundStyle(
                    .white.opacity(0.6))
                }
                LazyVGrid(
                  columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12 * scale
                ) {
                  ForEach(Array(data.zmanim.dropFirst(first).prefix(6))) { entry in
                    HStack {
                      Text(entry.title).font(.system(size: 16 * scale)).lineLimit(1)
                      Spacer()
                      Text(time(entry.date)).font(
                        .system(size: 24 * scale, weight: .medium, design: .rounded)
                      ).monospacedDigit()
                    }.padding(9 * scale).background(
                      entry.id == next ? Color.indigo.opacity(0.4) : Color.white.opacity(0.03),
                      in: RoundedRectangle(cornerRadius: 9))
                  }
                }
              }
            }.frame(maxWidth: .infinity)
            panel {
              VStack(alignment: .leading, spacing: 12 * scale) {
                heading(L10n.text("Local weather"), symbol: "cloud.sun", scale: scale)
                if let weather = data.weather {
                  HStack {
                    Image(systemName: weather.symbol).font(.system(size: 38 * scale))
                      .foregroundStyle(.yellow.opacity(0.85))
                    Text(String(format: "%.0f°", locale: L10n.locale, weather.temperature)).font(
                      .system(size: 54 * scale, weight: .light))
                    Spacer()
                    VStack(alignment: .trailing) {
                      Text(L10n.text(weather.condition)).font(.system(size: 20 * scale))
                      Text(
                        String(
                          format: L10n.text("High %.0f° · Low %.0f°"), weather.high, weather.low)
                      )
                      .font(.system(size: 16 * scale)).foregroundStyle(.white.opacity(0.7))
                    }
                  }
                  Text(
                    String(
                      format: L10n.text("Feels like %.0f°C · Humidity %.0f%% · Wind %.0f km/h"),
                      weather.feelsLike, weather.humidity, weather.wind)
                  ).font(.system(size: 15 * scale)).foregroundStyle(.white.opacity(0.7))
                  Text(
                    L10n.text("Open-Meteo · ")
                      + (weather.stale
                        ? "Saved conditions"
                        : weather.timestamp.replacingOccurrences(of: "T", with: " "))
                  ).font(.system(size: 11 * scale)).foregroundStyle(.white.opacity(0.5))
                } else {
                  Text(
                    L10n.text("Weather appears after your location is configured and refreshed.")
                  )
                  .foregroundStyle(.white.opacity(0.6))
                }
              }
            }.frame(maxWidth: .infinity)
          }
          if !data.quotes.isEmpty {
            panel {
              VStack(alignment: .leading, spacing: 12 * scale) {
                heading(L10n.text("Market watch"), symbol: "chart.xyaxis.line", scale: scale)
                LazyVGrid(
                  columns: Array(
                    repeating: GridItem(.flexible()), count: min(6, data.quotes.count)),
                  alignment: .leading, spacing: 12
                ) {
                  ForEach(data.quotes) { quote in
                    VStack(alignment: .leading, spacing: 5) {
                      Text(quote.symbol).font(.system(size: 17 * scale, weight: .semibold))
                      Text(
                        quote.price.map { String(format: "%.2f", locale: L10n.locale, $0) }
                          ?? L10n.text("—")
                      ).font(
                        .system(size: 27 * scale, weight: .medium, design: .rounded)
                      ).monospacedDigit()
                      Text(
                        quote.changePercent.map {
                          String(format: "%+.2f%%", locale: L10n.locale, $0)
                        }
                          ?? L10n.text("Unavailable")
                      ).font(.system(size: 17 * scale)).foregroundStyle(
                        (quote.changePercent ?? 0) >= 0 ? .mint : .orange)
                      Text(quote.timestamp.map(BeeDisplayTime.timestamp) ?? quote.error ?? "").font(
                        .system(size: 10 * scale)
                      ).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                  }
                }
              }
            }
          }
          HStack(alignment: .top, spacing: 18 * scale) {
            if data.feeds.isEmpty {
              panel {
                VStack(alignment: .leading, spacing: 12) {
                  heading(L10n.text("Your RSS feeds"), symbol: "newspaper", scale: scale)
                  Text(L10n.text("Add up to three feeds in Settings → RSS & Shabbat mode."))
                    .foregroundStyle(
                      .white.opacity(0.6))
                  Spacer()
                }
              }
            }
            ForEach(data.feeds) { feed in
              panel {
                VStack(alignment: .leading, spacing: 15 * scale) {
                  heading(feed.title, symbol: "newspaper", scale: scale)
                  if !feed.articles.isEmpty {
                    GeometryReader { space in
                      let articles = Array(feed.articles.prefix(10))
                      let rowHeight = max(1, space.size.height / CGFloat(articles.count))
                      VStack(spacing: 0) {
                        ForEach(articles) { article in
                          VStack(alignment: .leading, spacing: 2) {
                            Text(article.title)
                              .font(.system(size: 15 * scale, weight: .medium))
                              .lineLimit(rowHeight >= 44 ? 2 : 1)
                              .minimumScaleFactor(0.85)
                              .frame(maxWidth: .infinity, alignment: .leading)
                            if rowHeight >= 54 {
                              Text(BeeDisplayTime.timestamp(article.published))
                                .font(.system(size: 10 * scale))
                                .foregroundStyle(.white.opacity(0.5))
                            }
                          }
                          .frame(height: max(1, rowHeight - 1), alignment: .leading)
                          Divider().overlay(.white.opacity(0.12))
                        }
                      }
                    }
                  } else {
                    Text(feed.error ?? L10n.text("No articles in this feed.")).foregroundStyle(
                      .white.opacity(0.6))
                    Spacer()
                  }
                  if feed.stale {
                    Text(L10n.text("Saved articles · feed unavailable")).font(.caption)
                      .foregroundStyle(
                        .orange)
                  }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
              }
            }
          }.frame(maxHeight: .infinity)
          HStack {
            Text(
              data.refreshing
                ? L10n.text("Refreshing…")
                : L10n.format(
                  "Automatic refresh every %d min · Latest 10 headlines per feed",
                  ReaderPreferences.refreshSeconds(model.preferences.body) / 60)
            )
            Spacer()
            if let last = data.lastRefresh {
              Text(
                L10n.format(
                  "Last refresh %@", last.formatted(.dateTime.hour().minute().locale(L10n.locale))))
            }
          }.font(.system(size: 11 * scale)).foregroundStyle(.white.opacity(0.5))
          if !data.messages.isEmpty {
            Text(data.messages.map(L10n.message).joined(separator: " · ")).font(
              .system(size: 11 * scale)
            )
            .foregroundStyle(.orange).lineLimit(2)
          }
        }.padding(28 * scale)
      }
    }
    .foregroundStyle(.white).background(Color(red: 0.045, green: 0.055, blue: 0.11))
    .preferredColorScheme(.dark)
    .environment(\.locale, model.language.locale)
    .environment(\.layoutDirection, model.language.direction)
    .onExitCommand(perform: close)
    .task(
      id: (model.configuration?.instanceID ?? "local")
        + (model.preferences.body["shabbatRefreshSeconds"] ?? "300")
        + CompanionLocation(model.preferences.body).identity
    ) {
      while !Task.isCancelled {
        await data.refresh(model, dashboard: true)
        try? await Task.sleep(
          for: .seconds(ReaderPreferences.refreshSeconds(model.preferences.body)))
        if Task.isCancelled { break }
      }
    }
  }
  func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content().padding(20).background(
      Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18)
    ).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.white.opacity(0.08)))
  }
  func heading(_ title: String, symbol: String, scale: Double) -> some View {
    Label(title, systemImage: symbol).font(.system(size: 17 * scale, weight: .semibold))
      .foregroundStyle(.white.opacity(0.7))
  }
  func time(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = L10n.locale
    f.timeZone = TimeZone(identifier: model.preferences.body["timezone"] ?? "Asia/Jerusalem")
    f.dateFormat = "HH:mm"
    return f.string(from: date)
  }
  func hebrew(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = L10n.locale
    f.calendar = Calendar(identifier: .hebrew)
    f.locale = Locale(identifier: "he_IL")
    f.dateStyle = .full
    f.timeZone = TimeZone(identifier: model.preferences.body["timezone"] ?? "Asia/Jerusalem")
    return f.string(from: date)
  }
}
