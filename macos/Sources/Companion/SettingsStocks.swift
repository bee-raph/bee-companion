import SwiftUI

struct QuoteResponse: Codable {
  struct Quote: Codable, Identifiable {
    var symbol: String
    var price: Double?
    var change: Double?
    var changePercent: Double?
    var timestamp: String?
    var source: String?
    var error: String?
    var id: String { symbol }
  }
  var quotes: [Quote]
}
struct SearchResponse: Codable {
  struct Instrument: Codable, Identifiable {
    var symbol: String
    var name: String?
    var category: String?
    var dataset: String?
    // A provider symbol can occur in both stocks and options catalogs.
    var id: String { (dataset ?? category ?? "instrument") + ":" + symbol }
  }
  var instruments: [Instrument]
}
struct StocksView: View {
  @EnvironmentObject var model: AppModel
  var compact = false
  @State var query = ""
  @State var found: [SearchResponse.Instrument] = []
  @State var quotes: [QuoteResponse.Quote] = []
  @State var message = ""
  @State var searchGeneration = 0
  @State private var selectedStock: String?
  @FocusState private var searchFocused: Bool
  var watchlist: [Item] {
    model.items.filter { $0.kind == "watchlist_items" && !$0.deleted }.sorted {
      Int($0.body["order"] ?? "0") ?? 0 < Int($1.body["order"] ?? "0") ?? 0
    }
  }
  private var watchlistRows: some View {
    ForEach(watchlist.prefix(compact ? 5 : 100)) { item in
      HStack {
        Button(item.body["symbol"] ?? item.title) { open(item) }.buttonStyle(.link)
        Text(item.title).lineLimit(1)
        Spacer()
        if let quote = quotes.first(where: { $0.symbol == item.body["symbol"] }) {
          Text(quote.price.map { String(format: "%.4f", $0) } ?? L10n.text("—")).monospacedDigit()
          Text(quote.change.map { String(format: "%+.4f", $0) } ?? L10n.text("—"))
            .monospacedDigit()
          Text(quote.changePercent.map { String(format: "%+.2f%%", $0) } ?? L10n.text("—"))
            .foregroundStyle(
              (quote.changePercent ?? 0) >= 0 ? .green : .red)
          VStack(alignment: .trailing) {
            Text(quote.timestamp.map(BeeDisplayTime.timestamp) ?? L10n.text("Unavailable"))
            if let error = quote.error { Text(L10n.message(error)) }
          }.font(.caption)
        } else {
          Text(L10n.text("—"))
        }
        if !compact {
          TextField(
            L10n.text("TradingView symbol"),
            text: Binding(
              get: { item.body["tradingView"] ?? "" },
              set: { value in
                var copy = item
                copy.body["tradingView"] = value
                model.save(copy)
              })
          ).frame(width: 130)
          Button(L10n.text("↑")) {
            var copy = item
            copy.body["order"] = String((Int(item.body["order"] ?? "0") ?? 0) - 1)
            model.save(copy)
          }

        }
      }.tag(item.id).padding(.vertical, 3)
    }
  }
  private var content: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        BeeSectionHeading(
          title: "Market watch", subtitle: "Your followed instruments", symbol: "chart.xyaxis.line")
        Spacer()
        if !compact {
          Text(L10n.text("Updates automatically")).font(.caption).foregroundStyle(.secondary)
        }
      }
      if !compact {
        HStack {
          TextField(L10n.text("Search instruments"), text: $query).focused($searchFocused)
          Button(L10n.text("Search")) { Task { await search() } }
        }
        if !found.isEmpty {
          List {
            ForEach(found.prefix(10)) { instrument in
              VStack(spacing: 0) {
                HStack {
                  VStack(alignment: .leading, spacing: 3) {
                    Text(instrument.symbol + " · " + (instrument.name ?? ""))
                    if let category = instrument.category {
                      Text(category).font(.caption).foregroundStyle(.secondary)
                    }
                  }
                  Spacer()
                  Button(L10n.text("Follow")) {
                    model.save(
                      Item(
                        kind: "watchlist_items",
                        body: [
                          "title": instrument.name ?? instrument.symbol,
                          "symbol": instrument.symbol,
                          "order": String(watchlist.count), "tradingView": instrument.symbol,
                        ]))
                    found = []
                    Task { await refresh() }
                  }.controlSize(.small)
                }.padding(.horizontal, 14).padding(.vertical, 12)
                Divider()
              }
            }
          }.listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(height: CGFloat(min(found.count, 5)) * 64)
        }
      }
      if !message.isEmpty { Text(L10n.message(message)).font(.caption).foregroundStyle(.secondary) }
      if compact {
        watchlistRows
      } else {
        VStack(spacing: 0) {
          List(selection: $selectedStock) { watchlistRows }
            .listStyle(.inset(alternatesRowBackgrounds: true)).frame(minHeight: 180)
          CollectionControls(
            addTitle: "Search instruments", removeTitle: "Remove",
            canRemove: watchlist.contains { $0.id == selectedStock },
            add: { searchFocused = true },
            remove: {
              guard var item = watchlist.first(where: { $0.id == selectedStock }) else { return }
              item.deleted = true
              model.save(item)
              selectedStock = nil
            }
          ) { EmptyView() }
        }.overlay(Rectangle().strokeBorder(.separator, lineWidth: 0.5))
      }
      if watchlist.isEmpty {
        Text(L10n.text("Search for an instrument to start following prices.")).foregroundStyle(
          .secondary)
      }
    }.padding()
  }
  var body: some View {
    Group {
      if compact {
        content
      } else {
        ScrollView { content.frame(maxWidth: .infinity, alignment: .leading) }
      }
    }.task(id: watchlist.map { $0.id + ($0.body["symbol"] ?? "") }.joined(separator: ",")) {
      while !Task.isCancelled {
        await refresh()
        try? await Task.sleep(for: .seconds(60))
        if Task.isCancelled { break }
      }
    }
  }
  func open(_ item: Item) {
    var components = URLComponents(string: "https://www.tradingview.com/chart/")!
    components.queryItems = [
      URLQueryItem(name: "symbol", value: item.body["tradingView"] ?? item.body["symbol"])
    ]
    if let url = components.url { NSWorkspace.shared.open(url) }
  }
  func search() async {
    guard let api = model.api else { return }
    searchGeneration += 1
    let generation = searchGeneration
    let submittedQuery = query
    do {
      let result: SearchResponse = try await api.request(
        "market/search?q="
          + (submittedQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""))
      guard generation == searchGeneration else { return }
      var seen = Set<String>()
      found = result.instruments.filter { seen.insert($0.id).inserted }
      message = ""
    } catch {
      if generation == searchGeneration { message = error.localizedDescription }
    }
  }
  func refresh() async {
    guard let api = model.api, !watchlist.isEmpty else { return }
    do {
      let symbols =
        watchlist.compactMap { $0.body["symbol"] }.joined(separator: ",").addingPercentEncoding(
          withAllowedCharacters: .urlQueryAllowed) ?? ""
      let result: QuoteResponse = try await api.request("market/quotes?symbols=" + symbols)
      quotes = result.quotes
      message = ""
    } catch { message = error.localizedDescription }
  }
}
struct SettingsView: View {
  @EnvironmentObject var model: AppModel
  @State var login = "owner"
  @State var password = ""
  @State var busy = false
  @State var result = ""
  var settings: Item {
    model.preferences
  }
  func binding(_ key: String, _ fallback: String = "") -> Binding<String> {
    Binding(
      get: { settings.body[key] ?? fallback },
      set: { value in
        var item = settings
        item.body[key] = value
        model.save(item)
      })
  }
  var body: some View {
    ScrollView {
      Form {
        Picker(
          L10n.text("Language"),
          selection: Binding(
            get: { model.language }, set: { model.setLanguage($0) }
          )
        ) {
          ForEach(AppLanguage.allCases) { language in
            Text(language.name).tag(language)
          }
        }
        Divider()
        Text(L10n.text("Instance")).font(.title2)
        Text(model.configuration?.instanceName ?? L10n.text("Local library"))
        Text(model.configuration?.apiBaseURL.absoluteString ?? L10n.text("No backend configured"))
          .foregroundStyle(.secondary)
        Button(L10n.text("Import instance configuration")) { model.importConfiguration() }
        TextField(L10n.text("Owner login"), text: $login)
        SecureField(L10n.text("Password"), text: $password)
        HStack {
          Button(L10n.text("Sign in")) {
            guard let api = model.api else { return }
            busy = true
            Task {
              do {
                try await api.login(login, password)
                password = ""
                await model.sync()
                result = "Signed in"
              } catch { result = error.localizedDescription }
              busy = false
            }
          }.disabled(busy || model.api == nil)
          Button(L10n.text("Sign out")) {
            Task {
              do {
                guard model.pending == 0 else {
                  throw CompanionError.message("Synchronize pending changes before signing out")
                }
                try await model.api?.signOut()
                result = "Signed out"
              } catch { result = error.localizedDescription }
            }
          }
        }
        Text(L10n.message(result)).font(.caption)
        Divider()
        Text(L10n.text("World clocks")).font(.title2)
        TextField(
          L10n.text("Up to three IANA zones, comma separated"),
          text: binding("clocks", "Asia/Jerusalem,Europe/London,America/New_York"))
        Divider()
        Text(L10n.text("Hebrew calendar")).font(.title2)
        Toggle(
          L10n.text("Israel observances"),
          isOn: Binding(
            get: { settings.body["israel"] != "false" },
            set: { value in
              var item = settings
              item.body["israel"] = String(value)
              model.save(item)
            }))
        TextField(L10n.text("City name"), text: binding("city"))
        TextField(L10n.text("Latitude"), text: binding("latitude"))
        TextField(L10n.text("Longitude"), text: binding("longitude"))
        TextField(L10n.text("Time zone"), text: binding("timezone", "Asia/Jerusalem"))
        Text(
          L10n.text(
            "Location is required for candle lighting and zmanim. Calendar events from Apple stay local."
          )
        ).font(.caption)
        Divider()
        ReadingSettingsView()
        Divider()
        Text(L10n.text("Conflicts")).font(.title2)
        ForEach(model.conflicts) { conflict in
          VStack(alignment: .leading) {
            Text(conflict.local.title).font(.headline)
            HStack(alignment: .top) {
              Text(L10n.text("Your version\n") + Sharing.plain(conflict.local)).textSelection(
                .enabled)
              Divider()
              Text(
                L10n.text("Server version\n")
                  + (conflict.server.map { Sharing.plain($0) } ?? "Deleted")
              )
              .textSelection(.enabled)
            }
            HStack {
              Button(L10n.text("Keep my version")) { model.resolve(conflict, keepLocal: true) }
              Button(L10n.text("Use server version")) { model.resolve(conflict, keepLocal: false) }
            }
          }
        }
        Divider()
        Text(L10n.text("Diagnostics")).font(.title2)
        Text(L10n.message(model.message))
        Text(L10n.format("%d pending changes", model.pending))
        Button(L10n.text("Check external file edits")) { model.checkWorkingCopies() }
        Text(
          L10n.text(
            "The app saves locally. Docker is required only for backend access and synchronization."
          )
        ).font(.caption)
      }.formStyle(.grouped).padding().frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
