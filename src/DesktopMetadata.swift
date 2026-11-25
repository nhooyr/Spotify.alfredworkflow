import Foundation

// Read only the requested key ranges from immutable tables and complete journal
// records. Spotify's database is never opened for writing or locked.
enum DesktopDatabase {
  struct Record {
    let sequence: UInt64
    let value: Data
  }
  static func read(_ directory: URL, prefixes: [Data]) -> [Data: Record] {
    let targets = Array(Set(prefixes)).sorted { $0.lexicographicallyPrecedes($1) }
    guard !targets.isEmpty else { return [:] }
    func candidate(_ key: Data) -> Data? {
      var low = 0
      var high = targets.count
      while low < high {
        let middle = (low + high) / 2
        if key.lexicographicallyPrecedes(targets[middle]) {
          high = middle
        } else {
          low = middle + 1
        }
      }
      return low > 0 ? targets[low - 1] : nil
    }
    var latest: [Data: (UInt64, Data?)] = [:]
    func record(_ key: Data, _ value: Data, sequence: UInt64, kind: UInt64) {
      guard let prefix = candidate(key), key.starts(with: prefix), kind <= 1,
        latest[key] == nil || sequence > latest[key]!.0
      else { return }
      latest[key] = (sequence, kind == 1 ? value : nil)
    }
    for file
      in (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    {
      guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
      defer { try? handle.close() }
      if file.pathExtension == "ldb" || file.pathExtension == "sst" {
        do {
          let size = try handle.seekToEnd()
          guard size >= 48 else { continue }
          try handle.seek(toOffset: size - 48)
          let footer = try handle.read(upToCount: 48) ?? Data()
          guard little(footer, 40, 8) == 0xdb47_7524_8b80_fb57 else { continue }
          func block(_ descriptor: Data) throws -> Data {
            var reader = Bytes(descriptor)
            let offset = try reader.varint()
            let size = Int(try reader.varint())
            guard size <= 16 * 1024 * 1024 else {
              throw SpotifyFailure(message: "Invalid cache block.")
            }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: size + 5) ?? Data()
            guard data.count == size + 5 else {
              throw SpotifyFailure(message: "Incomplete cache block.")
            }
            return data[size] == 1
              ? try PlaylistOrder.snappy(Data(data.prefix(size)))
              : data[size] == 0 ? Data(data.prefix(size)) : Data()
          }
          var f = Bytes(footer)
          _ = try f.varint()
          _ = try f.varint()
          var previous = Data()
          for (key, descriptor) in try PlaylistOrder.entries(
            block(Data(footer.dropFirst(f.position))))
          {
            let upper = Data(key.dropLast(8))
            if let prefix = candidate(upper),
              previous.isEmpty || previous.lexicographicallyPrecedes(prefix + Data([255]))
            {
              for (key, value) in try PlaylistOrder.entries(block(descriptor)) where key.count >= 8
              {
                let trailer = little(key, key.count - 8, 8)
                record(Data(key.dropLast(8)), value, sequence: trailer >> 8, kind: trailer & 255)
              }
            }
            previous = upper
          }
        } catch { continue }
      } else if file.pathExtension == "log" {
        guard let data = try? handle.readToEnd(), data.count < 32 * 1024 * 1024 else { continue }
        var offset = 0
        var fragments = Data()
        while offset + 7 <= data.count {
          let remaining = 32768 - offset % 32768
          if remaining < 7 {
            offset += remaining
            continue
          }
          let length = Int(little(data, offset + 4, 2))
          let type = data[offset + 6]
          guard length <= remaining - 7, offset + 7 + length <= data.count else { break }
          let chunk = data.subdata(in: offset + 7..<offset + 7 + length)
          offset += 7 + length
          if type == 1 || type == 2 {
            fragments = chunk
          } else if type == 3 || type == 4 {
            fragments += chunk
          } else {
            continue
          }
          if type != 1 && type != 4 { continue }
          do {
            guard fragments.count >= 12 else { continue }
            let sequence = little(fragments, 0, 8)
            let count = Int(little(fragments, 8, 4))
            guard count < 100000 else { continue }
            var reader = Bytes(fragments)
            reader.position = 12
            for i in 0..<count {
              let kind = try reader.take(1).first!
              let key = try reader.take(Int(reader.varint()))
              let value = kind == 1 ? try reader.take(Int(reader.varint())) : Data()
              record(key, value, sequence: sequence + UInt64(i), kind: UInt64(kind))
            }
          } catch { continue }
        }
      }
    }
    return latest.compactMapValues { sequence, value in
      value.map { Record(sequence: sequence, value: $0) }
    }
  }
}

