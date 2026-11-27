import Foundation

final class PlaybackQueue {
  private let store: MusicStore
  private let api: SpotifyAPI
  private let online: () -> Bool
  private let refreshing = NSLock()
  private static let observedKey = "playback-queue:observed"
  private static let seedKey = "playback-queue:seed"
  private static let remoteKey = "playback-queue:remote"
  private static let occurrencesKey = "playback-queue:upcoming-occurrences"
  private static let reconciliationKey = "playback-queue:reconciliation"
  private static let recentKey = "playback-queue:recent"
  private static let freshKey = "playback-queue:fresh"

  var needsReconciliation: Bool {
    store.get(Self.reconciliationKey, stale: true) as? Bool == true
  }

  init(
    _ store: MusicStore, _ api: SpotifyAPI,
    online: @escaping () -> Bool = WebPlayback.networkAvailable
  ) {
    self.store = store
    self.api = api
    self.online = online
  }

  @discardableResult func observe(_ state: JSONObject) throws -> Bool {
    guard var track = normalized(dict(state["item"])) else { return false }
    var changed = false
    try store.transaction {
      let context = dict(state["context"])
      var saved = dict(store.get(Self.observedKey, stale: true))
      let seed = dict(store.get(Self.seedKey, stale: true))
      let current = dict(saved["current"])
      let previous = dict(current["track"])
      var history = saved["history"] as? [JSONObject] ?? []
      if !Self.sameTrack(previous, track),
        let known = history.reversed().first(where: {
          Self.sameTrack(dict($0["track"]), track)
            && Self.aliases(dict($0["track"])).count > 1
        })
      {
        track = Self.retainingIdentity(track, from: dict(known["track"]))
      }
      let sampled = (state["observed_at"] as? NSNumber)?.doubleValue
      let at =
        sampled.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        ?? Date().timeIntervalSince1970
      var updated: JSONObject
      let same = Self.sameTrack(previous, track)
      if same {
        track = Self.retainingIdentity(track, from: previous)
        updated = current
        changed =
          (try? jsonData(previous)) != (try? jsonData(track))
          || (try? jsonData(dict(current["context"]))) != (try? jsonData(context))
      } else {
        if !previous.isEmpty {
          history.append(current)
        }
        saved["history"] = Array(history.suffix(100))
        let seedID = Self.sameTrack(dict(seed["track"]), track) ? text(seed["id"]) : ""
        updated = [
          "id": seedID.isEmpty ? UUID().uuidString : seedID, "at": at,
        ]
        changed =
          !previous.isEmpty || seedID.isEmpty
          || (try? jsonData(dict(seed["track"]))) != (try? jsonData(track))
          || (try? jsonData(dict(seed["context"]))) != (try? jsonData(context))
      }
      updated["track"] = track
      updated["context"] = context
      if updated["playback_timestamp_ms"] == nil,
        let timestamp = (state["timestamp"] as? NSNumber)?.doubleValue,
        timestamp.isFinite, timestamp >= 0, timestamp < Double(Int64.max)
      {
        updated["playback_timestamp_ms"] = Int64(timestamp.rounded())
        changed = true
      }
      if !same || (try? jsonData(updated)) != (try? jsonData(current)) {
        saved["current"] = updated
        try store.put(Self.observedKey, saved, ttl: 365 * 86400)
      }
      if !seed.isEmpty { try store.execute("DELETE FROM responses WHERE key=?", [Self.seedKey]) }
    }
    return changed
  }

  private func seed(_ track: JSONObject) throws {
    let saved = dict(store.get(Self.observedKey, stale: true))
    guard dict(dict(saved["current"])["track"]).isEmpty else { return }
    let previous = dict(store.get(Self.seedKey, stale: true))
    let same = Self.sameTrack(dict(previous["track"]), track)
    let updated = same ? Self.retainingIdentity(track, from: dict(previous["track"])) : track
    if (try? jsonData(dict(previous["track"]))) == (try? jsonData(updated)) { return }
    try store.put(
      Self.seedKey,
      [
        "id": same ? text(previous["id"]) : UUID().uuidString,
        "track": updated, "at": same ? number(previous["at"]) : Date().timeIntervalSince1970,
      ], ttl: 365 * 86400)
  }

  func invalidate() throws {
    try store.execute("DELETE FROM responses WHERE key=?", [Self.freshKey])
  }

