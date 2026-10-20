import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum BackgroundWork {
  static func run<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await Task.detached(priority: .userInitiated) { try operation() }.value
  }
}

enum FileWork {
  static func checksum(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func chunk(_ url: URL, offset: Int, count: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    return try handle.read(upToCount: count) ?? Data()
  }

  static func copy(_ source: URL, to target: URL, overwrite: Bool = true) throws {
    let manager = FileManager.default
    if !overwrite && manager.fileExists(atPath: target.path) { return }
    try manager.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let staged = target.deletingLastPathComponent().appendingPathComponent(
      UUID().uuidString + ".copy")
    defer { try? manager.removeItem(at: staged) }
    try manager.copyItem(at: source, to: staged)
    if manager.fileExists(atPath: target.path) {
      _ = try manager.replaceItemAt(target, withItemAt: staged)
    } else {
      try manager.moveItem(at: staged, to: target)
    }
  }
}

actor WorkingCopyScanner {
  struct Change: Sendable {
    let item: Item
    let url: URL
  }
  private struct Signature: Equatable {
    let size: Int
    let modified: Date?
    let created: Date?
  }
  private var checked: [URL: (Signature, String)] = [:]

  func changes(in items: [Item], cache: URL) -> [Change] {
    var changes: [Change] = []
    var active = Set<URL>()
    for item in items where item.kind == "files" && !item.deleted {
      let target = cache.appendingPathComponent("working").appendingPathComponent(item.id)
        .appendingPathComponent(item.title)
      active.insert(target)
      guard
        let values = try? target.resourceValues(forKeys: [
          .fileSizeKey, .contentModificationDateKey, .creationDateKey,
        ])
      else { continue }
      let signature = Signature(
        size: values.fileSize ?? 0, modified: values.contentModificationDate,
        created: values.creationDate)
      let hash: String
      if let previous = checked[target], previous.0 == signature {
        hash = previous.1
      } else {
        guard let calculated = try? FileWork.checksum(target) else { continue }
        hash = calculated
        checked[target] = (signature, hash)
      }
      if hash != item.body["checksum"] { changes.append(Change(item: item, url: target)) }
    }
    checked = checked.filter { active.contains($0.key) }
    return changes
  }
}

enum NoteFileWork {
  static func plain(_ item: Item) -> String {
    [
      item.title, item.body["description"], item.body["text"], item.body["date"],
      item.body["status"],
    ]
    .compactMap { $0 }.joined(separator: "\n\n")
  }

  static func read(_ url: URL) throws -> Item {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    var item = Item(kind: "notes", body: ["title": url.deletingPathExtension().lastPathComponent])
    let format = url.pathExtension.lowercased()
    if ["rtf", "rtfd"].contains(format) {
      let rich = try NSAttributedString(
        url: url,
        options: [.documentType: format == "rtf" ? NSAttributedString.DocumentType.rtf : .rtfd],
        documentAttributes: nil)
      let encoded = try NoteSnapshot(rich, rich: true).encode()
      item.body["format"] = "rtf"
      item.body["text"] = encoded.text
      item.body["rtf"] = encoded.rtf
      item.body["rtfd"] = encoded.rtfd
    } else {
      item.body["format"] = "markdown"
      item.body["text"] = String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
    return item
  }

  static func write(_ item: Item, format: String, to url: URL) throws {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let data: Data
    if format == "rtfd",
      let value = NoteDocument.decode(rtf: item.body["rtf"] ?? "", rtfd: item.body["rtfd"] ?? "")
    {
      let wrapper = try value.fileWrapper(
        from: NSRange(location: 0, length: value.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
      try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
      return
    } else if format == "rtf" {
      if item.kind == "notes", let stored = item.body["rtf"],
        let rich = Data(base64Encoded: stored), !rich.isEmpty
      {
        data = rich
      } else {
        let text = NSAttributedString(string: plain(item))
        data = try text.data(
          from: NSRange(location: 0, length: text.length),
          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
      }
    } else if format == "md", item.kind == "notes", item.body["format"] == "rtf",
      let document = NoteDocument.decode(rtf: item.body["rtf"] ?? "", rtfd: item.body["rtfd"] ?? "")
    {
      data = Data(NoteMarkdown.export(document).utf8)
    } else {
      data = Data(plain(item).utf8)
    }
    try data.write(to: url, options: .atomic)
  }
}

enum NoteImageWork {
  static func prepare(_ url: URL) throws -> Data {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000,
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 1200,
        ] as CFDictionary)
    else { throw CompanionError.message("Choose an image smaller than 20 MB.") }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else {
      throw CompanionError.message("Choose an image smaller than 20 MB.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CompanionError.message("Choose an image smaller than 20 MB.")
    }
    return output as Data
  }
}
