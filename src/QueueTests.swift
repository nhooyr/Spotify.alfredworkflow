import Foundation

private final class QueueTestCredentials: CredentialStorage {
  private var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
  func remove() throws { data = nil }
}

private final class QueueTestProtocol: URLProtocol {
  static var response: ((URLRequest) -> (Int, JSONObject))!
  private static let lock = NSLock()
  private static var paths: [String] = []
  static func requests(reset: Bool = false) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    let result = paths
    if reset { paths.removeAll() }
    return result
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    Self.paths.append(request.url!.path)
    Self.lock.unlock()
    let (status, value) = Self.response(request)
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: try! jsonData(value))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

func runQueueRegressionTests() throws {
  func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else {
      throw SpotifyFailure(message: "Queue regression test: " + message)
    }
  }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "spotify-queue-regression-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let authorization = AuthorizationStore(storage: QueueTestCredentials())
  let paths = WorkflowPaths(
    root: root,
    environment: [
      "alfred_workflow_data": root.appendingPathComponent("data").path,
      "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    ], authorization: authorization)
  try paths.prepare()
  let clientID = String(repeating: "a", count: 32)
  try paths.saveClientID(clientID)
  func grant(_ scope: String) throws {
    try authorization.save([
      "client_id": clientID, "access_token": "queue-fixture", "refresh_token": "queue-fixture",
      "expires_at": Date().timeIntervalSince1970 + 3600, "scope": scope,
    ])
  }
  try grant(SpotifyAPI.scopes)
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [QueueTestProtocol.self]
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }
  let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
  try store.useAccount("queue-fixture")
  let api = SpotifyAPI(paths, session: session)
  var isOnline = true
  let model = PlaybackQueue(store, api, online: { isOnline })
  func track(_ id: String) -> JSONObject {
    [
      "uri": "spotify:track:" + String(repeating: id, count: 22), "type": "track", "name": id,
      "artists": [
        ["uri": "spotify:artist:" + String(repeating: "r", count: 22), "name": "Artist"]
      ],
      "album": [
        "uri": "spotify:album:" + String(repeating: "s", count: 22), "name": "Album",
        "images": [["url": "https://i.scdn.co/image/queue-fixture"]],
      ],
    ]
  }
  let first = track("a")
  let second = track("b")
  let third = track("c")
  let context: JSONObject = [
    "uri": "spotify:playlist:" + String(repeating: "p", count: 22), "name": "Fixture Playlist",
  ]
  try model.observe(["item": first, "context": context])
  try model.observe(["item": first, "context": context])
  let selectedCurrentID = text(try model.rows().last?["queue_row_id"])
  try model.observe(["item": second])
  let afterAdvance = try model.rows()
  try require(
    !selectedCurrentID.isEmpty
      && afterAdvance.filter { text($0["queue_row_id"]) == selectedCurrentID }.count == 1
      && text(afterAdvance.first?["queue_row_id"]) == selectedCurrentID
      && text(afterAdvance.first?["queue_role"]) == "history",
    "the selected current entry keeps its unique identity when it becomes history")
  try model.observe(["item": first, "context": context])
  let observed = try model.rows()
  try require(
    observed.map { text($0["uri"]) } == [
      text(first["uri"]), text(second["uri"]), text(first["uri"]),
    ],
    "local observations retain repeated plays while coalescing unchanged polls")
  try require(
    observed.map { text($0["queue_role"]) } == ["history", "history", "current"]
      && Set(observed.map { text($0["queue_row_id"]) }).count == 3
      && observed.allSatisfy { text($0["play_uri"]) == text($0["uri"]) }
      && text(observed[0]["context"]) == text(context["uri"]),
    "roles, unique row identities, play targets and original context survive normalization")
  try model.observe([:])
  try model.observe(["item": ["uri": first["uri"]!]])
  let reopened = PlaybackQueue(store, api, online: { false })
  try require(
    try reopened.rows().map { text($0["queue_row_id"]) }
      == observed.map { text($0["queue_row_id"]) },
    "history persists and incomplete/stopped snapshots do not erase it")
  QueueTestProtocol.response = { request in
    if request.url!.path.hasSuffix("/queue") {
      return (200, ["currently_playing": first, "queue": [second, second, first]])
    }
    return (
      200,
      [
        "items": [
          ["track": third, "played_at": "2025-01-01T00:01:00Z", "context": context],
          ["track": third, "played_at": "2025-01-01T00:00:00.000Z", "context": context],
        ]
      ]
    )
  }
  _ = QueueTestProtocol.requests(reset: true)
  let fetched = try model.rows(network: true)
  let upcoming = fetched.filter { text($0["queue_role"]) == "upcoming" }
  try require(
    upcoming.map { text($0["uri"]) } == [
      text(second["uri"]), text(second["uri"]), text(first["uri"]),
    ]
      && Set(upcoming.map { text($0["queue_row_id"]) }).count == 3,
    "upcoming queue order and repeated tracks are retained")
  try require(
    fetched.filter { text($0["queue_role"]) == "history" }.count == 4
      && fetched.filter { text($0["queue_role"]) == "current" }.count == 1
      && QueueTestProtocol.requests() == ["/v1/me/player/queue", "/v1/me/player/recently-played"],
    "Spotify history merges with local plays without collapsing repeated occurrences")
  _ = try model.rows(network: true)
  try require(QueueTestProtocol.requests().count == 2, "fresh reads do not repeat API requests")
  try model.didEnqueue([third, third])
  let added = try model.rows(network: true).filter { text($0["queue_role"]) == "upcoming" }
  try require(
    added.count == 5 && added.suffix(2).allSatisfy { text($0["uri"]) == text(third["uri"]) }
      && Set(added.map { text($0["queue_row_id"]) }).count == 5
      && QueueTestProtocol.requests().count == 2,
    "acknowledged additions appear immediately without a lagging refresh or duplicate loss")
  try grant("user-read-playback-state")
  try model.invalidate()
  _ = QueueTestProtocol.requests(reset: true)
  _ = try model.rows(network: true)
  try require(
    QueueTestProtocol.requests() == ["/v1/me/player/queue"],
    "existing tokens without history permission still load the queue without reauthorization")
  var remembered = dict(store.get("playback-queue:observed", stale: true))
  var rememberedCurrent = dict(remembered["current"])
  rememberedCurrent["at"] = Date().timeIntervalSince1970 - 10
  remembered["current"] = rememberedCurrent
  try store.put("playback-queue:observed", remembered)
  QueueTestProtocol.response = { _ in (200, ["currently_playing": third, "queue": [second]]) }
  try model.invalidate()
  let changedCurrent = try model.rows(network: true).first { text($0["queue_role"]) == "current" }
  try require(
    changedCurrent.map { text($0["uri"]) == text(third["uri"]) && text($0["context"]).isEmpty }
      == true,
    "new current tracks never inherit another track's playlist context")
  isOnline = false
  _ = QueueTestProtocol.requests(reset: true)
  let offline = try model.rows(network: true)
  try require(
    !offline.isEmpty && QueueTestProtocol.requests().isEmpty,
    "offline browsing reuses cached queue and history")
  try store.put("desktop:downloaded-uris", [text(first["uri"])])
  let library = MusicLibrary(store, api, online: { false })
  let downloaded = try library.browse(["kind": "queue"])
  try require(
    !downloaded.isEmpty && downloaded.allSatisfy { text($0["uri"]) == text(first["uri"]) },
    "offline queue filtering uses real track URIs rather than presentation identities")
  let path = try library.resolvePath("queue/")
  let typo = try library.resolvePath("queu/")
  try require(
    text(path.routes.last?["kind"]) == "queue" && path.consumed == "queue/" && typo.routes.isEmpty
      && homeItems.map { text($0["name"]) }.suffix(2) == ["Search", "Queue"],
    "queue paths work while Search remains fifth and Queue is sixth")
  isOnline = true
  QueueTestProtocol.response = { _ in (503, [:]) }
  try model.invalidate()
  try require(!(try model.rows(network: true)).isEmpty, "temporary failures retain cached results")
  try store.useAccount("other-account")
  try require(try model.rows().isEmpty, "account changes erase queue/history snapshots")
  do {
    _ = try model.rows(network: true)
    throw SpotifyFailure(
      message: "Queue regression test: empty failed refresh must surface its error")
  } catch let error as SpotifyFailure {
    try require(error.status == 503, "an empty uncached queue surfaces the original API error")
  }
  QueueTestProtocol.response = { _ in
    try! store.useAccount("switched-during-request")
    return (200, ["currently_playing": first, "queue": [second]])
  }
  do {
    _ = try model.rows(network: true)
    throw SpotifyFailure(message: "Queue regression test: account-switch response was accepted")
  } catch let error as URLError {
    try require(error.code == .cancelled, "account switches reject late responses")
  }
  try require(try model.rows().isEmpty, "late account responses cannot repopulate the new account")
  print(
    "Queue regression tests passed: history, duplicates, caching, additions, offline filtering, scopes and account isolation."
  )
}