  func didEnqueue(
    _ tracks: [JSONObject], expectedAccount: String, cancellation: RequestCancellation? = nil
  ) throws {
    let added = tracks.compactMap(normalized)
    guard !added.isEmpty else { return }
    try store.transaction {
      guard cancellation?.isCancelled != true,
        text(store.get("library:account", stale: true)) == expectedAccount
      else { throw URLError(.cancelled) }
      let upcoming = store.get(Self.remoteKey, stale: true) as? [JSONObject] ?? []
      try saveUpcoming(upcoming + added)
      // Spotify's acknowledgement can precede the updated queue response.
      try store.put(Self.freshKey, true, ttl: 2)
      if cancellation?.isCancelled == true { throw URLError(.cancelled) }
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
          let observedID = text(
            dict(dict(store.get(Self.observedKey, stale: true))["current"])["id"])
          let result = dict(try api.request("/me/player/queue", cancellation: cancellation))
          let upcoming = (result["queue"] as? [JSONObject] ?? []).compactMap(normalized)
          try store.transaction {
            try checkAccount()
            let accepted = dict(dict(store.get(Self.observedKey, stale: true))["current"])
            let current = normalized(dict(result["currently_playing"]))
            guard text(accepted["id"]) == observedID,
              dict(accepted["track"]).isEmpty
                || current.map({ Self.sameTrack(dict(accepted["track"]), $0) }) == true
            else {
              try store.put(Self.reconciliationKey, true, ttl: 365 * 86400)
              try checkAccount()
              return
            }
            if let current = current { try seed(current) }
            try saveUpcoming(upcoming)
            try store.execute("DELETE FROM responses WHERE key=?", [Self.reconciliationKey])
            try store.put(Self.freshKey, true, ttl: 5)
            try checkAccount()
          }
        } catch {
          if cancellation?.isCancelled == true || (error as? URLError)?.code == .cancelled {
            throw error
          }
          try store.transaction {
            try checkAccount()
            try store.execute("DELETE FROM responses WHERE key=?", [Self.reconciliationKey])
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
            let recent = (result["items"] as? [JSONObject] ?? []).compactMap {
              entry -> JSONObject? in
              guard let track = normalized(dict(entry["track"])),
                let date = Self.playedDate(text(entry["played_at"]))
              else { return nil }
              return [
                "id": Self.recentID(track, at: date.timeIntervalSince1970),
                "track": track, "context": dict(entry["context"]), "at": date.timeIntervalSince1970,
              ]
            }
            try store.transaction {
              try checkAccount()
              try store.put(Self.recentKey, recent, ttl: 365 * 86400)
              try checkAccount()
            }
          } catch {
            if cancellation?.isCancelled == true || (error as? URLError)?.code == .cancelled {
              throw error
            }
            if (error as? SpotifyFailure)?.status == 429 {
              try store.transaction {
                try checkAccount()
                try store.execute("DELETE FROM responses WHERE key=?", [Self.reconciliationKey])
              }
            }
            if failure == nil { failure = error }
          }
        }
      }
    }
    var result: [JSONObject] = []
    try store.transaction {
      try checkAccount()
      let observed = dict(store.get(Self.observedKey, stale: true))
      let accepted = dict(observed["current"])
      let current =
        dict(accepted["track"]).isEmpty
        ? dict(store.get(Self.seedKey, stale: true)) : accepted
      let history = observed["history"] as? [JSONObject] ?? []
      let recent = store.get(Self.recentKey, stale: true) as? [JSONObject] ?? []
      result = mergedHistory(history, current: current, recent: recent).map {
        row($0, role: "history")
      }
      if !dict(current["track"]).isEmpty { result.append(row(current, role: "current")) }
      let upcoming = store.get(Self.remoteKey, stale: true) as? [JSONObject] ?? []
      result += try upcomingEntries(upcoming).map { row($0, role: "upcoming") }
      try checkAccount()
    }
    if result.isEmpty, let failure = failure { throw failure }
    return result
  }

  private func saveUpcoming(_ tracks: [JSONObject]) throws {
    _ = try upcomingEntries(tracks)
    try store.put(Self.remoteKey, tracks, ttl: 365 * 86400)
  }

  private func upcomingEntries(_ tracks: [JSONObject]) throws -> [JSONObject] {
    let previous = store.get(Self.occurrencesKey, stale: true) as? [JSONObject] ?? []
    let known = previous.map { dict($0["track"]) }
    var matches: [Int: Int] = [:]
    if known.count <= tracks.count,
      zip(known, tracks).allSatisfy({ Self.sameTrack($0, $1) })
    {
      for index in known.indices { matches[index] = index }
    } else if tracks.count < known.count,
      let start = known.indices.first(where: { start in
        let count = known.count - start
        return count <= tracks.count
          && zip(known[start...], tracks).allSatisfy { Self.sameTrack($0, $1) }
      })
    {
      for index in start..<known.count { matches[index - start] = index }
    } else if !known.isEmpty, !tracks.isEmpty {
      var lengths = Array(
        repeating: Array(repeating: 0, count: tracks.count + 1), count: known.count + 1)
      for old in known.indices {
        for new in tracks.indices {
          lengths[old + 1][new + 1] =
            Self.sameTrack(known[old], tracks[new])
            ? lengths[old][new] + 1
            : max(lengths[old][new + 1], lengths[old + 1][new])
        }
      }
      var old = known.count
      var new = tracks.count
      while old > 0, new > 0 {
        if Self.sameTrack(known[old - 1], tracks[new - 1]) {
          matches[new - 1] = old - 1
          old -= 1
          new -= 1
        } else if lengths[old - 1][new] > lengths[old][new - 1] {
          old -= 1
        } else {
          new -= 1
        }
      }
    }
    let entries = tracks.enumerated().map { index, track -> JSONObject in
      if let old = matches[index] {
        return [
          "id": text(previous[old]["id"]),
          "track": Self.retainingIdentity(track, from: known[old]),
        ]
      }
      return ["id": UUID().uuidString, "track": track]
    }
    if (try? jsonData(entries)) != (try? jsonData(previous)) {
      try store.put(Self.occurrencesKey, entries, ttl: 365 * 86400)
    }
    return entries
  }

  private func normalized(_ value: JSONObject) -> JSONObject? {
    guard validTrack(text(value["uri"])), !text(value["name"]).isEmpty else { return nil }
    guard var item = text(value["kind"]) == "track" ? value : fromAPI(value, kind: "track") else {
      return nil
    }
    let linked = text(dict(value["linked_from"])["uri"])
    if validTrack(linked) { item["linked_from"] = ["uri": linked] }
    return Self.retainingIdentity(item, from: item)
  }

  static func canonicalURI(_ track: JSONObject) -> String {
    let known = text(track["queue_canonical_uri"])
    if aliases(track).contains(known) { return known }
    let linked = text(dict(track["linked_from"])["uri"])
    return validTrack(linked) ? linked : text(track["uri"])
  }

  static func sameTrack(_ first: JSONObject, _ second: JSONObject) -> Bool {
    guard validTrack(text(first["uri"])), validTrack(text(second["uri"])) else { return false }
    return !aliases(first).isDisjoint(with: aliases(second))
  }

  private static func aliases(_ track: JSONObject) -> Set<String> {
    Set(
      ((track["queue_aliases"] as? [String] ?? [])
        + [text(track["uri"]), text(dict(track["linked_from"])["uri"])])
        .filter(validTrack))
  }

  private static func retainingIdentity(_ incoming: JSONObject, from known: JSONObject)
    -> JSONObject
  {
    guard sameTrack(incoming, known) else { return incoming }
    var result = incoming
    let combined = aliases(incoming).union(aliases(known))
    guard combined.count > 1 else { return result }
    result["queue_aliases"] = combined.sorted()
    result["queue_canonical_uri"] = canonicalURI(known)
    if text(incoming["uri"]) == text(known["uri"]),
      !validTrack(text(dict(incoming["linked_from"])["uri"])),
      validTrack(text(dict(known["linked_from"])["uri"]))
    {
      result["linked_from"] = known["linked_from"]
    }
    return result
  }

  private static func recentID(_ track: JSONObject, at: Double) -> String {
    "spotify:" + String(Int64((at * 1000).rounded())) + ":" + canonicalURI(track)
  }

  private func mergedHistory(
    _ history: [JSONObject], current: JSONObject, recent: [JSONObject]
  ) -> [JSONObject] {
    let known = history + [current]
    var seen = Set<String>()
    let remote = recent.compactMap { entry -> JSONObject? in
      guard var track = normalized(dict(entry["track"])) else { return nil }
      if let identity = known.reversed().first(where: {
        Self.sameTrack(dict($0["track"]), track)
          && Self.aliases(dict($0["track"])).count > 1
      }) {
        track = Self.retainingIdentity(track, from: dict(identity["track"]))
      }
      var entry = entry
      let id = Self.recentID(track, at: number(entry["at"]))
      guard seen.insert(id).inserted else { return nil }
      entry["id"] = id
      entry["track"] = track
      return entry
    }
    var matched = Set<Int>()
    var matchedTimes: [String: Double] = [:]
    for entry in (history + [current]).sorted(by: { number($0["at"]) < number($1["at"]) }) {
      guard let timestamp = (entry["playback_timestamp_ms"] as? NSNumber)?.int64Value else {
        continue
      }
      if let index = remote.indices.first(where: {
        !matched.contains($0) && Self.sameTrack(dict(entry["track"]), dict(remote[$0]["track"]))
          && Int64((number(remote[$0]["at"]) * 1000).rounded()) == timestamp
      }) {
        matched.insert(index)
        matchedTimes[text(entry["id"])] = number(remote[index]["at"])
      }
    }
    let local = history.map { entry -> JSONObject in
      guard let at = matchedTimes[text(entry["id"])] else { return entry }
      var ordered = entry
      ordered["at"] = at
      return ordered
    }
    var combined =
      local
      + remote.enumerated().compactMap { index, entry in
        matched.contains(index) ? nil : entry
      }
    combined.sort { number($0["at"]) < number($1["at"]) }
    return Array(combined.suffix(100))
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
