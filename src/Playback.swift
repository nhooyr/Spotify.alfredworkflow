import Foundation
import Network
import SystemConfiguration

struct PlaybackContext: Equatable {
  let uri: String
  let kind: String
  var name: String
  static let likedSongs = PlaybackContext(uri: "spotify:collection:tracks", name: "Liked Songs")!
  init?(uri: String, name: String = "") {
    if isLikedSongsURI(uri) {
      self.kind = "collection"
      self.name = "Liked Songs"
    } else {
      guard validURI(uri), !validTrack(uri) else { return nil }
      self.kind = uri.components(separatedBy: ":")[1]
      self.name = name
    }
    self.uri = uri
  }
  init?(_ value: JSONObject) { self.init(uri: text(value["uri"]), name: text(value["name"])) }
  var object: JSONObject { ["uri": uri, "kind": kind, "name": name] }
  var label: String {
    kind == "collection"
      ? "Liked Songs" : name.isEmpty ? kind.capitalized : kind.capitalized + " · " + name
  }
}

// A command acknowledgement precedes Spotify's playback-state update. Keep the
// selected source stable until a snapshot actually describes that selection.
struct PlaybackTarget {
  let uri: String
  let context: String
  let previousTrack: String
  let previousContext: String
  let allowsLocal: Bool
  var acknowledged = false
  var confirmedTrack: String?
  var displayedTrack: String?

  private var expectedContext: String { validTrack(uri) ? context : uri }
  private func sameContext(_ first: String, _ second: String) -> Bool {
    first == second || isLikedSongsURI(first) && isLikedSongsURI(second)
  }
  func acceptsContext(_ observed: String) -> Bool {
    guard !expectedContext.isEmpty else { return true }
    if isLikedSongsURI(expectedContext) {
      return observed.isEmpty || isLikedSongsURI(observed)
    }
    return observed == expectedContext
  }
  func acceptsContextEvent(track: String, context observed: String) -> Bool {
    guard acknowledged, confirmedTrack != nil, validTrack(track) else { return false }
    if !previousContext.isEmpty, sameContext(observed, previousContext),
      !acceptsContext(previousContext)
    {
      return false
    }
    let external =
      !observed.isEmpty && !sameContext(observed, previousContext)
      && !sameContext(observed, expectedContext)
    if track == previousTrack, let displayed = displayedTrack, displayed != track, !external {
      return false
    }
    return true
  }
  func acceptsWeb(_ state: JSONObject) -> Bool {
    let item = dict(state["item"])
    let track = text(item["uri"])
    guard acknowledged, validTrack(track) else { return false }
    let observedContext = text(dict(state["context"])["uri"])
    if confirmedTrack != nil { return acceptsContextEvent(track: track, context: observedContext) }
    if validTrack(uri) {
      return (track == uri || text(dict(item["linked_from"])["uri"]) == uri)
        && acceptsContext(observedContext)
    }
    if track == previousTrack {
      if let displayed = displayedTrack, displayed != track { return false }
      if isLikedSongsURI(uri), observedContext.isEmpty, !isLikedSongsURI(previousContext) {
        return false
      }
    }
    return acceptsContext(observedContext)
  }
  func acceptsLocal(_ track: String) -> Bool {
    guard validTrack(track) else { return false }
    if let confirmed = confirmedTrack {
      return track != previousTrack || confirmed == previousTrack
    }
    if validTrack(uri) { return track == uri || track == displayedTrack }
    return allowsLocal && track != previousTrack
  }
}

enum DesktopAccount {
  static func currentUserID() -> String? {
    userID(
      at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/Spotify/prefs"))
  }
  static func userID(at file: URL) -> String? {
    guard let prefs = try? String(contentsOf: file, encoding: .utf8),
      let line = prefs.split(separator: "\n").first(where: {
        $0.hasPrefix("autologin.canonical_username=")
      }),
      let raw = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).last,
      let user =
        (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed))
        as? String,
      !user.isEmpty
    else { return nil }
    return user
  }
}

