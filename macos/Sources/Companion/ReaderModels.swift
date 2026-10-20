import SwiftUI

struct FeedConfiguration: Codable, Identifiable, Equatable {
  var id = UUID().uuidString.lowercased()
  var title = ""
  var url = ""
}
struct RSSResponse: Codable, Sendable {
  struct Feed: Codable, Identifiable, Sendable {
    struct Article: Codable, Identifiable, Sendable {
      var id: String
      var title: String
      var summary: String
      var url: String
      var published: String
    }
    var id: String
    var title: String
    var url: String
    var articles: [Article]
    var fetchedAt: String?
    var stale: Bool
    var error: String?
  }
  var feeds: [Feed]
}
struct WeatherResponse: Codable, Sendable {
  var temperature: Double
  var feelsLike: Double
  var humidity: Double
  var code: Int
  var wind: Double
  var high: Double
  var low: Double
  var timestamp: String
  var attribution: String
  var stale: Bool
  var condition: String {
    switch code {
    case 0: return "Clear sky"
    case 1...3: return "Partly cloudy"
    case 45, 48: return "Fog"
    case 51...67: return "Rain"
    case 71...77, 85, 86: return "Snow"
    case 80...82: return "Rain showers"
    case 95...99: return "Thunderstorms"
    default: return "Current conditions"
    }
  }
  var symbol: String {
    code == 0
      ? "sun.max.fill"
      : code < 4
        ? "cloud.sun.fill"
        : code >= 95
          ? "cloud.bolt.rain.fill"
          : code >= 71 && code <= 77 ? "cloud.snow.fill" : "cloud.rain.fill"
  }
}
extension AppModel {
  var preferences: Item {
    items.first { $0.kind == "user_settings" && !$0.deleted }
      ?? Item(id: "00000000-0000-0000-0000-000000000001", kind: "user_settings")
  }
  var feedConfigurations: [FeedConfiguration] {
    guard let text = preferences.body["rssFeeds"], let data = text.data(using: .utf8) else {
      return []
    }
    return (try? JSONDecoder().decode([FeedConfiguration].self, from: data)) ?? []
  }
}
enum ReaderPreferences {
  static func refreshSeconds(_ body: [String: String]) -> Int {
    min(3600, max(60, Int(body["shabbatRefreshSeconds"] ?? "300") ?? 300))
  }
  static func rotationSeconds(_ body: [String: String]) -> Int {
    min(120, max(10, Int(body["shabbatRotationSeconds"] ?? "15") ?? 15))
  }
  static func selectedStocks(_ body: [String: String]) -> [String] {
    guard let data = body["shabbatStocks"]?.data(using: .utf8) else { return [] }
    return Array(((try? JSONDecoder().decode([String].self, from: data)) ?? []).prefix(6))
  }
  static func validate(_ feeds: [FeedConfiguration]) throws {
    guard feeds.count <= 3, Set(feeds.map(\.id)).count == feeds.count else {
      throw CompanionError.message("Configure at most three distinct feeds")
    }
    for feed in feeds {
      guard let url = URLComponents(string: feed.url),
        ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil,
        url.password == nil, url.fragment == nil
      else {
        throw CompanionError.message("Enter a public HTTP or HTTPS feed URL without credentials")
      }
    }
  }
}
@MainActor final class ReaderData: ObservableObject {
  @Published var feeds: [RSSResponse.Feed] = []
  @Published var weather: WeatherResponse?
  @Published var quotes: [QuoteResponse.Quote] = []
  @Published var zmanim: [ZmanimEntry] = []
  @Published var messages: [String] = []
  @Published var refreshing = false
  @Published var lastRefresh: Date?
  private var instance = ""
  private var restoreTask: Task<Void, Never>?
  private var refreshGeneration = 0
  private var locationGeneration = 0
  func restore(_ model: AppModel) async {
    let identity = model.configuration?.instanceID ?? "local"
    if identity == instance {
      await restoreTask?.value
      return
    }
    restoreTask?.cancel()
    instance = identity
    refreshGeneration += 1
    locationGeneration += 1
    refreshing = false
    feeds = []
    weather = nil
    quotes = []
    zmanim = []
    let root = model.cache
    let task = Task { [weak self] in
      async let savedFeeds = ReaderCache.read(
        RSSResponse.self, from: root.appendingPathComponent("rss-cache.json"))
      async let savedWeather = ReaderCache.read(
        WeatherResponse.self, from: root.appendingPathComponent("weather-cache.json"))
      let stored = await (savedFeeds, savedWeather)
      guard let self, !Task.isCancelled, self.instance == identity else { return }
      self.feeds = (stored.0?.feeds ?? []).map { value in
        var feed = value
        feed.stale = true
        return feed
      }
      if var saved = stored.1 {
        saved.stale = true
        self.weather = saved
      }
      self.restoreTask = nil
    }
    restoreTask = task
    await task.value
  }
  func refreshLocation(_ model: AppModel, enabled: Bool = true) async {
    guard enabled else { return }
    await restore(model)
    locationGeneration += 1
    let generation = locationGeneration
    let location = CompanionLocation(model.preferences.body)
    let key = location.cacheKey(model.configuration?.instanceID ?? "local")
    let date = location.day()
    zmanim = ZmanimEntry.sorted(
      UserDefaults.standard.dictionary(forKey: key + ".zmanim." + date) as? [String: String] ?? [:])
    let weatherURL = model.cache.appendingPathComponent("weather-" + location.identity + ".json")
    let cachedWeather = await ReaderCache.read(WeatherResponse.self, from: weatherURL)
    guard generation == locationGeneration, !Task.isCancelled else { return }
    if var saved = cachedWeather {
      saved.stale = true
      weather = saved
    } else {
      weather = nil
    }
    guard let query = location.query else {
      messages.append(
        "Set city, latitude, longitude and time zone in Settings for weather and zmanim.")
      return
    }
    guard let api = model.api else { return }
    async let times: Void = loadTimes(
      api, query: query, date: date, key: key, generation: generation)
    async let conditions: Void = loadWeather(
      api, query: query, url: weatherURL, generation: generation)
    _ = await (times, conditions)
  }
  private func loadTimes(_ api: API, query: String, date: String, key: String, generation: Int)
    async
  {
    struct Times: Decodable { let times: [String: String] }
    do {
      let response: Times = try await api.request("calendar/zmanim?date=\(date)&" + query)
      guard generation == locationGeneration, !Task.isCancelled else { return }
      zmanim = ZmanimEntry.sorted(response.times)
      UserDefaults.standard.set(response.times, forKey: key + ".zmanim." + date)
    } catch {
      if generation == locationGeneration, !Task.isCancelled {
        messages.append("Zmanim unavailable; check location and connection.")
      }
    }
  }
  private func loadWeather(_ api: API, query: String, url: URL, generation: Int) async {
    do {
      let response: WeatherResponse = try await api.request("weather?" + query)
      guard generation == locationGeneration, !Task.isCancelled else { return }
      weather = response
      try await ReaderCache.write(response, to: url)
    } catch {
      guard generation == locationGeneration, !Task.isCancelled else { return }
      weather?.stale = true
      messages.append("Weather: " + error.localizedDescription)
    }
  }
  func refresh(_ model: AppModel, dashboard: Bool = false) async {
    await restore(model)
    guard !refreshing else { return }
    async let location: Void = refreshLocation(model, enabled: dashboard)
    let generation = refreshGeneration
    refreshing = true
    defer { if generation == refreshGeneration { refreshing = false } }
    messages = []
    guard let api = model.api else {
      messages = ["Connect your backend in Settings. Saved articles remain available offline."]
      return
    }
    do {
      let result: RSSResponse = try await api.request("rss/feeds")
      guard generation == refreshGeneration, !Task.isCancelled else { return }
      feeds = result.feeds
      try await ReaderCache.write(result, to: model.cache.appendingPathComponent("rss-cache.json"))
    } catch {
      guard generation == refreshGeneration, !Task.isCancelled else { return }
      feeds = feeds.map {
        var feed = $0
        feed.stale = true
        return feed
      }
      messages.append("RSS: " + error.localizedDescription)
    }
    await location
    guard generation == refreshGeneration, !Task.isCancelled else { return }
    guard dashboard else {
      lastRefresh = Date()
      return
    }
    let body = model.preferences.body
    let chosen = Set(ReaderPreferences.selectedStocks(body))
    let symbols = Array(
      Set(
        model.items.filter { $0.kind == "watchlist_items" && !$0.deleted && chosen.contains($0.id) }
          .compactMap { $0.body["symbol"] })
    ).sorted()
    if symbols.isEmpty {
      quotes = []
    } else {
      var parts = URLComponents()
      parts.queryItems = [URLQueryItem(name: "symbols", value: symbols.joined(separator: ","))]
      do {
        let result: QuoteResponse = try await api.request(
          "market/quotes?" + (parts.percentEncodedQuery ?? ""))
        guard generation == refreshGeneration, !Task.isCancelled else { return }
        quotes = result.quotes
      } catch {
        if generation == refreshGeneration, !Task.isCancelled {
          messages.append("Stocks: " + error.localizedDescription)
        }
      }
    }
    lastRefresh = Date()
  }
}

enum ReaderCache {
  static func read<Value: Decodable & Sendable>(_ type: Value.Type, from url: URL) async -> Value? {
    try? await BackgroundWork.run { try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
  }
  static func write<Value: Encodable & Sendable>(_ value: Value, to url: URL) async throws {
    try await BackgroundWork.run {
      try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
  }
}
