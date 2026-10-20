import Foundation
import SwiftUI

/// Shared location and cache identity for Today, agenda and Shabbat.
struct CompanionLocation {
  let body: [String: String]
  init(_ body: [String: String]) { self.body = body }
  var zone: String {
    body["timezone"].flatMap { TimeZone(identifier: $0) == nil ? nil : $0 } ?? "Asia/Jerusalem"
  }
  var identity: String {
    [body["latitude"] ?? "", body["longitude"] ?? "", zone].joined(separator: "_")
      .replacingOccurrences(of: "/", with: "_")
  }
  func cacheKey(_ instance: String) -> String { "location." + instance + "." + identity }
  var query: String? {
    func coordinate(_ key: String) -> Double? {
      Double((body[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }
    guard let lat = coordinate("latitude"), let lon = coordinate("longitude"), lat.isFinite,
      lon.isFinite,
      (-90...90).contains(lat), (-180...180).contains(lon)
    else { return nil }
    var parts = URLComponents()
    parts.queryItems = [
      URLQueryItem(name: "latitude", value: String(lat)),
      URLQueryItem(name: "longitude", value: String(lon)),
      URLQueryItem(name: "timezone", value: zone),
    ]
    return parts.percentEncodedQuery
  }
  func day(_ now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(identifier: zone)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: now)
  }
}

struct WeatherView: View {
  @EnvironmentObject var model: AppModel
  @StateObject private var data = ReaderData()
  var body: some View {
    BeeCard {
      VStack(alignment: .leading, spacing: 12) {
        BeeSectionHeading(
          title: "Local weather", subtitle: model.preferences.body["city"] ?? "",
          symbol: "cloud.sun")
        if let weather = data.weather {
          HStack(spacing: 20) {
            Image(systemName: weather.symbol).font(.system(size: 38)).foregroundStyle(
              BeeTheme.accent)
            Text(String(format: "%.0f°C", weather.temperature)).font(
              .system(size: 34, weight: .light)
            ).monospacedDigit()
            VStack(alignment: .leading, spacing: 5) {
              Text(L10n.text(weather.condition)).font(.headline)
              Text(L10n.format("High %.0f° · Low %.0f°", weather.high, weather.low))
              Text(
                L10n.format(
                  "Feels like %.0f°C · Humidity %.0f%% · Wind %.0f km/h", weather.feelsLike,
                  weather.humidity, weather.wind)
              ).foregroundStyle(.secondary)
            }
            Spacer()
          }
          Text(
            L10n.text("Open-Meteo · ")
              + (weather.stale
                ? L10n.text("Saved conditions") : BeeDisplayTime.timestamp(weather.timestamp))
          ).font(.caption).foregroundStyle(.secondary)
        } else {
          Text(L10n.text("Weather appears after your location is configured and refreshed."))
            .foregroundStyle(.secondary)
        }
        ForEach(data.messages, id: \.self) {
          Text(L10n.message($0)).font(.caption).foregroundStyle(.secondary)
        }
      }
    }.task(
      id: (model.configuration?.instanceID ?? "local")
        + CompanionLocation(model.preferences.body).identity
    ) {
      while !Task.isCancelled {
        data.messages = []
        await data.refreshLocation(model)
        try? await Task.sleep(for: .seconds(600))
      }
    }
  }
}