final class NetworkAvailability {
  static let shared = NetworkAvailability()
  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var available = true
  private var observers: [UUID: (Bool) -> Void] = [:]
  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self = self else { return }
      self.lock.lock()
      let available = path.status != .unsatisfied
      let changed = self.available != available
      self.available = available
      let observers = Array(self.observers.values)
      self.lock.unlock()
      if changed { for observer in observers { observer(available) } }
    }
    monitor.start(queue: DispatchQueue(label: "spotify.network", qos: .utility))
  }
  func isOnline() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return available
  }
  func observe(_ observer: @escaping (Bool) -> Void) -> UUID {
    let id = UUID()
    lock.lock()
    observers[id] = observer
    let current = available
    lock.unlock()
    observer(current)
    return id
  }
  func removeObserver(_ id: UUID) {
    lock.lock()
    observers.removeValue(forKey: id)
    lock.unlock()
  }
}

struct PlaybackIntent {
  let request: Int
  let desired: Bool
  let coalesces: Bool
  private(set) var latestDesired: Bool
  var acknowledged = false
  var expiresAt = Date.distantFuture

  init(request: Int, desired: Bool, coalesces: Bool = false) {
    self.request = request
    self.desired = desired
    self.coalesces = coalesces
    latestDesired = desired
  }
  mutating func request(_ playing: Bool) {
    latestDesired = playing
  }
  func followup(after observed: Bool) -> Bool? {
    guard coalesces, acknowledged, observed == desired, latestDesired != observed else {
      return nil
    }
    return latestDesired
  }
  mutating func acknowledge(now: Date = Date()) {
    guard !acknowledged else { return }
    acknowledged = true
    expiresAt = now.addingTimeInterval(3)
  }
  func accepts(_ observed: Bool, now: Date = Date()) -> Bool {
    acknowledged && (observed == desired || now >= expiresAt)
  }
}

// Kept on the backend's playback queue, separate from library sync and status polling.
final class WebPlayback {
  private let api: SpotifyAPI
  private let store: MusicStore?
  private let desktopUserID: () -> String?
  private let computerName: String
  private let online: () -> Bool
  private let wait: (TimeInterval) -> Void
  private var deviceID: String?

