import Foundation

private final class QueueBackendFixture {
  let lock = NSLock()
  var requests: [URLRequest] = []
  var failedPost: Int?
  var offlinePost = false
  var blockNextPost = false
  var blocked = false
  let release = DispatchSemaphore(value: 0)
  let tracks: [JSONObject]
  init(_ tracks: [JSONObject]) { self.tracks = tracks }
  var posts: [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests.filter { $0.httpMethod == "POST" }
  }
  var queueReads: Int {
    lock.lock()
    defer { lock.unlock() }
    return requests.filter { $0.httpMethod == "GET" && $0.url?.path == "/v1/me/player/queue" }.count
  }
  func respond(_ request: URLRequest) throws -> (Int, Data) {
    lock.lock()
    requests.append(request)
    let post = request.httpMethod == "POST"
    let count = requests.filter { $0.httpMethod == "POST" }.count
    let fails = failedPost == count
    let offline = offlinePost
    let block = post && blockNextPost
    if block {
      blockNextPost = false
      blocked = true
    }
    lock.unlock()
    if block { _ = release.wait(timeout: .now() + 3) }
    if post && offline { throw URLError(.notConnectedToInternet) }
    switch (request.httpMethod ?? "GET", request.url!.path) {
    case ("POST", "/v1/me/player/queue"):
      return fails
        ? (403, try jsonData(["error": ["message": "Fixture queue denied"]])) : (204, Data())
    case ("GET", "/v1/me/player/queue"):
      return (
        200, try jsonData(["currently_playing": tracks[0], "queue": [tracks[1], tracks[1]]])
      )
    case ("GET", "/v1/me/player/recently-played"):
      return (
        200, try jsonData(["items": [["track": tracks[2], "played_at": "2026-11-26T10:00:00Z"]]])
      )
    case ("GET", "/v1/me/player"):
      return (200, try jsonData(["is_playing": true, "item": tracks[0]]))
    default:
      throw SpotifyFailure(
        message:
          "Unexpected queue regression request: \(request.httpMethod ?? "GET") \(request.url!.path)"
      )
    }
  }
}

private final class QueueBackendURLProtocol: URLProtocol {
  static var fixture: QueueBackendFixture?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    do {
      guard let fixture = Self.fixture else { throw URLError(.cancelled) }
      let (status, data) = try fixture.respond(request)
      let response = HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch { client?.urlProtocol(self, didFailWithError: error) }
  }
  override func stopLoading() {}
}

