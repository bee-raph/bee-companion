import Foundation

/// Shared parsing avoids rebuilding date formatters while lists sort and render.
final class TimestampParser: @unchecked Sendable {
  private final class Result: NSObject {
    let date: Date?
    init(_ date: Date?) { self.date = date }
  }
  private let lock = NSLock()
  private let standard = ISO8601DateFormatter()
  private let fractional: ISO8601DateFormatter = {
    let value = ISO8601DateFormatter()
    value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return value
  }()
  private let cache = NSCache<NSString, Result>()
  init() { cache.countLimit = 4096 }
  func date(_ text: String) -> Date? {
    guard !text.isEmpty else { return nil }
    lock.lock()
    defer { lock.unlock() }
    if let result = cache.object(forKey: text as NSString) { return result.date }
    let date = text.contains(".") ? fractional.date(from: text) : standard.date(from: text)
    cache.setObject(Result(date), forKey: text as NSString)
    return date
  }
}

enum ItemTimestamp {
  private static let parser = TimestampParser()
  static func date(_ text: String) -> Date? { parser.date(text) }
}
