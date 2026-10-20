import AppKit
import SwiftUI

enum BeeTheme {
  static let accent = Color(red: 0.39, green: 0.37, blue: 0.80)
  static let mint = Color(red: 0.23, green: 0.61, blue: 0.53)
  static let amber = Color(red: 0.78, green: 0.53, blue: 0.22)
  static let canvas = Color(nsColor: .windowBackgroundColor)
  static let surface = Color(nsColor: .controlBackgroundColor)
  static let hairline = Color.primary.opacity(0.07)
}

struct BeeCard<Content: View>: View {
  var padding: CGFloat = 20
  @ViewBuilder var content: Content
  var body: some View {
    content.padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(BeeTheme.surface, in: RoundedRectangle(cornerRadius: 16))
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(BeeTheme.hairline))
      .shadow(color: .black.opacity(0.025), radius: 12, x: 0, y: 4)
  }
}

struct BeeSectionHeading: View {
  var title: String
  var subtitle: String = ""
  var symbol: String
  var color: Color = BeeTheme.accent
  var body: some View {
    HStack(spacing: 11) {
      Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
        .foregroundStyle(color).frame(width: 34, height: 34)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 3) {
        Text(L10n.text(title)).font(.system(size: 16, weight: .semibold))
        if !subtitle.isEmpty {
          Text(L10n.text(subtitle)).font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }
    }
  }
}

struct BeeMetric: View {
  var title: String
  var value: String
  var symbol: String
  var color: Color
  var body: some View {
    BeeCard {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 12) {
          Text(L10n.text(title)).font(.system(size: 12, weight: .medium)).foregroundStyle(
            .secondary)
          Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        Spacer()
        Image(systemName: symbol).font(.system(size: 17, weight: .medium))
          .foregroundStyle(color).padding(10)
          .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
      }
    }
  }
}

struct BeeEmptyState: View {
  var title: String
  var detail: String
  var symbol: String
  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: symbol).font(.system(size: 30, weight: .light))
        .foregroundStyle(BeeTheme.accent).frame(width: 76, height: 76)
        .background(BeeTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 23))
      Text(L10n.text(title)).font(.system(size: 19, weight: .semibold))
      Text(L10n.text(detail)).font(.system(size: 13)).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).frame(maxWidth: 270)
    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
  }
}

enum BeeDisplayTime {
  static func timestamp(_ value: String) -> String {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) {
      return date.formatted(
        .dateTime.year().month(.abbreviated).day().hour().minute().locale(L10n.locale))
    }
    let dateOnly = DateFormatter()
    dateOnly.locale = Locale(identifier: "en_US_POSIX")
    dateOnly.dateFormat = "yyyy-MM-dd"
    if let date = dateOnly.date(from: value) {
      return date.formatted(.dateTime.year().month(.abbreviated).day().locale(L10n.locale))
    }
    return value
  }
}