func runQueueBackendRegressionTests() throws {
  func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
      throw SpotifyFailure(message: "Queue backend regression test: " + message)
    }
  }
  let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(
    "spotify-queue-backend-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let environment = [
    "alfred_workflow_data": root.appendingPathComponent("data").path,
    "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    "SPOTIFY_DESKTOP_CACHE": root.appendingPathComponent("desktop").path,
    "SPOTIFY_DESKTOP_USER_CACHE": root.appendingPathComponent("empty").path,
  ]
  let authorization = testAuthorizationStore(root: root, environment: environment)
  let paths = WorkflowPaths(root: root, environment: environment, authorization: authorization)
  try paths.prepare()
  try paths.saveClientID(String(repeating: "a", count: 32))
  func token(_ scope: String) throws {
    try authorization.save([
      "client_id": String(repeating: "a", count: 32), "access_token": "fixture",
      "refresh_token": "fixture", "expires_at": Date().timeIntervalSince1970 + 3600,
      "scope": scope,
    ])
  }
  try token(SpotifyAPI.scopes)
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  try store.useAccount("queue-backend-fixture")
  try store.put(MusicLibrary.syncKey, true, ttl: 3600)
  try store.put("desktop:scanned:v4", true, ttl: 3600)
  try store.put(
    "playback:liked-songs-uri", "spotify:user:queue-backend-fixture:collection", ttl: 3600)
  let raw = (1...3).map { index -> JSONObject in
    let id = String(repeating: String(index), count: 22)
    return [
      "uri": "spotify:track:" + id, "id": id, "type": "track", "name": "Queue song \(index)",
      "artists": [["name": "Fixture artist"]], "album": ["name": "Fixture album", "images": []],
      "is_playable": true,
    ]
  }
  let tracks = raw.map { fromAPI($0, kind: "track")! }
  for track in tracks { try store.putItem(track) }
  let album: JSONObject = [
    "uri": "spotify:album:" + String(repeating: "a", count: 22), "name": "Album in order",
    "kind": "album", "tracks": [tracks[2], tracks[1], tracks[2]],
  ]
  let playlist: JSONObject = [
    "uri": "spotify:playlist:" + String(repeating: "p", count: 22), "name": "Playlist in order",
    "kind": "playlist", "tracks": [tracks[1], tracks[0]],
  ]
  try store.putItem(album)
  try store.putItem(playlist)
  let fixture = QueueBackendFixture(raw)
  QueueBackendURLProtocol.fixture = fixture
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [QueueBackendURLProtocol.self]
  let session = URLSession(configuration: config)
  let backend = NativeBackend(
    root, environment: environment, session: session, credentials: authorization)
  var updates: [JSONObject] = []
  backend.receive = { updates.append($0) }
  defer {
    backend.stop()
    fixture.release.signal()
    session.invalidateAndCancel()
    QueueBackendURLProtocol.fixture = nil
  }
  func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition(), Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
  }
  try backend.start()
  wait { updates.contains { text($0["connection"]) == "connected" } }
  try require(
    updates.contains { text($0["connection"]) == "connected" }, "starts without reauthorization")
  func command(_ name: String, _ args: [String] = []) throws -> JSONObject {
    let start = updates.count
    backend.send(["command": name, "args": args])
    wait { updates.dropFirst(start).contains { text($0["command"]) == name } }
    let value = updates.dropFirst(start).first { text($0["command"]) == name }
    try require(value != nil, "receives " + name)
    return value ?? [:]
  }
  var request = 0
  func enqueue(_ item: JSONObject) throws -> JSONObject {
    request += 1
    let current = request
    backend.send([
      "command": "queue-add",
      "args": [String(decoding: try jsonData(item), as: UTF8.self), String(current)],
    ])
    wait {
      updates.contains {
        text($0["type"]) == "queue-add" && number($0["request"]) == Double(current)
      }
    }
    let result = updates.first {
      text($0["type"]) == "queue-add" && number($0["request"]) == Double(current)
    }
    try require(result != nil, "returns an enqueue result")
    return result ?? [:]
  }
  let home = try command("home")
  let queueHome =
    (home["rows"] as? [JSONObject] ?? []).first {
      text(dict(dict($0["item"])["target"])["kind"]) == "queue"
    } ?? [:]
  try require(!queueHome.isEmpty, "publishes the Queue root")
  let callsBeforePreview = fixture.posts.count
  let preview = try command(
    "preview", [String(decoding: try jsonData(dict(queueHome["item"])), as: UTF8.self)])
  try require(
    text(dict(preview["variables"])["preview_title"]) == "Queue"
      && text(dict(preview["variables"])["preview_detail"]) == "Recently played and up next",
    "keeps Queue hover caption stable")
  try require(
    fixture.posts.count == callsBeforePreview, "preview never starts playback or adds items")
  _ = try command(
    "activate", [String(decoding: try jsonData(dict(queueHome["item"])), as: UTF8.self)])
  wait {
    updates.contains { value in
      text(value["route_kind"]) == "queue"
        && (value["rows"] as? [JSONObject] ?? []).contains { text($0["queue_role"]) == "upcoming" }
    }
  }
  let queueRows =
    updates.reversed().compactMap { $0["rows"] as? [JSONObject] }.first {
      $0.contains { text($0["queue_role"]) == "upcoming" }
    } ?? []
  try require(!queueRows.isEmpty, "refreshes queue in the background")
  let upcoming = queueRows.filter { text($0["queue_role"]) == "upcoming" }
  try require(
    upcoming.count == 2 && text(upcoming[0]["uri"]) != text(upcoming[1]["uri"])
      && text(dict(upcoming[0]["item"])["uri"]) == text(dict(upcoming[1]["item"])["uri"]),
    "retains repeated songs with distinct row identities")
  let repeatedPreview = try command(
    "preview", [String(decoding: try jsonData(dict(upcoming[1]["item"])), as: UTF8.self)])
  try require(
    text(repeatedPreview["selected"]) == text(upcoming[1]["uri"]),
    "preview replies identify the selected occurrence")
  try require(
    text(dict(repeatedPreview["variables"])["preview_detail"]) == text(upcoming[1]["detail"]),
    "queue preview retains its complete role and metadata caption")
  _ = try command("home")
  var cachedTrack = tracks[0]
  cachedTrack["image"] = "fixture-cached-cover"
  try store.putItem(cachedTrack)
  var localTrack = tracks[0]
  localTrack["image"] = ""
  backend.send([
    "command": "observe-playback",
    "args": [
      String(decoding: try jsonData(["item": localTrack, "is_playing": true]), as: UTF8.self)
    ],
  ])
  let observedQueue = PlaybackQueue(store, SpotifyAPI(paths, session: session), online: { false })
  func cachedCoverRetained() -> Bool {
    ((try? observedQueue.rows()) ?? []).contains {
      text($0["queue_role"]) == "current" && text($0["image"]) == "fixture-cached-cover"
    }
  }
  wait { cachedCoverRetained() }
  try require(cachedCoverRetained(), "local observations retain cached artwork metadata")
  let queueActivation = updates.count
  _ = try command(
    "activate", [String(decoding: try jsonData(dict(queueHome["item"])), as: UTF8.self)])
  wait { updates.dropFirst(queueActivation).contains { text($0["command"]) == "browse" } }
  try require(
    updates.dropFirst(queueActivation).contains { text($0["command"]) == "browse" },
    "finishes the Queue refresh before a metadata-only correction")
  let currentRowID = text(
    try observedQueue.rows().first { text($0["queue_role"]) == "current" }?["queue_row_id"])
  let readsBeforeCorrection = fixture.queueReads
  let correctionStart = updates.count
  var correctedTrack = localTrack
  correctedTrack["name"] = "Corrected current song"
  correctedTrack["artists"] = [["name": "Corrected artist"]]
  correctedTrack["album"] = ["name": "Corrected album"]
  correctedTrack["image"] = "fixture-corrected-cover"
  let correctedState: JSONObject = [
    "item": correctedTrack,
    "context": ["uri": text(playlist["uri"])],
  ]
  backend.send([
    "command": "observe-playback",
    "args": [String(decoding: try jsonData(correctedState), as: UTF8.self)],
  ])
  func correctionRow() -> JSONObject? {
    updates.dropFirst(correctionStart).filter { text($0["command"]) == "queue-update" }
      .compactMap { $0["rows"] as? [JSONObject] }.flatMap { $0 }
      .first { text($0["queue_role"]) == "current" && text($0["name"]) == "Corrected current song" }
  }
  wait { correctionRow() != nil }
  let correctedRow = correctionRow() ?? [:]
  try require(
    text(correctedRow["uri"]) == currentRowID
      && text(correctedRow["detail"]) == "Now playing · Corrected artist · Corrected album"
      && text(dict(correctedRow["item"])["image"]) == "fixture-corrected-cover"
      && text(dict(correctedRow["item"])["context"]) == text(playlist["uri"]),
    "same-track metadata and context corrections refresh visible Queue rows with stable identity")
  try require(
    fixture.queueReads == readsBeforeCorrection, "metadata corrections do not refetch the API queue"
  )
  let duplicateStart = updates.count
  backend.send([
    "command": "observe-playback",
    "args": [String(decoding: try jsonData(correctedState), as: UTF8.self)],
  ])
  _ = try command("home")
  try require(
    !updates.dropFirst(duplicateStart).contains { text($0["command"]) == "queue-update" }
      && fixture.queueReads == readsBeforeCorrection,
    "duplicate accepted metadata neither republishes Queue rows nor refetches them")
  backend.send([
    "command": "observe-playback",
    "args": [String(decoding: try jsonData(["item": tracks[1]]), as: UTF8.self)],
  ])
  func currentQueueURI() -> String {
    text(((try? observedQueue.rows()) ?? []).first { text($0["queue_role"]) == "current" }?["uri"])
  }
  wait { currentQueueURI() == text(tracks[1]["uri"]) }
  try require(currentQueueURI() == text(tracks[1]["uri"]), "accepted observations advance history")
  let acceptedRows = try observedQueue.rows().map { text($0["queue_row_id"]) }
  backend.send(["command": "repeat-state", "args": ["60000", "60001"]])
  wait {
    updates.contains { text($0["type"]) == "playback-state" && number($0["request"]) == 60001 }
  }
  try require(
    updates.contains { text($0["type"]) == "playback-state" && number($0["request"]) == 60001 },
    "receives the stale raw API playback snapshot")
  try require(
    updates.contains {
      text($0["type"]) == "playback-state" && number($0["request"]) == 60001
        && number($0["sampled_at"]) > 0
    }, "API snapshots retain their sampling time for playback ordering")
  let afterPollRows = try observedQueue.rows().map { text($0["queue_row_id"]) }
  try require(
    afterPollRows == acceptedRows
      && currentQueueURI() == text(tracks[1]["uri"]),
    "raw API snapshots cannot bypass accepted playback history")
  backend.send([
    "command": "observe-playback",
    "args": [String(decoding: try jsonData(["item": localTrack]), as: UTF8.self)],
  ])
  wait { cachedCoverRetained() }
  let first = try enqueue(tracks[0])
  try require(number(first["added"]) == 1 && first["error"] == nil, "adds a single song")
  let albumResult = try enqueue(album)
  try require(
    number(albumResult["added"]) == 3 && albumResult["error"] == nil, "adds every album song")
  let albumURIs = fixture.posts.suffix(3).map { request in
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first {
      $0.name == "uri"
    }!.value!
  }
  try require(
    albumURIs == [text(tracks[2]["uri"]), text(tracks[1]["uri"]), text(tracks[2]["uri"])],
    "keeps album order and duplicate occurrences")
  let playlistResult = try enqueue(playlist)
  try require(
    number(playlistResult["added"]) == 2 && playlistResult["error"] == nil,
    "adds playlist songs in order")
  let beforeUnsupported = fixture.posts.count
  let unsupported = try enqueue([
    "kind": "artist", "uri": "spotify:artist:" + String(repeating: "r", count: 22),
    "name": "Artist",
  ])
  try require(
    unsupported["error"] != nil && fixture.posts.count == beforeUnsupported,
    "rejects browse-only selections without requests")
  fixture.lock.lock()
  fixture.failedPost = fixture.requests.filter { $0.httpMethod == "POST" }.count + 2
  fixture.lock.unlock()
  let partial = try enqueue(album)
  try require(
    number(partial["added"]) == 1 && text(partial["error"]).contains("Added 1 song"),
    "reports partial additions accurately")
  fixture.lock.lock()
  fixture.failedPost = nil
  fixture.offlinePost = true
  fixture.lock.unlock()
  let offline = try enqueue(tracks[0])
  try require(
    offline["error"] != nil && offline["fallback"] == nil && number(offline["added"]) == 0,
    "network failures never fall back to local playback")
  fixture.lock.lock()
  fixture.offlinePost = false
  fixture.lock.unlock()
  try token("user-read-playback-state")
  let beforeScope = fixture.posts.count
  let scope = try enqueue(tracks[0])
  try require(
    scope["error"] != nil && fixture.posts.count == beforeScope,
    "missing modify permission does not send queue mutations")
  try token(SpotifyAPI.scopes)
  fixture.lock.lock()
  fixture.blockNextPost = true
  fixture.blocked = false
  fixture.lock.unlock()
  let beforeAccountSwitch = fixture.posts.count
  request += 1
  let oldAccountRequest = request
  backend.send([
    "command": "queue-add",
    "args": [String(decoding: try jsonData(album), as: UTF8.self), String(oldAccountRequest)],
  ])
  wait {
    fixture.lock.lock()
    defer { fixture.lock.unlock() }
    return fixture.blocked
  }
  fixture.lock.lock()
  let accountRequestBlocked = fixture.blocked
  fixture.lock.unlock()
  try require(accountRequestBlocked, "blocks the old account addition before acknowledgement")
  try store.useAccount("new-queue-backend-account")
  fixture.release.signal()
  let newAccountAddition = try enqueue(tracks[0])
  let newAccountRows = try observedQueue.rows()
  try require(
    number(newAccountAddition["added"]) == 1
      && fixture.posts.count == beforeAccountSwitch + 2
      && newAccountRows.map { text($0["uri"]) } == [text(tracks[0]["uri"])]
      && !updates.contains {
        text($0["type"]) == "queue-add" && number($0["request"]) == Double(oldAccountRequest)
      }, "an account switch rejects old additions, cached acknowledgements and success notices")
  fixture.lock.lock()
  fixture.blockNextPost = true
  fixture.blocked = false
  fixture.lock.unlock()
  request += 1
  let cancelledRequest = request
  backend.send([
    "command": "queue-add",
    "args": [String(decoding: try jsonData(album), as: UTF8.self), String(cancelledRequest)],
  ])
  wait {
    fixture.lock.lock()
    defer { fixture.lock.unlock() }
    return fixture.blocked
  }
  let beforeCancel = fixture.posts.count
  backend.stop()
  fixture.release.signal()
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))
  try require(
    fixture.posts.count == beforeCancel
      && !updates.contains {
        text($0["type"]) == "queue-add" && number($0["request"]) == Double(cancelledRequest)
      }, "stop cancels remaining additions and stale confirmation")
  fixture.lock.lock()
  let allRequests = fixture.requests
  fixture.lock.unlock()
  try require(
    allRequests.allSatisfy { request in
      !(request.httpMethod == "PUT" || request.url!.path == "/v1/me/player/play")
        && !(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
          .contains { $0.name == "device_id" }
    }, "never transfers output devices or starts playback")
  print(
    "Queue backend regression tests passed: stable rows, repeated songs, ordered additions, partial failures, cancellation and device preservation."
  )
}