  init(
    _ api: SpotifyAPI, store: MusicStore? = nil,
    computerName: String = SCDynamicStoreCopyComputerName(nil, nil) as String?
      ?? ProcessInfo.processInfo.hostName,
    online: @escaping () -> Bool = WebPlayback.networkAvailable,
    wait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
    desktopUserID: @escaping () -> String? = DesktopAccount.currentUserID
  ) {
    self.api = api
    self.store = store
    self.computerName = computerName
    self.online = online
    self.wait = wait
    self.desktopUserID = desktopUserID
  }
  func isDesktopDevice(_ device: JSONObject) -> Bool {
    text(device["type"]).lowercased() == "computer"
      && text(device["name"]).compare(
        computerName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
  }
  static func networkAvailable() -> Bool { NetworkAvailability.shared.isOnline() }
  static func payload(_ uri: String, context: String) throws -> JSONObject {
    guard validPlaybackURI(uri), context.isEmpty || validURI(context) else {
      throw SpotifyFailure(message: "This selection cannot be played in Spotify.")
    }
    if validTrack(uri) {
      if context.hasPrefix("spotify:album:") || context.hasPrefix("spotify:playlist:") {
        return ["context_uri": context, "offset": ["uri": uri], "position_ms": 0]
      }
      return ["uris": [uri], "position_ms": 0]
    }
    return ["context_uri": uri, "position_ms": 0]
  }
  static func collectionURI(userID: String) -> String? {
    guard !userID.isEmpty,
      let encoded = userID.addingPercentEncoding(
        withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
    else { return nil }
    return "spotify:user:" + encoded + ":collection"
  }
  private var cachedLikedSongsURI: String? {
    guard let uri = store?.get("playback:liked-songs-uri", stale: true) as? String,
      isLikedSongsURI(uri), uri != PlaybackContext.likedSongs.uri
    else { return nil }
    return uri
  }
  private func likedSongsURI(_ cancellation: RequestCancellation?) throws -> String {
    if let cached = cachedLikedSongsURI { return cached }
    let profile = dict(try api.request("/me", timeout: 2, cancellation: cancellation))
    guard let uri = Self.collectionURI(userID: text(profile["id"])) else {
      throw SpotifyFailure(message: "Spotify did not return an account ID for Liked Songs.")
    }
    try store?.useAccount(text(profile["id"]), cancellation: cancellation)
    return uri
  }
  func fallbackURI(_ uri: String) throws -> String {
    guard uri == PlaybackContext.likedSongs.uri else { return uri }
    if let id = desktopUserID(), let collection = Self.collectionURI(userID: id) {
      return collection
    }
    if let cached = cachedLikedSongsURI { return cached }
    throw SpotifyFailure(
      message: "Sign in to the Spotify desktop app or connect online once to play all Liked Songs.")
  }
  private func desktopDevice(_ cancellation: RequestCancellation? = nil) throws -> String {
    if let deviceID = deviceID { return deviceID }
    let devices =
      dict(try api.request("/me/player/devices", timeout: 2, cancellation: cancellation))["devices"]
      as? [JSONObject] ?? []
    if let active = devices.first(where: { $0["is_active"] as? Bool == true }),
      !isDesktopDevice(active)
    {
      throw SpotifyFailure(message: "Spotify playback moved to another device. Try again.")
    }
    let candidates = devices.filter {
      text($0["type"]) == "Computer" && $0["is_restricted"] as? Bool != true
        && text($0["name"]).compare(
          computerName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        && !text($0["id"]).isEmpty
    }
    guard
      let device = candidates.first(where: { $0["is_active"] as? Bool == true }) ?? candidates.first
    else {
      throw SpotifyFailure(
        message: "Spotify’s desktop player is not available through the Web API.", status: 404,
        requiresDesktopStart: true)
    }
    let id = text(device["id"])
    deviceID = id
    return id
  }
  func prepare(cancellation: RequestCancellation? = nil) {
    guard online(), api.hasScope("user-read-playback-state"),
      number(((try? api.paths.authorization.load()) ?? [:])["expires_at"]) > Date()
        .timeIntervalSince1970 + 60
    else { return }
    _ = try? likedSongsURI(cancellation)
  }
  static func appleScriptCommand(for result: JSONObject, offline: Bool, remote: Bool) -> String? {
    guard result["fallback"] as? Bool == true else { return nil }
    let command = text(result["command"])
    if ["toggle", "pause", "resume"].contains(command),
      text(result["fallback_reason"]) == "missing-playback-state"
    {
      return command
    }
    guard offline && !remote else { return nil }
    return command
  }
  func transport(_ command: String, cancellation: RequestCancellation? = nil) throws -> JSONObject {
    if cancellation?.isCancelled == true { throw URLError(.cancelled) }
    guard online() else {
      throw SpotifyFailure(message: "Spotify is offline.", isNetworkError: true)
    }
    guard api.hasScope("user-modify-playback-state") else {
      throw SpotifyFailure(
        message: "Run \(api.paths.command("reauth")) to allow controlling Spotify playback.")
    }
    var command = command
    var state: JSONObject = [:]
    if command == "toggle" {
      guard api.canReadPlayback else {
        throw SpotifyFailure(
          message: "Run \(api.paths.command("reauth")) to allow reading Spotify playback state.")
      }
      state = dict(try api.request("/me/player", timeout: 2, cancellation: cancellation))
      guard let playing = state["is_playing"] as? Bool else {
        return ["fallback": true, "fallback_reason": "missing-playback-state"]
      }
      command = playing ? "pause" : "resume"
    }
    let path: String
    let method: String
    let playing: Bool?
    var params: [String: String] = [:]
    switch command {
    case "pause": (path, method, playing) = ("pause", "PUT", false)
    case "resume": (path, method, playing) = ("play", "PUT", true)
    case "next": (path, method, playing) = ("next", "POST", nil)
    case "previous": (path, method, playing) = ("previous", "POST", nil)
    case "shuffle-on", "shuffle-off":
      (path, method, playing) = ("shuffle", "PUT", nil)
      params["state"] = command == "shuffle-on" ? "true" : "false"
    default: throw SpotifyFailure(message: "Unknown Spotify playback command.")
    }
    // An omitted device_id keeps control on Spotify's current output device.
    do {
      _ = try api.request(
        "/me/player/" + path, params: params, method: method, timeout: 2, expectJSON: false,
        cancellation: cancellation)
    } catch let failure as SpotifyFailure
      where playing != nil && [403, 404].contains(failure.status)
    {
      do {
        state = dict(try api.request("/me/player", timeout: 2, cancellation: cancellation))
      } catch {
        if cancellation?.isCancelled == true || (error as? URLError)?.code == .cancelled {
          throw URLError(.cancelled)
        }
        throw failure
      }
      if cancellation?.isCancelled == true { throw URLError(.cancelled) }
      guard let observed = state["is_playing"] as? Bool else {
        return ["fallback": true, "fallback_reason": "missing-playback-state"]
      }
      guard observed == playing else { throw failure }
    }
    var result: JSONObject = [:]
    if let playing = playing {
      result["playing"] = playing
      if !state.isEmpty {
        state["is_playing"] = playing
        result["state"] = state
      }
    }
    return result
  }
  func play(
    _ uri: String, context: String = "", recentlyLaunched: Bool = false,
    cancellation: RequestCancellation? = nil
  ) throws {
    var body = try Self.payload(uri, context: context)
    if cancellation?.isCancelled == true { throw URLError(.cancelled) }
    guard online() else {
      throw SpotifyFailure(message: "Spotify is offline.", isNetworkError: true)
    }
    guard api.hasScope("user-modify-playback-state"), api.hasScope("user-read-playback-state")
    else {
      throw SpotifyFailure(
        message:
          "Run \(api.paths.command("reauth")) to allow starting playback, then open Spotify Mini Player again."
      )
    }
    if uri == PlaybackContext.likedSongs.uri {
      body = try Self.payload(likedSongsURI(cancellation), context: context)
    }
    do {
      _ = try api.request(
        "/me/player/play", method: "PUT", body: body, timeout: 2, expectJSON: false,
        cancellation: cancellation)
      return
    } catch let error as SpotifyFailure where error.status == 404 {
      let state = dict(try api.request("/me/player", timeout: 2, cancellation: cancellation))
      guard state.isEmpty || state["device"] is NSNull else { throw error }
    }
    // Bootstrap the desktop only after Spotify confirms there is no current device.
    deviceID = nil
    let attempts = recentlyLaunched ? 6 : 2
    let deadline = Date().addingTimeInterval(recentlyLaunched ? 4 : 2.5)
    for attempt in 0..<attempts {
      do {
        if cancellation?.isCancelled == true { throw URLError(.cancelled) }
        let id = try desktopDevice(cancellation)
        _ = try api.request(
          "/me/player/play", params: ["device_id": id], method: "PUT", body: body, timeout: 2,
          expectJSON: false, cancellation: cancellation)
        return
      } catch let error as SpotifyFailure
        where error.status == 404 && attempt + 1 < attempts && Date() < deadline
      {
        deviceID = nil
        if cancellation?.isCancelled == true { throw URLError(.cancelled) }
        if recentlyLaunched { wait(0.2) }
      }
    }
  }
}
