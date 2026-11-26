import AppKit
import Darwin
import Foundation
import Security

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) {
  do {
    guard try condition() else {
      fputs("FAILED: \(message)\n", stderr)
      exit(1)
    }
  } catch {
    fputs("FAILED: \(message): \(error.localizedDescription)\n", stderr)
    exit(1)
  }
}
private func tempDirectory(_ prefix: String) -> URL {
  let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(prefix + UUID().uuidString)
  try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private final class MemoryCredentialStorage: CredentialStorage {
  private let lock = NSLock()
  var data: Data?
  var reads = 0, writes = 0, removals = 0
  var failRead = false, failWrite = false, failRemove = false
  func read() throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    reads += 1
    if failRead { throw SpotifyFailure(message: "Fixture Keychain is locked.") }
    return data
  }
  func write(_ value: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    writes += 1
    if failWrite { throw SpotifyFailure(message: "Fixture Keychain could not save sign-in.") }
    data = value
  }
  func remove() throws {
    lock.lock()
    defer { lock.unlock() }
    removals += 1
    if failRemove { throw SpotifyFailure(message: "Fixture Keychain could not clear sign-in.") }
    data = nil
  }
}
private enum TestCredentials {
  static let lock = NSLock()
  static var stores: [String: AuthorizationStore] = [:]
}
func testAuthorizationStore(
  root: URL, environment: [String: String] = ProcessInfo.processInfo.environment
) -> AuthorizationStore {
  let data = URL(
    fileURLWithPath: environment["alfred_workflow_data"] ?? root.appendingPathComponent("data").path
  )
  TestCredentials.lock.lock()
  defer { TestCredentials.lock.unlock() }
  if let existing = TestCredentials.stores[data.path] { return existing }
  let store = AuthorizationStore(storage: MemoryCredentialStorage())
  TestCredentials.stores[data.path] = store
  return store
}
private func testPaths(
  root: URL, clientID: String? = nil,
  environment: [String: String] = ProcessInfo.processInfo.environment
) -> WorkflowPaths {
  var environment = environment
  environment["alfred_workflow_data"] =
    environment["alfred_workflow_data"] ?? root.appendingPathComponent("data").path
  environment["alfred_workflow_cache"] =
    environment["alfred_workflow_cache"] ?? root.appendingPathComponent("cache").path
  let paths = WorkflowPaths(
    root: root, environment: environment,
    authorization: testAuthorizationStore(root: root, environment: environment))
  if let clientID = clientID { try! paths.saveClientID(clientID) }
  return paths
}

private func encodeVarint(_ value: UInt64) -> Data {
  var value = value
  var data = Data()
  repeat {
    let byte = UInt8(value & 127)
    value >>= 7
    data.append(byte | (value > 0 ? 128 : 0))
  } while value > 0
  return data
}
private func littleData(_ number: UInt64, _ count: Int) -> Data {
  Data((0..<count).map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) })
}
private func testBlock(_ key: Data, _ value: Data) -> Data {
  encodeVarint(0) + encodeVarint(UInt64(key.count)) + encodeVarint(UInt64(value.count)) + key
    + value + littleData(0, 4) + littleData(1, 4)
}
private func proto(_ field: Int, _ data: Data) -> Data {
  encodeVarint(UInt64(field << 3 | 2)) + encodeVarint(UInt64(data.count)) + data
}

final class TestURLProtocol: URLProtocol {
  static var response: ((URLRequest) -> (Int, Data))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let (status, data) = Self.response?(request) ?? (500, Data())
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private final class CancelledSearchURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.path == "/v1/search"
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
  override func stopLoading() {}
}

private final class WaitingURLProtocol: URLProtocol {
  static let started = DispatchSemaphore(value: 0)
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { Self.started.signal() }
  override func stopLoading() {}
}

private final class OfflineURLProtocol: URLProtocol {
  static var requests = 0
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.requests += 1
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }
  override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) -> Data {
  if let data = request.httpBody { return data }
  guard let stream = request.httpBodyStream else { return Data() }
  stream.open()
  defer { stream.close() }
  var result = Data()
  var bytes = [UInt8](repeating: 0, count: 1024)
  while true {
    let count = stream.read(&bytes, maxLength: bytes.count)
    if count <= 0 { break }
    result.append(contentsOf: bytes.prefix(count))
  }
  return result
}

private func testPlaybackContexts() throws {
  let root = tempDirectory("spotify-context-tests-")
  defer { try? FileManager.default.removeItem(at: root) }
  let paths = testPaths(
    root: root, clientID: String(repeating: "a", count: 32),
    environment: [
      "alfred_workflow_data": root.appendingPathComponent("data").path,
      "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    ])
  try paths.prepare()
  let client = String(repeating: "a", count: 32)
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [TestURLProtocol.self]
  let api = SpotifyAPI(paths, session: URLSession(configuration: config))
  let library = MusicLibrary(store, api)
  try api.paths.authorization.save([
    "client_id": client, "access_token": "test", "refresh_token": "test",
    "expires_at": Date().timeIntervalSince1970 + 3600, "scope": SpotifyAPI.scopes,
  ])
  let playlist = "spotify:playlist:" + String(repeating: "p", count: 22)
  let album = "spotify:album:" + String(repeating: "a", count: 22)
  let artist = "spotify:artist:" + String(repeating: "r", count: 22)
  let track = "spotify:track:" + String(repeating: "t", count: 22)
  let outside = "spotify:playlist:" + String(repeating: "x", count: 22)
  let forbidden = "spotify:playlist:" + String(repeating: "f", count: 22)
  var requests = 0
  TestURLProtocol.response = { request in
    requests += 1
    check(request.url!.host == "api.spotify.com", "Context metadata stays on Spotify's API")
    if request.url!.path.hasSuffix(String(repeating: "f", count: 22))
      || request.url!.path.hasSuffix("/items")
    {
      return (403, Data())
    }
    return (200, try! jsonData(["name": "Outside playlist"]))
  }
  defer { TestURLProtocol.response = nil }
  for item: JSONObject in [
    [
      "uri": playlist, "kind": "playlist", "name": "My Playlist",
      "image": "https://i.scdn.co/image/playlist-cover",
    ],
    [
      "uri": album, "kind": "album", "name": "My Album",
      "image": "https://i.scdn.co/image/album-cover",
    ],
    [
      "uri": artist, "kind": "artist", "name": "My Artist",
      "image": "https://i.scdn.co/image/artist-cover",
    ],
    ["uri": track, "kind": "track", "name": "Song", "album": ["uri": album, "name": "My Album"]],
  ] { try store.putItem(item) }
  try store.save(track, liked: true)
  func state(_ uri: String) -> JSONObject { ["context": ["uri": uri], "item": ["uri": track]] }
  for (uri, label) in [
    (playlist, "Playlist · My Playlist"), (album, "Album · My Album"),
    (artist, "Artist · My Artist"),
  ] {
    check(
      library.playbackContext(state(uri), network: true)?.label == label,
      "Cached playback context has its type and name")
  }
  check(requests == 0, "Existing context metadata needs no network request")
  for uri in ["spotify:collection:tracks", "spotify:user:fixture:collection"] {
    check(
      library.playbackContext(state(uri), network: true)?.label == "Liked Songs",
      "Liked Songs collection context is recognized")
  }
  let snapshotAlbum = "spotify:album:" + String(repeating: "b", count: 22)
  let snapshotArtist = "spotify:artist:" + String(repeating: "k", count: 22)
  check(
    library.playbackContext([
      "context": ["uri": snapshotAlbum],
      "item": ["album": ["uri": snapshotAlbum, "name": "Current Album"]],
    ])?.name == "Current Album", "Playback state supplies uncached album names")
  check(
    library.playbackContext([
      "context": ["uri": snapshotArtist],
      "item": ["artists": [["uri": snapshotArtist, "name": "Current Artist"]]],
    ])?.name == "Current Artist", "Playback state supplies uncached artist names")
  check(
    library.playbackContext(["item": ["album": ["uri": album, "name": "My Album"]]]) == nil,
    "No context is invented from a track's album")
  check(
    library.playbackContext(state("https://untrusted.example/context"), network: true) == nil
      && requests == 0, "Unsupported context identifiers are ignored")
  check(
    library.playbackContext(state(outside))?.label == "Playlist" && requests == 0,
    "Unknown context names display their type without blocking")
  check(
    library.playbackContext(state(outside), network: true)?.label == "Playlist · Outside playlist"
      && requests == 1, "Unknown context name resolves once")
  check(
    library.playbackContext(state(outside))?.name == "Outside playlist",
    "Resolved context names remain available offline")
  _ = library.playbackContext(state(outside), network: true)
  check(requests == 1, "Resolved context metadata is reused")
  _ = library.playbackContext(state(forbidden), network: true)
  _ = library.playbackContext(state(forbidden), network: true)
  check(
    requests == 2 && library.playbackContext(state(forbidden))?.label == "Playlist",
    "Unavailable metadata is cached without repeated failed requests")
  let songs = try library.browse(["kind": "songs"])
  check(
    text(songs.first?["name"]) == "Liked Songs" && text(songs.first?["action"]) == "play"
      && text(songs.first?["play_uri"]) == PlaybackContext.likedSongs.uri,
    "Songs starts with an action for the full Liked Songs collection")
  check(
    songs.filter { text($0["kind"]) == "track" }.map { text($0["uri"]) } == [track],
    "The Liked Songs action does not replace saved songs or inflate the song count")
  check(
    songs.allSatisfy {
      PlaybackContext(dict($0["playback_context"]))?.label == "Liked Songs"
        && text($0["context"]).isEmpty
    }, "Saved-song source does not invent an API playback context")
  let albums = try library.browse(["kind": "album", "uri": album])
  check(
    albums.count == 2
      && albums.allSatisfy {
        PlaybackContext(dict($0["playback_context"]))?.label == "Album · My Album"
      }, "Album play action and track rows carry the cached source")
  let artists = try library.browse(["kind": "artist", "uri": artist, "name": "My Artist"])
  check(
    PlaybackContext(dict(artists.first?["playback_context"]))?.label == "Artist · My Artist",
    "Artist play action carries its source")
  check(
    text(albums.first?["image"]) == "https://i.scdn.co/image/album-cover",
    "Album play row preserves its cover")
  check(
    text(artists.first?["image"]) == "https://i.scdn.co/image/artist-cover",
    "Artist play row preserves its portrait")
  let playlists = try library.browse(["kind": "playlist", "uri": playlist])
  check(
    text(playlists.first?["image"]) == "https://i.scdn.co/image/playlist-cover",
    "Playlist play row preserves its cover")
  let restricted = try library.browse(["kind": "playlist", "uri": playlist], network: true)
  check(
    text(restricted.first?["image"]) == "https://i.scdn.co/image/playlist-cover"
      && text(restricted.first?["play_uri"]) == playlist,
    "A restricted playlist retains its cover and playable context")
  let routeOnly = try library.browse([
    "kind": "album", "uri": "spotify:album:" + String(repeating: "e", count: 22),
    "name": "Route Album", "image": "https://i.scdn.co/image/route-cover",
  ])
  check(
    text(routeOnly.first?["image"]) == "https://i.scdn.co/image/route-cover",
    "An album reached through nested metadata retains its cover")
  print(
    "Playback context and play-row cover checks passed: albums, playlists, artists, restricted playlists, and nested metadata."
  )
}

private func testWebPlayback() throws {
  let root = tempDirectory("spotify-playback-tests-")
  defer { try? FileManager.default.removeItem(at: root) }
  let paths = testPaths(
    root: root, clientID: String(repeating: "a", count: 32),
    environment: [
      "alfred_workflow_data": root.appendingPathComponent("data").path,
      "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    ])
  try paths.prepare()
  let client = String(repeating: "a", count: 32)
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [TestURLProtocol.self]
  let api = SpotifyAPI(paths, session: URLSession(configuration: config))
  try api.paths.authorization.save([
    "client_id": client, "access_token": "test", "refresh_token": "test",
    "expires_at": Date().timeIntervalSince1970 + 3600, "scope": SpotifyAPI.scopes,
  ])
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  var deviceRequests = 0
  var emptyDevices = 0
  var profileRequests = 0
  var deviceID = "desktop"
  var noActiveDevice = false
  var deviceAppearedDuringBootstrap = false
  var response = 204
  var bodies: [JSONObject] = []
  var targets: [String] = []
  var waits: [TimeInterval] = []
  TestURLProtocol.response = { request in
    switch request.url!.path {
    case "/v1/me":
      profileRequests += 1
      return (200, try! jsonData(["id": "fixture"]))
    case "/v1/me/player/devices":
      deviceRequests += 1
      if emptyDevices > 0 {
        emptyDevices -= 1
        return (200, try! jsonData(["devices": []]))
      }
      return (
        200,
        try! jsonData([
          "devices": [
            [
              "id": "phone", "name": "Phone", "type": "Smartphone",
              "is_active": !noActiveDevice || deviceAppearedDuringBootstrap,
            ],
            ["id": "remote", "name": "Another Mac", "type": "Computer"],
            ["id": deviceID, "name": "Test Mac", "type": "Computer"],
          ]
        ])
      )
    case "/v1/me/player":
      return (
        200,
        try! jsonData(noActiveDevice ? [:] : ["device": ["id": "phone", "type": "Smartphone"]])
      )
    case "/v1/me/player/play":
      check(
        request.httpMethod == "PUT"
          && request.value(forHTTPHeaderField: "Content-Type") == "application/json",
        "Playback sends a JSON PUT")
      bodies.append(dict(try! JSONSerialization.jsonObject(with: requestBody(request))))
      let target = request.url!.queryItemsForTesting.first { $0.name == "device_id" }?.value ?? ""
      targets.append(target)
      if noActiveDevice && target.isEmpty { return (404, Data()) }
      return (response, response == 200 ? Data("command-id".utf8) : Data())
    default: return (500, Data())
    }
  }
  defer { TestURLProtocol.response = nil }
  let playback = WebPlayback(
    api, store: store, computerName: "Test Mac", online: { true }, wait: { waits.append($0) })
  let track = "spotify:track:" + String(repeating: "t", count: 22)
  let playlist = "spotify:playlist:" + String(repeating: "p", count: 22)
  let album = "spotify:album:" + String(repeating: "a", count: 22)
  let artist = "spotify:artist:" + String(repeating: "r", count: 22)
  playback.prepare()
  try playback.play(track)
  check(
    (bodies.last?["uris"] as? [String]) == [track] && bodies.last?["context_uri"] == nil,
    "Standalone track plays without an invented context")
  try playback.play(track, context: playlist)
  check(
    text(bodies.last?["context_uri"]) == playlist
      && text(dict(bodies.last?["offset"])["uri"]) == track,
    "Playlist track preserves its queue and selected offset")
  try playback.play(track, context: album)
  check(text(bodies.last?["context_uri"]) == album, "Album track preserves its album context")
  for uri in [playlist, album, artist] {
    try playback.play(uri)
    check(
      text(bodies.last?["context_uri"]) == uri && bodies.last?["uris"] == nil
        && bodies.last?["offset"] == nil, "Context playback supports playlists, albums, and artists"
    )
  }
  check(
    deviceRequests == 0 && targets.allSatisfy { $0.isEmpty },
    "Playback-device regression test: selections retain the active phone without desktop lookup")
  let collection = "spotify:user:fixture:collection"
  check(
    WebPlayback.collectionURI(userID: "fixture/name with space")
      == "spotify:user:fixture%2Fname%20with%20space:collection",
    "Collection account IDs are URI-encoded")
  check(
    WebPlayback.collectionURI(userID: "") == nil && validPlaybackURI(collection)
      && validPlaybackURI(PlaybackContext.likedSongs.uri)
      && !validPlaybackURI("https://example.com/collection"),
    "Only supported playback identifiers are accepted")
  try playback.play(PlaybackContext.likedSongs.uri)
  try playback.play(PlaybackContext.likedSongs.uri)
  check(
    profileRequests == 1 && text(bodies.last?["context_uri"]) == collection
      && bodies.last?["uris"] == nil, "All plays the full collection and reuses the account ID")
  let reopened = WebPlayback(
    api, store: store, computerName: "Test Mac", online: { true }, desktopUserID: { nil })
  try reopened.play(PlaybackContext.likedSongs.uri)
  check(profileRequests == 1, "The collection account ID survives reopening")
  let beforeOffline = bodies.count
  let offlineCollection = WebPlayback(api, store: store, online: { false }, desktopUserID: { nil })
  do {
    try offlineCollection.play(PlaybackContext.likedSongs.uri)
    check(false, "Offline collection uses the local fallback")
  } catch {
    check(
      (error as? SpotifyFailure)?.isNetworkError == true && bodies.count == beforeOffline
        && profileRequests == 1, "Offline collection does not wait for the network")
  }
  let cachedCollection = try offlineCollection.fallbackURI(PlaybackContext.likedSongs.uri)
  check(cachedCollection == collection, "Offline collection can use its persisted account ID")
  let localAccount = WebPlayback(api, online: { false }, desktopUserID: { "desktop-fixture" })
  let desktopCollection = try localAccount.fallbackURI(PlaybackContext.likedSongs.uri)
  check(
    desktopCollection == "spotify:user:desktop-fixture:collection",
    "Offline collection can use Spotify's desktop account")
  let emptyAccount = WebPlayback(api, online: { false }, desktopUserID: { nil })
  do {
    _ = try emptyAccount.fallbackURI(PlaybackContext.likedSongs.uri)
    check(false, "A missing account must produce an actionable error")
  } catch {
    check(
      error.localizedDescription.contains("Spotify desktop app"),
      "Missing account explains how to play the collection")
  }
  let prefs = root.appendingPathComponent("spotify-prefs")
  try Data(
    "autologin.username=\"email@example.com\"\nautologin.canonical_username=\"desktop-fixture\"\n"
      .utf8
  ).write(to: prefs)
  check(
    DesktopAccount.userID(at: prefs) == "desktop-fixture",
    "Desktop account reads the canonical ID instead of an email")
  try Data("autologin.username=\"email@example.com\"\n".utf8).write(to: prefs)
  check(
    DesktopAccount.userID(at: prefs) == nil, "An email is not guessed to be a collection account ID"
  )
  response = 200
  try playback.play(track)
  check(
    bodies.last?["position_ms"] as? Int == 0,
    "Playback accepts command-ID responses and starts at the beginning")
  emptyDevices = 2
  deviceID = "restarted-desktop"
  noActiveDevice = true
  try playback.play(track, recentlyLaunched: true)
  check(
    waits.count == 2 && targets.last == "restarted-desktop",
    "A newly launched Spotify gets time to register only after no active device is confirmed")
  noActiveDevice = false
  response = 403
  do {
    try playback.play(track)
    check(false, "Playback must retain API errors")
  } catch {
    check(
      (error as? SpotifyFailure)?.status == 403,
      "Permission failures do not silently activate Spotify")
  }
  response = 404
  let beforeRemoteFailure = deviceRequests
  do {
    try playback.play(track)
    check(false, "An active remote device's failure must remain visible")
  } catch {
    check(
      (error as? SpotifyFailure)?.status == 404 && deviceRequests == beforeRemoteFailure,
      "Playback-device regression test: remote 404 never bootstraps or falls back to the Mac")
  }
  response = 500
  do {
    try playback.play(track)
    check(false, "An active remote device's service error must remain visible")
  } catch {
    check(
      (error as? SpotifyFailure)?.status == 500 && deviceRequests == beforeRemoteFailure,
      "Playback-device regression test: online service failures cannot seize the output device")
  }
  noActiveDevice = true
  response = 404
  deviceAppearedDuringBootstrap = true
  let beforeBootstrapRace = targets.count
  do {
    try playback.play(track)
    check(false, "A newly active phone must not be replaced during desktop startup")
  } catch {
    check(
      (error as? SpotifyFailure)?.requiresDesktopStart == false
        && targets.count == beforeBootstrapRace + 1
        && targets.last == "",
      "Playback-device regression test preserves a phone that appears during desktop bootstrap")
  }
  deviceAppearedDuringBootstrap = false
  do {
    try playback.play(track)
    check(false, "Unavailable online desktop playback must retain its API error")
  } catch {
    check(
      (error as? SpotifyFailure)?.status == 404,
      "Playback-device regression test: unavailable online playback never permits AppleScript")
  }
  emptyDevices = 2
  do {
    try playback.play(track)
    check(false, "A missing desktop player must request a background launch")
  } catch {
    check(
      (error as? SpotifyFailure)?.requiresDesktopStart == true,
      "Playback-device regression test starts the desktop through the API only after no active device is confirmed"
    )
  }
  let requests = deviceRequests
  let offline = WebPlayback(api, computerName: "Test Mac", online: { false })
  do {
    try offline.play(track)
    check(false, "Offline playback must use the local fallback")
  } catch {
    check(
      (error as? SpotifyFailure)?.isNetworkError == true && deviceRequests == requests,
      "Offline playback immediately falls back without a network request")
  }
  let cancellation = RequestCancellation()
  cancellation.cancel()
  do {
    try playback.play(track, cancellation: cancellation)
    check(false, "A superseded selection must not play")
  } catch {
    check(
      (error as? URLError)?.code == .cancelled,
      "A superseded selection cannot trigger the local fallback")
  }
  let offlineConfig = URLSessionConfiguration.ephemeral
  offlineConfig.protocolClasses = [OfflineURLProtocol.self]
  let failedNetwork = WebPlayback(
    SpotifyAPI(paths, session: URLSession(configuration: offlineConfig)), computerName: "Test Mac",
    online: { true })
  do {
    try failedNetwork.play(track)
    check(false, "Unknown online playback-device failures must remain visible")
  } catch {
    check(
      (error as? SpotifyFailure)?.isNetworkError == true,
      "Playback-device regression test: an unknown remote output is not replaced on a network failure"
    )
  }
  do {
    try playback.play("invalid")
    check(false, "Invalid playback URI must be rejected")
  } catch {
    check(
      (error as? SpotifyFailure)?.isNetworkError == false,
      "Invalid selections do not reach AppleScript")
  }
  try NativeBackend.clearConnection(paths)
  check(
    store.get("playback:liked-songs-uri", stale: true) == nil,
    "Reauth clears the previous account's collection ID")
  print(
    "Web playback targeting, full Liked Songs collection, startup, cancellation, and offline fallback passed."
  )
}

private func testPlaybackPolling() throws {
  let root = tempDirectory("spotify-polling-regression-")
  defer { try? FileManager.default.removeItem(at: root) }
  let environment = [
    "alfred_workflow_data": root.appendingPathComponent("data").path,
    "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    "SPOTIFY_DESKTOP_CACHE": root.appendingPathComponent("desktop").path,
    "SPOTIFY_DESKTOP_USER_CACHE": root.appendingPathComponent("empty").path,
  ]
  let paths = testPaths(
    root: root, clientID: String(repeating: "a", count: 32), environment: environment)
  try paths.prepare()
  try paths.authorization.save([
    "client_id": String(repeating: "a", count: 32), "access_token": "test", "refresh_token": "test",
    "expires_at": Date().timeIntervalSince1970 + 3600, "scope": SpotifyAPI.scopes,
  ])
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  try store.useAccount("fixture")
  try store.put(MusicLibrary.syncKey, true, ttl: 3600)
  try store.put("desktop:scanned:v4", true, ttl: 3600)
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [TestURLProtocol.self]
  let session = URLSession(configuration: config)
  let gate = DispatchSemaphore(value: 0)
  let lock = NSLock()
  var requests = 0
  func requestCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }
  TestURLProtocol.response = { request in
    check(
      request.url?.path == "/v1/me/player",
      "Playback polling regression test uses only mocked state requests")
    lock.lock()
    requests += 1
    let index = requests
    lock.unlock()
    if index == 1 || index == 3 {
      check(
        gate.wait(timeout: .now() + 3) == .success,
        "Playback polling regression test releases its gated request " + String(index))
    }
    if index == 3 { return (204, Data()) }
    return (
      200,
      try! jsonData([
        "device": ["id": "phone", "name": "Phone", "type": "Smartphone"],
        "is_playing": index == 1, "repeat_state": "off",
        "item": ["uri": "spotify:track:" + String(repeating: "t", count: 22)],
      ])
    )
  }
  let backend = NativeBackend(
    root, environment: environment, session: session, credentials: paths.authorization)
  var connected = false
  var barrier = false
  var states: [JSONObject] = []
  var repeats: [JSONObject] = []
  backend.receive = { value in
    if text(value["connection"]) == "connected" { connected = true }
    if text(value["command"]) == "show" { barrier = true }
    if text(value["type"]) == "playback-state" { states.append(value) }
    if text(value["type"]) == "repeat", value["poll"] as? Bool == true { repeats.append(value) }
  }
  defer {
    gate.signal()
    backend.stop()
    session.invalidateAndCancel()
    TestURLProtocol.response = nil
  }
  func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
  }
  try backend.start()
  wait { connected }
  check(connected, "Playback polling regression test starts its isolated connected backend")
  backend.send(["command": "repeat-state", "args": ["1", "10"]])
  wait { requestCount() == 1 }
  check(requestCount() == 1, "Playback polling regression test holds the first state request")
  backend.send(["command": "repeat-state", "args": ["1", "10"]])
  backend.send(["command": "repeat-state", "args": ["2", "11"]])
  backend.send(["command": "repeat-state", "args": ["3", "12"]])
  backend.send(["command": "show"])
  wait { barrier }
  check(
    barrier, "Playback polling regression test queues newer requests before completing the old one")
  gate.signal()
  wait { states.count == 2 }
  check(
    requestCount() == 2 && states.map { number($0["request"]) } == [10, 12]
      && states.allSatisfy { $0["remote"] as? Bool == true }
      && dict(states[0]["state"])["is_playing"] as? Bool == true
      && dict(states[1]["state"])["is_playing"] as? Bool == false,
    "Playback polling regression test coalesces to the latest request without relabeling a stale snapshot"
  )
  backend.send(["command": "repeat-state", "args": ["4", "13"]])
  wait { requestCount() == 3 }
  check(
    requestCount() == 3, "Playback polling regression test holds a temporary no-playback response")
  barrier = false
  backend.send(["command": "repeat-state", "args": ["5", "14"]])
  backend.send(["command": "show"])
  wait { barrier }
  check(
    barrier, "Playback polling regression test queues recovery before the empty response finishes")
  gate.signal()
  wait {
    states.contains { number($0["request"]) == 14 }
      && repeats.contains { number($0["request"]) == 5 }
  }
  check(
    requestCount() == 4 && states.map { number($0["request"]) } == [10, 12, 14]
      && states.allSatisfy { !dict($0["state"]).isEmpty && $0["remote"] as? Bool == true }
      && repeats.map { number($0["request"]) } == [1, 3, 5]
      && text(repeats.last?["mode"]) == "off",
    "Playback polling regression test keeps the header on HTTP 204 and resumes coalesced state and repeat updates"
  )
  print(
    "Playback polling regression test passed: coalesced refresh, preserved generations, remote state, and temporary empty-response recovery."
  )
}

private func testInitialLibrarySync() throws {
  let root = tempDirectory("spotify-initial-sync-regression-")
  defer { try? FileManager.default.removeItem(at: root) }
  let environment = [
    "alfred_workflow_data": root.appendingPathComponent("data").path,
    "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    "SPOTIFY_DESKTOP_CACHE": root.appendingPathComponent("desktop").path,
    "SPOTIFY_DESKTOP_USER_CACHE": root.appendingPathComponent("empty").path,
  ]
  let paths = testPaths(
    root: root, clientID: String(repeating: "a", count: 32), environment: environment)
  try paths.prepare()
  try paths.authorization.save([
    "client_id": String(repeating: "a", count: 32), "access_token": "test", "refresh_token": "test",
    "expires_at": Date().timeIntervalSince1970 + 3600, "scope": SpotifyAPI.scopes,
  ])
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  try store.useAccount("fixture")
  try store.put("desktop:scanned:v4", true, ttl: 3600)
  let gate = DispatchSemaphore(value: 0)
  let lock = NSLock()
  var started = 0
  var returned = 0
  var libraryStatus = 200
  func counts() -> (Int, Int) {
    lock.lock()
    defer { lock.unlock() }
    return (started, returned)
  }
  TestURLProtocol.response = { request in
    switch request.url?.path {
    case "/api/token":
      return (200, try! jsonData(["access_token": "refreshed", "expires_in": 3600]))
    case "/v1/me": return (200, try! jsonData(["id": "fixture"]))
    case "/v1/me/following": return (200, try! jsonData(["artists": ["items": []]]))
    case "/v1/me/tracks":
      lock.lock()
      started += 1
      lock.unlock()
      check(
        gate.wait(timeout: .now() + 3) == .success,
        "Initial sync regression test releases its mocked library request")
      lock.lock()
      returned += 1
      lock.unlock()
      return (libraryStatus, try! jsonData(["items": []]))
    case "/v1/me/albums", "/v1/me/playlists": return (200, try! jsonData(["items": []]))
    default:
      check(false, "Initial sync regression test uses only mocked library requests")
      return (500, Data())
    }
  }
  defer { TestURLProtocol.response = nil }
  func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
  }
  func round(_ number: Int, initial: Bool, fail: Bool = false, cancel: Bool = false) throws {
    libraryStatus = fail ? 500 : 200
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CancelledSearchURLProtocol.self, TestURLProtocol.self]
    let session = URLSession(configuration: config)
    let backend = NativeBackend(
      root, environment: environment, session: session, credentials: paths.authorization)
    var updates: [JSONObject] = []
    backend.receive = { updates.append($0) }
    defer {
      if counts().1 < counts().0 { gate.signal() }
      backend.stop()
      session.invalidateAndCancel()
    }
    try backend.start()
    wait { counts().0 == number }
    check(counts().0 == number, "Initial sync regression test reaches its library fetch")
    backend.send(["command": "show"])
    wait { updates.contains { text($0["command"]) == "show" } }
    let snapshot = updates.first { text($0["command"]) == "show" } ?? [:]
    check(
      snapshot["initial_sync"] as? Bool == initial,
      "Initial sync regression test preserves the correct indicator when reopening")
    if cancel { backend.stop() }
    gate.signal()
    wait {
      counts().1 == number
        && (cancel
          ? updates.contains {
            text($0["type"]) == "initial-sync" && $0["initial_sync"] as? Bool == false
          }
          : updates.contains {
            text($0["command"]) == "refresh" && $0["initial_sync"] as? Bool == false
          })
    }
    let signals = updates.filter { text($0["type"]) == "initial-sync" }.compactMap {
      $0["initial_sync"] as? Bool
    }
    check(
      signals == (initial ? [true, false] : []),
      "Initial sync regression test shows activity only for the first library fetch and always clears it"
    )
    if fail {
      check(
        updates.contains {
          text($0["command"]) == "refresh" && $0["message_is_error"] as? Bool == true
        },
        "Initial sync regression test retains real synchronization errors")
    } else if !cancel {
      check(
        store.get(MusicLibrary.syncKey) != nil,
        "Initial sync regression test records completed synchronization")
      let before = updates.count
      backend.send(["command": "catalog", "args": ["cancelled search"]])
      wait {
        updates.dropFirst(before).contains {
          text($0["command"]) == "browse" && $0["searching"] as? Bool == false
        }
      }
      check(
        updates.dropFirst(before).contains {
          text($0["command"]) == "browse" && $0["searching"] as? Bool == false
        }
          && !updates.dropFirst(before).contains { text($0["type"]) == "error" },
        "Cancelled catalogue regression test settles the current query without a false connection error"
      )
    }
  }
  try round(1, initial: true)
  try store.put(MusicLibrary.syncKey, true, ttl: -1)
  try round(2, initial: false)
  try store.execute("DELETE FROM responses WHERE key=?", [MusicLibrary.syncKey])
  try round(3, initial: true, fail: true)
  try round(4, initial: true, cancel: true)
  print(
    "Initial sync regression tests passed: first fetch, cached refresh, error/cancellation cleanup, and cancelled search."
  )
}

