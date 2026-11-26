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
  try model.didEnqueue([third, third], expectedAccount: "queue-fixture")
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
    changedCurrent.map {
      text($0["uri"]) == text(first["uri"]) && text($0["context"]) == text(context["uri"])
    } == true,
    "a lagging queue response cannot replace accepted playback after its timestamp ages")
  try model.observe(["item": third])
  let acceptedCurrent = try model.rows().first { text($0["queue_role"]) == "current" }
  try require(
    acceptedCurrent.map { text($0["uri"]) == text(third["uri"]) && text($0["context"]).isEmpty }
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

  let transitions = try MusicStore(paths.cache.appendingPathComponent("queue-transitions.sqlite3"))
  try transitions.useAccount("queue-transitions")
  let transitionQueue = PlaybackQueue(transitions, api, online: { true })
  var queueCurrent = first
  var queueUpcoming = [third, third]
  QueueTestProtocol.response = { _ in
    (200, ["currently_playing": queueCurrent, "queue": queueUpcoming])
  }
  try transitionQueue.observe([:])
  let bootstrapped = try transitionQueue.rows(network: true)
  try require(
    bootstrapped.filter { text($0["queue_role"]) == "current" }.map { text($0["uri"]) }
      == [text(first["uri"])],
    "the queue endpoint bootstraps current playback before an accepted observation")
  try transitionQueue.observe(["item": first])
  queueCurrent = second
  try transitionQueue.invalidate()
  let unchangedAccepted = try transitionQueue.rows(network: true)
  try require(
    unchangedAccepted.filter { text($0["queue_role"]) == "current" }.map { text($0["uri"]) }
      == [text(first["uri"])],
    "an unchanged accepted poll also prevents the queue endpoint from inventing a transition")
  queueCurrent = first
  try transitionQueue.observe(["item": second])
  var oldObservations = dict(transitions.get("playback-queue:observed", stale: true))
  var oldHistory = oldObservations["history"] as? [JSONObject] ?? []
  var oldCurrent = dict(oldObservations["current"])
  try require(oldHistory.count == 1, "accepted A-to-B playback records exactly one history entry")
  let now = Date().timeIntervalSince1970
  oldHistory[0]["at"] = now - 120
  oldCurrent["at"] = now - 60
  oldObservations["history"] = oldHistory
  oldObservations["current"] = oldCurrent
  try transitions.put("playback-queue:observed", oldObservations)
  let acceptedIDs = try transitionQueue.rows().prefix(2).map { text($0["queue_row_id"]) }
  queueUpcoming = [third, first, third]
  try transitionQueue.invalidate()
  let staleQueue = try transitionQueue.rows(network: true)
  try require(
    staleQueue.map { text($0["uri"]) } == [
      text(first["uri"]), text(second["uri"]), text(third["uri"]), text(first["uri"]),
      text(third["uri"]),
    ]
      && staleQueue.map { text($0["queue_role"]) } == [
        "history", "current", "upcoming", "upcoming", "upcoming",
      ] && staleQueue.prefix(2).map { text($0["queue_row_id"]) } == acceptedIDs,
    "a stale queue current cannot invent a transition after accepted playback ages")
  queueCurrent = second
  try transitionQueue.invalidate()
  let confirmedQueue = try transitionQueue.rows(network: true)
  try require(
    confirmedQueue.prefix(2).map { text($0["queue_row_id"]) } == acceptedIDs,
    "a later queue confirmation does not create duplicate playback history")
  try transitionQueue.observe(["item": first])
  let repeatedPlayback = try transitionQueue.rows()
  try require(
    repeatedPlayback.prefix(3).map { text($0["uri"]) } == [
      text(first["uri"]), text(second["uri"]), text(first["uri"]),
    ]
      && repeatedPlayback.prefix(3).map { text($0["queue_role"]) } == [
        "history", "history", "current",
      ],
    "genuine accepted A-to-B-to-A playback retains all three occurrences")
  try transitions.useAccount("new-queue-account")
  try require(
    try transitionQueue.rows().isEmpty,
    "switching accounts removes cached queue and playback history")
  queueCurrent = second
  queueUpcoming = [third]
  let newAccountQueue = try transitionQueue.rows(network: true)
  try require(
    newAccountQueue.map { text($0["uri"]) } == [text(second["uri"]), text(third["uri"])],
    "a new account can bootstrap playback despite the previous account's accepted observation")
  try transitionQueue.observe(["item": second])
  queueCurrent = first
  try transitionQueue.invalidate()
  let newAccountAccepted = try transitionQueue.rows(network: true)
  try require(
    newAccountAccepted.map { text($0["uri"]) } == [text(second["uri"]), text(third["uri"])]
      && newAccountAccepted.map { text($0["queue_role"]) } == ["current", "upcoming"],
    "an accepted observation under the new account also rejects stale queue playback")

  func fixture(_ name: String) throws -> (MusicStore, PlaybackQueue) {
    let database = try MusicStore(paths.cache.appendingPathComponent(name + ".sqlite3"))
    try database.useAccount(name)
    return (database, PlaybackQueue(database, api, online: { true }))
  }
  func snapshot(
    _ item: JSONObject, at: Double, progress: Double? = nil, timestamp: Double? = nil
  ) -> JSONObject {
    var result: JSONObject = ["item": item, "observed_at": at, "is_playing": true]
    if let progress = progress { result["progress_ms"] = progress }
    if let timestamp = timestamp { result["timestamp"] = timestamp }
    return result
  }
  let (seedStore, provisional) = try fixture("queue-provisional")
  QueueTestProtocol.response = { _ in (200, ["currently_playing": first, "queue": []]) }
  let seedRows = try provisional.rows(network: true)
  try require(
    seedRows.count == 1 && seedStore.get("playback-queue:observed", stale: true) == nil,
    "queue bootstrap uses a separate provisional entry rather than accepted history")
  let seedID = text(seedRows.first?["queue_row_id"])
  let matchingConfirmation = try provisional.observe(["item": first])
  try require(
    !matchingConfirmation && text(try provisional.rows().first?["queue_row_id"]) == seedID,
    "matching accepted playback keeps the provisional row identity without a visible change")
  try provisional.observe(["item": second])
  let persistedIDs = try provisional.rows().map { text($0["queue_row_id"]) }
  let restarted = PlaybackQueue(seedStore, api, online: { true })
  try restarted.invalidate()
  _ = try restarted.rows(network: true)
  try restarted.observe(["item": second])
  try require(
    try restarted.rows().map { text($0["queue_row_id"]) } == persistedIDs,
    "a stale queue bootstrap cannot replay persisted accepted tracks after a process restart")
  let (unconfirmedStore, unconfirmed) = try fixture("queue-unconfirmed")
  _ = try unconfirmed.rows(network: true)
  let reopenedUnconfirmed = PlaybackQueue(unconfirmedStore, api, online: { true })
  try reopenedUnconfirmed.observe(["item": second])
  try require(
    try reopenedUnconfirmed.rows().map { text($0["uri"]) } == [text(second["uri"])],
    "a stale provisional track never becomes a played history entry, including after restart")

  var relinked = track("d")
  relinked["name"] = first["name"]
  relinked["linked_from"] = ["uri": text(first["uri"])]
  try require(
    text(dict(fromAPI(relinked, kind: "track")?["linked_from"])["uri"]) == text(first["uri"]),
    "API normalization retains the original identity of relinked tracks")
  let (aliasStore, aliasQueue) = try fixture("queue-relinked")
  try aliasQueue.observe(["item": relinked])
  let aliasID = text(try aliasQueue.rows().first?["queue_row_id"])
  var thinRelinked = relinked
  thinRelinked.removeValue(forKey: "linked_from")
  for item in [thinRelinked, first, thinRelinked] {
    try aliasQueue.observe(["item": item])
    let rows = try aliasQueue.rows()
    try require(
      rows.count == 1 && text(rows[0]["queue_row_id"]) == aliasID
        && text(rows[0]["play_uri"]) == text(item["uri"])
        && PlaybackQueue.canonicalURI(rows[0]) == text(first["uri"]),
      "thin relinked metadata preserves one occurrence and the actual incoming play URI")
  }
  try aliasQueue.observe(["item": second])
  try aliasQueue.observe(["item": thinRelinked])
  try aliasQueue.observe(["item": first])
  try require(
    try aliasQueue.rows().count == 3,
    "recording aliases remain known across genuine intervening plays without merging occurrences")
  try aliasQueue.observe(["item": first, "context": context])
  var renamedContext = context
  renamedContext["name"] = "Updated context name"
  let contextChanged = try aliasQueue.observe(["item": first, "context": renamedContext])
  let contextualRows = try aliasQueue.rows()
  try require(
    contextChanged && contextualRows.count == 3
      && text(dict(contextualRows.last?["playback_context"])["name"]) == "Updated context name",
    "same-URI context metadata corrections update the current entry without adding a play")
  try aliasStore.put(
    "playback-queue:recent",
    [
      ["track": thinRelinked, "at": 80.0, "id": "thin-alias"],
      ["track": first, "at": 80.0, "id": "original-alias"],
      ["track": first, "at": 82.0, "id": "distinct-repeated-play"],
    ])
  let knownAliasEvents = try aliasQueue.rows().filter {
    text($0["queue_row_id"]).hasPrefix("queue:played:spotify:")
  }
  try require(
    knownAliasEvents.count == 2,
    "known recording aliases deduplicate thin cached events only at the same exact instant")

  try grant(SpotifyAPI.scopes)
  let (_, historyQueue) = try fixture("queue-history-events")
  try historyQueue.observe(snapshot(first, at: 110, progress: 30_000, timestamp: 80_000))
  let localHistoryID = text(try historyQueue.rows().first?["queue_row_id"])
  let timingChanged = try historyQueue.observe(
    snapshot(first, at: 111, progress: 31_000, timestamp: 111_000))
  try require(!timingChanged, "progress-only observations do not change visible queue metadata")
  try historyQueue.observe(snapshot(second, at: 200, progress: 0))
  QueueTestProtocol.response = { request in
    if request.url!.path.hasSuffix("/queue") {
      return (200, ["currently_playing": second, "queue": []])
    }
    return (
      200,
      [
        "items": [
          ["track": first, "played_at": "1970-01-01T00:01:20Z"],
          ["track": first, "played_at": "1970-01-01T00:01:20.000Z"],
          ["track": relinked, "played_at": "1970-01-01T00:01:20.000Z"],
          ["track": first, "played_at": "1970-01-01T00:01:22Z"],
          ["track": third, "played_at": "1970-01-01T00:01:21Z"],
        ]
      ]
    )
  }
  let reconciled = try historyQueue.rows(network: true)
  try require(
    reconciled.map { text($0["uri"]) } == [
      text(first["uri"]), text(third["uri"]), text(first["uri"]), text(second["uri"]),
    ] && text(reconciled.first?["queue_row_id"]) == localHistoryID,
    "exact Spotify event timestamps reconcile local/API occurrences with stable local IDs")
  let (remoteStore, remoteQueue) = try fixture("queue-remote-events")
  let providerRows = try remoteQueue.rows(network: true)
  try require(
    providerRows.filter { text($0["queue_role"]) == "history" }.count == 3
      && Set(providerRows.map { text($0["queue_row_id"]) }).count == providerRows.count,
    "identical remote instants and aliases deduplicate while distinct close repeats survive")
  let cachedRemote = remoteStore.get("playback-queue:recent", stale: true) as? [JSONObject] ?? []
  try remoteStore.put(
    "playback-queue:recent",
    cachedRemote.enumerated().map { index, entry -> JSONObject in
      var entry = entry
      entry["id"] = "stored-format-variant-" + String(index)
      return entry
    })
  try require(
    try remoteQueue.rows().map { text($0["queue_row_id"]) }
      == providerRows.map { text($0["queue_row_id"]) },
    "cached remote event identity derives from the instant and recording rather than old ID formatting"
  )
  let (_, unknownQueue) = try fixture("queue-unknown-timing")
  try unknownQueue.observe(snapshot(first, at: 81))
  try unknownQueue.observe(snapshot(second, at: 200))
  let ambiguous = try unknownQueue.rows(network: true)
  try require(
    ambiguous.filter { text($0["queue_role"]) == "history" }.count == 4,
    "unknown local start timing preserves potentially distinct plays instead of guessing by URI")
  let progressOnly = try unknownQueue.observe(snapshot(second, at: 205, progress: 5_000))
  try require(!progressOnly, "progress alone does not change visible queue metadata")
  let (identityStore, identityQueue) = try fixture("queue-late-event-identity")
  try identityQueue.observe(snapshot(first, at: 110))
  try identityStore.put(
    "playback-queue:recent", [["track": first, "at": 80.0, "id": "unmatched-provider-event"]])
  let beforeIdentity = try identityQueue.rows()
  try require(beforeIdentity.count == 2, "missing provider identity keeps ambiguous plays separate")
  let acquiredIdentity = try identityQueue.observe(snapshot(first, at: 111, timestamp: 80_000))
  let afterIdentity = try identityQueue.rows()
  try require(
    acquiredIdentity && afterIdentity.count == 1
      && text(afterIdentity[0]["queue_row_id"]) == text(beforeIdentity.last?["queue_row_id"]),
    "acquiring an exact provider event identity refreshes membership while keeping the local row ID"
  )
  for (name, timestamp): (String, Double?) in [("seek", nil), ("resume", 105_000)] {
    let (seekStore, seekQueue) = try fixture("queue-unverified-" + name)
    try seekQueue.observe(snapshot(first, at: 110, progress: 90_000, timestamp: timestamp))
    try seekQueue.observe(snapshot(second, at: 200, progress: 0))
    try seekStore.put(
      "playback-queue:recent",
      [["track": first, "at": 50.0, "id": "earlier-distinct-play"]])
    try require(
      try seekQueue.rows().map { text($0["uri"]) } == [
        text(first["uri"]), text(first["uri"]), text(second["uri"]),
      ],
      "a seek or resume cannot turn playback position into proof of an earlier play")
  }

  let (enqueueStore, enqueueQueue) = try fixture("queue-enqueue-old")
  try enqueueQueue.didEnqueue([first], expectedAccount: "queue-enqueue-old")
  try enqueueStore.useAccount("queue-enqueue-new")
  try enqueueQueue.didEnqueue([second], expectedAccount: "queue-enqueue-new")
  func responses(_ database: MusicStore) throws -> Data {
    try jsonData(database.rows("SELECT * FROM responses ORDER BY key"))
  }
  let beforeRejectedAdd = try responses(enqueueStore)
  do {
    try enqueueQueue.didEnqueue([third], expectedAccount: "queue-enqueue-old")
    throw SpotifyFailure(message: "Queue regression test: an old-account addition was accepted")
  } catch let error as URLError {
    try require(error.code == .cancelled, "old-account additions are rejected")
  }
  let cancelledAdd = RequestCancellation()
  cancelledAdd.cancel()
  do {
    try enqueueQueue.didEnqueue(
      [third], expectedAccount: "queue-enqueue-new", cancellation: cancelledAdd)
    throw SpotifyFailure(message: "Queue regression test: a cancelled addition was accepted")
  } catch let error as URLError {
    try require(error.code == .cancelled, "cancelled additions are rejected")
  }
  try require(
    try responses(enqueueStore) == beforeRejectedAdd,
    "rejected additions preserve the response cache byte-for-byte")
  do {
    _ = try enqueueQueue.rows(cancellation: cancelledAdd)
    throw SpotifyFailure(message: "Queue regression test: a cancelled cache read was accepted")
  } catch let error as URLError {
    try require(error.code == .cancelled, "cancelled reads do not return cached queue data")
  }
  let (cancelStore, cancelQueue) = try fixture("queue-cancelled-response")
  let cancelledRead = RequestCancellation()
  QueueTestProtocol.response = { _ in
    cancelledRead.cancel()
    return (200, ["currently_playing": first, "queue": [third]])
  }
  let beforeCancelledRead = try responses(cancelStore)
  do {
    _ = try cancelQueue.rows(network: true, cancellation: cancelledRead)
    throw SpotifyFailure(message: "Queue regression test: a cancelled queue response was accepted")
  } catch let error as URLError {
    try require(error.code == .cancelled, "cancelled queue replies are rejected before caching")
  }
  try require(
    try responses(cancelStore) == beforeCancelledRead,
    "cancelled queue responses cannot persist a provisional current or upcoming rows")
  let (accountStore, accountQueue) = try fixture("queue-account-response")
  QueueTestProtocol.response = { request in
    if request.url!.path.hasSuffix("/queue") {
      return (200, ["currently_playing": first, "queue": [third]])
    }
    try! accountStore.useAccount("queue-account-switched")
    return (200, ["items": [["track": first, "played_at": "1970-01-01T00:01:20Z"]]])
  }
  do {
    _ = try accountQueue.rows(network: true)
    throw SpotifyFailure(
      message: "Queue regression test: an old-account history reply was accepted")
  } catch let error as URLError {
    try require(error.code == .cancelled, "account changes cancel late history responses")
  }
  try require(
    try accountQueue.rows().isEmpty,
    "a late history reply cannot repopulate provisional playback or queue data for a new account")
  print(
    "Queue regression tests passed: history, duplicates, caching, additions, offline filtering, scopes and account isolation."
  )
}
