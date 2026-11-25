import CryptoKit
import Darwin
import Foundation
import SQLite3
import Security

let workflowID = "ca.aqsnow.alfred.spotify"
let defaultWorkflowKeyword = "spot"
typealias JSONObject = [String: Any]

enum RepeatMode: String, CaseIterable {
  case off, context, track
  var next: RepeatMode {
    switch self {
    case .off: return .context
    case .context: return .track
    case .track: return .off
    }
  }
  var label: String {
    switch self {
    case .off: return "Off"
    case .context: return "Repeat all"
    case .track: return "Repeat one"
    }
  }
}

struct SpotifyFailure: LocalizedError {
  let message: String
  var status: Int = 0
  var isNetworkError = false
  var requiresDesktopStart = false
  var errorDescription: String? { message }
}
func jsonData(_ object: Any) throws -> Data {
  try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
}
func readJSON(_ url: URL) -> Any? {
  guard let data = try? Data(contentsOf: url) else { return nil }
  return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
}
func writeJSON(_ value: Any, _ url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  try jsonData(value).write(to: url, options: .atomic)
  chmod(url.path, 0o600)
}
func dict(_ object: Any?) -> JSONObject { object as? JSONObject ?? [:] }
func text(_ object: Any?) -> String { object as? String ?? "" }
func number(_ object: Any?) -> Double { (object as? NSNumber)?.doubleValue ?? 0 }
func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func base64URL(_ data: Data) -> String {
  data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
    of: "/", with: "_"
  ).replacingOccurrences(of: "=", with: "")
}
func randomToken(_ count: Int = 32) -> String {
  var bytes = [UInt8](repeating: 0, count: count)
  precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
  return base64URL(Data(bytes))
}
func validTrack(_ uri: String) -> Bool {
  uri.range(of: #"^spotify:track:[A-Za-z0-9]{22}$"#, options: .regularExpression) != nil
}
func validURI(_ uri: String) -> Bool {
  uri.range(
    of: #"^spotify:(track|album|artist|playlist):[A-Za-z0-9]{22}$"#, options: .regularExpression)
    != nil
}

func isLikedSongsURI(_ uri: String) -> Bool {
  uri == "spotify:collection:tracks"
    || uri.range(of: #"^spotify:user:[^:\s]+:collection$"#, options: .regularExpression) != nil
}
func validPlaybackURI(_ uri: String) -> Bool { validURI(uri) || isLikedSongsURI(uri) }

struct WorkflowPaths {
  let root: URL
  let data: URL
  let cache: URL
  let desktop: URL
  let authorization: AuthorizationStore
  private let clientIDSettings: ClientIDSettings
  init(
    root: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
    authorization: AuthorizationStore? = nil
  ) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    self.root = root
    data = URL(
      fileURLWithPath: environment["alfred_workflow_data"]
        ?? home.appendingPathComponent(
          "Library/Application Support/Alfred/Workflow Data/\(workflowID)"
        ).path)
    cache = URL(
      fileURLWithPath: environment["alfred_workflow_cache"]
        ?? home.appendingPathComponent(
          "Library/Caches/com.runningwithcrayons.Alfred/Workflow Data/\(workflowID)"
        ).path)
    desktop = URL(
      fileURLWithPath: environment["SPOTIFY_DESKTOP_CACHE"]
        ?? home.appendingPathComponent("Library/Caches/com.spotify.client/Browser/Cache/Cache_Data")
        .path)
    self.authorization = authorization ?? AuthorizationStore()
    clientIDSettings = ClientIDSettings(authorization: self.authorization)
  }
  func prepare() throws {
    for url in [data, cache] {
      try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
  }
  func keyword(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    let prefs =
      (try? Data(contentsOf: root.appendingPathComponent("prefs.plist"))).flatMap {
        try? PropertyListSerialization.propertyList(from: $0, format: nil) as? JSONObject
      } ?? [:]
    let value = text(prefs["keyword"] ?? environment["keyword"] ?? defaultWorkflowKeyword)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? defaultWorkflowKeyword : value
  }
  func command(_ suffix: String) -> String { keyword() + " " + suffix }
  func clientID() -> String { clientIDSettings.value }
  func loadClientID() throws { try clientIDSettings.load() }
  func saveClientID(_ value: String) throws { try clientIDSettings.save(value) }
  func clearClientID() throws { try clientIDSettings.clear() }
}

final class MusicStore {
  private var db: OpaquePointer?
  private let mutex = NSRecursiveLock()
  let path: URL
  init(_ path: URL) throws {
    self.path = path
    guard
      sqlite3_open_v2(
        path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK
    else { throw SpotifyFailure(message: "Could not open the music cache.") }
    chmod(path.path, 0o600)
    sqlite3_busy_timeout(db, 10000)
    try execute(
      "CREATE TABLE IF NOT EXISTS items(uri TEXT PRIMARY KEY,kind TEXT NOT NULL,name TEXT NOT NULL,payload TEXT NOT NULL,richness INTEGER NOT NULL DEFAULT 0)"
    )
    try execute("CREATE INDEX IF NOT EXISTS items_kind ON items(kind)")
    try execute(
      "CREATE INDEX IF NOT EXISTS items_track_album ON items(json_extract(payload,'$.album.uri')) WHERE kind='track'"
    )
    try execute("CREATE TABLE IF NOT EXISTS saved(uri TEXT PRIMARY KEY)")
    try execute(
      "CREATE TABLE IF NOT EXISTS responses(key TEXT PRIMARY KEY,payload TEXT NOT NULL,expires REAL NOT NULL)"
    )
    try execute(
      "CREATE TABLE IF NOT EXISTS desktop(path TEXT PRIMARY KEY,stamp INTEGER NOT NULL,url TEXT NOT NULL,offset INTEGER NOT NULL,length INTEGER NOT NULL)"
    )
    try execute("CREATE INDEX IF NOT EXISTS desktop_url ON desktop(url)")
  }
  deinit { sqlite3_close(db) }
  private func statement(_ sql: String, _ args: [Any]) throws -> OpaquePointer {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
      throw SpotifyFailure(message: "Could not read the music cache.")
    }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (offset, arg) in args.enumerated() {
      let i = Int32(offset + 1)
      if let string = arg as? String {
        sqlite3_bind_text(stmt, i, string, -1, transient)
      } else if let int = arg as? Int64 {
        sqlite3_bind_int64(stmt, i, int)
      } else if let value = arg as? NSNumber {
        sqlite3_bind_double(stmt, i, value.doubleValue)
      } else {
        sqlite3_bind_null(stmt, i)
      }
    }
    return stmt
  }
  func execute(_ sql: String, _ args: [Any] = []) throws {
    mutex.lock()
    defer { mutex.unlock() }
    let stmt = try statement(sql, args)
    defer { sqlite3_finalize(stmt) }
    let result = sqlite3_step(stmt)
    if result != SQLITE_DONE && result != SQLITE_ROW {
      throw SpotifyFailure(message: "Could not update the music cache.")
    }
  }
  func rows(_ sql: String, _ args: [Any] = []) throws -> [JSONObject] {
    mutex.lock()
    defer { mutex.unlock() }
    let stmt = try statement(sql, args)
    defer { sqlite3_finalize(stmt) }
    var result: [JSONObject] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      var row: JSONObject = [:]
      for i in 0..<sqlite3_column_count(stmt) {
        let name = String(cString: sqlite3_column_name(stmt, i))
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(stmt, i))
        case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
        case SQLITE_FLOAT: row[name] = sqlite3_column_double(stmt, i)
        default: break
        }
      }
      result.append(row)
    }
    return result
  }
  func transaction(_ action: () throws -> Void) throws {
    mutex.lock()
    defer { mutex.unlock() }
    try execute("BEGIN IMMEDIATE")
    do {
      try action()
      try execute("COMMIT")
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }
  func item(_ uri: String) -> JSONObject? {
    guard
      let value = try? rows("SELECT payload FROM items WHERE uri=?", [uri]).first?["payload"]
        as? String, let data = value.data(using: .utf8)
    else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
  }
  func items(_ kind: String? = nil, saved: Bool = false) -> [JSONObject] {
    let sql =
      "SELECT payload FROM items" + (saved ? " JOIN saved USING(uri)" : "")
      + (kind == nil ? "" : " WHERE kind=?") + " ORDER BY items.rowid"
    return decodedItems(sql, kind.map { [$0] } ?? [])
  }
  func tracks(inAlbum uri: String) -> [JSONObject] {
    decodedItems(
      "SELECT payload FROM items WHERE kind='track' AND json_extract(payload,'$.album.uri')=? ORDER BY rowid",
      [uri])
  }
  func tracksNeedingArtwork(_ referenced: Set<String>) -> Set<String> {
    mutex.lock()
    defer { mutex.unlock() }
    let missing = Set(
      ((try? rows(
        "SELECT uri FROM items WHERE kind='track' AND (json_type(payload,'$.image') IS NOT 'text' OR json_extract(payload,'$.image')='')"
      )) ?? []).map { text($0["uri"]) })
    guard !referenced.isEmpty else { return missing }
    let cached = Set(
      ((try? rows("SELECT uri FROM items WHERE kind='track'")) ?? [])
        .map { text($0["uri"]) })
    return missing.union(referenced.subtracting(cached))
  }
  func artworkURLs() -> [String] {
    ((try? rows(
      "SELECT json_extract(items.payload,'$.image') AS image FROM items LEFT JOIN saved USING(uri) ORDER BY CASE WHEN items.kind='track' AND saved.uri IS NOT NULL THEN 0 ELSE 1 END, items.rowid"
    )) ?? []).map { text($0["image"]) }
  }
  private func decodedItems(_ sql: String, _ args: [Any]) -> [JSONObject] {
    ((try? rows(sql, args)) ?? []).compactMap { row in
      text(row["payload"]).data(using: .utf8).flatMap {
        (try? JSONSerialization.jsonObject(with: $0)) as? JSONObject
      }
    }
  }
  func putItem(_ value: JSONObject) throws {
    let uri = text(value["uri"])
    guard !uri.isEmpty, !text(value["name"]).isEmpty else { return }
    var merged = item(uri) ?? [:]
    for (key, value) in value {
      if let s = value as? String, s.isEmpty, merged[key] != nil { continue }
      merged[key] = value
    }
    let richness =
      (merged["tracks"] as? [Any] ?? []).count * 10 + (merged["albums"] as? [Any] ?? []).count
    try execute(
      "INSERT INTO items VALUES(?,?,?,?,?) ON CONFLICT(uri) DO UPDATE SET kind=excluded.kind,name=excluded.name,payload=excluded.payload,richness=excluded.richness WHERE excluded.richness>=items.richness",
      [
        uri, text(merged["kind"]), text(merged["name"]),
        String(decoding: try jsonData(merged), as: UTF8.self), richness,
      ])
  }
  func get(_ key: String, stale: Bool = false) -> Any? {
    guard let row = try? rows("SELECT payload,expires FROM responses WHERE key=?", [key]).first,
      stale || number(row["expires"]) > Date().timeIntervalSince1970
    else { return nil }
    return text(row["payload"]).data(using: .utf8).flatMap {
      try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed)
    }
  }
  func put(_ key: String, _ value: Any, ttl: Double = 3600) throws {
    try execute(
      "INSERT OR REPLACE INTO responses VALUES(?,?,?)",
      [
        key, String(decoding: try jsonData(value), as: UTF8.self),
        Date().timeIntervalSince1970 + ttl,
      ])
  }
  // Reauth keeps the library; only a confirmed account change invalidates membership.
  func useAccount(_ id: String, cancellation: RequestCancellation? = nil) throws {
    guard !id.isEmpty else {
      throw SpotifyFailure(message: "Spotify did not return an account ID.")
    }
    try transaction {
      if cancellation?.isCancelled == true { throw URLError(.cancelled) }
      let previous = text(get("library:account", stale: true))
      if !previous.isEmpty && previous != id {
        try execute("DELETE FROM saved")
        try execute(
          "DELETE FROM responses WHERE key NOT LIKE 'desktop:%' AND key NOT LIKE 'cache:%' AND key NOT LIKE 'evicted-art:%'"
        )
      }
      try put("library:account", id, ttl: 365 * 86400)
      if let collection = WebPlayback.collectionURI(userID: id) {
        try put("playback:liked-songs-uri", collection, ttl: 365 * 86400)
      }
      if cancellation?.isCancelled == true { throw URLError(.cancelled) }
    }
  }
  func isSaved(_ uri: String) -> Bool {
    !((try? rows("SELECT 1 FROM saved WHERE uri=?", [uri])) ?? []).isEmpty
  }
  func save(_ uri: String, liked: Bool) throws {
    try execute(
      liked ? "INSERT OR IGNORE INTO saved VALUES(?)" : "DELETE FROM saved WHERE uri=?", [uri])
  }
}