enum DesktopMetadata {
  static func playlistKey(_ uri: String) -> Data {
    Data("!pl#slc#".utf8) + Data([UInt8(uri.utf8.count)]) + Data((uri + "#").utf8)
  }
  static func trackKey(_ uri: String) -> Data {
    Data("!xmeta#cache#".utf8) + Data([1, 42, 35, UInt8(uri.utf8.count)]) + Data((uri + "#").utf8)
  }
  struct Downloads {
    let collections: [String: [String]]
    var tracks: Set<String> { Set(collections.values.flatMap { $0 }) }
  }
  // Spotify's download manifest is separate from its metadata and streaming cache.
  // Read bounded, complete records; unknown or unfinished entries are not playable.
  static func downloads(_ data: Data) throws -> Downloads {
    guard data.count <= 8 * 1024 * 1024 else {
      throw SpotifyFailure(message: "Download manifest is too large.")
    }
    var reader = Bytes(data)
    func tag(_ expected: UInt8) throws {
      guard try reader.take(1).first == expected else {
        throw SpotifyFailure(message: "Unknown download manifest format.")
      }
    }
    func blob(_ type: UInt8) throws -> Data {
      try tag(type)
      let size = try reader.varint()
      guard size <= 1024 * 1024 else {
        throw SpotifyFailure(message: "Invalid download manifest field.")
      }
      return try reader.take(Int(size))
    }
    func count() throws -> Int {
      let value = try reader.varint()
      guard value & 7 == 4, value >> 3 <= 100000 else {
        throw SpotifyFailure(message: "Invalid download manifest count.")
      }
      return Int(value >> 3)
    }
    try tag(5)
    let collections = try count()
    var result: [String: [String]] = [:]
    for _ in 0..<collections {
      let uri = String(decoding: try blob(1), as: UTF8.self)
      guard try blob(9) == Data("_playlist".utf8) else {
        throw SpotifyFailure(message: "Unknown download manifest entry.")
      }
      try tag(13)
      let tracks = try count()
      var ready: [String] = []
      for _ in 0..<tracks {
        let gid = try blob(1)
        guard gid.count == 16 else { throw SpotifyFailure(message: "Invalid downloaded song ID.") }
        try tag(16)
        let state = try reader.varint()
        try tag(120)
        if state == 0 { ready.append("spotify:track:" + spotifyID(gid)) }
      }
      try tag(8)
      _ = try reader.varint()
      try tag(8)
      let enabled = try reader.varint()
      let error = try blob(9)
      try tag(8)
      _ = try reader.varint()
      if reader.bytes.indices.contains(reader.position), reader.bytes[reader.position] == 17 {
        _ = try blob(17)
      }
      try tag(120)
      if enabled == 1, error.isEmpty, !ready.isEmpty,
        (validURI(uri) && !validTrack(uri)) || isLikedSongsURI(uri)
      {
        result[uri] = ready
      }
    }
    return Downloads(collections: result)
  }
  static func readDownloads(_ directory: URL) -> Downloads? {
    let file = directory.deletingLastPathComponent().appendingPathComponent("offline_lists.bnk")
    guard FileManager.default.fileExists(atPath: file.path) else {
      return Downloads(collections: [:])
    }
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? downloads(data)
  }
  struct Playlist {
    let item: JSONObject
    let uris: [String]
    let complete: Bool
  }
  static func playlist(_ data: Data, uri: String) -> Playlist? {
    guard let root = try? Proto(data), let raw = root.values[3]?.first,
      let attributes = try? Proto(raw),
      !attributes.string(1).isEmpty, attributes.integers[6]?.first != 1,
      let rawContents = root.values[5]?.first, let contents = try? Proto(rawContents),
      (contents.integers[1]?.first ?? 0) == 0
    else { return nil }
    let entries = contents.values[3] ?? []
    let uris = entries.compactMap { try? Proto($0).string(1) }.filter(validTrack)
    var item: JSONObject = [
      "uri": uri, "kind": "playlist", "id": uri.components(separatedBy: ":").last ?? "",
      "name": attributes.string(1), "total": Int(root.integers[2]?.first ?? UInt64(entries.count)),
    ]
    let image = (attributes.values[13] ?? []).compactMap { try? Proto($0).string(2) }.last(
      where: DesktopCache.imageURL)
    if let image = image {
      item["image"] = image
    } else if let picture = attributes.values[3]?.first, picture.count == 20 {
      item["image"] =
        "https://i.scdn.co/image/" + picture.map { String(format: "%02x", $0) }.joined()
    }
    return Playlist(
      item: item, uris: uris,
      complete: contents.integers[2]?.first != 1
        && Int(root.integers[2]?.first ?? UInt64(entries.count)) == entries.count)
  }
  static func track(_ data: Data) -> JSONObject? {
    guard let root = try? Proto(data), let raw = root.values[2]?.first, let any = try? Proto(raw),
      any.string(1) == "type.googleapis.com/spotify.metadata.Track",
      let value = any.values[2]?.first
    else { return nil }
    return fromProto(value, kind: "track")
  }
  @discardableResult static func index(_ directory: URL, store: MusicStore) throws -> Int {
    let downloads = readDownloads(directory)
    let offline = Set(
      downloads?.collections.keys.filter { $0.hasPrefix("spotify:playlist:") } ?? store.get(
        "desktop:offline-playlists", stale: true) as? [String] ?? [])
    let wanted = Set(store.items("playlist", saved: true).map { text($0["uri"]) }).union(
      store.get("desktop:playlist-order", stale: true) as? [String] ?? []
    ).union(offline)
    let records = DesktopDatabase.read(directory, prefixes: wanted.map(playlistKey))
    let lists = wanted.compactMap { uri in
      records[playlistKey(uri)].flatMap { playlist($0.value, uri: uri) }
    }
    let referenced = Set(lists.flatMap { $0.uris }).union(downloads?.tracks ?? [])
    let missing = store.tracksNeedingArtwork(referenced)
    let metadata = DesktopDatabase.read(directory, prefixes: missing.map(trackKey))
    var changed = 0
    try store.transaction {
      try store.put("desktop:offline-playlists", Array(offline).sorted(), ttl: 365 * 86400)
      for uri in missing {
        guard let raw = metadata[trackKey(uri)], let item = track(raw.value),
          text(item["uri"]) == uri
        else { continue }
        if store.item(uri).map({ NSDictionary(dictionary: $0).isEqual(to: item) }) != true {
          changed += 1
        }
        try store.putItem(item)
        for artist in item["artists"] as? [JSONObject] ?? [] { try store.putItem(artist) }
        let album = dict(item["album"])
        if !album.isEmpty { try store.putItem(album) }
      }
      for list in lists {
        let uri = text(list.item["uri"])
        let key = "desktop:contents:" + uri
        let complete = list.complete && list.uris.allSatisfy { store.item($0) != nil }
        let snapshot: JSONObject = ["uris": list.uris, "complete": complete]
        if store.get(key, stale: true).map({
          NSDictionary(dictionary: dict($0)).isEqual(to: snapshot)
        }) != true {
          changed += 1
        }
        try store.putItem(list.item)
        try store.put(key, snapshot, ttl: 365 * 86400)
      }
      if let downloads = downloads {
        let tracks = downloads.tracks
        var available = tracks.union(downloads.collections.keys)
        for item in store.items("track") where tracks.contains(text(item["uri"])) {
          let album = dict(item["album"])
          if !text(album["uri"]).isEmpty { available.insert(text(album["uri"])) }
          for artist in (item["artists"] as? [JSONObject] ?? [])
            + (album["artists"] as? [JSONObject] ?? [])
          {
            if !text(artist["uri"]).isEmpty { available.insert(text(artist["uri"])) }
          }
        }
        let ordered = Array(available).sorted()
        if store.get("desktop:downloaded-uris", stale: true) as? [String] != ordered {
          changed += 1
        }
        try store.put("desktop:downloaded-uris", ordered, ttl: 365 * 86400)
        try store.put("desktop:offline-tracks", Array(tracks).sorted(), ttl: 365 * 86400)
      }
    }
    return changed
  }
}
