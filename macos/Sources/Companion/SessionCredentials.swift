import CryptoKit
import Foundation

struct SessionCredentials {
  let directory: URL

  init(directory: URL? = nil) {
    self.directory =
      directory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("WorkCompanion/Sessions", isDirectory: true)
  }

  func file(_ key: String) -> URL {
    let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(name + ".json")
  }

  func load(_ key: String) throws -> Tokens? {
    let url = file(key)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      let data = try Data(contentsOf: url)
      if data.isEmpty { return nil }
      return try JSONDecoder().decode(Tokens.self, from: data)
    }
    return nil
  }

  func save(_ tokens: Tokens?, key: String) throws {
    let manager = FileManager.default
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var folder = directory
    try folder.setResourceValues(excluded)
    let data = try tokens.map { try JSONEncoder().encode($0) } ?? Data()
    try data.write(to: file(key), options: .atomic)
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(key).path)
  }

}