final class RequestCancellation {
  private let lock = NSLock()
  private var cancelled = false
  private weak var task: URLSessionTask?
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
  func attach(_ task: URLSessionTask) {
    lock.lock()
    self.task = task
    let cancel = cancelled
    lock.unlock()
    if cancel { task.cancel() }
  }
  func cancel() {
    lock.lock()
    cancelled = true
    let current = task
    lock.unlock()
    current?.cancel()
  }
}

final class SpotifyAPI {
  static let scopes =
    "user-library-read user-library-modify playlist-read-private playlist-read-collaborative user-follow-read user-read-playback-state user-modify-playback-state"
  private static let tokenLock = NSRecursiveLock()
  let paths: WorkflowPaths
  let session: URLSession
  init(_ paths: WorkflowPaths, session: URLSession? = nil) {
    self.paths = paths
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 12
    config.timeoutIntervalForResource = 20
    self.session = session ?? URLSession(configuration: config)
  }
  var connected: Bool {
    let token = (try? paths.authorization.load()) ?? [:]
    return !text(token["access_token"]).isEmpty && !text(token["refresh_token"]).isEmpty
      && text(token["client_id"]) == paths.clientID()
  }
  func hasScope(_ scope: String) -> Bool {
    text(((try? paths.authorization.load()) ?? [:])["scope"]).split(separator: " ").contains(
      Substring(scope))
  }
  var canSave: Bool { hasScope("user-library-modify") }
  var canReadPlayback: Bool { hasScope("user-read-playback-state") }
  func playbackState() throws -> JSONObject {
    guard canReadPlayback else {
      throw SpotifyFailure(
        message:
          "Run \(paths.command("reauth")) once to allow reading playback state, then open Spotify Mini Player again."
      )
    }
    return dict(try request("/me/player"))
  }
  func repeatState() throws -> RepeatMode? {
    RepeatMode(rawValue: text(try playbackState()["repeat_state"]))
  }
  func setRepeat(_ mode: RepeatMode) throws {
    guard hasScope("user-modify-playback-state") else {
      throw SpotifyFailure(
        message:
          "Run \(paths.command("reauth")) once to allow changing repeat mode, then connect again.")
    }
    do {
      _ = try request(
        "/me/player/repeat", params: ["state": mode.rawValue], method: "PUT", expectJSON: false)
    } catch let error as SpotifyFailure where error.status == 404 {
      throw SpotifyFailure(
        message: "Start playing music in Spotify, then change repeat mode.", status: 404)
    }
  }
  func send(_ request: URLRequest, cancellation: RequestCancellation? = nil) throws -> (
    Data, HTTPURLResponse
  ) {
    if cancellation?.isCancelled == true { throw URLError(.cancelled) }
    let ready = DispatchSemaphore(value: 0)
    var result: (Data?, URLResponse?, Error?) = (nil, nil, nil)
    let task = session.dataTask(with: request) { data, response, error in
      result = (data, response, error)
      ready.signal()
    }
    cancellation?.attach(task)
    task.resume()
    guard ready.wait(timeout: .now() + 22) == .success else {
      task.cancel()
      throw SpotifyFailure(message: "Spotify did not respond. Try again.", isNetworkError: true)
    }
    if cancellation?.isCancelled == true { throw URLError(.cancelled) }
    if let error = result.2 {
      if (error as? URLError)?.code == .cancelled { throw error }
      throw SpotifyFailure(
        message: "Could not reach Spotify. Check your connection and try again.",
        isNetworkError: true)
    }
    guard let response = result.1 as? HTTPURLResponse else {
      throw SpotifyFailure(message: "Spotify returned an invalid response.")
    }
    return (result.0 ?? Data(), response)
  }
  func validateClientID(_ id: String, redirect: String, cancellation: RequestCancellation) throws {
    // A deliberately unissued grant checks registration without signing in or storing a token.
    // Other grant errors are expected here; real authorization still happens in the browser.
    var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 6
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.form([
      "grant_type": "authorization_code", "client_id": id,
      "code": randomToken(48), "code_verifier": randomToken(64), "redirect_uri": redirect,
    ]).data(using: .utf8)
    let (data, response) = try send(request, cancellation: cancellation)
    let result = dict(try? JSONSerialization.jsonObject(with: data))
    let reason = text(result["error_description"]).lowercased()
    if text(result["error"]) == "invalid_client",
      !reason.contains("client secret"), !reason.contains("client_secret")
    {
      throw SpotifyFailure(
        message: "Spotify rejected the previously entered Client ID", status: response.statusCode)
    }
    if response.statusCode == 429 {
      let seconds = min(
        86400, max(1, Double(response.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60))
      throw SpotifyFailure(message: Self.rateLimitMessage(seconds), status: 429)
    }
    if response.statusCode >= 500 {
      throw SpotifyFailure(
        message: "Spotify could not start sign-in. Try again.", status: response.statusCode)
    }
  }
  func exchange(_ fields: [String: String], valid: () -> Bool = { true }) throws -> String {
    Self.tokenLock.lock()
    defer { Self.tokenLock.unlock() }
    let id = paths.clientID()
    guard validClientID(id) else {
      throw SpotifyFailure(message: "Open Spotify Mini Player and enter your Spotify Client ID.")
    }
    let snapshot = try paths.authorization.snapshot()
    var previous = snapshot.token
    if text(previous["client_id"]) != id { previous = [:] }
    let refreshing = fields["grant_type"] == "refresh_token"
    let values = fields.merging(["client_id": id]) { _, new in new }
    var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.form(values).data(using: .utf8)
    let (data, response) = try send(request)
    guard response.statusCode == 200 else {
      throw SpotifyFailure(
        message: "Spotify sign-in expired or the client credentials changed. Connect again.",
        status: response.statusCode)
    }
    let result = dict(try JSONSerialization.jsonObject(with: data))
    let access = text(result["access_token"])
    let refresh =
      text(result["refresh_token"]).isEmpty && refreshing
      ? text(previous["refresh_token"]) : text(result["refresh_token"])
    guard !access.isEmpty, !refresh.isEmpty else {
      throw SpotifyFailure(message: "Spotify returned an incomplete sign-in response.")
    }
    guard valid(), paths.clientID() == id else {
      throw SpotifyFailure(message: "This sign-in was cleared. Connect again.")
    }
    try paths.authorization.save(
      [
        "client_id": id, "access_token": access, "refresh_token": refresh,
        "expires_at": Date().timeIntervalSince1970 + number(result["expires_in"]),
        "scope": result["scope"] ?? (refreshing ? previous["scope"] ?? "" : Self.scopes),
      ], generation: snapshot.generation)
    return access
  }
  func accessToken(force: Bool = false) throws -> String {
    Self.tokenLock.lock()
    defer { Self.tokenLock.unlock() }
    let token = try paths.authorization.load()
    guard connected else {
      throw SpotifyFailure(message: "Connect to Spotify to browse your saved library.", status: 401)
    }
    if !force, number(token["expires_at"]) > Date().timeIntervalSince1970 + 60 {
      return text(token["access_token"])
    }
    return try exchange([
      "grant_type": "refresh_token", "refresh_token": text(token["refresh_token"]),
    ])
  }
  static func form(_ values: [String: String]) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return values.sorted { $0.key < $1.key }.map {
      ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "="
        + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }.joined(separator: "&")
  }
  static func rateLimitMessage(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(ceil(interval)))
    return
      "Spotify is rate limiting requests. Try again in \(seconds / 3600) hours, \(seconds / 60 % 60) minutes and \(seconds % 60) seconds."
  }
  func request(
    _ path: String, params: [String: String] = [:], method: String = "GET", body: JSONObject? = nil,
    timeout: TimeInterval? = nil, expectJSON: Bool = true, cancellation: RequestCancellation? = nil
  ) throws -> Any {
    if cancellation?.isCancelled == true { throw URLError(.cancelled) }
    guard path.hasPrefix("/"), !path.hasPrefix("//") else {
      throw SpotifyFailure(message: "Invalid Spotify request.")
    }
    let cooldown = dict(readJSON(paths.data.appendingPathComponent("api-cooldown.json")))
    let remaining = number(cooldown["until"]) - Date().timeIntervalSince1970
    if remaining > 0 {
      throw SpotifyFailure(message: Self.rateLimitMessage(remaining), status: 429)
    }
    let url = URL(
      string: "https://api.spotify.com/v1" + path
        + (params.isEmpty ? "" : (path.contains("?") ? "&" : "?") + Self.form(params)))!
    for attempt in 0..<2 {
      var request = URLRequest(url: url)
      request.httpMethod = method
      if let body = body {
        request.httpBody = try jsonData(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      }
      if let timeout = timeout { request.timeoutInterval = timeout }
      request.setValue(
        "Bearer " + (try accessToken(force: attempt == 1)), forHTTPHeaderField: "Authorization")
      let (data, response) = try send(request, cancellation: cancellation)
      if response.statusCode == 401 && attempt == 0 { continue }
      if response.statusCode == 429 {
        let seconds = min(
          86400, max(1, Double(response.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60))
        let message = Self.rateLimitMessage(seconds)
        try writeJSON(
          ["until": Date().timeIntervalSince1970 + seconds],
          paths.data.appendingPathComponent("api-cooldown.json"))
        throw SpotifyFailure(message: message, status: 429)
      }
      guard (200..<300).contains(response.statusCode) else {
        var message = "Spotify could not complete this request (\(response.statusCode))."
        let detail = text(
          dict(dict(try? JSONSerialization.jsonObject(with: data))["error"])["message"])
        if !detail.isEmpty { message += " " + detail }
        throw SpotifyFailure(
          message: response.statusCode == 401 ? "Reconnect to Spotify to renew access." : message,
          status: response.statusCode)
      }
      // Successful playback commands may return a plain-text command ID.
      if !expectJSON || response.statusCode == 204 || data.isEmpty { return [:] }
      return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }
    throw SpotifyFailure(message: "Reconnect to Spotify to renew access.", status: 401)
  }
  func pages(
    _ path: String, params: [String: String] = [:], nested: String? = nil,
    cancellation: RequestCancellation? = nil
  ) throws -> [JSONObject] {
    var path = path
    var params = ["limit": "50"].merging(params) { _, new in new }
    var result: [JSONObject] = []
    var seen = Set<String>()
    while !path.isEmpty {
      guard seen.insert(path + Self.form(params)).inserted else {
        throw SpotifyFailure(message: "Spotify returned a repeated library page.")
      }
      var page = dict(try request(path, params: params, cancellation: cancellation))
      if let nested = nested { page = dict(page[nested]) }
      guard let items = page["items"] as? [Any] else {
        throw SpotifyFailure(message: "Spotify returned an invalid library page.")
      }
      result += items.compactMap { $0 as? JSONObject }
      let next = text(page["next"])
      if next.isEmpty { break }
      guard let url = URL(string: next), url.scheme == "https", url.host == "api.spotify.com",
        url.path.hasPrefix("/v1/")
      else { throw SpotifyFailure(message: "Spotify returned an invalid library page.") }
      path = String(url.path.dropFirst(3)) + (url.query.map { "?" + $0 } ?? "")
      params = [:]
    }
    return result
  }
}
