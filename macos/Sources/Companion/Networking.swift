import Foundation

actor API {
  private let credentials = SessionCredentials()
  let configuration: InstanceConfiguration
  var tokens: Tokens?
  private var refreshFlight: Task<Void, Error>?
  private var credentialsLoaded = false
  init(_ config: InstanceConfiguration) { configuration = config }
  private func loadCredentialsIfNeeded() throws {
    guard !credentialsLoaded else { return }
    tokens = try credentials.load(configuration.instanceID)
    credentialsLoaded = true
  }
  func login(_ login: String, _ password: String) async throws {
    let remote: RemoteInstance = try await request("instance", authorized: false)
    guard remote.instanceID == configuration.instanceID, remote.apiVersion == 1 else {
      throw CompanionError.message("This backend does not match your instance configuration")
    }
    let result: Tokens = try await request(
      "auth/login", method: "POST",
      body: JSONSerialization.data(withJSONObject: ["login": login, "password": password]),
      authorized: false)
    try store(result)
  }
  func store(_ value: Tokens) throws {
    try credentials.save(value, key: configuration.instanceID)
    tokens = value
    credentialsLoaded = true
  }
  func signOut() async throws {
    let _: [String: Bool] = try await request("auth/logout", method: "POST")
    try credentials.save(nil, key: configuration.instanceID)
    tokens = nil
  }
  func request<T: Decodable>(
    _ path: String, method: String = "GET", body: Data? = nil, authorized: Bool = true,
    retry: Bool = true
  ) async throws -> T {
    let data = try await raw(path, method: method, body: body, authorized: authorized, retry: retry)
    return try JSONDecoder().decode(T.self, from: data)
  }
  private func refreshSession(_ token: String) async throws {
    if let flight = refreshFlight {
      try await flight.value
      return
    }
    let flight = Task {
      let refreshed: Tokens = try await self.request(
        "auth/refresh", method: "POST",
        body: JSONSerialization.data(withJSONObject: ["token": token]), authorized: false,
        retry: false)
      try self.store(refreshed)
    }
    refreshFlight = flight
    defer { refreshFlight = nil }
    try await flight.value
  }
  func download(_ path: String, to target: URL, checksum: String, retry: Bool = true) async throws {
    try loadCredentialsIfNeeded()
    guard let url = URL(string: configuration.apiBaseURL.absoluteString + "/api/v1/" + path),
      let tokens
    else { throw CompanionError.message("Sign in in Settings") }
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    request.setValue("Bearer " + tokens.accessToken, forHTTPHeaderField: "Authorization")
    let usedToken = tokens.accessToken
    let (temporary, response) = try await URLSession.shared.download(for: request)
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let http = response as? HTTPURLResponse else {
      throw CompanionError.message("Invalid server response")
    }
    if http.statusCode == 401, retry, let current = self.tokens {
      if current.accessToken == usedToken { try await refreshSession(current.refreshToken) }
      return try await download(path, to: target, checksum: checksum, retry: false)
    }
    guard (200..<300).contains(http.statusCode) else {
      throw CompanionError.message("Invalid server response")
    }
    try await BackgroundWork.run {
      guard try FileWork.checksum(temporary) == checksum else {
        throw CompanionError.message("Downloaded file checksum mismatch")
      }
      try FileWork.copy(temporary, to: target)
    }
  }
  func raw(
    _ path: String, method: String = "GET", body: Data? = nil, authorized: Bool = true,
    retry: Bool = true, contentType: String = "application/json"
  ) async throws -> Data {
    guard let url = URL(string: configuration.apiBaseURL.absoluteString + "/api/v1/" + path) else {
      throw CompanionError.message("Invalid API URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    request.timeoutInterval = 30
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    if authorized {
      try loadCredentialsIfNeeded()
      guard let tokens else { throw CompanionError.message("Sign in in Settings") }
      request.setValue("Bearer " + tokens.accessToken, forHTTPHeaderField: "Authorization")
    }
    let usedToken = tokens?.accessToken
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw CompanionError.message("Invalid server response")
    }
    if http.statusCode == 401, authorized, retry, let current = tokens {
      if current.accessToken == usedToken { try await refreshSession(current.refreshToken) }
      return try await raw(
        path, method: method, body: body, authorized: authorized, retry: false,
        contentType: contentType)
    }
    guard (200..<300).contains(http.statusCode) else {
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      throw CompanionError.message(
        payload?["detail"] as? String
          ?? String(data: data, encoding: .utf8) ?? "Server error \(http.statusCode)")
    }
    return data
  }
}
