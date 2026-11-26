import Foundation

private final class SeekTestCredentials: CredentialStorage {
  private var data: Data?
  func read() throws -> Data? { data }
  func write(_ data: Data) throws { self.data = data }
  func remove() throws { data = nil }
}

private final class SeekTestProtocol: URLProtocol {
  static var response: ((URLRequest) -> (Int, Data))!
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let (status, body) = Self.response(request)
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
        headerFields: ["Retry-After": "1"])!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

func runSeekRegressionTests() throws {
  func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw SpotifyFailure(message: "Seek regression test: " + message) }
  }
  func failure(_ message: String, _ operation: () throws -> Void) throws -> Error {
    do { try operation() } catch { return error }
    throw SpotifyFailure(message: "Seek regression test unexpectedly succeeded: " + message)
  }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "spotify-seek-regression-" + UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let paths = WorkflowPaths(
    root: root,
    environment: [
      "alfred_workflow_data": root.appendingPathComponent("data").path,
      "alfred_workflow_cache": root.appendingPathComponent("cache").path,
    ], authorization: AuthorizationStore(storage: SeekTestCredentials()))
  try paths.prepare()
  let clientID = String(repeating: "a", count: 32)
  try paths.saveClientID(clientID)
  func grant(_ scopes: String = SpotifyAPI.scopes) throws {
    try paths.authorization.save([
      "client_id": clientID, "access_token": "seek-fixture", "refresh_token": "seek-fixture",
      "expires_at": Date().timeIntervalSince1970 + 3600, "scope": scopes,
    ])
  }
  try grant()
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [SeekTestProtocol.self]
  let session = URLSession(configuration: configuration)
  defer {
    session.invalidateAndCancel()
    SeekTestProtocol.response = nil
  }
  let api = SpotifyAPI(paths, session: session)
  let track = "spotify:track:" + String(repeating: "t", count: 22)
  let otherTrack = "spotify:track:" + String(repeating: "u", count: 22)
  func snapshot(
    progress: Any = 10000, duration: Any? = 120000, timestamp: Any? = 100000,
    uri: String? = nil, device: String = "phone", playing: Bool = false
  ) -> JSONObject {
    var item: JSONObject = ["uri": uri ?? track]
    item["duration_ms"] = duration
    var state: JSONObject = [
      "progress_ms": progress, "is_playing": playing,
      "device": ["id": device, "type": "Smartphone", "name": "Phone"], "item": item,
    ]
    state["timestamp"] = timestamp
    return state
  }
  var state = snapshot()
  var clock: TimeInterval = 1000
  var online = true
  var readStatus = 200
  var mutationStatus = 204
  var cancelOnRead: RequestCancellation?
  var cancelOnMutation: RequestCancellation?
  var calls: [(String, String)] = []
  var targets: [Int] = []
  var targetedDevice = false
  let errorBody = try jsonData(["error": ["message": "Seek fixture rejected the command"]])
  SeekTestProtocol.response = { request in
    let method = request.httpMethod ?? ""
    let path = request.url!.path
    calls.append((method, path))
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    targetedDevice =
      targetedDevice || query.contains { $0.name == "device_id" }
      || path == "/v1/me/player/devices"
    if path == "/v1/me/player", method == "GET" {
      cancelOnRead?.cancel()
      return (
        readStatus,
        readStatus == 204 ? Data() : readStatus == 200 ? try! jsonData(state) : errorBody
      )
    }
    if path == "/v1/me/player/seek", method == "PUT" {
      targets.append(Int(query.first { $0.name == "position_ms" }?.value ?? "") ?? -1)
      cancelOnMutation?.cancel()
      return (mutationStatus, mutationStatus == 204 ? Data() : errorBody)
    }
    if method == "PUT", ["/v1/me/player/pause", "/v1/me/player/play"].contains(path) {
      return (204, Data())
    }
    return (500, errorBody)
  }
  func player() -> WebPlayback { WebPlayback(api, online: { online }, now: { clock }) }
  func reset() throws {
    state = snapshot()
    clock = 1000
    online = true
    readStatus = 200
    mutationStatus = 204
    cancelOnRead = nil
    cancelOnMutation = nil
    calls = []
    targets = []
    let cooldown = paths.data.appendingPathComponent("api-cooldown.json")
    if FileManager.default.fileExists(atPath: cooldown.path) {
      try FileManager.default.removeItem(at: cooldown)
    }
  }

  let paused = try player().transport("seek-forward")
  try require(
    paused.isEmpty && targets == [15000]
      && calls.map { $0.0 } == ["GET", "PUT"]
      && calls.map { $0.1 } == ["/v1/me/player", "/v1/me/player/seek"],
    "seeking a paused phone changes only its position, without a stale state or playing result")
  for (progress, duration, command, expected): (Int, Int?, String, Int) in [
    (2000, 120000, "seek-backward", 0), (0, 120000, "seek-backward", 0),
    (118000, 120000, "seek-forward", 119999), (5000, nil, "seek-forward", 10000),
  ] {
    try reset()
    state = snapshot(progress: progress, duration: duration)
    _ = try player().transport(command)
    try require(targets == [expected], "five-second seeks stay within known track boundaries")
  }
  for progress: Any in [NSNull(), -1, "10000", true] {
    try reset()
    state = snapshot(progress: progress)
    _ = try failure("invalid progress") { _ = try player().transport("seek-forward") }
    try require(targets.isEmpty, "invalid or absent playback progress cannot send a seek")
  }
  try reset()
  readStatus = 204
  _ = try failure("missing playback state") { _ = try player().transport("seek-backward") }
  try require(
    targets.isEmpty
      && WebPlayback.appleScriptCommand(
        for: [
          "fallback": true, "command": "seek-forward", "fallback_reason": "missing-playback-state",
        ],
        offline: false, remote: false) == nil,
    "missing online progress never turns seeking into local AppleScript playback")

  try reset()
  let repeated = player()
  _ = try repeated.transport("seek-forward")
  clock += 0.5
  _ = try repeated.transport("seek-forward")
  clock += 0.5
  _ = try repeated.transport("seek-backward")
  try require(
    targets == [15000, 20000, 15000],
    "rapid repeated and inverse seeks accumulate acknowledged positions while the API lags")
  try reset()
  state = snapshot(playing: true)
  let advancing = player()
  _ = try advancing.transport("seek-forward")
  clock += 1
  _ = try advancing.transport("seek-forward")
  try require(targets == [15000, 21000], "elapsed playback advances only a playing seek anchor")
  state = snapshot(playing: false)
  _ = try advancing.transport("seek-forward")
  try require(targets.last == 15000, "a changed paused state uses the provider's position")

  for replacement in [
    snapshot(progress: 7000, timestamp: 100001), snapshot(progress: 7000, device: "other-phone"),
    snapshot(progress: 7000, uri: otherTrack),
  ] {
    try reset()
    let playback = player()
    _ = try playback.transport("seek-forward")
    state = replacement
    _ = try playback.transport("seek-forward")
    try require(
      targets == [15000, 12000], "a new provider revision, device or track discards the anchor")
  }
  for elapsed: TimeInterval in [3, -1] {
    try reset()
    let playback = player()
    _ = try playback.transport("seek-forward")
    clock += elapsed
    _ = try playback.transport("seek-forward")
    try require(
      targets == [15000, 15000], "expired or future-dated anchors cannot replace fresh progress")
  }
  for field in ["timestamp", "device", "item"] {
    try reset()
    state.removeValue(forKey: field)
    let playback = player()
    _ = try playback.transport("seek-forward")
    _ = try playback.transport("seek-forward")
    try require(
      targets == [15000, 15000], "unknown playback identity cannot retain an optimistic anchor")
  }
  for command in ["pause", "play"] {
    try reset()
    let playback = player()
    _ = try playback.transport("seek-forward")
    if command == "play" {
      try playback.play(otherTrack)
    } else {
      _ = try playback.transport(command)
    }
    _ = try playback.transport("seek-forward")
    try require(targets == [15000, 15000], "other playback mutations discard the seek anchor")
  }
  for failedRead in [false, true] {
    for status in [403, 404, 429, 500] {
      try reset()
      let playback = player()
      _ = try playback.transport("seek-forward")
      if failedRead { readStatus = status } else { mutationStatus = status }
      let error = try failure("HTTP \(status)") { _ = try playback.transport("seek-forward") }
      try require(
        (error as? SpotifyFailure)?.status == status,
        "seek HTTP failures retain Spotify's original status without playback fallback")
      try reset()
      _ = try playback.transport("seek-forward")
      try require(targets == [15000], "a failed request clears the acknowledged seek anchor")
    }
  }
  for phase in ["before", "read", "mutation", "after"] {
    try reset()
    let playback = player()
    let cancellation = RequestCancellation()
    _ = try playback.transport("seek-forward", cancellation: phase == "after" ? cancellation : nil)
    let mutationsBefore = targets.count
    if phase == "after" {
      cancellation.cancel()
    } else {
      if phase == "before" { cancellation.cancel() }
      if phase == "read" { cancelOnRead = cancellation }
      if phase == "mutation" { cancelOnMutation = cancellation }
      let error = try failure("cancelled seek") {
        _ = try playback.transport("seek-forward", cancellation: cancellation)
      }
      try require((error as? URLError)?.code == .cancelled, "cancelled seeks stay cancelled")
      if phase != "mutation" {
        try require(
          targets.count == mutationsBefore, "cancellation before PUT prevents the mutation")
      }
    }
    cancelOnRead = nil
    cancelOnMutation = nil
    _ = try playback.transport("seek-forward")
    try require(
      targets.last == 15000, "cancellation cannot carry a seek anchor into a later request")
  }
  try reset()
  let offline = player()
  _ = try offline.transport("seek-forward")
  online = false
  let offlineFailure = try failure("offline seek") { _ = try offline.transport("seek-forward") }
  try require(
    (offlineFailure as? SpotifyFailure)?.isNetworkError == true,
    "offline seeking reports network loss")
  online = true
  _ = try offline.transport("seek-forward")
  try require(targets == [15000, 15000], "network failure clears the seek anchor")
  for scopes in ["user-read-playback-state", "user-modify-playback-state"] {
    try reset()
    try grant(scopes)
    let error = try failure("missing seek scope") { _ = try player().transport("seek-forward") }
    try require(
      error.localizedDescription.contains("reauth") && calls.isEmpty,
      "both read and modify scopes are required before a seek request")
  }
  try require(!targetedDevice, "seeking never changes Spotify's active output device")
  print(
    "Seek regression tests passed: paused devices, boundaries, rapid presses, provider revisions, failures, cancellation and offline isolation."
  )
}
