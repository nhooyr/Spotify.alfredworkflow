import Foundation

final class PlaybackQueue {
  private let store: MusicStore
  private let api: SpotifyAPI
  private let online: () -> Bool
  private let refreshing = NSLock()
  private var observedAccount: String?
  private static let observedKey = "playback-queue:observed"
  private static let remoteKey = "playback-queue:remote"
  private static let recentKey = "playback-queue:recent"
  private static let freshKey = "playback-queue:fresh"

  init(
    _ store: MusicStore, _ api: SpotifyAPI,
    online: @escaping () -> Bool = WebPlayback.networkAvailable
  ) {
    self.store = store
    self.api = api
    self.online = online
  }

  func observe(_ state: JSONObject) throws {
    try observe(state, accepted: true)
  }

  private func observe(_ state: JSONObject, accepted: Bool) throws {
    guard let track = normalized(dict(state["item"])) else { return }
    let context = dict(state["context"])
    try store.transaction {
      let account = text(store.get("library:account", stale: true))
      if accepted {
        observedAccount = account
      } else if observedAccount == account {
        return
      }
      var saved = dict(store.get(Self.observedKey, stale: true))
      let current = dict(saved["current"])
      let previous = dict(current["track"])
      if text(previous["uri"]) == text(track["uri"]) {
        if (try? jsonData(previous)) == (try? jsonData(track)),
          text(dict(current["context"])["uri"]) == text(context["uri"])
        {
          return
        }
        var updated = current
        updated["track"] = track
        updated["context"] = context
        saved["current"] = updated
      } else {
        var history = saved["history"] as? [JSONObject] ?? []
        if !previous.isEmpty { history.append(current) }
        saved["history"] = Array(history.suffix(100))
        saved["current"] = [
          "id": UUID().uuidString, "track": track, "context": context,
          "at": Date().timeIntervalSince1970,
        ]
      }
      try store.put(Self.observedKey, saved, ttl: 365 * 86400)
    }
  }

  func invalidate() throws {
    try store.execute("DELETE FROM responses WHERE key=?", [Self.freshKey])
  }

  func didEnqueue(_ tracks: [JSONObject]) throws {
    let added = tracks.compactMap(normalized)
    guard !added.isEmpty else { return }
    try store.transaction {
      let upcoming = store.get(Self.remoteKey, stale: true) as? [JSONObject] ?? []
      try store.put(Self.remoteKey, upcoming + added, ttl: 365 * 86400)
      // Spotify's acknowledgement can precede the updated queue response.
      try store.put(Self.freshKey, true, ttl: 2)
    }
  }

  func rows(network: Bool = false, cancellation: RequestCancellation? = nil) throws -> [JSONObject]
  {
    let account = text(store.get("library:account", stale: true))
    func checkAccount() throws {
      if cancellation?.isCancelled == true
        || text(store.get("library:account", stale: true)) != account
      {
        throw URLError(.cancelled)
      }
    }
    var failure: Error?
    if network, online(), store.get(Self.freshKey) == nil, refreshing.try() {
      defer { refreshing.unlock() }
      if store.get(Self.freshKey) == nil {
        do {
          if !api.canReadPlayback {
            throw SpotifyFailure(message: "Reconnect to Spotify to allow reading its queue.")
          }
          let result = dict(try api.request("/me/player/queue", cancellation: cancellation))
          try checkAccount()
          if let current = normalized(dict(result["currently_playing"])) {
            let saved = dict(store.get(Self.observedKey, stale: true))
            let observed = dict(saved["current"])
            let sameTrack = text(dict(observed["track"])["uri"]) == text(current["uri"])
            // Queue snapshots bootstrap the display; accepted playback owns transitions.
            try observe(
              [
                "item": current, "context": sameTrack ? observed["context"] ?? [:] : [:],
              ], accepted: false)
          }
          let upcoming = (result["queue"] as? [JSONObject] ?? []).compactMap(normalized)
          try store.put(Self.remoteKey, upcoming, ttl: 365 * 86400)
          try store.put(Self.freshKey, true, ttl: 5)
        } catch {
          if cancellation?.isCancelled == true || (error as? URLError)?.code == .cancelled {
            throw error
          }
          failure = error
        }
        if api.hasScope("user-read-recently-played"),
          (failure as? SpotifyFailure)?.status != 429
        {
          do {
            let result = dict(
              try api.request(
                "/me/player/recently-played", params: ["limit": "50"], cancellation: cancellation))
            try checkAccount()
            let recent = (result["items"] as? [JSONObject] ?? []).compactMap {
              entry -> JSONObject? in
              guard let track = normalized(dict(entry["track"])),
                let date = Self.playedDate(text(entry["played_at"]))
              else { return nil }
              return [
                "id": "spotify:" + text(entry["played_at"]) + ":" + text(track["uri"]),
                "track": track, "context": dict(entry["context"]), "at": date.timeIntervalSince1970,
              ]
            }
            try store.put(Self.recentKey, recent, ttl: 365 * 86400)
          } catch {
            if cancellation?.isCancelled == true || (error as? URLError)?.code == .cancelled {
              throw error
            }
            if failure == nil { failure = error }
          }
        }
      }
    }
    if cancellation?.isCancelled == true { throw URLError(.cancelled) }
    let observed = dict(store.get(Self.observedKey, stale: true))
    let current = dict(observed["current"])
    var history = observed["history"] as? [JSONObject] ?? []
    let recent = store.get(Self.recentKey, stale: true) as? [JSONObject] ?? []
    for entry in recent {
      let uri = text(dict(entry["track"])["uri"])
      let duplicate = history.contains {
        text(dict($0["track"])["uri"]) == uri && abs(number($0["at"]) - number(entry["at"])) < 5
      }
      let isCurrent =
        text(dict(current["track"])["uri"]) == uri
        && abs(number(current["at"]) - number(entry["at"])) < 5
      if !duplicate && !isCurrent { history.append(entry) }
    }
    history.sort { number($0["at"]) < number($1["at"]) }
    var result = Array(history.suffix(100)).map { row($0, role: "history") }
    if !dict(current["track"]).isEmpty { result.append(row(current, role: "current")) }
    let upcoming = store.get(Self.remoteKey, stale: true) as? [JSONObject] ?? []
    var occurrences: [String: Int] = [:]
    for track in upcoming {
      let uri = text(track["uri"])
      let occurrence = occurrences[uri, default: 0]
      occurrences[uri] = occurrence + 1
      result.append(
        row(["id": uri + ":" + String(occurrence), "track": track], role: "upcoming"))
    }
    if result.isEmpty, let failure = failure { throw failure }
    return result
  }

  private func normalized(_ value: JSONObject) -> JSONObject? {
    guard validTrack(text(value["uri"])), !text(value["name"]).isEmpty else { return nil }
    if text(value["kind"]) == "track" { return value }
    return fromAPI(value, kind: "track")
  }

  private func row(_ entry: JSONObject, role: String) -> JSONObject {
    var item = dict(entry["track"])
    let uri = text(item["uri"])
    item["play_uri"] = uri
    item["queue_row_id"] =
      "queue:" + (role == "upcoming" ? "upcoming:" : "played:") + text(entry["id"])
    item["queue_role"] = role
    item["queue_label"] =
      role == "current" ? "Now playing" : role == "history" ? "Played" : "Up next"
    item["symbol"] = role == "current" ? "play.fill" : "music.note"
    let context = dict(entry["context"])
    if !text(context["uri"]).isEmpty {
      item["context"] = context["uri"]
      item["playback_context"] = context
    }
    return item
  }

  private static func playedDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }
}
