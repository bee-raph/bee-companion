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
  var watchlist: [Item] {
    model.items.filter { $0.kind == "watchlist_items" && !$0.deleted }.sorted {
      Int($0.body["order"] ?? "0") ?? 0 < Int($1.body["order"] ?? "0") ?? 0
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        BeeSectionHeading(
          title: "Market watch", subtitle: "Your followed instruments", symbol: "chart.xyaxis.line")
        Spacer()
        Button("Refresh") { Task { await refresh() } }
      }
      if !compact {
        HStack {
          TextField("Search instruments", text: $query)
          Button("Search") { Task { await search() } }
        }
        ForEach(found.prefix(10)) { instrument in
          HStack {
            VStack(alignment: .leading, spacing: 3) {
              Text(instrument.symbol + " · " + (instrument.name ?? ""))
              if let category = instrument.category {
                Text(category).font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer()
            Button("Follow") {
              model.save(
                Item(
                  kind: "watchlist_items",
                  body: [
                    "title": instrument.name ?? instrument.symbol, "symbol": instrument.symbol,
                    "order": String(watchlist.count), "tradingView": instrument.symbol,
                  ]))
              found = []
              Task { await refresh() }
            }
          }
        }
      }
      Text(message).font(.caption).foregroundStyle(.secondary)
      ForEach(watchlist.prefix(compact ? 5 : 100)) { item in
        HStack {
          Button(item.body["symbol"] ?? item.title) { open(item) }.buttonStyle(.link)
          Text(item.title).lineLimit(1)
          Spacer()
          if let quote = quotes.first(where: { $0.symbol == item.body["symbol"] }) {
            Text(quote.price.map { String(format: "%.4f", $0) } ?? "—").monospacedDigit()
            Text(quote.change.map { String(format: "%+.4f", $0) } ?? "—").monospacedDigit()
            Text(quote.changePercent.map { String(format: "%+.2f%%", $0) } ?? "—").foregroundStyle(
              (quote.changePercent ?? 0) >= 0 ? .green : .red)
            VStack(alignment: .trailing) {
              Text(quote.timestamp.map(BeeDisplayTime.timestamp) ?? "Unavailable")
              Text(quote.source ?? quote.error ?? "")
            }.font(.caption)
          } else {
            Text("—")
          }
          if !compact {
            TextField(
              "TradingView symbol",
              text: Binding(
                get: { item.body["tradingView"] ?? "" },
                set: { value in
                  var copy = item
                  copy.body["tradingView"] = value
                  model.save(copy)
                })
            ).frame(width: 130)
            Button("↑") {
              var copy = item
              copy.body["order"] = String((Int(item.body["order"] ?? "0") ?? 0) - 1)
              model.save(copy)
            }
            Button("Remove") {
              var copy = item
              copy.deleted = true
              model.save(copy)
            }
          }
        }
      }
      if watchlist.isEmpty {
        Text("Search for an instrument to start following prices.").foregroundStyle(.secondary)
      }
    }.padding().task {
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
      message = "London Strategic Edge · latest available candles"
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
    model.items.first { $0.kind == "user_settings" && !$0.deleted }
      ?? Item(id: "00000000-0000-0000-0000-000000000001", kind: "user_settings", body: [:])
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
        Text("Instance").font(.title2)
        Text(model.configuration?.instanceName ?? "Local library")
        Text(model.configuration?.apiBaseURL.absoluteString ?? "No backend configured")
          .foregroundStyle(.secondary)
        Button("Import instance configuration") { model.importConfiguration() }
        TextField("Owner login", text: $login)
        SecureField("Password", text: $password)
        HStack {
          Button("Sign in") {
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
          Button("Sign out") {
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
        Text(result).font(.caption)
        Divider()
        Text("World clocks").font(.title2)
        TextField(
          "Up to three IANA zones, comma separated",
          text: binding("clocks", "Asia/Jerusalem,Europe/London,America/New_York"))
        Divider()
        Text("Hebrew calendar").font(.title2)
        Toggle(
          "Israel observances",
          isOn: Binding(
            get: { settings.body["israel"] != "false" },
            set: { value in
              var item = settings
              item.body["israel"] = String(value)
              model.save(item)
            }))
        TextField("City name", text: binding("city"))
        TextField("Latitude", text: binding("latitude"))
        TextField("Longitude", text: binding("longitude"))
        TextField("Time zone", text: binding("timezone", "Asia/Jerusalem"))
        Text(
          "Location is required for candle lighting and zmanim. Calendar events from Apple stay local."
        ).font(.caption)
        Divider()
        ReadingSettingsView()
        Divider()
        Text("Conflicts").font(.title2)
        ForEach(model.conflicts) { conflict in
          VStack(alignment: .leading) {
            Text(conflict.local.title).font(.headline)
            HStack(alignment: .top) {
              Text("Your version\n" + Sharing.plain(conflict.local)).textSelection(.enabled)
              Divider()
              Text("Server version\n" + (conflict.server.map { Sharing.plain($0) } ?? "Deleted"))
                .textSelection(.enabled)
            }
            HStack {
              Button("Keep my version") { model.resolve(conflict, keepLocal: true) }
              Button("Use server version") { model.resolve(conflict, keepLocal: false) }
            }
          }
        }
        Divider()
        Text("Diagnostics").font(.title2)
        Text(model.message)
        Text("\(model.pending) pending changes")
        Button("Check external file edits") { model.checkWorkingCopies() }
        Text(
          "The app saves locally. Docker is required only for backend access and synchronization."
        ).font(.caption)
      }.formStyle(.grouped).padding()
    }
  }
}