private func testPlaybackTarget() {
  let previous = "spotify:track:" + String(repeating: "a", count: 22)
  let selected = "spotify:track:" + String(repeating: "b", count: 22)
  let relinked = "spotify:track:" + String(repeating: "c", count: 22)
  let playlist = "spotify:playlist:" + String(repeating: "d", count: 22)
  let otherPlaylist = "spotify:playlist:" + String(repeating: "e", count: 22)
  let externalPlaylist = "spotify:playlist:" + String(repeating: "f", count: 22)
  let accountCollection = "spotify:user:fixture:collection"
  func state(_ track: String, context: String? = nil, linked: String? = nil) -> JSONObject {
    var item: JSONObject = ["uri": track]
    if let linked = linked { item["linked_from"] = ["uri": linked] }
    var result: JSONObject = ["item": item]
    result["context"] = context.map { ["uri": $0] } ?? NSNull()
    return result
  }
  func makeTarget(
    _ uri: String, context: String = "", previousContext: String? = nil, allowsLocal: Bool = true
  ) -> PlaybackTarget {
    PlaybackTarget(
      uri: uri, context: context, previousTrack: previous,
      previousContext: previousContext ?? otherPlaylist, allowsLocal: allowsLocal)
  }
  var target = makeTarget(playlist)
  check(
    !target.acceptsWeb(state(selected, context: playlist))
      && !target.acceptsContextEvent(track: selected, context: playlist),
    "Playback target regression test ignores snapshots before command acknowledgement")
  target.acknowledged = true
  check(
    target.acceptsContext(playlist) && !target.acceptsContext(otherPlaylist)
      && !target.acceptsContextEvent(track: selected, context: playlist),
    "Playback target regression test protects context-only updates until state confirms")
  check(
    !target.acceptsWeb(state(previous, context: otherPlaylist))
      && target.acceptsWeb(state(selected, context: playlist)),
    "Playback target regression test waits for the selected playlist in the current generation")
  check(
    !target.acceptsWeb(state("invalid", context: playlist)) && !target.acceptsWeb([:]),
    "Playback target regression test ignores incomplete or invalid state")
  check(
    target.acceptsLocal(selected) && !target.acceptsLocal(previous),
    "Playback target regression test accepts a fresh local track without rolling back")
  target.displayedTrack = selected
  check(
    !target.acceptsWeb(state(previous, context: playlist)),
    "Playback target regression test rejects old track metadata after displaying the new track")
  target.confirmedTrack = selected
  check(
    target.acceptsLocal(selected) && target.acceptsLocal(relinked)
      && !target.acceptsLocal(previous),
    "Playback target regression test allows local autoplay while fencing the previous track")
  check(
    target.acceptsWeb(state(relinked, context: playlist))
      && target.acceptsWeb(state(relinked, context: externalPlaylist))
      && !target.acceptsWeb(state(selected, context: otherPlaylist))
      && !target.acceptsWeb(state(previous, context: playlist)),
    "Playback target regression test allows confirmed autoplay and external sources without rollback"
  )
  check(
    target.acceptsWeb(state(previous, context: externalPlaylist))
      && target.acceptsContextEvent(track: previous, context: externalPlaylist)
      && !target.acceptsContextEvent(track: previous, context: "")
      && !target.acceptsContextEvent(track: selected, context: otherPlaylist),
    "Playback target regression test distinguishes an explicit external source from stale context")
  var rapid = makeTarget(playlist, allowsLocal: false)
  rapid.acknowledged = true
  check(
    !rapid.acceptsLocal(selected) && rapid.acceptsWeb(state(selected, context: playlist)),
    "Playback target regression test suppresses ambiguous local snapshots during rapid selections")
  var same = makeTarget(playlist, previousContext: playlist)
  same.acknowledged = true
  check(
    same.acceptsWeb(state(previous, context: playlist)),
    "Playback target regression test lets a repeated selection settle without a track change")
  var track = makeTarget(selected, context: playlist)
  track.acknowledged = true
  check(
    track.acceptsWeb(state(selected, context: playlist))
      && !track.acceptsWeb(state(selected, context: otherPlaylist)),
    "Playback target regression test requires the selected track and its requested playlist")
  check(
    track.acceptsWeb(state(relinked, context: playlist, linked: selected))
      && !track.acceptsWeb(state(previous, context: playlist)),
    "Playback target regression test recognizes Spotify relinking without accepting another track")
  track.confirmedTrack = relinked
  track.displayedTrack = relinked
  check(
    track.acceptsLocal(selected) && track.acceptsLocal(relinked) && !track.acceptsLocal(previous)
      && track.acceptsWeb(state(selected, context: externalPlaylist)),
    "Playback target regression test keeps relinked identities and later external playback")
  var repeatRelinked = PlaybackTarget(
    uri: selected, context: playlist, previousTrack: relinked,
    previousContext: playlist, allowsLocal: true)
  repeatRelinked.acknowledged = true
  repeatRelinked.displayedTrack = selected
  check(
    repeatRelinked.acceptsWeb(state(relinked, context: playlist, linked: selected)),
    "Playback target regression test settles a repeated selection of the already playing relinked track"
  )
  repeatRelinked.displayedTrack = relinked
  check(
    repeatRelinked.acceptsLocal(relinked) && !repeatRelinked.acceptsLocal(previous),
    "Playback target regression test preserves an accepted displayed relinked identity")
  var standalone = makeTarget(selected, context: "", allowsLocal: false)
  standalone.acknowledged = true
  check(
    standalone.acceptsWeb(state(selected)) && standalone.acceptsLocal(selected)
      && standalone.acceptsContext(otherPlaylist),
    "Playback target regression test confirms a known standalone track on any device")
  var liked = makeTarget(PlaybackContext.likedSongs.uri)
  liked.acknowledged = true
  check(
    liked.acceptsWeb(state(selected)) && liked.acceptsContext("")
      && liked.acceptsContext(accountCollection)
      && liked.acceptsWeb(state(selected, context: accountCollection))
      && !liked.acceptsWeb(state(selected, context: playlist))
      && !liked.acceptsWeb(state(previous)),
    "Playback target regression test accepts Liked Songs aliases but rejects ambiguous prior null state"
  )
  var repeatedLiked = makeTarget(PlaybackContext.likedSongs.uri, previousContext: accountCollection)
  repeatedLiked.acknowledged = true
  check(
    repeatedLiked.acceptsWeb(state(previous)),
    "Playback target regression test settles a repeated Liked Songs selection with null context")
  liked.confirmedTrack = selected
  liked.displayedTrack = selected
  check(
    liked.acceptsWeb(state(previous, context: externalPlaylist))
      && liked.acceptsContextEvent(track: previous, context: externalPlaylist),
    "Playback target regression test permits a real playlist to replace confirmed Liked Songs")
  var accountLiked = makeTarget(accountCollection, allowsLocal: false)
  accountLiked.acknowledged = true
  check(
    accountLiked.acceptsWeb(state(selected, context: PlaybackContext.likedSongs.uri)),
    "Playback target regression test normalizes both Liked Songs aliases")
  var fromLiked = makeTarget(playlist, previousContext: accountCollection)
  fromLiked.acknowledged = true
  fromLiked.confirmedTrack = selected
  fromLiked.displayedTrack = selected
  check(
    !fromLiked.acceptsWeb(state(selected, context: PlaybackContext.likedSongs.uri)),
    "Playback target regression test normalizes the old Liked Songs source while fencing it")
  print(
    "Playback target regression tests passed: acknowledgement, context, relinking, autoplay, rapid selections, and stale snapshot rejection."
  )
}

