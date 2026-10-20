import Foundation
import XCTest

@testable import Companion

final class SessionCredentialsTests: XCTestCase {
  func directory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  func testSessionSurvivesRelaunchAndRefreshWithPrivatePermissions() throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionCredentials(directory: directory)
    try store.save(
      Tokens(accessToken: "first-access", refreshToken: "first-refresh"), key: "instance")
    XCTAssertEqual(try store.load("instance")?.accessToken, "first-access")
    try store.save(
      Tokens(accessToken: "next-access", refreshToken: "next-refresh"), key: "instance")
    let relaunched = SessionCredentials(directory: directory)
    XCTAssertEqual(try relaunched.load("instance")?.refreshToken, "next-refresh")
    let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
    let file = try FileManager.default.attributesOfItem(atPath: store.file("instance").path)
    XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testSignOutAndInstanceIsolation() throws {
    let directory = directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SessionCredentials(directory: directory)
    XCTAssertNil(try store.load("first"))
    try store.save(Tokens(accessToken: "first-access", refreshToken: "first-refresh"), key: "first")
    try store.save(
      Tokens(accessToken: "second-access", refreshToken: "second-refresh"), key: "second")
    try store.save(nil, key: "first")
    XCTAssertNil(try SessionCredentials(directory: directory).load("first"))
    XCTAssertEqual(try store.load("second")?.accessToken, "second-access")
    XCTAssertEqual(store.file("../../elsewhere").deletingLastPathComponent().path, directory.path)
    XCTAssertEqual(
      try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
  }
}