private func testWebTransport() throws {
  let root = tempDirectory("spotify-transport-regression-")
  defer { try? FileManager.default.removeItem(at: root) }
  let paths = testPaths(
    root: root, clientID: String(repeating: "a", count: 32),
    environment: [
      "alfred_workflow_data": root.appendingPathComponent("data").path,
      "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    ])
  try paths.prepare()
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [TestURLProtocol.self]
  let api = SpotifyAPI(paths, session: URLSession(configuration: config))
  try api.paths.authorization.save([
    "client_id": String(repeating: "a", count: 32), "access_token": "test",
    "refresh_token": "test", "expires_at": Date().timeIntervalSince1970 + 3600,
    "scope": SpotifyAPI.scopes,
  ])
  var playing = true
  var shuffleStates: [String] = []
  var stateStatus = 200
  var stateOverride: JSONObject?
  var response = 204
  var calls: [(String, String)] = []
  TestURLProtocol.response = { request in
    let path = request.url!.path
    calls.append((request.httpMethod ?? "", path))
    check(
      request.url!.queryItemsForTesting.allSatisfy { $0.name != "device_id" }
        && !path.hasSuffix("/devices"),
      "Playback-device regression test never targets or transfers to the desktop")
    if path == "/v1/me/player" {
      return (
        stateStatus,
        stateStatus == 204
          ? Data()
          : try! jsonData(
            stateOverride ?? [
              "device": ["id": "phone", "name": "Phone", "type": "Smartphone"],
              "is_playing": playing,
            ])
      )
    }
    check(
      [
        "/v1/me/player/play", "/v1/me/player/pause", "/v1/me/player/next", "/v1/me/player/previous",
        "/v1/me/player/shuffle",
      ]
      .contains(path),
      "Playback-device regression test uses only active-device playback endpoints")
    if response == 204 {
      if path.hasSuffix("/shuffle") {
        shuffleStates.append(
          request.url!.queryItemsForTesting.first { $0.name == "state" }?.value ?? "")
      }
      if path.hasSuffix("/pause") { playing = false }
      if path.hasSuffix("/play") { playing = true }
    }
    return (response, Data())
  }
  defer { TestURLProtocol.response = nil }
  let playback = WebPlayback(api, online: { true })
  let paused = try playback.transport("toggle")
  check(
    paused["playing"] as? Bool == false && dict(paused["state"])["is_playing"] as? Bool == false
      && text(dict(dict(paused["state"])["device"])["id"]) == "phone"
      && calls.map { $0.1 } == ["/v1/me/player", "/v1/me/player/pause"],
    "Playback-device regression test pauses the active phone and returns its authoritative state")
  let resumed = try playback.transport("toggle")
  check(
    resumed["playing"] as? Bool == true && playing,
    "Playback-device regression test resumes the same active phone")
  for (command, method, endpoint) in [
    ("pause", "PUT", "pause"), ("resume", "PUT", "play"),
    ("next", "POST", "next"), ("previous", "POST", "previous"),
  ] {
    let before = calls.count
    _ = try playback.transport(command)
    check(
      calls.count == before + 1 && calls.last?.0 == method
        && calls.last?.1 == "/v1/me/player/" + endpoint,
      "Playback-device regression test sends a known control in one request: " + command)
  }
  for command in ["shuffle-on", "shuffle-on", "shuffle-off", "shuffle-off"] {
    let before = calls.count
    _ = try playback.transport(command)
    check(
      calls.count == before + 1 && calls.last?.0 == "PUT"
        && calls.last?.1 == "/v1/me/player/shuffle",
      "Shuffle regression test updates the active phone in one API request")
  }
  check(
    shuffleStates == ["true", "true", "false", "false"],
    "Shuffle regression test uses idempotent explicit on and off states")
  for (name, status, payload): (String, Int, JSONObject) in [
    ("empty JSON", 200, [:]), ("no content", 204, [:]),
    ("missing is_playing", 200, ["device": ["id": "phone"]]),
    ("null is_playing", 200, ["is_playing": NSNull()]),
  ] {
    stateStatus = status
    stateOverride = payload
    let before = calls.count
    let fallback = try playback.transport("toggle")
    let event = fallback.merging(["command": "toggle"]) { _, new in new }
    check(
      fallback["fallback"] as? Bool == true
        && text(fallback["fallback_reason"]) == "missing-playback-state"
        && calls.count == before + 1 && calls.last?.0 == "GET"
        && calls.last?.1 == "/v1/me/player"
        && WebPlayback.appleScriptCommand(for: event, offline: false, remote: true) == "toggle",
      "Playback-state regression test requests local toggle without changing API output for " + name
    )
  }
  stateStatus = 200
  stateOverride = nil
  for (command, expected) in [
    ("toggle", "toggle"), ("pause", "pause"), ("resume", "resume"),
    ("next", "next"), ("previous", "previous"),
  ] {
    let fallback: JSONObject = ["fallback": true, "command": command]
    check(
      WebPlayback.appleScriptCommand(for: fallback, offline: true, remote: false) == expected
        && WebPlayback.appleScriptCommand(for: fallback, offline: false, remote: false) == nil
        && WebPlayback.appleScriptCommand(for: fallback, offline: true, remote: true) == nil,
      "Playback-state regression test retains the offline local-only fallback policy for " + command
    )
  }
  check(
    WebPlayback.appleScriptCommand(
      for: ["command": "next", "fallback": true, "fallback_reason": "missing-playback-state"],
      offline: false, remote: true) == nil,
    "Playback-state regression test limits the missing-state exception to play/pause")
  for status in [403, 500, 429] {
    stateStatus = status
    let before = calls.count
    do {
      _ = try playback.transport("toggle")
      check(false, "A rejected playback-state request must remain an error")
    } catch {
      check(
        (error as? SpotifyFailure)?.status == status
          && calls.count == before + 1 && calls.last?.0 == "GET"
          && calls.last?.1 == "/v1/me/player",
        "Playback-state regression test does not request fallback on API status " + String(status))
    }
    if status == 429 {
      try FileManager.default.removeItem(at: paths.data.appendingPathComponent("api-cooldown.json"))
    }
    stateStatus = 200
    response = status
    do {
      _ = try playback.transport("shuffle-on")
      check(false, "A rejected remote control must remain an error")
    } catch {
      check(
        (error as? SpotifyFailure)?.status == status,
        "Playback-device regression test preserves the output on API status " + String(status))
    }
  }
  let beforeOffline = calls.count
  do {
    _ = try WebPlayback(api, online: { false }).transport("toggle")
    check(false, "Offline controls use the existing local path")
  } catch {
    check(
      (error as? SpotifyFailure)?.isNetworkError == true && calls.count == beforeOffline,
      "Playback-device regression test retains immediate offline fallback without network access")
  }
  let cancellation = RequestCancellation()
  cancellation.cancel()
  do {
    _ = try playback.transport("next", cancellation: cancellation)
    check(false, "Cancelled transport must not reach the API")
  } catch {
    check(
      (error as? URLError)?.code == .cancelled && calls.count == beforeOffline,
      "Playback-device regression test cancels without sending or falling back")
  }
  print(
    "Active-device transport regression tests passed: phone controls, missing-state local toggle, failure isolation, and offline behavior."
  )
}

private func testPlaybackIntent() {
  for (command, code): (String, UInt32) in [("pause", 0x5061_7573), ("resume", 0x506c_6179)] {
    let event = SpotifyCommands.playbackEvent(command, uri: "", context: "")
    check(
      event?.eventClass == 0x7370_6679 && event?.eventID == code,
      "Local playback regression test sends explicit " + command + " rather than a toggle")
  }
  let now = Date(timeIntervalSince1970: 1000)
  for desired in [false, true] {
    var intent = PlaybackIntent(request: 42, desired: desired)
    check(
      intent.request == 42 && intent.desired == desired
        && !intent.accepts(desired, now: now) && !intent.accepts(!desired, now: now)
        && !intent.accepts(!desired, now: now.addingTimeInterval(60)),
      "Playback intent regression test rejects all snapshots until command acknowledgement")
    intent.acknowledge(now: now)
    intent.acknowledge(now: now.addingTimeInterval(2))
    check(
      intent.request == 42 && intent.accepts(desired, now: now)
        && !intent.accepts(!desired, now: now.addingTimeInterval(2.999))
        && intent.accepts(!desired, now: now.addingTimeInterval(3)),
      "Playback intent regression test accepts confirmation and bounds stale-state protection")
  }
  for sent in [false, true] {
    var burst = PlaybackIntent(request: 77, desired: sent, coalesces: true)
    for _ in 0..<10_000 { burst.request(!burst.latestDesired) }
    check(
      burst.latestDesired == sent && burst.desired == sent && burst.request == 77,
      "Playback burst regression test coalesces ten thousand toggles with the correct parity")
    burst.request(!sent)
    check(
      burst.followup(after: sent) == nil,
      "Playback burst regression test cannot dispatch a follow-up before acknowledgement")
    burst.acknowledge(now: now)
    check(
      burst.followup(after: !sent) == nil,
      "Playback burst regression test requires actual target confirmation after acknowledgement")
    check(
      burst.accepts(!sent, now: now.addingTimeInterval(3))
        && burst.followup(after: !sent) == nil,
      "Playback burst regression test never dispatches queued intent from unconfirmed or expired state"
    )
    burst.request(sent)
    check(
      burst.followup(after: sent) == nil,
      "Playback burst regression test collapses a net no-op queue after confirmation")
    burst.request(!sent)
    burst.request(sent)
    burst.request(!sent)
    let latest = burst.followup(after: sent)
    check(
      latest == !sent && burst.desired == sent && burst.latestDesired == !sent,
      "Playback burst regression test dispatches only the latest requested state after confirmation"
    )
    var followup = PlaybackIntent(request: 78, desired: latest!, coalesces: true)
    followup.acknowledge(now: now)
    check(
      followup.followup(after: !sent) == nil,
      "Playback burst regression test finishes a confirmed burst without another follow-up")
    var direct = PlaybackIntent(request: 79, desired: sent)
    direct.request(!sent)
    direct.acknowledge(now: now)
    check(
      direct.followup(after: sent) == nil,
      "Playback burst regression test leaves ordinary noncoalescing intents unchanged")
  }
  print(
    "Playback intent regression tests passed: acknowledgement, confirmation, bounded expiry, and burst coalescing."
  )
}

private func testExplicitTransportRecovery() throws {
  let root = tempDirectory("spotify-explicit-transport-regression-")
  defer { try? FileManager.default.removeItem(at: root) }
  let paths = testPaths(root: root, clientID: String(repeating: "a", count: 32), environment: [:])
  try paths.prepare()
  try paths.authorization.save([
    "client_id": String(repeating: "a", count: 32), "access_token": "test", "refresh_token": "test",
    "expires_at": Date().timeIntervalSince1970 + 3600, "scope": SpotifyAPI.scopes,
  ])
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [TestURLProtocol.self]
  let session = URLSession(configuration: config)
  defer { session.invalidateAndCancel() }
  let playback = WebPlayback(SpotifyAPI(paths, session: session), online: { true })
  let restriction = "Player command failed: Restriction violated"
  let errorBody = try jsonData(["error": ["status": 403, "message": restriction]])
  var mutationStatus = 403
  var stateStatus = 200
  var statePayload: JSONObject = [:]
  var calls: [(String, String)] = []
  var cancelProbe: RequestCancellation?
  TestURLProtocol.response = { request in
    let method = request.httpMethod ?? ""
    let path = request.url!.path
    calls.append((method, path))
    check(
      request.url!.queryItemsForTesting.allSatisfy { $0.name != "device_id" },
      "Explicit transport regression test never transfers playback to another device")
    if path == "/api/token" {
      return (200, try! jsonData(["access_token": "refreshed", "expires_in": 3600]))
    }
    if path == "/v1/me/player" {
      cancelProbe?.cancel()
      return (stateStatus, stateStatus == 204 ? Data() : try! jsonData(statePayload))
    }
    check(
      method == "PUT" && ["/v1/me/player/pause", "/v1/me/player/play"].contains(path),
      "Explicit transport regression test only mutates the requested playback state")
    return (mutationStatus, errorBody)
  }
  defer { TestURLProtocol.response = nil }
  func reset() throws {
    calls = []
    stateStatus = 200
    statePayload = [:]
    cancelProbe = nil
    let cooldown = paths.data.appendingPathComponent("api-cooldown.json")
    if FileManager.default.fileExists(atPath: cooldown.path) {
      try FileManager.default.removeItem(at: cooldown)
    }
  }
  for status in [403, 404] {
    mutationStatus = status
    for (command, desired, endpoint) in [("pause", false, "pause"), ("resume", true, "play")] {
      try reset()
      statePayload = [
        "is_playing": desired, "device": ["id": "phone", "type": "Smartphone", "name": "Phone"],
      ]
      let confirmed = try playback.transport(command)
      check(
        confirmed["playing"] as? Bool == desired
          && dict(confirmed["state"])["is_playing"] as? Bool == desired
          && text(dict(dict(confirmed["state"])["device"])["id"]) == "phone"
          && confirmed["fallback"] == nil
          && calls.map { $0.0 } == ["PUT", "GET"]
          && calls.map { $0.1 } == ["/v1/me/player/" + endpoint, "/v1/me/player"],
        "Explicit transport regression test confirms an already satisfied " + command
          + " after HTTP " + String(status))
      for (probeStatus, payload): (Int, JSONObject) in [
        (200, [:]), (204, [:]), (200, ["device": ["id": "phone"]]),
        (200, ["is_playing": NSNull()]),
      ] {
        try reset()
        stateStatus = probeStatus
        statePayload = payload
        let fallback = try playback.transport(command)
        let event = fallback.merging(["command": command]) { _, new in new }
        check(
          fallback["fallback"] as? Bool == true
            && text(fallback["fallback_reason"]) == "missing-playback-state"
            && WebPlayback.appleScriptCommand(for: event, offline: false, remote: true) == command
            && calls.map { $0.0 } == ["PUT", "GET"]
            && calls.map { $0.1 } == ["/v1/me/player/" + endpoint, "/v1/me/player"],
          "Explicit transport regression test preserves " + command + " when the probe has no state"
        )
      }
      try reset()
      statePayload = ["is_playing": !desired, "device": ["id": "phone", "type": "Smartphone"]]
      do {
        _ = try playback.transport(command)
        check(false, "Contradictory remote playback must preserve the original command error")
      } catch {
        check(
          (error as? SpotifyFailure)?.status == status
            && error.localizedDescription.contains(restriction)
            && error.localizedDescription.contains("(\(status))")
            && calls.map { $0.0 } == ["PUT", "GET"],
          "Explicit transport regression test preserves Spotify's restriction reason on a remote device"
        )
      }
    }
  }
  mutationStatus = 403
  for status in [401, 429, 500] {
    try reset()
    stateStatus = status
    do {
      _ = try playback.transport("pause")
      check(false, "A failed state probe must not trigger local playback")
    } catch {
      check(
        (error as? SpotifyFailure)?.status == 403
          && error.localizedDescription.contains(restriction)
          && calls.filter { $0.0 == "PUT" }.count == 1
          && calls.contains { $0 == ("GET", "/v1/me/player") },
        "Explicit transport regression test retains the original error when probe status is "
          + String(status))
    }
  }
  for status in [401, 429, 500] {
    try reset()
    mutationStatus = status
    do {
      _ = try playback.transport("pause")
      check(false, "Ordinary API errors must remain errors")
    } catch {
      check(
        (error as? SpotifyFailure)?.status == status
          && !calls.contains { $0.0 == "GET" },
        "Explicit transport regression test does not probe or fall back on initial HTTP "
          + String(status))
    }
  }
  try reset()
  mutationStatus = 403
  let cancellation = RequestCancellation()
  cancelProbe = cancellation
  do {
    _ = try playback.transport("pause", cancellation: cancellation)
    check(false, "A cancelled state probe must remain cancelled")
  } catch {
    check(
      (error as? URLError)?.code == .cancelled
        && calls.map { $0.0 } == ["PUT", "GET"],
      "Explicit transport regression test propagates cancellation without local playback")
  }
  print(
    "Explicit transport regression tests passed: satisfied commands, missing state, original errors, cancellation, and no device transfer."
  )
}

private func writeTable(_ records: [(Data, Data)], to file: URL) throws {
  var data = Data()
  var index = Data()
  for (key, value) in records.sorted(by: { $0.0.lexicographicallyPrecedes($1.0) }) {
    let block = testBlock(key, value)
    let handle = encodeVarint(UInt64(data.count)) + encodeVarint(UInt64(block.count))
    data += block + Data(repeating: 0, count: 5)
    index +=
      encodeVarint(0) + encodeVarint(UInt64(key.count)) + encodeVarint(UInt64(handle.count)) + key
      + handle
  }
  index += littleData(0, 4) + littleData(1, 4)
  var footer =
    encodeVarint(0) + encodeVarint(0) + encodeVarint(UInt64(data.count))
    + encodeVarint(UInt64(index.count))
  footer += Data(repeating: 0, count: 40 - footer.count) + littleData(0xdb47_7524_8b80_fb57, 8)
  try (data + index + Data(repeating: 0, count: 5) + footer).write(to: file)
}

private func testSignInFailures() throws {
  let root = tempDirectory("spotify-signin-failures-")
  defer {
    try? FileManager.default.removeItem(at: root)
    TestURLProtocol.response = nil
  }
  let id = String(repeating: "a", count: 32)
  for mode in [
    "invalid-client", "browser-error", "callback-error", "cancelled", "token-error", "timeout",
    "public-client",
  ] {
    let folder = root.appendingPathComponent(mode)
    let environment = [
      "alfred_workflow_data": folder.appendingPathComponent("data").path,
      "alfred_workflow_cache": folder.appendingPathComponent("cache").path,
      "SPOTIFY_DESKTOP_CACHE": folder.appendingPathComponent("desktop").path,
    ]
    let paths = testPaths(root: folder, clientID: id, environment: environment)
    try paths.prepare()
    try paths.saveClientID(id)
    try paths.authorization.save(["client_id": id, "access_token": "", "refresh_token": ""])
    let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
    let retainedTrack = "spotify:track:" + String(repeating: "t", count: 22)
    try store.putItem(["uri": retainedTrack, "kind": "track", "name": "Keep metadata"])
    try store.save(retainedTrack, liked: true)
    let cover = paths.cache.appendingPathComponent("artwork/keep.img")
    try FileManager.default.createDirectory(
      at: cover.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: cover)
    var requests = 0
    var opened = 0
    var browserEvents = 0
    var failure: JSONObject = [:]
    var reopened: JSONObject = [:]
    var statuses: [String] = []
    var flow: AuthorizationFlow?
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TestURLProtocol.self]
    let session = URLSession(configuration: config)
    TestURLProtocol.response = { request in
      check(
        request.url?.host == "accounts.spotify.com" && request.url?.path == "/api/token",
        "Sign-in tests never contact the real API")
      requests += 1
      let body = String(decoding: requestBody(request), as: UTF8.self)
      check(
        body.contains("client_id=" + id) && !body.contains("client_secret"),
        "Registration check stays on the PKCE path")
      if mode == "invalid-client" {
        return (
          400,
          try! jsonData(["error": "invalid_client", "error_description": "Failed to get client"])
        )
      }
      if mode == "public-client" {
        return (
          400,
          try! jsonData(["error": "invalid_client", "error_description": "Invalid client secret"])
        )
      }
      return (
        400,
        try! jsonData(["error": "invalid_grant", "error_description": "Invalid authorization code"])
      )
    }
    let backend = NativeBackend(
      folder, environment: environment, session: session, credentials: paths.authorization,
      authorization: { paths, api in
        let value = AuthorizationFlow(
          paths, api, callbackPort: 0, timeout: mode == "timeout" ? 0.05 : 180,
          browser: { _ in
            if opened == 0 {
              check(
                !statuses.contains("Finish connecting in your browser"),
                "Browser guidance never appears during Client ID validation")
            }
            opened += 1
            return mode != "browser-error"
          })
        flow = value
        return value
      })
    backend.receive = { value in
      if let message = value["message"] as? String { statuses.append(message) }
      if text(value["type"]) == "browser-opened" { browserEvents += 1 }
      if text(value["command"]) == "client-id-reset" { failure = value }
      if text(value["command"]) == "show" { reopened = value }
    }
    defer {
      backend.stop()
      session.invalidateAndCancel()
    }
    try backend.start()
    func wait(_ done: () -> Bool) {
      let deadline = Date().addingTimeInterval(3)
      while !done() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
      }
    }
    if ["callback-error", "cancelled", "token-error", "public-client"].contains(mode) {
      wait { opened > 0 }
      check(
        try opened == 1 && text(paths.authorization.load()["access_token"]).isEmpty,
        "Registration validation does not save a login before browser authorization")
      wait { browserEvents == 1 }
      check(
        browserEvents == 1 && statuses.last == "Finish connecting in your browser",
        "Browser guidance appears with the actual browser handoff")
      if mode == "callback-error" {
        backend.send(["command": "connect"])
        wait { opened == 2 && browserEvents == 2 }
        check(
          opened == 2 && browserEvents == 2, "Reopening the auth browser hides the player again")
      }
      let parts = flow!.authorizationURL!
      let query = Dictionary(
        parts.queryItemsForTesting.map { ($0.name, $0.value ?? "") },
        uniquingKeysWith: { first, _ in first })
      var callback = URLComponents(string: query["redirect_uri"]!)!
      callback.queryItems =
        [URLQueryItem(name: "state", value: query["state"]!)]
        + (mode == "token-error"
          ? [URLQueryItem(name: "code", value: "expired-code")]
          : [
            URLQueryItem(
              name: "error", value: mode == "cancelled" ? "access_denied" : "server_error")
          ])
      URLSession.shared.dataTask(with: callback.url!) { _, _, _ in }.resume()
    }
    wait { !failure.isEmpty }
    check(
      text(failure["connection"]) == "credentials" && failure["message_is_error"] as? Bool == true,
      mode + " returns to the Client ID prompt with error severity")
    check(try paths.authorization.load().isEmpty, "Failed sign-in clears its Keychain credentials")
    check(
      store.items().count == 1 && store.isSaved(retainedTrack)
        && FileManager.default.fileExists(atPath: cover.path),
      "Sign-in failures preserve saved membership, artwork, and library metadata")
    if mode == "invalid-client" {
      check(
        opened == 0 && requests == 1 && browserEvents == 0,
        "Unregistered IDs leave the player open without a browser handoff")
      check(
        text(failure["message"]) == "Spotify rejected the previously entered Client ID",
        "Spotify rejection uses the requested status text")
    }
    if ["invalid-client", "browser-error"].contains(mode) {
      check(
        statuses.first == "Checking Spotify Client ID…"
          && !statuses.contains("Finish connecting in your browser"),
        "Validation and launch failures go straight from checking to the error without browser guidance"
      )
    }
    if mode == "browser-error" {
      check(browserEvents == 0, "A failed browser launch leaves the sign-in prompt visible")
    }
    backend.send(["command": "show"])
    wait { !reopened.isEmpty }
    check(
      text(reopened["connection"]) == "credentials" && reopened["message_is_error"] as? Bool == true
        && (reopened["rows"] as? [JSONObject])?.count == 1,
      "Reopening never reuses the failed in-memory ID")
    backend.stop()
  }
  print(
    "Sign-in failures passed: unregistered IDs, browser failures, callback errors, token errors, timeout, and retained artwork/metadata."
  )
}

private func testReauthLibraryRetention() throws {
  let root = tempDirectory("spotify-reauth-library-")
  defer {
    try? FileManager.default.removeItem(at: root)
    TestURLProtocol.response = nil
  }
  let client = String(repeating: "a", count: 32)
  let paths = testPaths(
    root: root, clientID: client,
    environment: [
      "alfred_workflow_data": root.appendingPathComponent("data").path,
      "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    ])
  try paths.prepare()
  try paths.saveClientID(client)
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [TestURLProtocol.self]
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }
  let api = SpotifyAPI(paths, session: session)
  let library = MusicLibrary(store, api)
  func authorize() throws {
    try api.paths.authorization.save([
      "client_id": paths.clientID(), "access_token": "test", "refresh_token": "test",
      "expires_at": Date().timeIntervalSince1970 + 3600, "scope": SpotifyAPI.scopes,
    ])
  }
  try authorize()
  func item(_ kind: String, _ letter: String, _ name: String) -> JSONObject {
    ["uri": "spotify:\(kind):" + String(repeating: letter, count: 22), "kind": kind, "name": name]
  }
  let album = item("album", "a", "Saved album")
  let artist = item("artist", "r", "Followed artist")
  let playlist = item("playlist", "p", "Custom playlist")
  let track = item("track", "t", "Liked song").merging(["album": album]) { _, new in new }
  let original = Set([album, artist, playlist, track].map { text($0["uri"]) })
  var account = "same-account"
  var failPath = ""
  var malformed = false
  var empty = false
  var requests = 0
  TestURLProtocol.response = { request in
    requests += 1
    let path = request.url!.path
    if path == failPath {
      return malformed
        ? (200, try! jsonData(["unexpected": []]))
        : (429, try! jsonData(["error": ["status": 429]]))
    }
    switch path {
    case "/v1/me": return (200, try! jsonData(["id": account]))
    case "/v1/me/tracks": return (200, try! jsonData(["items": empty ? [] : [["track": track]]]))
    case "/v1/me/albums": return (200, try! jsonData(["items": empty ? [] : [["album": album]]]))
    case "/v1/me/following":
      return (200, try! jsonData(["artists": ["items": empty ? [] : [artist]]]))
    case "/v1/me/playlists": return (200, try! jsonData(["items": empty ? [] : [playlist]]))
    default:
      check(false, "Unexpected library retention request")
      return (500, Data())
    }
  }
  try library.sync()
  let cover = paths.cache.appendingPathComponent("artwork/keep.img")
  try FileManager.default.createDirectory(
    at: cover.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data([1, 2, 3]).write(to: cover)
  let contentsKey = "contents:" + text(playlist["uri"])
  try store.put(contentsKey, [track], ttl: 365 * 86400)
  try store.put("desktop:downloaded-uris", Array(original), ttl: 365 * 86400)
  func saved() -> Set<String> { Set(store.items(saved: true).map { text($0["uri"]) }) }
  func checkLibrary(_ label: String) throws {
    check(saved() == original, label + " preserves all saved membership")
    let playlists = try library.browse(["kind": "playlists"])
    let albums = try library.browse(["kind": "albums"])
    let artists = try library.browse(["kind": "artists"])
    let songs = try library.browse(["kind": "songs"])
    check(
      playlists.count == 1 && albums.count == 1 && artists.count == 1 && songs.count == 2,
      label + " keeps all library menus populated")
    check(
      store.get("library:playlist-order", stale: true) as? [String] == [text(playlist["uri"])],
      label + " preserves playlist order")
    check(
      (store.get(contentsKey, stale: true) as? [JSONObject])?.count == 1
        && FileManager.default.fileExists(atPath: cover.path),
      label + " preserves cached contents and artwork")
  }
  try NativeBackend.clearConnection(paths)
  check(!api.connected && paths.clientID().isEmpty, "Reauth still clears sign-in and Client ID")
  try checkLibrary("Reauth")
  check(
    text(store.get("library:account", stale: true)) == account, "Cache ownership survives reauth")
  // Reusing the Spotify account with another developer app must retain its library too.
  try paths.saveClientID(String(repeating: "b", count: 32))
  try authorize()
  let cooldown = paths.data.appendingPathComponent("api-cooldown.json")
  for path in ["/v1/me", "/v1/me/playlists"] {
    failPath = path
    do {
      try library.sync()
      check(false, "Rate-limited refresh must report failure")
    } catch { check((error as? SpotifyFailure)?.status == 429, "Rate limit remains visible") }
    try checkLibrary("Rate limit at " + path)
    let before = requests
    do {
      try library.sync()
      check(false, "Cooldown must remain in effect")
    } catch {
      check(
        (error as? SpotifyFailure)?.status == 429 && requests == before,
        "Cooldown avoids repeated requests without discarding data")
    }
    try FileManager.default.removeItem(at: cooldown)
  }
  malformed = true
  do {
    try library.sync()
    check(false, "Malformed library response must fail")
  } catch {
    check(
      error.localizedDescription.contains("invalid library page"),
      "Malformed library response is not an empty library")
  }
  try checkLibrary("Incomplete refresh")
  failPath = ""
  let cancellation = RequestCancellation()
  cancellation.cancel()
  let before = requests
  do {
    try library.sync(cancellation: cancellation)
    check(false, "Cancelled refresh must not run")
  } catch {
    check(
      (error as? URLError)?.code == .cancelled && requests == before,
      "Reset cancels refresh before it can modify membership")
  }
  try checkLibrary("Cancelled refresh")
  try library.sync()
  try checkLibrary("Same account in a new developer app")
  account = "different-account"
  failPath = "/v1/me/tracks"
  malformed = false
  do {
    try library.sync()
    check(false, "New account rate limit must remain visible")
  } catch {
    check(
      (error as? SpotifyFailure)?.status == 429, "Account change can still encounter a rate limit")
  }
  check(
    saved().isEmpty && store.get("library:followed-artists", stale: true) == nil
      && store.get(contentsKey, stale: true) == nil,
    "A confirmed different account cannot inherit the previous account's saved library")
  check(
    text(store.get("library:account", stale: true)) == account && store.items().count == 4
      && FileManager.default.fileExists(atPath: cover.path),
    "Account changes retain reusable metadata and artwork")
  try FileManager.default.removeItem(at: cooldown)
  failPath = ""
  empty = true
  try library.sync()
  check(
    saved().isEmpty && store.get(MusicLibrary.syncKey) != nil, "A successful empty library is valid"
  )
  print(
    "Reauth library retention passed: membership, order, cached contents/artwork, rate limits, incomplete/cancelled refreshes, and account changes."
  )
}

private func testCredentialStorage() throws {
  let root = tempDirectory("spotify-keychain-tests-")
  defer { try? FileManager.default.removeItem(at: root) }
  let token: JSONObject = [
    "client_id": String(repeating: "a", count: 32), "access_token": "fixture-access",
    "refresh_token": "fixture-refresh", "expires_at": Date().timeIntervalSince1970 + 3600,
    "scope": SpotifyAPI.scopes,
  ]
  let memory = MemoryCredentialStorage()
  let store = AuthorizationStore(storage: memory)
  try store.save(token)
  check(
    text(try store.load()["access_token"]) == "fixture-access",
    "Sign-in is saved in protected storage")
  let reads = memory.reads
  for _ in 0..<1000 { _ = try store.load() }
  check(memory.reads == reads, "Warm credential reads never touch Keychain again")
  let cold = AuthorizationStore(storage: memory)
  check(
    text(try cold.load()["refresh_token"]) == "fixture-refresh",
    "A cold process recovers persisted sign-in")
  var updated = token
  updated["access_token"] = "updated-access"
  memory.failWrite = true
  do {
    try store.save(updated)
    check(false, "Failed Keychain writes must be visible")
  } catch {}
  check(
    text(try store.load()["access_token"]) == "fixture-access",
    "A failed write does not publish unsaved credentials")
  memory.failWrite = false
  let generation = try store.snapshot().generation
  try store.clear()
  do {
    try store.save(updated, generation: generation)
    check(false, "A cleared generation must reject a late refresh")
  } catch {}
  check(
    try store.load().isEmpty && memory.data == nil,
    "Reauth cannot be undone by an old network response")

  let failed = MemoryCredentialStorage()
  let retry = AuthorizationStore(storage: failed)
  failed.data = try jsonData(token)
  failed.failRead = true
  do {
    _ = try retry.load()
    check(false, "Locked Keychain must fail closed")
  } catch {}
  check(failed.writes == 0, "A locked Keychain never overwrites protected credentials")
  failed.failRead = false
  check(
    text(try retry.load()["access_token"]) == "fixture-access",
    "Keychain access recovers after unlocking")
  failed.failWrite = true
  do {
    try retry.save(updated)
    check(false, "Failed Keychain writes must be visible")
  } catch {}
  check(
    text(try retry.load()["access_token"]) == "fixture-access",
    "A failed write retains the confirmed sign-in")
  failed.failWrite = false
  try retry.save(updated)
  failed.failRemove = true
  do {
    try retry.clear()
    check(false, "Failed Keychain deletion must be visible")
  } catch {}
  do {
    _ = try retry.load()
    check(false, "A failed clear must keep blocking credential reads")
  } catch {}
  failed.failRemove = false
  try retry.clear()

  let idMemory = MemoryCredentialStorage()
  let idOnly = AuthorizationStore(storage: idMemory)
  try idOnly.saveClientID(String(repeating: "b", count: 32))
  check(
    text(try AuthorizationStore(storage: idMemory).load()["client_id"])
      == String(repeating: "b", count: 32), "A manual Client ID persists before sign-in")
  try idOnly.save(token)
  try idOnly.saveClientID(String(repeating: "c", count: 32))
  check(
    text(try idOnly.load()["client_id"]) == String(repeating: "c", count: 32),
    "A new manual Client ID is saved in protected storage")
  check(
    try idOnly.load()["access_token"] == nil,
    "Changing Client ID cannot reuse tokens belonging to a different app")
  try idOnly.clear()
  check(idMemory.data == nil, "Reauth clears a Client ID even when no sign-in completed")

  let corrupt = MemoryCredentialStorage()
  corrupt.data = Data("not-json".utf8)
  let damaged = AuthorizationStore(storage: corrupt)
  do {
    _ = try damaged.load()
    check(false, "Corrupt Keychain data must not be ignored")
  } catch {}
  check(corrupt.writes == 0, "Corrupt protected data is reported without overwriting it")

  let paths = testPaths(
    root: root.appendingPathComponent("race"), clientID: String(repeating: "a", count: 32),
    environment: [:])
  try paths.prepare()
  try paths.authorization.save(token)
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [TestURLProtocol.self]
  let api = SpotifyAPI(paths, session: URLSession(configuration: configuration))
  defer { TestURLProtocol.response = nil }
  TestURLProtocol.response = { _ in
    try! paths.authorization.clear()
    return (
      200,
      try! jsonData([
        "access_token": "late-access", "refresh_token": "late-refresh", "expires_in": 3600,
      ])
    )
  }
  do {
    _ = try api.accessToken(force: true)
    check(false, "A reset during refresh must cancel credential persistence")
  } catch {}
  check(
    try paths.authorization.load().isEmpty,
    "An in-flight token refresh cannot resurrect a cleared sign-in")

  func verify(_ value: Bool, _ message: String) throws {
    if !value { throw SpotifyFailure(message: message) }
  }
  // Isolate dummy credentials with a fresh service; never access the real Spotify item.
  let disk = KeychainCredentialStorage(
    service: workflowID + ".tests." + UUID().uuidString,
    label: "Spotify Mini Player Test Sign-In")
  defer { try? disk.remove() }
  let real = AuthorizationStore(storage: disk)
  try real.saveClientID(String(repeating: "a", count: 32))
  try verify(
    text(try AuthorizationStore(storage: disk).load()["client_id"])
      == String(repeating: "a", count: 32),
    "Native Keychain persists a manually entered ID before sign-in")
  try real.save(token)
  let realCold = AuthorizationStore(storage: disk)
  try verify(
    text(try realCold.load()["refresh_token"]) == "fixture-refresh",
    "Native Keychain round trip survives a cold store")
  try real.save(updated)
  try verify(
    text(try AuthorizationStore(storage: disk).load()["access_token"]) == "updated-access",
    "Native Keychain updates preserve the item")
  try real.clear()
  try verify(try disk.read() == nil, "Native reauth deletes the Keychain item")
  print(
    "Keychain credentials passed: native round trip, memory caching, failures, refresh races, and reauth deletion."
  )
}

private func testClientIDSettings() throws {
  let root = tempDirectory("spotify-client-id-tests-")
  defer { try? FileManager.default.removeItem(at: root) }
  let paths = testPaths(root: root, environment: [:])
  try paths.prepare()
  let firstID = String(repeating: "a", count: 32)
  let savedID = String(repeating: "b", count: 32)
  let prefs = root.appendingPathComponent("prefs.plist")
  let preferences = try PropertyListSerialization.data(
    fromPropertyList: ["keyword": "myspot", "custom": 42], format: .binary, options: 0)
  try preferences.write(to: prefs)
  try paths.loadClientID()
  check(paths.clientID().isEmpty, "An empty Keychain requires manual setup")
  do {
    try paths.saveClientID("not-an-id")
    check(false, "Invalid setup input must fail")
  } catch {}
  check(try paths.authorization.load().isEmpty, "Invalid input is never stored")
  try paths.saveClientID("  " + savedID + "\n")
  check(
    try paths.clientID() == savedID && text(paths.authorization.load()["client_id"]) == savedID,
    "Entered ID is trimmed and saved in Keychain")
  let reopened = testPaths(root: root, environment: [:])
  check(reopened.clientID().isEmpty, "Constructing paths does not perform credential I/O")
  try reopened.loadClientID()
  check(reopened.clientID() == savedID, "Keychain restores the manually entered Client ID")
  try paths.authorization.save([
    "client_id": firstID, "access_token": "test", "refresh_token": "test",
  ])
  try paths.loadClientID()
  check(
    paths.clientID() == firstID && SpotifyAPI(paths).connected,
    "An existing Keychain sign-in restores its Client ID")
  try NativeBackend.clearConnection(paths)
  try reopened.loadClientID()
  check(
    try paths.clientID().isEmpty && reopened.clientID().isEmpty
      && paths.authorization.load().isEmpty,
    "Reauth clears in-memory and Keychain setup")
  check(
    try Data(contentsOf: prefs) == preferences,
    "Credential operations never rewrite Alfred preferences")
  print(
    "Client ID setup passed: manual entry, Keychain persistence, invalid input, reauth, and unchanged preferences."
  )
}

private func testWorkflowKeyword() throws {
  let root = tempDirectory("spotify-keyword-tests-")
  defer { try? FileManager.default.removeItem(at: root) }
  let paths = testPaths(
    root: root, clientID: String(repeating: "a", count: 32),
    environment: [
      "alfred_workflow_data": root.appendingPathComponent("data").path,
      "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    ])
  try paths.prepare()
  check(paths.keyword(environment: [:]) == "spot", "Default command prefix is spot")
  check(
    paths.keyword(environment: ["keyword": " spotify "]) == "spotify",
    "Alfred's configured keyword is used and trimmed")
  func save(_ keyword: String) throws {
    try PropertyListSerialization.data(
      fromPropertyList: ["keyword": keyword], format: .xml, options: 0
    ).write(to: root.appendingPathComponent("prefs.plist"))
  }
  try save("music")
  check(
    paths.keyword(environment: ["keyword": "old"]) == "music"
      && paths.command("reauth") == "music reauth",
    "Saved keyword overrides a warm process's old environment")
  let api = SpotifyAPI(paths)
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  let library = MusicLibrary(store, api)
  for command in ["state", "repeat", "like", "play"] {
    do {
      switch command {
      case "state": _ = try api.playbackState()
      case "repeat": try api.setRepeat(.context)
      case "like":
        try library.setLiked("spotify:track:" + String(repeating: "t", count: 22), liked: true)
      default:
        try WebPlayback(api, online: { true }).play(
          "spotify:track:" + String(repeating: "t", count: 22))
      }
      check(false, "Missing playback scopes must produce an actionable error")
    } catch {
      check(
        error.localizedDescription.contains("music reauth"),
        "Reauth guidance follows the customized keyword")
    }
  }
  try save(" ")
  check(
    paths.keyword(environment: ["keyword": "old"]) == "spot",
    "Clearing a keyword restores the default")
  print(
    "Shared keyword checks passed: defaults, preferences, live changes, and customized reauth guidance."
  )
}

private func testPlaintextPaths() throws {
  let root = tempDirectory("spotify-path-tests-")
  defer { try? FileManager.default.removeItem(at: root) }
  let paths = testPaths(
    root: root, clientID: String(repeating: "a", count: 32),
    environment: [
      "alfred_workflow_data": root.appendingPathComponent("data").path,
      "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    ])
  try paths.prepare()
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [OfflineURLProtocol.self]
  let library = MusicLibrary(store, SpotifyAPI(paths, session: URLSession(configuration: config)))
  let artistURI = "spotify:artist:" + String(repeating: "r", count: 22)
  let albumURI = "spotify:album:" + String(repeating: "a", count: 22)
  let playlistURI = "spotify:playlist:" + String(repeating: "p", count: 22)
  let trackURI = "spotify:track:" + String(repeating: "t", count: 22)
  let shadowURI = "spotify:playlist:" + String(repeating: "q", count: 22)
  let shadowPlaylist: JSONObject = ["uri": shadowURI, "kind": "playlist", "name": "Liked Songs"]
  let publicURI = "spotify:playlist:" + String(repeating: "u", count: 22)
  let publicPlaylist: JSONObject = [
    "uri": publicURI, "kind": "playlist", "name": "Liked Songs Public",
  ]
  let album: JSONObject = [
    "uri": albumURI, "kind": "album", "name": "Side / A",
    "artists": [["uri": artistURI, "name": "AC/DC"]],
  ]
  let artist: JSONObject = ["uri": artistURI, "kind": "artist", "name": "AC/DC", "albums": [album]]
  let playlist: JSONObject = ["uri": playlistURI, "kind": "playlist", "name": "Road / Trip"]
  let track: JSONObject = ["uri": trackURI, "kind": "track", "name": "Song", "album": album]
  for item in [artist, album, playlist, track, shadowPlaylist, publicPlaylist] {
    try store.putItem(item)
    try store.save(text(item["uri"]), liked: true)
  }
  try store.put("library:followed-artists", [artistURI])
  let requests = OfflineURLProtocol.requests
  for (name, kind) in [
    ("Playlists", "playlists"), ("Albums", "albums"), ("Artists", "artists"), ("Songs", "songs"),
  ] {
    for spelling in [name, name.lowercased(), String(name.dropLast())] {
      let input = spelling + "/filter"
      let resolved = try library.resolvePath(input)
      check(
        resolved.routes.count == 1 && text(resolved.routes[0]["kind"]) == kind,
        "Typed category paths and singular aliases select the correct view")
      check(
        String(input.dropFirst(resolved.consumed.count)) == "filter",
        "Typed category filters stay separate from the folder path")
      check(
        LibraryPath.prefix(for: resolved.routes) == spelling + "/",
        "Path casing regression test preserves typed category casing and singular aliases")
      let rows = try library.browse(resolved.routes.last!)
      check(!rows.isEmpty, "Typed category paths use the actual saved library")
    }
  }
  for spelling in ["Liked Songs", "liked songs", "LiKeD SoNgS"] {
    let resolved = try library.resolvePath(spelling + "/all")
    check(
      resolved.routes.count == 1 && text(resolved.routes[0]["kind"]) == "songs"
        && text(resolved.routes[0]["name"]) == "Liked Songs"
        && LibraryPath.prefix(for: resolved.routes) == spelling + "/"
        && String((spelling + "/all").dropFirst(resolved.consumed.count)) == "all",
      "Liked Songs root regression test accepts the canonical root while preserving its typed case")
  }
  let canonicalRoot = try library.resolvePath("liked songs/")
  let realPlaylist = try library.resolvePath("playlists/liked songs/")
  let publicPath = try library.resolvePath("playlists/liked songs public/")
  check(
    text(canonicalRoot.routes.last?["kind"]) == "songs"
      && text(realPlaylist.routes.last?["kind"]) == "songs"
      && text(realPlaylist.routes.last?["uri"]).isEmpty
      && text(realPlaylist.routes.last?["path_component"]) == "liked songs"
      && text(publicPath.routes.last?["kind"]) == "playlist"
      && text(publicPath.routes.last?["uri"]) == publicURI,
    "Liked Songs root regression test aliases exact-name playlists without changing longer names")
  check(
    isLikedSongsPlaylist(shadowPlaylist)
      && isLikedSongsPlaylist(shadowPlaylist.merging(["name": "LiKeD SoNgS"]) { _, new in new })
      && isLikedSongsPlaylist(["kind": "playlist", "uri": PlaybackContext.likedSongs.uri])
      && !isLikedSongsPlaylist(publicPlaylist)
      && !isLikedSongsPlaylist(["kind": "album", "name": "Liked Songs"]),
    "Liked Songs playlist regression test requires the playlist kind and exact name or collection URI"
  )
  let aliasedRows = try library.browse(shadowPlaylist, network: true)
  check(
    text(aliasedRows.first?["play_uri"]) == PlaybackContext.likedSongs.uri
      && aliasedRows.dropFirst().map { text($0["uri"]) } == [trackURI],
    "Liked Songs playlist regression test browses saved songs without requesting playlist tracks")
  let canonicalRows = try library.browse(canonicalRoot.routes.last!)
  let legacyRoot = try library.resolvePath("songs/")
  let legacyRows = try library.browse(legacyRoot.routes.last!)
  check(
    text(canonicalRows.first?["name"]) == "Liked Songs"
      && text(canonicalRows.first?["match"]) == "All"
      && text(legacyRows.first?["match"]) == "Liked Songs All",
    "Liked Songs root regression test keeps collection aliases specific to their root spelling")
  let nested = "Artists/AC/DC/Side / A/Song"
  let resolved = try library.resolvePath(nested)
  check(
    resolved.routes.map { text($0["kind"]) } == ["artists", "artist", "album"]
      && text(resolved.routes.last?["uri"]) == albumURI
      && resolved.consumed == "Artists/AC/DC/Side / A/",
    "Typed nested paths support slashes inside artist and album names")
  check(
    String(nested.dropFirst(resolved.consumed.count)) == "Song",
    "Nested paths leave a filter for the final view")
  let mixed = try library.resolvePath("aRtIsT/Ac/dC/SiDé / a/FiLtEr")
  check(
    LibraryPath.prefix(for: mixed.routes) == "aRtIsT/Ac/dC/SiDé / a/"
      && String("aRtIsT/Ac/dC/SiDé / a/FiLtEr".dropFirst(mixed.consumed.count)) == "FiLtEr"
      && text(mixed.routes[1]["name"]) == "AC/DC"
      && text(mixed.routes[2]["name"]) == "Side / A",
    "Path casing regression test preserves mixed casing, accents and filters without changing names"
  )
  check(
    LibraryPath.prefix(for: [["kind": "artists", "name": "Artists"], artist, album])
      == "artists/ac/dc/side / a/"
      && LibraryPath.prefix(for: [["kind": "songs"]]) == "liked songs/",
    "Path casing regression test inserts lowercase categories and nested music names")
  check(
    LibraryPath.prefix(for: Array(mixed.routes.dropLast()) + [album])
      == "aRtIsT/Ac/dC/side / a/",
    "Path casing regression test preserves a typed parent while inserting a lowercase child")
  check(
    LibraryPath.prefix(for: [["kind": "catalog", "query": "Mixed CASE"]]) == "/"
      && LibraryPath.prefix(for: [["kind": "catalog", "query": "Mixed CASE"], artist])
        == "/Mixed CASE/ac/dc/",
    "Path casing regression test leaves catalogue queries untouched")
  let direct = try library.resolvePath("Side / A/")
  check(
    direct.routes.count == 1 && text(direct.routes.last?["uri"]) == albumURI,
    "A breadcrumb opened from search can be typed directly")
  let playlistPath = try library.resolvePath("Playlists/Road / Trip/")
  check(
    text(playlistPath.routes.last?["uri"]) == playlistURI,
    "Playlist paths preserve names containing slashes")
  let partial = try library.resolvePath("Artists/AC/D")
  check(
    partial.routes.count == 1 && partial.consumed == "Artists/",
    "Incomplete folder names remain filters until their delimiter is entered")
  let unknown = try library.resolvePath("Unknown/Album/")
  check(
    unknown.routes.isEmpty && unknown.consumed.isEmpty,
    "An unknown path remains a literal local query")
  let all = try library.resolvePath("Songs/All/")
  check(
    all.routes.count == 1, "Typing a play action never starts playback or turns it into a folder")
  check(
    OfflineURLProtocol.requests == requests,
    "Typed paths resolve from cached metadata without HTTP requests")
  // Exercise the backend stack too: show/back must retain the typed components,
  // while opening another child adds only that child's lowercase name.
  try store.put("desktop:downloaded-uris", [artistURI, albumURI, playlistURI, trackURI, publicURI])
  let offlineLibrary = MusicLibrary(store, library.api, online: { false })
  let offlinePlaylists = try offlineLibrary.browse(["kind": "playlists"])
  check(
    offlineLibrary.catalog().contains(where: isLikedSongsPlaylist)
      && offlinePlaylists.contains(where: isLikedSongsPlaylist),
    "Offline Liked Songs regression test includes aliases with downloaded saved songs")
  try store.save(trackURI, liked: false)
  let unlikedCatalog = offlineLibrary.catalog()
  let unlikedPlaylists = try offlineLibrary.browse(["kind": "playlists"])
  check(
    !unlikedCatalog.contains(where: isLikedSongsPlaylist)
      && !unlikedPlaylists.contains(where: isLikedSongsPlaylist)
      && unlikedCatalog.contains { text($0["uri"]) == trackURI },
    "Offline Liked Songs regression test excludes aliases when only unliked downloaded songs remain"
  )
  try store.save(trackURI, liked: true)
  try paths.authorization.save([
    "client_id": String(repeating: "a", count: 32), "access_token": "fixture",
    "refresh_token": "fixture", "expires_at": Date().timeIntervalSince1970 + 30,
    "scope": SpotifyAPI.scopes,
  ])
  try store.put(MusicLibrary.syncKey, true, ttl: 3600)
  try store.put("desktop:scanned:v4", true, ttl: 3600)
  let backendSession = URLSession(configuration: config)
  let backend = NativeBackend(
    root,
    environment: [
      "alfred_workflow_data": paths.data.path, "alfred_workflow_cache": paths.cache.path,
      "SPOTIFY_DESKTOP_CACHE": root.appendingPathComponent("desktop").path,
      "SPOTIFY_DESKTOP_USER_CACHE": root.appendingPathComponent("empty").path,
    ], session: backendSession, credentials: paths.authorization)
  var updates: [JSONObject] = []
  backend.receive = { updates.append($0) }
  defer {
    backend.stop()
    backendSession.invalidateAndCancel()
  }
  func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
  }
  try backend.start()
  wait { updates.contains { text($0["connection"]) == "connected" } }
  check(
    updates.contains { text($0["connection"]) == "connected" },
    "Path casing regression test starts an isolated connected backend")
  func command(_ name: String, _ args: [String] = []) -> JSONObject {
    let start = updates.count
    backend.send(["command": name, "args": args])
    wait { updates.dropFirst(start).contains { text($0["command"]) == name } }
    let result = updates.dropFirst(start).first { text($0["command"]) == name }
    check(result != nil, "Path casing regression test receives the " + name + " result")
    return result ?? [:]
  }
  func activate(_ item: JSONObject) -> JSONObject {
    command("activate", [String(decoding: try! jsonData(item), as: UTF8.self)])
  }
  let searchRows = command("home")["rows"] as? [JSONObject] ?? []
  let searchRow = searchRows.first { text(dict($0["item"])["action"]) == "catalog" } ?? [:]
  let searchPayload = dict(searchRow["item"])
  let searchSubtitle = "Search Spotify's full catalogue"
  check(
    text(searchRow["detail"]) == searchSubtitle && text(searchPayload["detail"]) == searchSubtitle,
    "Search caption regression test preserves the subtitle in the published row and preview payload"
  )
  for _ in 0..<2 {
    let preview = command("preview", [String(decoding: try jsonData(searchPayload), as: UTF8.self)])
    let variables = dict(preview["variables"])
    check(
      text(variables["preview_title"]) == "Search Spotify"
        && text(variables["preview_detail"]) == searchSubtitle,
      "Search caption regression test keeps the subtitle through repeated backend preview replies")
  }
  let likedMenu = homeItems.first { text(dict($0["target"])["kind"]) == "songs" }!
  check(
    text(likedMenu["name"]) == "Liked Songs"
      && text(activate(likedMenu)["search_text"]) == "liked songs/",
    "Liked Songs root regression test uses the new menu name and canonical inserted query")
  let collision = command("path", ["liked songs/"])
  check(
    text(collision["route_kind"]) == "songs"
      && text(command("path", ["playlists/liked songs/"])["route_kind"]) == "songs"
      && text(command("path", ["playlists/liked songs public/"])["route_kind"]) == "playlist",
    "Liked Songs root regression test treats exact-name playlists as the collection offline too")
  _ = command("home")
  let playlistsMenu = homeItems.first { text(dict($0["target"])["kind"]) == "playlists" }!
  _ = activate(playlistsMenu)
  let openedAlias = activate(shadowPlaylist)
  let openedCollection = (openedAlias["rows"] as? [JSONObject])?.first ?? [:]
  check(
    text(openedAlias["route_kind"]) == "songs"
      && text(openedAlias["search_text"]) == "liked songs/"
      && text(dict(openedCollection["item"])["play_uri"]) == PlaybackContext.likedSongs.uri,
    "Liked Songs navigation regression test opens playlist aliases with the canonical collection query"
  )
  let aliasParent = command("back", ["liked songs/"])
  let parentRows = aliasParent["rows"] as? [JSONObject] ?? []
  check(
    text(aliasParent["route_kind"]) == "playlists"
      && text(aliasParent["search_text"]) == "playlists/"
      && parentRows.contains { text(dict($0["item"])["uri"]) == shadowURI }
      && parentRows.contains { text(dict($0["item"])["uri"]) == publicURI },
    "Liked Songs navigation regression test restores the playlist parent and original selectable rows"
  )
  let typedAlias = command("path", ["playlists/liked songs/"])
  check(
    text(typedAlias["route_kind"]) == "songs"
      && text(typedAlias["prefix"]) == "playlists/liked songs/"
      && text(typedAlias["path_prefix"]) == "playlists/liked songs/",
    "Liked Songs navigation regression test preserves explicitly typed playlist parents")
  _ = command("home")
  let artistsMenu = homeItems.first { text(dict($0["target"])["kind"]) == "artists" }!
  check(
    text(activate(artistsMenu)["prefix"]) == "artists/"
      && text(activate(artist)["prefix"]) == "artists/ac/dc/"
      && text(activate(album)["prefix"]) == "artists/ac/dc/side / a/",
    "Backend path casing regression test inserts lowercase category and nested query components")
  let typedPrefix = "aRtIsT/Ac/dC/SiDé / a/"
  let typed = command("path", [typedPrefix + "FiLtEr"])
  check(
    text(typed["prefix"]) == typedPrefix && text(typed["path_prefix"]) == typedPrefix
      && text(command("show")["prefix"]) == typedPrefix,
    "Backend path casing regression test retains typed casing on path resolution and reopen")
  check(
    text(command("back", [typedPrefix + "FiLtEr"])["search_text"]) == typedPrefix
      && text(command("back", [typedPrefix])["search_text"]) == "aRtIsT/Ac/dC/"
      && text(activate(album)["search_text"]) == "aRtIsT/Ac/dC/side / a/",
    "Backend path casing regression test preserves parent casing during filter removal and navigation"
  )
  check(
    text(command("path", ["sOnG/"])["prefix"]) == "sOnG/"
      && text(command("show")["prefix"]) == "sOnG/",
    "Backend path casing regression test keeps typed singular category aliases unchanged")
  for query in ["songs/all", "songs/liked songs", "liked songs/all"] {
    let result = command("path", [query])
    let rows = result["rows"] as? [JSONObject] ?? []
    let collection = rows.first ?? [:]
    let words = text(collection["match"]).lowercased().split(whereSeparator: { $0.isWhitespace })
    let filter = String(query.dropFirst(text(result["path_prefix"]).count))
    check(
      text(result["path_prefix"]) == (query.hasPrefix("liked songs/") ? "liked songs/" : "songs/")
        && text(collection["name"]) == "Liked Songs"
        && text(dict(collection["item"])["play_uri"]) == PlaybackContext.likedSongs.uri
        && filter.split(whereSeparator: { $0.isWhitespace }).allSatisfy { term in
          words.contains { $0.hasPrefix(term) }
        },
      "Liked Songs regression test preserves the display label and collection playback for " + query
    )
    check(
      rows.dropFirst().allSatisfy {
        !text($0["match"]).lowercased().split(whereSeparator: { $0.isWhitespace }).contains("all")
      }, "Liked Songs regression test limits the all alias to the collection action")
  }
  let duplicate = command("path", ["liked songs/liked songs"])
  let duplicateCollection = (duplicate["rows"] as? [JSONObject])?.first ?? [:]
  let duplicateWords = text(duplicateCollection["match"]).lowercased().split(whereSeparator: {
    $0.isWhitespace
  })
  check(
    text(duplicate["path_prefix"]) == "liked songs/"
      && !["liked", "songs"].allSatisfy { term in duplicateWords.contains { $0.hasPrefix(term) } },
    "Liked Songs root regression test does not offer a duplicated liked songs/liked songs alias")
  print(
    "Plaintext paths passed: categories, aliases, nested folders, casing, slash names, filters, and offline resolution."
  )
}

private func testSavedAlbums() throws {
  let root = tempDirectory("spotify-saved-albums-tests-")
  defer { try? FileManager.default.removeItem(at: root) }
  let paths = testPaths(
    root: root, clientID: String(repeating: "a", count: 32),
    environment: [
      "alfred_workflow_data": root.appendingPathComponent("data").path,
      "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    ])
  try paths.prepare()
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  let library = MusicLibrary(store, SpotifyAPI(paths))
  func album(_ id: String, _ name: String) -> JSONObject {
    ["uri": "spotify:album:" + String(repeating: id, count: 22), "kind": "album", "name": name]
  }
  let zebra = album("z", "Zebra")
  let alpha = album("a", "Alpha")
  let likedOnly = album("l", "Liked song's album")
  let cachedOnly = album("c", "Cached album")
  for item in [zebra, alpha, likedOnly, cachedOnly] { try store.putItem(item) }
  for item in [zebra, alpha] { try store.save(text(item["uri"]), liked: true) }
  let track: JSONObject = [
    "uri": "spotify:track:" + String(repeating: "t", count: 22), "kind": "track",
    "name": "Liked song", "album": likedOnly,
  ]
  try store.putItem(track)
  try store.save(text(track["uri"]), liked: true)
  let albums = try library.browse(["kind": "albums"])
  check(
    albums.map { text($0["uri"]) } == [text(alpha["uri"]), text(zebra["uri"])],
    "Albums lists only explicitly saved albums, in order, even with liked songs and cached metadata"
  )
  try store.save(text(zebra["uri"]), liked: false)
  let remaining = try library.browse(["kind": "albums"])
  check(
    remaining.count == 1 && text(remaining[0]["uri"]) == text(alpha["uri"]),
    "Removing a saved album updates the list and its count")
  try store.save(text(alpha["uri"]), liked: false)
  let empty = try library.browse(["kind": "albums"])
  check(empty.isEmpty, "Liked songs do not create saved albums when no albums are saved")
  let songs = try library.browse(["kind": "songs"])
  check(
    songs.count == 2 && text(songs[1]["uri"]) == text(track["uri"]),
    "Correcting album membership preserves Liked Songs")
  let contents = try library.browse(likedOnly)
  check(
    contents.count == 2 && text(contents[1]["uri"]) == text(track["uri"])
      && store.item(text(cachedOnly["uri"])) != nil,
    "Unsaved album metadata and contents remain available offline")
  print(
    "Saved album membership passed: saved albums only, removals, empty library, and retained offline metadata."
  )
}

private func testFollowedArtists() throws {
  let root = tempDirectory("spotify-followed-artists-tests-")
  defer { try? FileManager.default.removeItem(at: root) }
  let paths = testPaths(
    root: root, clientID: String(repeating: "a", count: 32),
    environment: [
      "alfred_workflow_data": root.appendingPathComponent("data").path,
      "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    ])
  try paths.prepare()
  let client = String(repeating: "a", count: 32)
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [TestURLProtocol.self]
  let api = SpotifyAPI(paths, session: URLSession(configuration: config))
  let library = MusicLibrary(store, api, online: { true })
  try api.paths.authorization.save([
    "client_id": client, "access_token": "test", "refresh_token": "test",
    "expires_at": Date().timeIntervalSince1970 + 3600, "scope": SpotifyAPI.scopes,
  ])
  func artist(_ id: String, _ name: String) -> JSONObject {
    ["uri": "spotify:artist:" + String(repeating: id, count: 22), "name": name]
  }
  let followed = artist("f", "Alpha")
  let second = artist("s", "Zebra")
  let likedArtist = artist("l", "Liked song artist")
  let albumArtist = artist("b", "Album artist")
  let album: JSONObject = [
    "uri": "spotify:album:" + String(repeating: "a", count: 22), "name": "Album",
    "artists": [albumArtist],
  ]
  let track: JSONObject = [
    "uri": "spotify:track:" + String(repeating: "t", count: 22), "name": "Song",
    "artists": [likedArtist], "album": album,
  ]
  try store.putItem(likedArtist.merging(["kind": "artist"]) { _, new in new })
  try store.save(text(likedArtist["uri"]), liked: true)
  var includeSecond = true
  TestURLProtocol.response = { request in
    switch request.url!.path {
    case "/v1/me": return (200, try! jsonData(["id": "followed-artists-fixture"]))
    case "/v1/me/tracks": return (200, try! jsonData(["items": [["track": track]]]))
    case "/v1/me/albums": return (200, try! jsonData(["items": [["album": album]]]))
    case "/v1/me/following":
      if request.url!.queryItemsForTesting.contains(where: { $0.name == "after" }) {
        return (200, try! jsonData(["artists": ["items": [second]]]))
      }
      var page: JSONObject = ["items": [followed]]
      if includeSecond {
        page["next"] = "https://api.spotify.com/v1/me/following?type=artist&after=fixture"
      }
      return (200, try! jsonData(["artists": page]))
    case "/v1/me/playlists": return (200, try! jsonData(["items": []]))
    default:
      check(false, "Unexpected artist membership request")
      return (500, Data())
    }
  }
  defer { TestURLProtocol.response = nil }
  try library.sync()
  let artists = try library.browse(["kind": "artists"])
  check(
    artists.map { text($0["uri"]) } == [text(followed["uri"]), text(second["uri"])],
    "Artists contains only followed artists across all API pages")
  check(
    !store.isSaved(text(likedArtist["uri"])) && !store.isSaved(text(albumArtist["uri"]))
      && store.item(text(likedArtist["uri"])) != nil && store.item(text(albumArtist["uri"])) != nil,
    "Liked-song and album artist metadata does not become followed membership")
  includeSecond = false
  try library.sync()
  let remaining = try library.browse(["kind": "artists"])
  check(
    remaining.count == 1 && text(remaining[0]["uri"]) == text(followed["uri"]),
    "Unfollowing removes the artist on refresh")
  check(store.get(MusicLibrary.syncKey) != nil, "Corrected membership has a versioned sync marker")
  print("Followed artists passed: pagination, unfollows, and metadata separated from membership.")
}

private func downloadManifest(_ entries: [Data]) -> Data {
  Data([5]) + encodeVarint(UInt64(entries.count) << 3 | 4) + entries.reduce(Data(), +)
}
private func downloadEntry(
  _ uri: String, tracks: [(UInt8, UInt64)], enabled: UInt64 = 1, error: String = ""
) -> Data {
  func blob(_ type: UInt8, _ value: Data) -> Data {
    Data([type]) + encodeVarint(UInt64(value.count)) + value
  }
  var value = blob(1, Data(uri.utf8)) + blob(9, Data("_playlist".utf8))
  value += Data([13]) + encodeVarint(UInt64(tracks.count) << 3 | 4)
  for (id, state) in tracks {
    value +=
      blob(1, Data(repeating: id, count: 16)) + Data([16]) + encodeVarint(state) + Data([120])
  }
  value +=
    Data([8]) + encodeVarint(1234) + Data([8]) + encodeVarint(enabled) + blob(9, Data(error.utf8))
  value += Data([8]) + encodeVarint(1) + blob(17, Data("spotify:image:fixture".utf8)) + Data([120])
  return value
}
private func testOfflineDownloads() throws {
  let root = tempDirectory("spotify-downloads-tests-")
  defer { try? FileManager.default.removeItem(at: root) }
  let paths = testPaths(
    root: root, clientID: String(repeating: "a", count: 32),
    environment: [
      "alfred_workflow_data": root.appendingPathComponent("data").path,
      "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    ])
  try paths.prepare()
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [OfflineURLProtocol.self]
  var online = false
  let library = MusicLibrary(
    store, SpotifyAPI(paths, session: URLSession(configuration: config)), online: { online })
  func item(_ kind: String, _ id: String, _ name: String) -> JSONObject {
    ["uri": "spotify:" + kind + ":" + String(repeating: id, count: 22), "kind": kind, "name": name]
  }
  let followed = item("artist", "f", "Followed")
  let other = item("artist", "o", "No downloads")
  let unfollowed = item("artist", "u", "Unfollowed")
  let album = item("album", "a", "Downloaded album").merging(["artists": [followed]]) { _, new in
    new
  }
  let cachedAlbum = item("album", "b", "Cached album").merging(["artists": [followed]]) { _, new in
    new
  }
  var songs: [JSONObject] = []
  for id: UInt8 in [1, 2, 3] {
    let song: JSONObject = [
      "uri": "spotify:track:" + spotifyID(Data(repeating: id, count: 16)), "kind": "track",
      "name": "Song \(id)",
      "album": id == 3 ? cachedAlbum : album, "artists": [followed, unfollowed],
    ]
    songs.append(song)
  }
  let playlist = item("playlist", "p", "Downloaded playlist").merging(["tracks": songs]) { _, new in
    new
  }
  let notReady = item("playlist", "q", "Download disabled")
  for value in [followed, other, album, cachedAlbum, playlist, notReady] + songs {
    try store.putItem(value)
    try store.save(text(value["uri"]), liked: true)
  }
  try store.putItem(unfollowed)
  try store.put("library:followed-artists", [text(followed["uri"]), text(other["uri"])])
  let entries = [
    downloadEntry(text(playlist["uri"]), tracks: [(1, 0), (2, 1)]),
    downloadEntry(text(album["uri"]), tracks: [(1, 0)]),
    downloadEntry(text(notReady["uri"]), tracks: [(3, 0)], enabled: 0),
    downloadEntry(
      "spotify:playlist:" + String(repeating: "e", count: 22), tracks: [(3, 0)], error: "failed"),
  ]
  let manifest = downloadManifest(entries)
  let parsed = try DesktopMetadata.downloads(manifest)
  check(
    parsed.tracks == [text(songs[0]["uri"])] && parsed.collections.count == 2,
    "Download manifest excludes unready, disabled, and failed records")
  do {
    _ = try DesktopMetadata.downloads(Data(manifest.dropLast()))
    check(false, "Truncated download manifest must fail")
  } catch {}
  let directory = root.appendingPathComponent("primary.ldb")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let file = root.appendingPathComponent("offline_lists.bnk")
  try manifest.write(to: file)
  _ = try DesktopMetadata.index(directory, store: store)
  func uris(_ kind: String) throws -> [String] {
    try library.browse(["kind": kind], network: true).map { text($0["uri"]) }
  }
  let requests = OfflineURLProtocol.requests
  let offlineAlbums = try uris("albums")
  let offlineArtists = try uris("artists")
  let offlinePlaylists = try uris("playlists")
  check(
    offlineAlbums == [text(album["uri"])],
    "Offline Albums contains saved albums with downloaded songs only")
  check(
    offlineArtists == [text(followed["uri"])],
    "Offline Artists requires both following and downloaded songs")
  check(
    offlinePlaylists == [text(playlist["uri"])],
    "Offline Playlists contains downloaded playlists only")
  let offlineSongs = try library.browse(["kind": "songs"])
  check(
    offlineSongs.count == 2 && text(offlineSongs[1]["uri"]) == text(songs[0]["uri"]),
    "Offline Liked Songs excludes cached and unready songs")
  let contents = try library.browse(playlist)
  check(
    contents.count == 2 && text(contents[1]["uri"]) == text(songs[0]["uri"]),
    "Offline playlist contents and play action contain downloaded music")
  let artistAlbums = try library.browse(followed)
  check(
    artistAlbums.count == 2 && text(artistAlbums[1]["uri"]) == text(album["uri"]),
    "Offline artist browsing excludes albums without downloads")
  let catalog = library.catalog()
  check(
    !catalog.contains {
      [text(songs[1]["uri"]), text(songs[2]["uri"]), text(unfollowed["uri"])].contains(
        text($0["uri"]))
    }, "Offline search cannot expose cached-only music or unfollowed artists")
  try store.put("search:cached", songs)
  let search = try library.browse(["kind": "catalog", "query": "cached"], network: true)
  check(
    search.count == 1 && text(search[0]["uri"]) == text(songs[0]["uri"]),
    "Cached Spotify search results obey download filtering too")
  check(OfflineURLProtocol.requests == requests, "Offline browsing sends no network requests")
  online = true
  let onlineAlbums = try uris("albums")
  let onlineArtists = try uris("artists")
  check(
    onlineAlbums.count == 2 && onlineArtists.count == 2,
    "Going online restores the full saved library")
  online = false
  try downloadManifest([]).write(to: file)
  _ = try DesktopMetadata.index(directory, store: store)
  let removedSongs = try uris("songs")
  let removedPlaylists = try uris("playlists")
  check(
    removedSongs.isEmpty && removedPlaylists.isEmpty,
    "Removing downloads clears offline results without deleting library metadata")
  check(
    store.items("track", saved: true).count == 3,
    "Download filtering never removes Liked Songs membership")
  print(
    "Offline downloads passed: ready records, browsing, search, counts, network transitions, and removals."
  )
}

private func testAlbumTrackCounts() {
  let albumURI = "spotify:album:" + String(repeating: "a", count: 22)
  let api = fromAPI(["uri": albumURI, "name": "Single", "total_tracks": 1], kind: "album")!
  check(number(api["total"]) == 1, "API album track count survives normalization")
  let track: JSONObject = ["gid": String(repeating: "01", count: 16), "name": "Song"]
  let stub: JSONObject = ["gid": String(repeating: "02", count: 16)]
  let album: JSONObject = ["gid": String(repeating: "03", count: 16), "name": "Album"]
  let single = fromDesktop(
    album.merging(["disc": [["track": [track]]]]) { _, new in new }, kind: "album")!
  let multiple = fromDesktop(
    album.merging(["disc": [["track": [track]], ["track": [stub]]]]) { _, new in new },
    kind: "album")!
  check(
    number(single["total"]) == 1 && number(multiple["total"]) == 2,
    "Desktop album totals count all discs, including incomplete track metadata")
  check(
    (multiple["tracks"] as? [JSONObject])?.count == 1
      && fromDesktop(album, kind: "album")?["total"] == nil,
    "Partial track details and unknown album totals are distinct")
  let base = proto(1, Data(repeating: 3, count: 16)) + proto(2, Data("Album".utf8))
  let song = proto(1, Data(repeating: 1, count: 16)) + proto(2, Data("Song".utf8))
  let incomplete = proto(1, Data(repeating: 2, count: 16))
  let singleProto = fromProto(base + proto(11, proto(1, song)), kind: "album")!
  let multipleProto = fromProto(
    base + proto(11, proto(1, song)) + proto(11, proto(1, incomplete)), kind: "album")!
  check(
    number(singleProto["total"]) == 1 && number(multipleProto["total"]) == 2
      && (multipleProto["tracks"] as? [JSONObject])?.count == 1,
    "Protobuf album totals do not undercount incomplete track records")
  check(
    fromProto(base, kind: "album")?["total"] == nil,
    "A protobuf album without disc metadata has an unknown count")
  print(
    "Album track counts passed: API, desktop JSON, protobuf, multiple discs, and incomplete metadata."
  )
}

private func testOfflineCache() throws {
  OfflineURLProtocol.requests = 0
  let root = tempDirectory("spotify-offline-tests-")
  defer { try? FileManager.default.removeItem(at: root) }
  let paths = testPaths(
    root: root, clientID: String(repeating: "a", count: 32),
    environment: [
      "alfred_workflow_data": root.appendingPathComponent("data").path,
      "alfred_workflow_cache": root.appendingPathComponent("cache").path,
      "SPOTIFY_DESKTOP_CACHE": root.appendingPathComponent("http").path,
    ])
  try paths.prepare()
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [OfflineURLProtocol.self]
  let session = URLSession(configuration: config)
  let api = SpotifyAPI(paths, session: session)
  let library = MusicLibrary(store, api)
  let cache = DesktopCache(paths, store, session: session)
  try api.paths.authorization.save([
    "client_id": String(repeating: "a", count: 32), "access_token": "expired",
    "refresh_token": "offline", "expires_at": 0,
  ])
  let directory = root.appendingPathComponent("primary.ldb")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let playlistURI = "spotify:playlist:" + String(repeating: "p", count: 22)
  let trackURI = "spotify:track:" + spotifyID(Data(repeating: 1, count: 16))
  let likedURI = "spotify:track:" + spotifyID(Data(repeating: 4, count: 16))
  let albumURI = "spotify:album:" + spotifyID(Data(repeating: 2, count: 16))
  let coverID = String(repeating: "03", count: 20)
  let coverURL = "https://i.scdn.co/image/" + coverID
  let album =
    proto(1, Data(repeating: 2, count: 16)) + proto(2, Data("Offline album".utf8))
    + proto(9, proto(1, Data(repeating: 3, count: 20)))
  func track(_ byte: UInt8) -> Data {
    let track =
      proto(1, Data(repeating: byte, count: 16)) + proto(2, Data("Offline song".utf8))
      + proto(3, album)
    return proto(
      2, proto(1, Data("type.googleapis.com/spotify.metadata.Track".utf8)) + proto(2, track))
  }
  let content = Data([8, 0, 16, 0]) + proto(3, proto(1, Data(trackURI.utf8)))
  let playlist =
    Data([16, 1]) + proto(3, proto(1, Data("Offline playlist".utf8))) + proto(5, content)
  let removedKey = Data("fixture:deleted".utf8)
  let updatedKey = Data("fixture:updated".utf8)
  try writeTable(
    [
      (DesktopMetadata.playlistKey(playlistURI) + littleData(7 << 8 | 1, 8), playlist),
      (DesktopMetadata.trackKey(trackURI) + littleData(7 << 8 | 1, 8), track(1)),
      (DesktopMetadata.trackKey(likedURI) + littleData(7 << 8 | 1, 8), track(4)),
      (removedKey + littleData(7 << 8 | 1, 8), Data("old".utf8)),
      (updatedKey + littleData(7 << 8 | 1, 8), Data("old".utf8)),
    ], to: directory.appendingPathComponent("000001.ldb"))
  let batch =
    littleData(9, 8) + littleData(2, 4) + Data([0]) + encodeVarint(UInt64(removedKey.count))
    + removedKey + Data([1]) + encodeVarint(UInt64(updatedKey.count)) + updatedKey + encodeVarint(3)
    + Data("new".utf8)
  try
    (Data(repeating: 0, count: 4) + littleData(UInt64(batch.count), 2) + Data([1]) + batch
    + Data([0, 0, 0, 0, 255, 127, 1])).write(to: directory.appendingPathComponent("000002.log"))
  let records = DesktopDatabase.read(directory, prefixes: [removedKey, updatedKey])
  check(
    records.count == 1 && records[updatedKey]?.value == Data("new".utf8),
    "Desktop journal updates and tombstones override older tables; incomplete records are ignored")
  try store.put("desktop:playlist-order", [playlistURI])
  try store.putItem(["uri": likedURI, "kind": "track", "name": "Saved song", "image": ""])
  try store.save(likedURI, liked: true)
  let imported = try DesktopMetadata.index(directory, store: store)
  check(
    imported >= 3 && text(store.item(trackURI)?["image"]) == coverURL
      && text(store.item(likedURI)?["image"]) == coverURL,
    "Import playlist and saved-song metadata from native desktop cache")
  check(
    !store.isSaved(trackURI) && store.isSaved(likedURI),
    "Desktop metadata never changes Liked Songs membership")
  let rows = try library.browse(["kind": "playlist", "uri": playlistURI], network: true)
  check(
    rows.count == 2 && text(rows[1]["uri"]) == trackURI && OfflineURLProtocol.requests == 0,
    "Complete desktop playlist opens offline without token refresh")
  try store.put("contents:" + albumURI, [store.item(trackURI)!], ttl: -1)
  let albums = try library.browse(["kind": "album", "uri": albumURI])
  check(albums.count == 2, "Expired album contents remain browsable offline")
  let noNative = "spotify:playlist:" + String(repeating: "q", count: 22)
  try store.putItem(["uri": noNative, "kind": "playlist", "name": "Previously opened"])
  try store.put("contents:" + noNative, [store.item(trackURI)!], ttl: -1)
  let fallback = try library.browse(["kind": "playlist", "uri": noNative], network: true)
  check(
    fallback.count == 2 && api.connected,
    "Offline refresh retains expired playlist contents and connection")
  try store.put("search:offline", [store.item(trackURI)!], ttl: -1)
  let search = try library.browse(["kind": "catalog", "query": "offline"], network: true)
  check(search.count == 1, "Previously cached catalogue queries survive offline token expiry")
  do {
    _ = try library.browse(["kind": "catalog", "query": "uncached"], network: true)
    check(false, "Uncached catalogue query must explain unavailable network")
  } catch {
    check(
      (error as? SpotifyFailure)?.isNetworkError == true,
      "Uncached network search preserves its connection error")
  }
  let image = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jUKsAAAAASUVORK5CYII="
  )!
  // Spotify often caches another size of the same cover ID.
  let alias = "https://i.scdn.co/image/" + coverID.prefix(8) + "abcdef01" + coverID.suffix(24)
  let key = Data(alias.utf8)
  let header =
    littleData(0xfcfb_6d1b_a772_5c30, 8) + littleData(5, 4) + littleData(UInt64(key.count), 4)
    + Data(repeating: 0, count: 8)
  let crc = image.withUnsafeBytes { spotify_crc32($0.baseAddress, $0.count) }
  let bodyFooter =
    littleData(0xf4fa_6f45_970d_41d8, 8) + littleData(1, 4) + littleData(UInt64(crc), 4)
    + Data(repeating: 0, count: 8)
  let finalFooter = littleData(0xf4fa_6f45_970d_41d8, 8) + Data(repeating: 0, count: 16)
  try FileManager.default.createDirectory(at: paths.desktop, withIntermediateDirectories: true)
  let original = paths.desktop.appendingPathComponent("cover_0")
  try (header + key + image + bodyFooter + finalFooter).write(to: original)
  _ = try cache.index()
  let requests = OfflineURLProtocol.requests
  let preserved = try cache.preserveArtwork()
  check(preserved == 1, "Desktop artwork is preserved before a track is selected")
  check(
    OfflineURLProtocol.requests == requests,
    "Cover preservation reuses desktop cache without network")
  try FileManager.default.removeItem(at: original)
  let retained = try cache.image(coverURL, download: false)
  check(
    retained != nil && (try? Data(contentsOf: URL(fileURLWithPath: retained!))) == image,
    "Cover survives Spotify cache eviction and works offline")
  try store.putItem([
    "uri": "spotify:track:" + String(repeating: "m", count: 22), "kind": "track",
    "name": "Missing art", "image": "https://i.scdn.co/image/missing",
  ])
  _ = try cache.preserveArtwork(downloadMissing: true)
  check(
    OfflineURLProtocol.requests == requests + 1,
    "Background artwork filling stops immediately when offline")
  let unusedURL = "https://i.scdn.co/image/unused"
  let unused = paths.cache.appendingPathComponent(
    "artwork/" + sha256(Data(unusedURL.utf8)) + ".img")
  try store.putItem([
    "uri": "spotify:track:" + String(repeating: "m", count: 22), "kind": "track",
    "name": "Old search result", "image": unusedURL,
  ])
  let recent = paths.cache.appendingPathComponent(
    "artwork/" + String(repeating: "b", count: 64) + ".img")
  let desktopSentinel = paths.desktop.appendingPathComponent("untouched.img")
  try Data(repeating: 1, count: 1024).write(to: unused)
  try Data(repeating: 1, count: 1024).write(to: recent)
  try (image + bodyFooter).write(to: desktopSentinel)
  try store.execute(
    "INSERT INTO desktop VALUES(?,?,?,?,?)", [desktopSentinel.path, 0, unusedURL, 0, image.count])
  let old = Date().addingTimeInterval(-3 * 86400)
  try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: unused.path)
  try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: retained!)
  let underLimit = try cache.prune(maxBytes: 1_000_000_000)
  check(
    underLimit == 0 && FileManager.default.fileExists(atPath: unused.path),
    "No cleanup below the one-gigabyte threshold")
  let removed = try cache.prune(maxBytes: 1)
  check(
    removed == 1 && !FileManager.default.fileExists(atPath: unused.path),
    "Oversized workflow cache removes old unreferenced artwork")
  check(
    FileManager.default.fileExists(atPath: retained!)
      && FileManager.default.fileExists(atPath: recent.path),
    "Cleanup preserves saved-library and recently used artwork")
  check(
    FileManager.default.fileExists(atPath: desktopSentinel.path),
    "Cleanup never touches Spotify's desktop cache")
  _ = try cache.preserveArtwork()
  check(
    !FileManager.default.fileExists(atPath: unused.path),
    "Background warming does not recreate evicted unused art")
  let requestedAgain = try cache.image(unusedURL, download: false)
  check(requestedAgain != nil, "Explicitly viewing evicted artwork can reuse Spotify's copy again")
  print(
    "Offline checks passed: native metadata, playlist contents, expired caches, preserved artwork, network fallback, and bounded cleanup."
  )
}

private func testArtworkRequests() throws {
  let root = tempDirectory("spotify-artwork-requests-")
  defer {
    try? FileManager.default.removeItem(at: root)
    TestURLProtocol.response = nil
  }
  let paths = testPaths(root: root, environment: [:])
  try paths.prepare()
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [TestURLProtocol.self]
  let cache = DesktopCache(paths, store, session: URLSession(configuration: config))
  defer { cache.session.invalidateAndCancel() }
  let url = "https://i.scdn.co/image/" + String(repeating: "a", count: 40)
  let image = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  )!
  let lock = NSLock()
  let started = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  var requests = 0
  var results: [String] = []
  TestURLProtocol.response = { request in
    check(request.url?.absoluteString == url, "Artwork tests never contact another endpoint")
    lock.lock()
    requests += 1
    let first = requests == 1
    lock.unlock()
    if first {
      started.signal()
      _ = release.wait(timeout: .now() + 3)
    }
    return (200, image)
  }
  let finished = DispatchGroup()
  func fetch() {
    finished.enter()
    DispatchQueue.global().async {
      let path = (try? cache.image(url, download: true)) ?? ""
      lock.lock()
      results.append(path)
      lock.unlock()
      finished.leave()
    }
  }
  fetch()
  check(started.wait(timeout: .now() + 2) == .success, "The first cover request starts")
  for _ in 0..<7 { fetch() }
  let localDone = DispatchSemaphore(value: 0)
  var localPath: String?
  DispatchQueue.global().async {
    localPath = try? cache.image(url, download: false)
    localDone.signal()
  }
  check(
    localDone.wait(timeout: .now() + 1) == .success && localPath == nil,
    "Local cover lookup never waits for a pending download")
  release.signal()
  check(finished.wait(timeout: .now() + 3) == .success, "All coalesced cover requests complete")
  check(
    requests == 1 && results.count == 8 && Set(results).count == 1 && !results[0].isEmpty,
    "Concurrent cover requests share one HTTP request and cached file")
  check(
    try cache.image(url, download: false) == results[0],
    "The shared cover is available offline after completion")
  let databaseHeld = DispatchSemaphore(value: 0)
  let releaseDatabase = DispatchSemaphore(value: 0)
  let databaseDone = DispatchSemaphore(value: 0)
  DispatchQueue.global().async {
    try? store.transaction {
      databaseHeld.signal()
      _ = releaseDatabase.wait(timeout: .now() + 3)
    }
    databaseDone.signal()
  }
  check(
    databaseHeld.wait(timeout: .now() + 1) == .success,
    "A library transaction holds the metadata database")
  let cachedDone = DispatchSemaphore(value: 0)
  var cachedPath: String?
  DispatchQueue.global().async {
    cachedPath = try? cache.image(url, download: false)
    cachedDone.signal()
  }
  let hitWasImmediate = cachedDone.wait(timeout: .now() + 1) == .success && cachedPath == results[0]
  releaseDatabase.signal()
  check(databaseDone.wait(timeout: .now() + 1) == .success, "The library transaction finishes")
  check(hitWasImmediate, "Cached artwork never waits for library database writes")
  print(
    "Artwork request checks passed: coalesced downloads, nonblocking local lookups, and database-free cache hits."
  )
}

private func testThemes() {
  let root = tempDirectory("spotify-theme-tests-")
  defer { try? FileManager.default.removeItem(at: root) }
  let preferences = root.appendingPathComponent("preferences with \"quotes\".alfredpreferences")
  let file = preferences.appendingPathComponent("themes/theme.custom.fixture/theme.json")
  try! FileManager.default.createDirectory(
    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
  let doc: JSONObject = [
    "alfredtheme": [
      "window": ["color": "#182434CC", "borderColor": "#AABBCCFF", "roundness": 10],
      "result": [
        "text": ["color": "#EDF2F9FF", "colorSelected": "#102030FF", "font": "Avenir"],
        "backgroundSelected": "#F3D257FF",
      ], "search": ["text": ["color": "#F7F8F9FF"]],
    ]
  ]
  try! jsonData(doc).write(to: file)
  let source = ThemeSource()
  let context = [
    "id": "theme.custom.fixture", "preferences": preferences.path,
    "background": "rgba(255,255,255,1)",
  ]
  let (firstKey, theme) = source.load(context: context, environment: [:], home: root, dark: false)
  check(
    abs(theme.background.alphaComponent - 0.8) < 0.001 && theme.cornerRadius == 10,
    "Alfred theme opacity and radius")
  check(
    theme.resultFont == "Avenir" && theme.searchText == PlayerTheme.color("#F7F8F9FF"),
    "Alfred theme fonts and cursor colour")
  check(
    source.load(context: context, environment: [:], home: root, dark: false).0 == firstKey,
    "Unchanged theme reuses parsed palette")
  try! jsonData(["alfredtheme": ["window": ["color": "#FFFFFFFF"]]]).write(to: file)
  try! FileManager.default.setAttributes(
    [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)
  let (secondKey, changed) = source.load(
    context: context, environment: [:], home: root, dark: false)
  check(
    firstKey != secondKey && changed.background == PlayerTheme.color("#FFFFFFFF"),
    "Changed theme reloads in the resident player")
  let settings = root.appendingPathComponent("Library/Application Support/Alfred/prefs.json")
  let appearance = preferences.appendingPathComponent(
    "preferences/local/fixture/appearance/prefs.plist")
  for url in [settings, appearance] {
    try! FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  }
  try! jsonData(["current": preferences.path, "localhash": "fixture"]).write(to: settings)
  try! PropertyListSerialization.data(
    fromPropertyList: ["lightthemeuid": "theme.custom.fixture"], format: .binary, options: 0
  ).write(to: appearance)
  check(
    source.load(context: [:], environment: [:], home: root, dark: false).1.background
      == PlayerTheme.color("#FFFFFFFF"), "Theme selection resolves from Alfred preferences")
  let other = preferences.appendingPathComponent("themes/theme.next.fixture/theme.json")
  try! FileManager.default.createDirectory(
    at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
  try! jsonData(["alfredtheme": ["window": ["color": "#102030FF"]]]).write(to: other)
  try! PropertyListSerialization.data(
    fromPropertyList: ["lightthemeuid": "theme.next.fixture"], format: .binary, options: 0
  ).write(to: appearance)
  try! FileManager.default.setAttributes(
    [.modificationDate: Date().addingTimeInterval(3)], ofItemAtPath: appearance.path)
  check(
    source.load(context: [:], environment: [:], home: root, dark: false).1.background
      == PlayerTheme.color("#102030FF"),
    "Cached appearance settings reload when the selected theme changes")
  let alternate = root.appendingPathComponent("alternate.alfredpreferences")
  let alternateTheme = alternate.appendingPathComponent("themes/theme.next.fixture/theme.json")
  let alternateAppearance = alternate.appendingPathComponent(
    "preferences/local/fixture/appearance/prefs.plist")
  for url in [alternateTheme, alternateAppearance] {
    try! FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  }
  try! jsonData(["alfredtheme": ["window": ["color": "#405060FF"]]]).write(to: alternateTheme)
  try! PropertyListSerialization.data(
    fromPropertyList: ["lightthemeuid": "theme.next.fixture"], format: .binary, options: 0
  ).write(to: alternateAppearance)
  try! jsonData(["current": alternate.path, "localhash": "fixture"]).write(to: settings)
  try! FileManager.default.setAttributes(
    [.modificationDate: Date().addingTimeInterval(4)], ofItemAtPath: settings.path)
  check(
    source.load(context: [:], environment: [:], home: root, dark: false).1.background
      == PlayerTheme.color("#405060FF"), "Cached settings follow a moved Alfred preferences folder")
  let builtin = PlayerTheme(context: [
    "background": "rgba(12,20,30,0.8)", "selection": "rgba(250,240,230,1)",
  ])
  check(
    builtin.text == .white && builtin.selectedText == .black
      && abs(builtin.background.alphaComponent - 0.8) < 0.001,
    "Built-in theme fallback remains legible")
  check(
    PlayerTheme.color("invalid") == nil && PlayerTheme.color("#xyz") == nil
      && PlayerTheme.color("rgba(1,2,3)") == nil, "Invalid theme colours fall back safely")
  check(
    PlayerTheme().font("missing-font", size: 16).pointSize == 16,
    "Unavailable theme font falls back to system font")
}

private func runPlaybackBarrierRegressionTests() {
  let commands = SpotifyCommands()
  let lock = NSLock()
  var events: [String] = []
  func append(_ event: String) {
    lock.lock()
    events.append(event)
    lock.unlock()
  }
  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
  let owner = RequestCancellation()
  var idleCompleted = false
  commands.afterPlayback(owner) { idleCompleted = true }
  check(idleCompleted, "Playback barrier regression test keeps the idle dispatch immediate")
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  commands.enqueuePlayback {
    append("local began")
    entered.signal()
    release.wait()
    append("local finished")
  }
  check(
    entered.wait(timeout: .now() + 3) == .success,
    "Playback barrier regression test enters the simulated local mutation")
  defer { release.signal() }
  let superseded = RequestCancellation()
  commands.afterPlayback(superseded) { append("superseded Web mutation") }
  superseded.cancel()
  commands.afterPlayback(owner) { append("first Web mutation") }
  commands.afterPlayback(owner) { append("second Web mutation") }
  check(
    snapshot() == ["local began"],
    "Playback barrier regression test still waits after the previous owner is cancelled")
  release.signal()
  let deadline = Date().addingTimeInterval(3)
  while snapshot().count < 4, Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
  }
  check(
    snapshot() == ["local began", "local finished", "first Web mutation", "second Web mutation"],
    "Playback barrier regression test preserves mutation order and discards superseded owners")
  var cancelledCompleted = false
  commands.afterPlayback(superseded) { cancelledCompleted = true }
  check(
    !cancelledCompleted,
    "Playback barrier regression test also rejects a cancelled owner on the idle path")
  let pendingEntered = DispatchSemaphore(value: 0)
  let pendingRelease = DispatchSemaphore(value: 0)
  let physical = commands.enqueuePlayback {
    pendingEntered.signal()
    pendingRelease.wait()
  }
  check(
    pendingEntered.wait(timeout: .now() + 3) == .success,
    "Playback barrier regression test enters a second simulated local mutation")
  commands.afterPlayback(owner) { append("older deferred Web mutation") }
  pendingRelease.signal()
  check(
    physical.wait(timeout: .now() + 3) == .success,
    "Playback barrier regression test finishes local work while main delivery is blocked")
  commands.afterPlayback(owner) { append("newer Web mutation") }
  check(
    snapshot().count == 4,
    "Playback barrier regression test prevents an idle-path overtake of a queued delivery")
  let deliveryDeadline = Date().addingTimeInterval(3)
  while snapshot().count < 6, Date() < deliveryDeadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.005))
  }
  check(
    Array(snapshot().suffix(2)) == ["older deferred Web mutation", "newer Web mutation"],
    "Playback barrier regression test retains order after physical local work completes")
  print(
    "Playback mutation barrier regression tests passed: local completion, ordered Web dispatch, owner cancellation, and idle fast path."
  )
}

func runModelTests() {
  runPlaybackBarrierRegressionTests()
  do {
    try runQueueRegressionTests()
    try runQueueBackendRegressionTests()
  } catch {
    check(false, "Queue regression test: \(error)")
  }
  do { try testVersionLabels() } catch { check(false, "Version label regression test: \(error)") }
  do {
    try testCredentialStorage()
    try testClientIDSettings()
    try testSignInFailures()
    try testWorkflowKeyword()
  } catch { check(false, "Shared keyword: " + error.localizedDescription) }
  do { try testPlaintextPaths() } catch {
    check(false, "Plaintext paths: " + error.localizedDescription)
  }
  do { try testSavedAlbums() } catch { check(false, "Saved albums: " + error.localizedDescription) }
  do { try testFollowedArtists() } catch {
    check(false, "Followed artists: " + error.localizedDescription)
  }
  do { try testReauthLibraryRetention() } catch {
    check(false, "Reauth library retention: " + error.localizedDescription)
  }
  do { try testOfflineDownloads() } catch {
    check(false, "Downloaded music: " + error.localizedDescription)
  }
  testAlbumTrackCounts()
  do { try testPlaybackContexts() } catch {
    check(false, "Playback context tests: " + error.localizedDescription)
  }
  do { try testWebPlayback() } catch {
    check(false, "Web playback tests: " + error.localizedDescription)
  }
  do { try testWebTransport() } catch {
    check(false, "Active-device transport regression test: " + error.localizedDescription)
  }
  do { try testInitialLibrarySync() } catch {
    check(false, "Initial library sync regression test: " + error.localizedDescription)
  }
  testPlaybackTarget()
  testPlaybackIntent()
  do { try testExplicitTransportRecovery() } catch {
    check(false, "Explicit transport regression test: " + error.localizedDescription)
  }
  do { try testPlaybackPolling() } catch {
    check(false, "Playback polling regression test: " + error.localizedDescription)
  }

  do { try testArtworkRequests() } catch {
    check(false, "Artwork requests: " + error.localizedDescription)
  }
  do { try testOfflineCache() } catch {
    fputs("FAILED: offline cache: \(error)\n", stderr)
    exit(1)
  }
  do { try runLibraryPerformanceRegressionTests() } catch {
    check(false, "Library performance regression test: " + error.localizedDescription)
  }
  testThemes()
  let root = tempDirectory("spotify-model-tests-")
  defer { try? FileManager.default.removeItem(at: root) }
  do {
    let paths = testPaths(
      root: root, clientID: String(repeating: "a", count: 32),
      environment: [
        "alfred_workflow_data": root.appendingPathComponent("data").path,
        "alfred_workflow_cache": root.appendingPathComponent("cache").path,
        "SPOTIFY_DESKTOP_CACHE": root.appendingPathComponent("desktop").path,
      ])
    try paths.prepare()
    let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TestURLProtocol.self]
    let api = SpotifyAPI(paths, session: URLSession(configuration: config))
    let library = MusicLibrary(store, api)
    let track: JSONObject = [
      "uri": "spotify:track:" + String(repeating: "t", count: 22),
      "id": String(repeating: "t", count: 22), "name": "Example", "kind": "track", "image": "",
    ]
    try store.putItem(track)
    check(
      store.item(text(track["uri"]))?["name"] as? String == "Example", "SQLite metadata round trip")
    try store.save(text(track["uri"]), liked: true)
    check(store.isSaved(text(track["uri"])), "Liked membership persists")
    try store.put("test:expired", ["value": 2], ttl: -1)
    check(
      store.get("test:expired") == nil && store.get("test:expired", stale: true) != nil,
      "Cache expiry and stale read")
    let ids = ["z", "a", "m"].map { "spotify:playlist:" + String(repeating: $0, count: 22) }
    for (i, id) in ids.enumerated() {
      try store.putItem(["uri": id, "kind": "playlist", "name": ["Zebra", "Alpha", "Middle"][i]])
      try store.save(id, liked: true)
    }
    try store.put("library:playlist-order", ids.reversed().map { $0 })
    check(
      library.orderedPlaylists().map { text($0["uri"]) } == ids.reversed().map { $0 },
      "API playlist order survives")
    try store.put("desktop:playlist-order", ids)
    check(
      library.orderedPlaylists().map { text($0["uri"]) } == ids,
      "Desktop custom order overrides alphabetic and API order")
    let contents = ids.reduce(Data([8, 0, 16, 0])) { $0 + proto(3, proto(1, Data($1.utf8))) }
    check(PlaylistOrder.decode(proto(5, contents)) == ids, "Cached playlist-root protobuf order")
    let rootValue = proto(5, contents)
    let tableFolder = root.appendingPathComponent("table")
    try FileManager.default.createDirectory(at: tableFolder, withIntermediateDirectories: true)
    let key = Data("!pl#slc#2spotify:user:fixture:rootlist#".utf8) + littleData(7 << 8 | 1, 8)
    let dataBlock = testBlock(key, rootValue)
    let indexBlock = testBlock(key, encodeVarint(0) + encodeVarint(UInt64(dataBlock.count)))
    let indexOffset = dataBlock.count + 5
    var footer =
      encodeVarint(0) + encodeVarint(0) + encodeVarint(UInt64(indexOffset))
      + encodeVarint(UInt64(indexBlock.count))
    footer += Data(repeating: 0, count: 40 - footer.count)
    footer += littleData(0xdb47_7524_8b80_fb57, 8)
    try
      (dataBlock + Data(repeating: 0, count: 5) + indexBlock + Data(repeating: 0, count: 5) + footer)
      .write(to: tableFolder.appendingPathComponent("000001.ldb"))
    check(PlaylistOrder.read(tableFolder) == ids, "Read custom order from immutable LevelDB table")
    for compressed in [
      "H4sIAAAAAAAA/0tOTM5ITVHITS1JTEksSQQA6hltWQ8AAAA=", "KLUv/SAPeQAAY2FjaGVkIG1ldGFkYXRh",
    ] {
      let decoded = try DesktopCache.unpack(Data(base64Encoded: compressed)!)
      check(decoded == Data("cached metadata".utf8), "Native gzip/Zstandard cache decoding")
    }
    let cacheURL =
      "https://spclient.wg.spotify.com/metadata/4/track/" + String(repeating: "0", count: 32)
    let body = try jsonData(["gid": String(repeating: "0", count: 32), "name": "Cached song"])
    let checksum = body.withUnsafeBytes { spotify_crc32($0.baseAddress, $0.count) }
    let keyData = Data(cacheURL.utf8)
    let header =
      littleData(0xfcfb_6d1b_a772_5c30, 8) + littleData(5, 4) + littleData(UInt64(keyData.count), 4)
      + Data(repeating: 0, count: 8)
    let bodyFooter =
      littleData(0xf4fa_6f45_970d_41d8, 8) + littleData(1, 4) + littleData(UInt64(checksum), 4)
      + Data(repeating: 0, count: 8)
    let finalFooter = littleData(0xf4fa_6f45_970d_41d8, 8) + Data(repeating: 0, count: 16)
    try FileManager.default.createDirectory(at: paths.desktop, withIntermediateDirectories: true)
    try (header + keyData + body + bodyFooter + finalFooter).write(
      to: paths.desktop.appendingPathComponent("test_0"))
    let cache = DesktopCache(paths, store)
    let imported = try cache.index()
    check(
      imported == 1 && store.item("spotify:track:" + String(repeating: "0", count: 22)) != nil,
      "Read existing Chromium metadata without HTTP requests")
    let literal = Data("cached block".utf8)
    let decodedBlock = try PlaylistOrder.snappy(
      encodeVarint(UInt64(literal.count)) + Data([UInt8((literal.count - 1) << 2)]) + literal)
    check(decodedBlock == literal, "Snappy literal decoding")
    check(
      spotifyID(Data(repeating: 0, count: 16)) == String(repeating: "0", count: 22),
      "Spotify base62 zero")
    check(validTrack(text(track["uri"])) && !validTrack(ids[0]), "Only track URIs can be liked")
    var tokenRequests = 0
    var libraryMethods: [String] = []
    var staleLibrary = false
    var catalogRequests = 0
    var repeatRequests: [String] = []
    var repeatResponse = (204, Data())
    var playbackResponse = (200, try! jsonData(["repeat_state": "track"]))
    TestURLProtocol.response = { request in
      if request.url!.path == "/api/token" {
        tokenRequests += 1
        check(
          request.value(forHTTPHeaderField: "Authorization") == nil, "PKCE sends no client secret")
      }
      if request.url!.path == "/api/token" {
        return (
          200,
          try! jsonData([
            "access_token": "test", "refresh_token": "refresh", "expires_in": 3600,
            "scope": SpotifyAPI.scopes,
          ])
        )
      }
      if request.url!.path == "/v1/me/player/repeat" {
        check(request.httpMethod == "PUT", "Repeat uses the playback API setter")
        let state = request.url!.queryItemsForTesting.first { $0.name == "state" }?.value ?? ""
        repeatRequests.append(state)
        return repeatResponse
      }
      if request.url!.path == "/v1/me/player" { return playbackResponse }
      if request.url!.path == "/v1/search" {
        catalogRequests += 1
        return (200, try! jsonData(["tracks": ["items": [track]]]))
      }
      if request.url!.path == "/v1/me/library/contains" { return (200, try! jsonData([false])) }
      if request.url!.path == "/v1/me/library" {
        libraryMethods.append(request.httpMethod ?? "")
        return (200, Data())
      }
      if request.url!.path == "/v1/me" { return (200, try! jsonData(["id": "api-fixture"])) }
      if request.url!.path == "/v1/me/following" {
        return (200, try! jsonData(["artists": ["items": []]]))
      }
      if staleLibrary && request.url!.path == "/v1/me/tracks" {
        return (200, try! jsonData(["items": [["track": track]]]))
      }
      return (200, try! jsonData(["items": []]))
    }
    _ = try api.exchange(["grant_type": "authorization_code", "code_verifier": "test-verifier"])
    check(api.connected && api.canSave, "PKCE grants and persists scopes")
    for mode in RepeatMode.allCases { try api.setRepeat(mode) }
    check(repeatRequests == ["off", "context", "track"], "Repeat supports off, all, and one")
    let currentRepeat = try api.repeatState()
    check(currentRepeat == .track, "Read repeat mode from playback state")
    for response in [
      (200, Data("fixture-command-id".utf8)), (200, Data(" \n".utf8)), (204, Data()),
    ] {
      repeatResponse = response
      for mode in RepeatMode.allCases { try api.setRepeat(mode) }
    }
    repeatResponse = (403, Data("Forbidden".utf8))
    do {
      try api.setRepeat(.context)
      check(false, "Repeat must preserve real HTTP failures")
    } catch {
      check((error as? SpotifyFailure)?.status == 403, "Repeat reports unsuccessful HTTP status")
    }
    playbackResponse = (200, Data("malformed-playback-state".utf8))
    do {
      _ = try api.repeatState()
      check(false, "Playback state still requires valid JSON")
    } catch { check(!(error is SpotifyFailure), "Read responses retain JSON validation") }
    repeatResponse = (204, Data())
    playbackResponse = (200, try! jsonData(["repeat_state": "track"]))
    let liked = try library.liked(text(track["uri"]))
    check(liked == false, "Public membership read updates cache")
    try library.setLiked(text(track["uri"]), liked: true)
    check(store.isSaved(text(track["uri"])), "Public save updates local membership")
    try library.setLiked(text(track["uri"]), liked: true)
    check(
      store.isSaved(text(track["uri"])) && libraryMethods.suffix(2) == ["PUT", "PUT"],
      "Like command is idempotent")
    try library.setLiked(text(track["uri"]), liked: false)
    try library.setLiked(text(track["uri"]), liked: false)
    check(
      !store.isSaved(text(track["uri"])) && libraryMethods.suffix(2) == ["DELETE", "DELETE"],
      "Unlike command is idempotent")
    staleLibrary = true
    try library.sync()
    check(
      !store.isSaved(text(track["uri"])),
      "An in-flight library refresh cannot re-like a removed song")
    staleLibrary = false
    var token = try api.paths.authorization.load()
    token["scope"] = "user-library-read"
    try api.paths.authorization.save(token)
    do {
      try library.setLiked(text(track["uri"]), liked: true)
      check(false, "Save must require granted scope")
    } catch {
      check(
        error.localizedDescription.contains(paths.command("reauth")),
        "Save permission error is actionable")
    }
    do {
      try api.setRepeat(.context)
      check(false, "Repeat must require playback scope")
    } catch {
      check(
        error.localizedDescription.contains(paths.command("reauth")),
        "Repeat explains the missing playback permission")
    }
    token["expires_at"] = 0
    try api.paths.authorization.save(token)
    _ = try api.accessToken()
    check(tokenRequests == 2, "Refresh PKCE without client authentication")
    let emptySearch = try library.browse(["kind": "catalog", "query": ""], network: true)
    check(
      emptySearch.isEmpty && catalogRequests == 0, "Empty catalogue mode sends no search request")
    let results = try library.browse(["kind": "catalog", "query": "full catalogue"], network: true)
    _ = try library.browse(["kind": "catalog", "query": "full catalogue"], network: true)
    check(
      results.count == 1 && catalogRequests == 1,
      "Live catalogue queries reuse cached Spotify results")
    let cancelled = RequestCancellation()
    cancelled.cancel()
    do {
      _ = try api.request("/search", cancellation: cancelled)
      check(false, "Cancelled search must not run")
    } catch {
      check(
        (error as? URLError)?.code == .cancelled && catalogRequests == 1,
        "Cancelled search never reaches Spotify")
    }
    let waitingConfig = URLSessionConfiguration.ephemeral
    waitingConfig.protocolClasses = [WaitingURLProtocol.self]
    let waitingAPI = SpotifyAPI(paths, session: URLSession(configuration: waitingConfig))
    let inFlight = RequestCancellation()
    let finishedSearch = DispatchSemaphore(value: 0)
    var cancelledInFlight = false
    DispatchQueue.global().async {
      do { _ = try waitingAPI.request("/search", cancellation: inFlight) } catch {
        cancelledInFlight = (error as? URLError)?.code == .cancelled
      }
      finishedSearch.signal()
    }
    check(WaitingURLProtocol.started.wait(timeout: .now() + 2) == .success, "Live search starts")
    inFlight.cancel()
    check(
      finishedSearch.wait(timeout: .now() + 2) == .success && cancelledInFlight,
      "Superseded in-flight search cancels immediately")
    let endedSession = DispatchSemaphore(value: 0)
    var sessionCancelled = false
    DispatchQueue.global().async {
      do { _ = try waitingAPI.request("/search") } catch {
        sessionCancelled = (error as? URLError)?.code == .cancelled
      }
      endedSession.signal()
    }
    check(
      WaitingURLProtocol.started.wait(timeout: .now() + 2) == .success,
      "Session cancellation regression test starts a request without an explicit cancellation token"
    )
    waitingAPI.session.invalidateAndCancel()
    check(
      endedSession.wait(timeout: .now() + 2) == .success && sessionCancelled,
      "Session cancellation regression test never misreports cancellation as a Spotify connection error"
    )
    try NativeBackend.clearConnection(paths)
    check(!api.connected && store.items().count == 5, "Reauth preserves music metadata")
    check(paths.clientID().isEmpty, "Reauth clears Client ID")
    try paths.saveClientID(String(repeating: "a", count: 32))
    check(
      homeItems.map { text($0["name"]) } == [
        "Playlists", "Albums", "Artists", "Liked Songs", "Search", "Queue",
      ],
      "Menu priority")
    let finished = DispatchSemaphore(value: 0)
    var connected = false
    var browserURLs: [URL] = []
    let flow = AuthorizationFlow(
      paths, api, callbackPort: 0,
      browser: {
        browserURLs.append($0)
        return true
      })
    try flow.start { result in
      if case .success = result { connected = true }
      finished.signal()
    }
    let browserDeadline = Date().addingTimeInterval(2)
    while browserURLs.isEmpty && Date() < browserDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    check(flow.reopenBrowser(), "A pending sign-in can reopen its browser")
    RunLoop.current.run(until: Date().addingTimeInterval(0.03))
    check(
      browserURLs.count == 2 && browserURLs[0] == browserURLs[1],
      "Reopening sign-in reuses the pending state and callback")
    let query = Dictionary(
      flow.authorizationURL!.queryItemsForTesting.map { ($0.name, $0.value ?? "") },
      uniquingKeysWith: { first, _ in first })
    check(
      AuthorizationFlow.defaultCallbackPort == 8765,
      "Production sign-in uses the registered fixed port")
    let redirect = URL(string: query["redirect_uri"]!)!
    check(
      redirect.host == "127.0.0.1" && (redirect.port ?? 0) > 0
        && redirect.path == "/spotify_callback",
      "Test sign-in uses its own loopback port and the production callback path")
    func callback(_ state: String) -> Int {
      var url = URLComponents(string: query["redirect_uri"]!)!
      url.queryItems = [
        URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "test-code"),
      ]
      let ready = DispatchSemaphore(value: 0)
      var status = 0
      URLSession.shared.dataTask(with: url.url!) { _, response, _ in
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        ready.signal()
      }.resume()
      _ = ready.wait(timeout: .now() + 3)
      return status
    }
    check(callback("invalid") == 400 && !api.connected, "Reject invalid callback state")
    check(callback(query["state"]!) == 200, "Accept valid loopback callback")
    check(
      finished.wait(timeout: .now() + 2) == .success && connected && api.connected,
      "PKCE callback returns a usable native connection")
    check(!flow.reopenBrowser(), "Completed sign-in does not reopen an expired browser URL")
    if ProcessInfo.processInfo.environment["SPOTIFY_TEST_REAL_CACHE"] == "1",
      let directory = PlaylistOrder.desktopDirectory()
    {
      let start = Date()
      let order = PlaylistOrder.read(directory)
      check(!(order ?? []).isEmpty, "Read real desktop custom order")
      print(
        "Desktop order verified: \(order!.count) playlists in \(Int(Date().timeIntervalSince(start) * 1000)) ms (read-only)."
      )
    }
    print(
      "Native model checks passed: themes, storage, cache, playlist ordering, PKCE, likes, repeat, and reset."
    )
  } catch {
    fputs("FAILED: \(error)\n", stderr)
    exit(1)
  }
}

extension URL {
  fileprivate var queryItemsForTesting: [URLQueryItem] {
    URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems ?? []
  }
}

private func spawnClient(_ url: URL, _ arguments: [String] = [], environment: [String: String]) {
  var argv = ([url.path] + arguments).map { strdup($0) } + [nil]
  var env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
  defer {
    for p in argv { free(p) }
    for p in env { free(p) }
  }
  var pid: pid_t = 0
  let result = argv.withUnsafeMutableBufferPointer { args in
    env.withUnsafeMutableBufferPointer { vars in
      posix_spawn(&pid, url.path, nil, nil, args.baseAddress!, vars.baseAddress!)
    }
  }
  check(result == 0, "Spawn native launcher")
  var status: Int32 = 0
  while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
  check(status == 0, "Native launcher succeeded")
}

@discardableResult private func run(
  _ url: URL, _ args: [String] = [], environment: [String: String]
) -> String {
  let process = Process()
  let output = Pipe()
  process.executableURL = url
  process.arguments = args
  process.environment = environment
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  do { try process.run() } catch {
    check(false, "Could not launch test child")
    return ""
  }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  check(process.terminationStatus == 0, "Test child exited with \(process.terminationStatus)")
  return String(decoding: data, as: UTF8.self)
}
private func testVersionLabels() throws {
  for (input, exported) in [
    ("0.5.5", "0.5.5"), ("v0.5.5", "0.5.5"), ("0.5.5-dev", "0.5.5-dev"),
    ("v0.5.5-dev", "0.5.5-dev"), ("v0.5.5-dev.1+build.2", "0.5.5-dev.1+build.2"),
    ("0.5.5+build", "0.5.5+build"),
  ] {
    check(
      alfredVersion(input) == exported,
      "Alfred versions retain release labels without a duplicate v")
    check(
      try appBundleVersion(input) == "0.5.5",
      "Version labels produce numeric native bundle versions")
  }
  for input in ["", "vnext", "v0.5-dev"] {
    do {
      _ = try appBundleVersion(input)
      check(false, "Invalid native bundle versions must be rejected")
    } catch {}
  }
}
private func testWorkflowMetadataGeneration(_ exported: JSONObject) throws {
  try testVersionLabels()
  let root = tempDirectory("spotify-metadata-")

  defer { try? FileManager.default.removeItem(at: root) }
  let stage = root.appendingPathComponent("stage")
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("workflow"), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: stage.appendingPathComponent("Spotify Mini Player.app/Contents"),
    withIntermediateDirectories: true)
  var template = exported
  template.removeValue(forKey: "readme")
  template.removeValue(forKey: "version")
  let source = root.appendingPathComponent("workflow/info.plist")
  let original = try PropertyListSerialization.data(
    fromPropertyList: template, format: .xml, options: 0)
  try original.write(to: source)
  try "Unstaged README must not replace the export snapshot.".write(
    to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
  let ciImage =
    "![ci](https://github.com/nhooyr/Spotify.alfredworkflow/actions/workflows/ci.yml/badge.svg?branch=main)"
  let ciLink = "https://github.com/nhooyr/Spotify.alfredworkflow/actions/workflows/ci.yml"
  let releaseImage =
    "![GitHub Release](https://img.shields.io/github/v/release/nhooyr/Spotify.alfredworkflow?include_prereleases&color=64C864)"
  let releaseLink = "https://github.com/nhooyr/Spotify.alfredworkflow/releases"
  let body =
    "\n\n![Player](./docs/ss.png)\n\n![Remote cover](https://example.com/cover.png)\n\n[CI details](\(ciLink))\n"
  let heading = "# Spotify.alfredworkflow"
  for (readme, help) in [
    ("Initial staged README.", "Initial staged README."),
    (
      "Updated staged README with new documentation.",
      "Updated staged README with new documentation."
    ),
    ("\(heading) [\(ciImage)](\(ciLink)) \(releaseImage)" + body, heading + body),
    ("\(heading) \(ciImage) [\(releaseImage)](\(releaseLink))" + body, heading + body),
  ] {
    try readme.write(
      to: stage.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try writeWorkflowMetadata(root, stage: stage)
    let generated =
      try PropertyListSerialization.propertyList(
        from: Data(contentsOf: stage.appendingPathComponent("info.plist")), format: nil)
      as! JSONObject
    let after = try Data(contentsOf: source)
    let app =
      try PropertyListSerialization.propertyList(
        from: Data(
          contentsOf: stage.appendingPathComponent("Spotify Mini Player.app/Contents/Info.plist")),
        format: nil) as! JSONObject
    let nativeVersion = try appBundleVersion(version)
    check(
      text(app["CFBundleVersion"]) == nativeVersion
        && text(app["CFBundleShortVersionString"]) == nativeVersion,
      "Native bundle metadata uses the numeric version while workflow metadata preserves the full label"
    )
    check(after == original, "Metadata generation never rewrites its input template")
    check(
      text(generated["readme"]) == help,
      "Generated help omits badges while preserving staged documentation and screenshots")
    check(
      try String(contentsOf: stage.appendingPathComponent("README.md"), encoding: .utf8) == readme,
      "Generating embedded help leaves the packaged README unchanged")
    check(
      text(generated["version"]) == alfredVersion(version),
      "Alfred metadata omits the display prefix already supplied by Alfred")
    check(
      text(generated["bundleid"]) == text(template["bundleid"])
        && text(generated["name"]) == text(template["name"]),
      "Generating documentation retains the workflow definition")
  }
  print(
    "Metadata generation passed: immutable template, staged README snapshots, and generated release version."
  )
}

func runIntegrationTests(screenshot: URL? = nil) {
  let root = tempDirectory("spotify-ui-tests-")
  defer { try? FileManager.default.removeItem(at: root) }
  let executable = currentExecutable()
  let workflow = executable.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
  let info =
    try! PropertyListSerialization.propertyList(
      from: Data(contentsOf: workflow.appendingPathComponent("info.plist")), format: nil)
    as! JSONObject
  do { try testWorkflowMetadataGeneration(info) } catch {
    check(false, "Metadata generation: " + error.localizedDescription)
  }
  let objects = info["objects"] as! [JSONObject]
  let settings = info["userconfigurationconfig"] as? [JSONObject] ?? []
  check(
    settings.map { text($0["variable"]) } == ["keyword"],
    "Only the shared keyword is stored in synced workflow configuration")
  check(dict(info["variables"]).isEmpty, "No credentials are packaged in workflow variables")
  let keywordSetting = settings.first { text($0["variable"]) == "keyword" }
  check(
    text(dict(keywordSetting?["config"])["default"]) == "spot"
      && dict(keywordSetting?["config"])["trim"] as? Bool == true,
    "The shared keyword defaults to spot and trims whitespace")
  let commands = objects.first { text($0["uid"]) == "COMMANDS" }
  let commandConfig = dict(commands?["config"])
  check(
    text(commands?["type"]) == "alfred.workflow.input.scriptfilter"
      && text(commandConfig["keyword"]) == "{var:keyword}"
      && text(commandConfig["script"]) == "exec ./show --commands \"$1\""
      && number(commandConfig["argumenttype"]) == 1
      && commandConfig["alfredfiltersresults"] as? Bool == false,
    "One native command list controls result order and query-dependent completion")
  let keywords = objects.compactMap { dict($0["config"])["keyword"] as? String }
  check(keywords == ["{var:keyword}"], "Every command uses the shared configurable prefix")
  let readme = try! String(
    contentsOf: workflow.appendingPathComponent("README.md"), encoding: .utf8)
  let documented = readme.split(separator: "\n").compactMap { line -> String? in
    let prefix = "| `spot "
    guard line.hasPrefix(prefix) else { return nil }
    return line.dropFirst(prefix.count).split(separator: "`", maxSplits: 1).first.map { String($0) }
  }
  check(documented.count == 9, "The README documents all commands")
  var commandEnvironment = ProcessInfo.processInfo.environment
  let commandSocket = root.appendingPathComponent("command-menu-not-running")
  commandEnvironment["SPOTIFY_NATIVE_SOCKET_DIR"] = commandSocket.path
  func commandRows(_ query: String) -> [JSONObject] {
    let output = run(
      workflow.appendingPathComponent("show"), ["--commands", query],
      environment: commandEnvironment)
    return dict(try? JSONSerialization.jsonObject(with: Data(output.utf8)))["items"]
      as? [JSONObject] ?? []
  }
  let allCommands = commandRows("")
  check(
    allCommands.map { text($0["autocomplete"]) } == documented,
    "Alfred command results follow the README order")
  check(
    allCommands.allSatisfy { $0["uid"] == nil && $0["valid"] as? Bool == false },
    "Bare prefix completes commands instead of launching, without learned result reordering")
  check(
    allCommands.first { text($0["arg"]) == "reauth" }?["title"] as? String
      == "Clear sign-in to reauthorize"
      && allCommands.first { text($0["arg"]) == "quit" }?["title"] as? String
        == "Quit Spotify Mini Player",
    "Native command results retain the requested descriptions")
  let aliases = ["shuf": "shuffle", "unshuf": "noshuffle", "demo": "screenshot"]
  let destinations = [
    "mini": "PLAYER", "like": "ACTION_LIKE", "unlike": "ACTION_UNLIKE",
    "shuffle": "ACTION_SHUFFLE", "noshuffle": "ACTION_NOSHUFFLE", "refresh": "ACTION_REFRESH",
    "reauth": "CLEAR_ACTION", "screenshot": "ACTION_SCREENSHOT", "quit": "ACTION_QUIT",
  ]
  let arguments = documented.map { aliases[$0] ?? $0 }
  check(
    allCommands.map { text($0["arg"]) } == arguments, "Command arguments match the documented names"
  )
  let router = objects.first { text($0["uid"]) == "ROUTE_COMMAND" }
  let conditions = dict(router?["config"])["conditions"] as? [JSONObject] ?? []
  check(
    text(router?["type"]) == "alfred.workflow.utility.conditional"
      && conditions.map { text($0["matchstring"]) } == arguments
      && conditions.map { text($0["outputlabel"]) } == documented,
    "Workflow routes follow the same README order")
  let routes = dict(info["connections"])["ROUTE_COMMAND"] as? [JSONObject] ?? []
  check(routes.count == arguments.count, "Every command has one route")
  let inputLinks = dict(info["connections"])["COMMANDS"] as? [JSONObject] ?? []
  check(
    inputLinks.count == 1 && text(inputLinks[0]["destinationuid"]) == "ROUTE_COMMAND",
    "The ordered list dispatches through the command router")
  for (index, suffix) in documented.enumerated() {
    let argument = arguments[index]
    let rows = commandRows("  " + suffix.uppercased() + "  ")
    check(
      rows.count == 1 && text(rows[0]["arg"]) == argument && rows[0]["valid"] as? Bool == true,
      "Typing a full command selects only its action: " + suffix)
    let condition = conditions[index]
    check(
      text(condition["inputstring"]) == "{query}" && number(condition["matchmode"]) == 0
        && condition["matchcasesensitive"] as? Bool == false,
      "Command routes use exact case-insensitive argument matches")
    let route = routes.first { text($0["sourceoutputuid"]) == text(condition["uid"]) }
    check(
      text(route?["destinationuid"]) == destinations[argument]
        && route?["vitoclose"] as? Bool == (argument != "reauth"),
      "Command reaches its existing action and preserves reauth feedback: " + suffix)
    if argument != "reauth" {
      let action = objects.first { text($0["uid"]) == destinations[argument] }
      check(
        text(dict(action?["config"])["script"])
          == (argument == "mini" ? "exec ./show" : "exec ./show --" + argument),
        "Command retains its execution path: " + suffix)
    }
  }
  check(
    commandRows("lik").map { text($0["arg"]) } == ["like", "unlike"]
      && commandRows("huf").map { text($0["arg"]) } == ["shuffle", "noshuffle"]
      && commandRows("toggle mode").map { text($0["arg"]) } == ["screenshot"]
      && commandRows("not-a-command").isEmpty,
    "Filtering keeps README-relative order and handles exact, partial, and multiword queries")
  check(
    !FileManager.default.fileExists(atPath: commandSocket.path),
    "Listing commands never starts the player or creates its socket")
  for prefix in ["spot", "spotify", "music"] {
    check(
      text(commandConfig["keyword"]).replacingOccurrences(of: "{var:keyword}", with: prefix)
        == prefix,
      "Changing one prefix applies to the whole command list")
  }
  check(
    Set(objects.map { text($0["uid"]) }).count == objects.count,
    "Workflow object identifiers remain unique")
  check(
    !objects.contains { text($0["type"]) == "alfred.workflow.output.notification" },
    "Reauth has no notification output")
  let feedback = objects.first { text($0["uid"]) == "REAUTH_RESULT" }
  check(
    text(feedback?["type"]) == "alfred.workflow.input.scriptfilter",
    "Reauth returns to Alfred results")
  let links = dict(info["connections"])
  check(
    (links["CLEAR_ACTION"] as? [JSONObject])?.first?["destinationuid"] as? String
      == "REAUTH_RESULT", "Clearing sign-in shows the inline result")
  check(
    (links["REAUTH_RESULT"] as? [JSONObject])?.first?["destinationuid"] as? String == "PLAYER",
    "Return on reauth result opens the player")
  let hotkeys = objects.filter { text($0["type"]) == "alfred.workflow.trigger.hotkey" }
  check(
    hotkeys.count == 1 && text(hotkeys[0]["uid"]) == "HOTKEY",
    "Only the launch hotkey is configurable in Alfred")
  let launchConfig = dict(hotkeys[0]["config"])
  check(
    number(launchConfig["hotkey"]) == 49 && number(launchConfig["hotmod"]) == 1_310_720
      && text(launchConfig["hotstring"]) == "Space",
    "Launch hotkey exports Control-Command-Space by default")
  check(
    number(launchConfig["action"]) == 0 && number(launchConfig["argument"]) == 0
      && number(launchConfig["modsmode"]) == 2,
    "Launch hotkey runs directly with no argument and fastest modifier handling")
  check(
    number(launchConfig["relatedAppsMode"]) == 0 && launchConfig["relatedApps"] == nil,
    "Only the launch shortcut is global")
  let canvas = dict(info["uidata"])
  check(
    number(dict(canvas["HOTKEY"])["ypos"]) < number(dict(canvas["COMMANDS"])["ypos"]),
    "Launch hotkey is visible at the top of the canvas")
  let orderedActions = arguments.compactMap { destinations[$0] }
  check(
    objects.map { text($0["uid"]) }.filter { orderedActions.contains($0) } == orderedActions
      && orderedActions.sorted {
        number(dict(canvas[$0])["ypos"]) < number(dict(canvas[$1])["ypos"])
      } == orderedActions,
    "Stored action order and visible workflow layout match the README")
  let launch = objects.first { text($0["uid"]) == "HOTKEY_PLAYER" }

  check(
    text(dict(launch?["config"])["script"]) == "exec ./show --hotkey",
    "The launch hotkey opens the mini player from other apps")
  let success = (reauthFeedback()["items"] as! [JSONObject])[0]
  check(
    text(success["title"]) == "Open Spotify Mini Player" && success["valid"] as? Bool == true,
    "Reauth result clearly offers the player")
  let failure = (reauthFeedback(error: "Fixture error")["items"] as! [JSONObject])[0]
  check(
    text(failure["subtitle"]) == "Fixture error" && failure["valid"] as? Bool == false,
    "Reauth errors stay visible in Alfred")
  var env = ProcessInfo.processInfo.environment
  env["SPOTIFY_NATIVE_SOCKET_DIR"] = root.appendingPathComponent("ipc").path
  env["alfred_workflow_data"] = root.appendingPathComponent("data").path
  env["alfred_workflow_cache"] = root.appendingPathComponent("cache").path
  env["SPOTIFY_DESKTOP_CACHE"] = root.appendingPathComponent("desktop").path
  env["SPOTIFY_DESKTOP_USER_CACHE"] = root.appendingPathComponent("empty").path
  env["alfred_theme"] = "theme.custom.quoted\"\\name\nfixture"
  let ready = dict(
    try! JSONSerialization.jsonObject(
      with: Data(run(executable, ["--reauth-result"], environment: env).utf8)))
  check(
    ((ready["items"] as? [JSONObject])?.first?["title"] as? String) == "Open Spotify Mini Player",
    "Inline reauth CLI emits valid Alfred JSON")
  var failedEnvironment = env
  failedEnvironment["spotify_reauth_error"] = "Fixture error"
  let failed = dict(
    try! JSONSerialization.jsonObject(
      with: Data(run(executable, ["--reauth-result"], environment: failedEnvironment).utf8)))
  check(
    ((failed["items"] as? [JSONObject])?.first?["valid"] as? Bool) == false,
    "Inline reauth errors cannot open a falsely successful result")
  spawnClient(workflow.appendingPathComponent("show"), ["--quit"], environment: env)
  check(
    !FileManager.default.fileExists(atPath: env["SPOTIFY_NATIVE_SOCKET_DIR"]!),
    "Quitting an absent player succeeds without starting or creating it")
  let parent = Process()
  parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
  parent.arguments = ["60"]
  try! parent.run()
  let server = Process()
  server.executableURL = executable
  server.arguments = ["--test-server", "--lifetime-pid", String(parent.processIdentifier)]
  server.environment = env
  server.standardOutput = FileHandle.nullDevice
  server.standardError = FileHandle.nullDevice
  try! server.run()
  defer {
    if parent.isRunning {
      parent.terminate()
      parent.waitUntilExit()
    }
    if server.isRunning {
      server.terminate()
      server.waitUntilExit()
    }
  }
  func request(_ command: String) -> JSONObject {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let path = env["SPOTIFY_NATIVE_SOCKET_DIR"]! + "/player.sock"
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connected != 0 { return [:] }
    let packet = try! jsonData(["command": command, "build": buildIdentifier]) + Data([10])
    _ = packet.withUnsafeBytes { write(fd, $0.baseAddress, packet.count) }
    var bytes = [UInt8](repeating: 0, count: 8192)
    var data = Data()
    while !data.contains(10) {
      let n = read(fd, &bytes, bytes.count)
      if n <= 0 { break }
      data.append(contentsOf: bytes.prefix(n))
    }
    return dict(try? JSONSerialization.jsonObject(with: data))
  }
  let deadline = Date().addingTimeInterval(6)
  var initial: JSONObject = [:]
  while Date() < deadline {
    initial = request("state")
    if initial["pid"] != nil { break }
    usleep(20000)
  }
  check(initial["pid"] != nil, "Native test host started")
  var timings: [Double] = []
  for _ in 0..<50 {
    let start = DispatchTime.now().uptimeNanoseconds
    spawnClient(workflow.appendingPathComponent("show"), environment: env)
    timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
  }
  check(number(request("state")["pid"]) == number(initial["pid"]), "Hotkey keeps the same process")
  check(
    dict(request("state")["theme"])["id"] as? String == env["alfred_theme"],
    "C launcher safely forwards theme context")
  func waitForFocusedWindow(mode: Bool, shows: Double) -> JSONObject {
    let deadline = Date().addingTimeInterval(3)
    var state = request("test-demo-windows")
    func ready() -> Bool {
      ["active", "key", "visible", "editor", "handoff"].allSatisfy { state[$0] as? Bool == true }
        && state["demo"] as? Bool == mode && number(state["shows"]) == shows
    }
    while !ready(), Date() < deadline {
      usleep(5_000)
      state = request("test-demo-windows")
    }
    print("focused window: \(String(decoding: try! jsonData(state), as: UTF8.self))")
    check(ready(), "Player window finishes activation and focus for mode=\(mode), shows=\(shows)")
    return state
  }
  var uiFailures: [String] = []
  func checkUI(_ condition: Bool, _ message: String) {
    if !condition { uiFailures.append(message) }
  }
  for command in [
    "test-ui", "test-text-updates", "test-home-captions", "test-queue-ui", "test-queue-playback",
    "test-menu-scrolling",
    "test-menu-viewport", "test-editing",
    "test-local-bindings",
    "test-navigation",
    "test-navigation-shortcuts", "test-plaintext-paths", "test-input-focus", "test-connection-ui",
    "test-connection-session", "test-client-id-input", "test-controls", "test-direct-play",
    "test-single-line", "test-offline-ui", "test-status-ui", "test-remote-playback",
    "test-playback-header", "test-playback-metadata",
    "test-repeat",
    "test-playback-context", "test-play-artwork", "test-theme", "test-screenshot-mode",
    "test-spaces", "test-search", "test-artwork", "test-missing-artwork", "test-catalog-mode",
    "test-catalog-resume",
  ] {
    if command.hasPrefix("test-menu-") {
      let shows = number(request("state")["shows"])
      _ = request("test-demo-prepare")
      _ = waitForFocusedWindow(mode: false, shows: shows + 1)
    }
    let previousWindow = command == "test-queue-ui" ? request("test-demo-windows") : nil
    let initial = request(command)
    var result = initial
    let deadline = Date().addingTimeInterval(command.hasPrefix("test-menu-") ? 10 : 3)
    while text(result["status"]) == "pending" && Date() < deadline {
      usleep(10000)
      result = initial.merging(request(command + "-result")) { _, latest in latest }
    }
    print("\(command): \(String(decoding: try! jsonData(result), as: UTF8.self))")
    for (key, value) in result where key != "status" {
      if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
        checkUI(value.boolValue, command + ": " + key)
      }
    }
    checkUI(text(result["status"]) == "ok", command + " completed")
    if let previousWindow = previousWindow {
      let restored = request("test-demo-windows")
      checkUI(
        restored["visible"] as? Bool == previousWindow["visible"] as? Bool
          && restored["key"] as? Bool == previousWindow["key"] as? Bool,
        "Queue UI regression test restores window visibility and keyboard focus")
    }

  }
  check(uiFailures.isEmpty, "UI regression test failures:\n" + uiFailures.joined(separator: "\n"))
  let showsBeforePrepare = number(request("state")["shows"])
  _ = request("test-demo-prepare")
  let prepared = waitForFocusedWindow(mode: false, shows: showsBeforePrepare + 1)
  // AppKit creates hidden input helpers lazily; check visible windows and editor reuse.
  let demoWindows = prepared["visibleWindows"] as? [Int]
  let demoEditor = text(prepared["editorID"])
  check(demoWindows?.count == 1, "Demo test starts with only the player visible")
  check(!demoEditor.isEmpty, "Demo test reports its active search editor")
  for index in 0..<6 {
    let showsBefore = number(request("state")["shows"])
    spawnClient(workflow.appendingPathComponent("show"), ["--screenshot"], environment: env)
    let state = waitForFocusedWindow(mode: index % 2 == 0, shows: showsBefore + 1)
    check(state["demo"] as? Bool == (index % 2 == 0), "One demo command changes mode exactly once")
    check(state["visible"] as? Bool == true, "Demo toggles leave the player open in either mode")
    check(state["editor"] as? Bool == true, "Demo toggles retain the active search editor")
    check(text(state["editorID"]) == demoEditor, "Demo toggles reuse the same search editor")
    check(
      state["visibleWindows"] as? [Int] == demoWindows,
      "Demo toggles keep only the original player window visible")
    check(
      number(request("state")["shows"]) == showsBefore + 1, "Each demo toggle shows the player once"
    )
  }
  _ = request("hide")
  print(
    "Repeated demo launcher checks passed: stable input windows, single toggles, and a visible player in either mode."
  )
  let showsBeforeCommands = number(request("state")["shows"])
  for (command, key, expected) in [
    ("like", "liked", true), ("unlike", "liked", false), ("shuffle", "shuffling", true),
    ("noshuffle", "shuffling", false),
  ] {
    spawnClient(workflow.appendingPathComponent("show"), ["--" + command], environment: env)
    spawnClient(workflow.appendingPathComponent("show"), ["--" + command], environment: env)
    check(
      request("state")[key] as? Bool == expected, "Repeated " + command + " command is idempotent")
  }
  check(
    number(request("state")["shows"]) == showsBeforeCommands,
    "State commands do not open the player")
  print("Idempotent like, unlike, shuffle, and noshuffle launcher commands passed.")
  _ = request("hide")
  let beforeTransport = request("state")
  let refreshes = number(request("state")["refresh_requests"])
  spawnClient(workflow.appendingPathComponent("show"), ["--refresh"], environment: env)
  check(
    number(request("state")["refresh_requests"]) == refreshes + 1
      && number(request("state")["shows"]) == number(beforeTransport["shows"]),
    "spot refresh uses the same refresh action without opening the player")
  print("Background refresh launcher checks passed.")
  spawnClient(workflow.appendingPathComponent("show"), ["--screenshot"], environment: env)
  check(
    request("state")["screenshot_mode"] as? Bool == true,
    "Screenshot command enables persistent visibility")
  _ = request("hide")
  check(request("state")["screenshot_mode"] as? Bool == false, "Hiding exits screenshot mode")
  let benchmark = request("benchmark")
  check(number(benchmark["matches"]) == 111, "Native filter matches expected rows")
  print(
    "50 launches: median \(timings.sorted()[25]) ms; 10,000-row filter \(number(benchmark["filter_ms"])) ms"
  )
  parent.terminate()
  parent.waitUntilExit()
  server.waitUntilExit()
  check(
    !FileManager.default.fileExists(atPath: env["SPOTIFY_NATIVE_SOCKET_DIR"]! + "/player.sock"),
    "Host exits with Alfred lifetime")
  let liveParent = Process()
  liveParent.executableURL = URL(fileURLWithPath: "/bin/sleep")
  liveParent.arguments = ["20"]
  try! liveParent.run()
  for command in ["test-quit-panel", "test-quit-search"] {
    let host = Process()
    host.executableURL = executable
    host.arguments = ["--test-server", "--lifetime-pid", String(liveParent.processIdentifier)]
    host.environment = env
    host.standardOutput = FileHandle.nullDevice
    host.standardError = FileHandle.nullDevice
    try! host.run()
    let deadline = Date().addingTimeInterval(6)
    while request("state")["pid"] == nil && Date() < deadline { usleep(20000) }
    check(request("state")["pid"] != nil, "Command-Q test host starts")
    if command == "test-quit-search" {
      _ = request("test-demo-prepare")
      check(
        request("test-demo-windows")["editor"] as? Bool == true,
        "Command-Q works with the search field editor active")
    } else {
      check(
        text(request("state")["connection"]) != "connected",
        "Command-Q also works before Spotify is connected")
    }
    check(text(request(command)["status"]) == "ok", "Command-Q is handled by the native responder")
    host.waitUntilExit()
    check(host.terminationStatus == 0, "Command-Q exits the player normally")
    check(
      request("state").isEmpty
        && !FileManager.default.fileExists(
          atPath: env["SPOTIFY_NATIVE_SOCKET_DIR"]! + "/player.sock"),
      "Command-Q stops the process and cleans up its socket")
    check(liveParent.isRunning, "Command-Q leaves Alfred's lifetime owner running")
  }
  print(
    "Command-Q checks passed: search field, disconnected setup, process exit, and socket cleanup.")
  let live = Process()
  live.executableURL = executable
  live.arguments = ["--test-backend", "--lifetime-pid", String(liveParent.processIdentifier)]
  live.environment = env
  live.standardOutput = FileHandle.nullDevice
  live.standardError = FileHandle.nullDevice
  try! live.run()
  var liveState: JSONObject = [:]
  let liveDeadline = Date().addingTimeInterval(6)
  repeat {
    liveState = request("state")
    if text(liveState["connection"]) == "credentials" { break }
    usleep(20000)
  } while Date() < liveDeadline
  check(
    text(liveState["connection"]) == "credentials" && number(liveState["rows"]) == 1,
    "Native backend initializes without credentials or network")
  check(
    number(liveState["backend_pid"]) == number(liveState["pid"]),
    "Library backend runs in the same native process")
  let preserved = URL(fileURLWithPath: env["alfred_workflow_cache"]!)
    .appendingPathComponent("quit-preserved")
  try! Data("Keep cached metadata and artwork".utf8).write(to: preserved)
  spawnClient(workflow.appendingPathComponent("show"), ["--quit"], environment: env)
  live.waitUntilExit()
  check(liveParent.isRunning, "Quitting the player leaves its Alfred lifetime owner running")
  check(
    !FileManager.default.fileExists(atPath: env["SPOTIFY_NATIVE_SOCKET_DIR"]! + "/player.sock"),
    "spot quit stops the player and its in-process backend and removes the socket")
  spawnClient(workflow.appendingPathComponent("show"), ["--quit"], environment: env)
  check(request("state").isEmpty, "Repeated quit commands never restart the player")
  let freshRoot = root.appendingPathComponent("fresh-launch")
  let freshLauncher = freshRoot.appendingPathComponent("show")
  let freshHost = freshRoot.appendingPathComponent(
    "Spotify Mini Player.app/Contents/MacOS/SpotifyMiniPlayer")
  try! FileManager.default.createDirectory(
    at: freshHost.deletingLastPathComponent(), withIntermediateDirectories: true)
  try! FileManager.default.copyItem(at: workflow.appendingPathComponent("show"), to: freshLauncher)
  let quotedExecutable = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  try!
    "#!/bin/sh\nexec \(quotedExecutable) --test-backend --lifetime-pid \(liveParent.processIdentifier)\n"
    .write(to: freshHost, atomically: true, encoding: .utf8)
  try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: freshHost.path)
  spawnClient(freshLauncher, environment: env)
  var freshState: JSONObject = [:]
  let freshDeadline = Date().addingTimeInterval(6)
  repeat {
    freshState = request("state")
    if text(freshState["connection"]) == "credentials" { break }
    usleep(20000)
  } while Date() < freshDeadline
  check(
    number(freshState["pid"]) != number(liveState["pid"])
      && number(freshState["pid"]) > 0 && number(freshState["shows"]) == 1
      && text(freshState["connection"]) == "credentials",
    "Opening after quit starts a fresh player process exactly once")
  check(
    FileManager.default.fileExists(atPath: preserved.path),
    "Quitting preserves cached metadata and artwork")
  spawnClient(freshLauncher, ["--quit"], environment: env)
  check(request("state").isEmpty, "The fresh player can also be quit cleanly")
  liveParent.terminate()
  liveParent.waitUntilExit()
  print(
    "Quit launcher checks passed: absent player, backend shutdown, retained cache, and a fresh next launch."
  )
  let snapshot = screenshot ?? root.appendingPathComponent("player.png")
  _ = run(executable, ["--snapshot", snapshot.path], environment: env)
  check(
    FileManager.default.fileExists(atPath: snapshot.path), "Native integration screenshot was saved"
  )
  print("Native integration checks passed.")
}
