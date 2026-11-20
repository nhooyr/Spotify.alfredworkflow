import Foundation

struct Bytes {
  var bytes: [UInt8]
  var position = 0
  init(_ data: Data) { bytes = Array(data) }
  mutating func varint() throws -> UInt64 {
    var result: UInt64 = 0
    for shift in stride(from: 0, through: 63, by: 7) {
      guard position < bytes.count else { throw SpotifyFailure(message: "Truncated cache record.") }
      let byte = bytes[position]
      position += 1
      result |= UInt64(byte & 127) << shift
      if byte < 128 { return result }
    }
    throw SpotifyFailure(message: "Invalid cache integer.")
  }
  mutating func take(_ count: Int) throws -> Data {
    guard count >= 0, position <= bytes.count - count else {
      throw SpotifyFailure(message: "Truncated cache record.")
    }
    defer { position += count }
    return Data(bytes[position..<position + count])
  }
}
func little(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
  guard offset >= 0, offset + count <= data.count else { return 0 }
  return (0..<count).reduce(0) { $0 | UInt64(data[data.startIndex + offset + $1]) << ($1 * 8) }
}
struct Proto {
  var values: [Int: [Data]] = [:]
  var integers: [Int: [UInt64]] = [:]
  init(_ data: Data) throws {
    var reader = Bytes(data)
    while reader.position < reader.bytes.count {
      let tag = try reader.varint()
      let key = Int(tag >> 3)
      guard key > 0 else { throw SpotifyFailure(message: "Invalid cached metadata.") }
      switch tag & 7 {
      case 0: integers[key, default: []].append(try reader.varint())
      case 1: _ = try reader.take(8)
      case 2:
        let length = try reader.varint()
        guard length <= 16 * 1024 * 1024 else {
          throw SpotifyFailure(message: "Invalid cached metadata length.")
        }
        values[key, default: []].append(try reader.take(Int(length)))
      case 5: _ = try reader.take(4)
      default: throw SpotifyFailure(message: "Unknown cached metadata format.")
      }
    }
  }
  func string(_ field: Int) -> String {
    values[field]?.first.flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }
}
func spotifyID(_ bytes: Data) -> String {
  guard bytes.count == 16 else { return "" }
  let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
  var value = Array(bytes)
  var output = ""
  while value.contains(where: { $0 != 0 }) {
    var remainder = 0
    for i in value.indices {
      let next = remainder * 256 + Int(value[i])
      value[i] = UInt8(next / 62)
      remainder = next % 62
    }
    output.insert(alphabet[remainder], at: output.startIndex)
  }
  return String(repeating: "0", count: max(0, 22 - output.count)) + output
}
func fromAPI(_ value: JSONObject, kind: String? = nil) -> JSONObject? {
  let uri = text(value["uri"])
  let kind = kind ?? text(value["type"])
  guard validURI(uri), !text(value["name"]).isEmpty else { return nil }
  var item: JSONObject = [
    "uri": uri, "kind": kind, "id": text(value["id"]), "name": text(value["name"]),
  ]
  let album = dict(value["album"])
  let images = value["images"] as? [JSONObject] ?? album["images"] as? [JSONObject] ?? []
  item["image"] = text(images.first?["url"])
  item["artists"] = (value["artists"] as? [JSONObject] ?? []).compactMap {
    fromAPI($0, kind: "artist")
  }
  if kind == "track" {
    item["album"] = fromAPI(album, kind: "album") ?? [:]
    for key in ["duration_ms", "disc_number", "track_number", "is_playable", "is_local"] {
      item[key] = value[key]
    }
  }
  if kind == "album" {
    item["year"] = String(text(value["release_date"]).prefix(4))
    item["total"] = value["total_tracks"]
  }
  if kind == "playlist" { item["total"] = dict(value["items"] ?? value["tracks"])["total"] }
  return item
}
func fromDesktop(_ value: JSONObject, kind: String, depth: Int = 0) -> JSONObject? {
  guard depth < 8 else { return nil }
  let hex = text(value["gid"])
  guard hex.count == 32 else { return nil }
  var bytes = Data()
  var offset = hex.startIndex
  while offset < hex.endIndex {
    let end = hex.index(offset, offsetBy: 2)
    guard let byte = UInt8(hex[offset..<end], radix: 16) else { return nil }
    bytes.append(byte)
    offset = end
  }
  let id = spotifyID(bytes)
  guard !id.isEmpty, !text(value["name"]).isEmpty else { return nil }
  var item: JSONObject = [
    "uri": "spotify:\(kind):\(id)", "kind": kind, "id": id, "name": text(value["name"]),
  ]
  let images =
    dict(value[kind == "artist" ? "portrait_group" : "cover_group"])["image"] as? [JSONObject] ?? []
  item["image"] =
    images.reversed().compactMap { value -> String? in
      let id = text(value["file_id"])
      return id.count == 40 ? "https://i.scdn.co/image/" + id.lowercased() : nil
    }.first ?? ""
  item["artists"] = (value["artist"] as? [JSONObject] ?? []).compactMap {
    fromDesktop($0, kind: "artist", depth: depth + 1)
  }
  if kind == "track" {
    let album = fromDesktop(dict(value["album"]), kind: "album", depth: depth + 1) ?? [:]
    item["album"] = album
    item["image"] = text(album["image"])
    item["duration_ms"] = value["duration"]
    item["track_number"] = value["number"]
    item["disc_number"] = value["disc_number"]
  } else if kind == "album" {
    item["year"] = dict(value["date"])["year"].map { String(describing: $0) } ?? ""
    let entries = (value["disc"] as? [JSONObject] ?? []).flatMap {
      $0["track"] as? [JSONObject] ?? []
    }
    if !entries.isEmpty { item["total"] = entries.count }
    var tracks = entries.compactMap { fromDesktop($0, kind: "track", depth: depth + 1) }
    for i in tracks.indices {
      tracks[i]["album"] = item
      tracks[i]["image"] = item["image"]
    }
    item["tracks"] = tracks
  } else if kind == "artist" {
    item["albums"] = ["album_group", "single_group", "compilation_group"].flatMap {
      value[$0] as? [JSONObject] ?? []
    }.flatMap { $0["album"] as? [JSONObject] ?? [] }.compactMap {
      fromDesktop($0, kind: "album", depth: depth + 1)
    }
  }
  return item
}
func fromProto(_ data: Data, kind: String, depth: Int = 0) -> JSONObject? {
  guard depth < 7, let p = try? Proto(data), let gid = p.values[1]?.first else { return nil }
  let id = spotifyID(gid)
  guard !id.isEmpty, !p.string(2).isEmpty else { return nil }
  var item: JSONObject = [
    "uri": "spotify:\(kind):\(id)", "kind": kind, "id": id, "name": p.string(2),
  ]
  func covers(_ direct: Int, _ group: Int) -> String {
    let blobs =
      (p.values[direct] ?? [])
      + (p.values[group] ?? []).flatMap { (try? Proto($0).values[1]) ?? [] }
    return blobs.compactMap { (try? Proto($0).values[1]?.first) ?? nil }.filter { $0.count == 20 }
      .last.map { "https://i.scdn.co/image/" + $0.map { String(format: "%02x", $0) }.joined() }
      ?? ""
  }
  item["image"] = kind == "artist" ? covers(11, 17) : covers(9, 17)
  item["artists"] = (p.values[kind == "track" ? 4 : 3] ?? []).compactMap {
    fromProto($0, kind: "artist", depth: depth + 1)
  }
  if kind == "track" {
    let album = p.values[3]?.first.flatMap { fromProto($0, kind: "album", depth: depth + 1) } ?? [:]
    item["album"] = album
    item["image"] = album["image"]
    for (field, key) in [(5, "track_number"), (6, "disc_number"), (7, "duration_ms")] {
      let n = p.integers[field]?.first ?? 0
      item[key] = Int64(n >> 1) ^ -Int64(n & 1)
    }
  }
  if kind == "album" {
    let year = p.values[6]?.first.flatMap { try? Proto($0).integers[1]?.first } ?? 0
    item["year"] = String(year >> 1)
    let entries = (p.values[11] ?? []).flatMap { (try? Proto($0).values[1]) ?? [] }
    if !entries.isEmpty { item["total"] = entries.count }
    var tracks = entries.compactMap { fromProto($0, kind: "track", depth: depth + 1) }
    for i in tracks.indices {
      tracks[i]["album"] = item
      tracks[i]["image"] = item["image"]
    }
    item["tracks"] = tracks
  }
  if kind == "artist" {
    item["albums"] = [5, 6, 7].flatMap { p.values[$0] ?? [] }.flatMap {
      (try? Proto($0).values[1]) ?? []
    }.compactMap { fromProto($0, kind: "album", depth: depth + 1) }
  }
  return item
}

final class DesktopCache {
  static let maxBody = 8 * 1024 * 1024
  let paths: WorkflowPaths
  let store: MusicStore
  let session: URLSession
  private final class ImageRequest { var result: Result<String?, Error>? }
  private let imageCondition = NSCondition()
  private var imageRequests: [String: ImageRequest] = [:]
  init(_ paths: WorkflowPaths, _ store: MusicStore, session: URLSession? = nil) {
    self.paths = paths
    self.store = store
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 6
    config.timeoutIntervalForResource = 6
    self.session = session ?? URLSession(configuration: config)
  }
  static func isImage(_ data: Data) -> Bool {
    data.count <= maxBody
      && (data.starts(with: [0xff, 0xd8, 0xff])
        || data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        || (data.count > 12 && data.starts(with: Data("RIFF".utf8))
          && data[8..<12] == Data("WEBP".utf8)))
  }
  // Preserve covers independently of Spotify's evictable HTTP cache. Copy local
  // entries first; the optional network pass only fills genuinely missing art.
  @discardableResult func preserveArtwork(downloadMissing: Bool = false) throws -> Int {
    var seen = Set<String>()
    var copied = 0
    var protected: Set<String>?
    for item in store.items("track", saved: true) + store.items() {
      let url = text(item["image"])
      guard Self.imageURL(url), seen.insert(url).inserted else { continue }
      let output = paths.cache.appendingPathComponent("artwork/" + sha256(Data(url.utf8)) + ".img")
      if store.get("evicted-art:" + output.lastPathComponent, stale: true) != nil {
        if protected == nil { protected = protectedArtwork() }
        if protected?.contains(output.lastPathComponent) != true { continue }
      }
      if FileManager.default.fileExists(atPath: output.path) { continue }
      do { if try image(url, download: downloadMissing) != nil { copied += 1 } } catch let error
        as SpotifyFailure where error.isNetworkError
      { break }
    }
    return copied
  }
  // The limit is soft: never evict saved/downloaded-library art or art used
  // within the last day just to reach it. Only our own artwork files qualify.
  @discardableResult func prune(maxBytes: Int64 = 1_000_000_000, now: Date = Date()) throws -> Int {
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    guard
      let files = FileManager.default.enumerator(
        at: paths.cache, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
    else { return 0 }
    let art = paths.cache.appendingPathComponent("artwork").standardizedFileURL
    var bytes: Int64 = 0
    var candidates: [(URL, Int64, Date)] = []
    let cutoff = now.addingTimeInterval(-86400)
    for case let file as URL in files {
      guard let values = try? file.resourceValues(forKeys: keys) else { continue }
      if values.isSymbolicLink == true {
        files.skipDescendants()
        continue
      }
      guard values.isRegularFile == true else { continue }
      let size = Int64(values.fileSize ?? 0)
      bytes += size
      if file.deletingLastPathComponent().standardizedFileURL == art,
        file.lastPathComponent.range(of: #"^[a-f0-9]{64}\.img$"#, options: .regularExpression)
          != nil,
        let modified = values.contentModificationDate, modified < cutoff
      {
        candidates.append((file, size, modified))
      }
    }
    guard bytes > maxBytes else { return 0 }
    let protected = protectedArtwork()
    var removed = 0
    for (file, size, _) in candidates.sorted(by: { $0.2 < $1.2 }) {
      if bytes <= maxBytes * 9 / 10 { break }
      guard !protected.contains(file.lastPathComponent),
        let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate,
        modified < cutoff
      else { continue }
      do {
        try FileManager.default.removeItem(at: file)
        try store.put("evicted-art:" + file.lastPathComponent, true, ttl: 365 * 86400)
        bytes -= size
        removed += 1
      } catch { continue }
    }
    return removed
  }
  private func protectedArtwork() -> Set<String> {
    let saved = store.items(saved: true)
    let albums = Set(saved.filter { text($0["kind"]) == "album" }.map { text($0["uri"]) })
    let playlists = Set(saved.filter { text($0["kind"]) == "playlist" }.map { text($0["uri"]) })
      .union(store.get("desktop:playlist-order", stale: true) as? [String] ?? [])
      .union(store.get("desktop:offline-playlists", stale: true) as? [String] ?? [])
    var needed = Set(saved.map { text($0["uri"]) }).union(
      store.get("desktop:offline-tracks", stale: true) as? [String] ?? [])
    var urls = Set(saved.map { text($0["image"]) })
    for uri in playlists {
      needed.formUnion(
        dict(store.get("desktop:contents:" + uri, stale: true))["uris"] as? [String] ?? [])
      for item in store.get("contents:" + uri, stale: true) as? [JSONObject] ?? [] {
        needed.insert(text(item["uri"]))
        urls.insert(text(item["image"]))
      }
      if let item = store.item(uri) { urls.insert(text(item["image"])) }
    }
    for item in store.items("track")
    where needed.contains(text(item["uri"])) || albums.contains(text(dict(item["album"])["uri"])) {
      urls.insert(text(item["image"]))
      urls.insert(text(dict(item["album"])["image"]))
    }
    return Set(urls.filter { !$0.isEmpty }.map { sha256(Data($0.utf8)) + ".img" })
  }
  static func imageURL(_ string: String) -> Bool {
    guard let url = URL(string: string), url.scheme == "https" else { return false }
    return [
      "i.scdn.co", "mosaic.scdn.co", "i.spotifycdn.com", "image-cdn-ak.spotifycdn.com",
      "image-cdn-fa.spotifycdn.com", "pickasso.spotifycdn.com",
    ].contains(url.host ?? "")
  }
  static func entry(_ url: URL) throws -> (String, Int, Int) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    try handle.seek(toOffset: 0)
    let header = try handle.read(upToCount: 24) ?? Data()
    guard header.count == 24, little(header, 0, 8) == 0xfcfb_6d1b_a772_5c30,
      little(header, 8, 4) == 5
    else { throw SpotifyFailure(message: "Unknown cache format.") }
    let length = Int(little(header, 12, 4))
    guard length > 0, length < 16384, size > UInt64(length + 72) else {
      throw SpotifyFailure(message: "Invalid cache entry.")
    }
    let key = String(decoding: try handle.read(upToCount: length) ?? Data(), as: UTF8.self)
    let pattern = #"https://[^\s\u0000]+"#
    let re = try NSRegularExpression(pattern: pattern)
    guard let range = re.matches(in: key, range: NSRange(key.startIndex..., in: key)).last?.range,
      let swiftRange = Range(range, in: key)
    else { throw SpotifyFailure(message: "No cached URL.") }
    let string = String(key[swiftRange])
    guard let parsed = URL(string: string),
      imageURL(string)
        || (parsed.host == "spclient.wg.spotify.com"
          && parsed.path.range(
            of: #"^/metadata/4/(track|album|artist)/[a-f0-9]{32}$"#, options: .regularExpression)
            != nil)
    else { throw SpotifyFailure(message: "Not a music cache entry.") }
    try handle.seek(toOffset: size - 24)
    let footer = try handle.read(upToCount: 24) ?? Data()
    guard little(footer, 0, 8) == 0xf4fa_6f45_970d_41d8 else {
      throw SpotifyFailure(message: "Incomplete cache entry.")
    }
    let flags = little(footer, 8, 4)
    let end = Int(size) - 24 - (flags & 2 == 0 ? 0 : 32) - Int(little(footer, 16, 4)) - 24
    let offset = 24 + length
    guard flags & ~3 == 0, end >= offset, end - offset <= maxBody else {
      throw SpotifyFailure(message: "Invalid cache body.")
    }
    return (string, offset, end - offset)
  }
  static func body(_ url: URL, _ offset: Int, _ length: Int) throws -> Data {
    guard offset >= 0, length >= 0, length <= maxBody else {
      throw SpotifyFailure(message: "Invalid cached body size.")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(offset))
    let data = try handle.read(upToCount: length) ?? Data()
    let footer = try handle.read(upToCount: 24) ?? Data()
    guard data.count == length, footer.count == 24, little(footer, 0, 8) == 0xf4fa_6f45_970d_41d8
    else { throw SpotifyFailure(message: "Cache changed while reading.") }
    if little(footer, 8, 4) & 1 != 0 {
      let sum = data.withUnsafeBytes { spotify_crc32($0.baseAddress, data.count) }
      guard UInt64(sum) == little(footer, 12, 4) else {
        throw SpotifyFailure(message: "Cache checksum mismatch.")
      }
    }
    return data
  }
  static func unpack(_ data: Data) throws -> Data {
    let gzip = data.starts(with: [0x1f, 0x8b])
    let zstd = data.starts(with: [0x28, 0xb5, 0x2f, 0xfd])
    if !gzip && !zstd { return data }
    let knownSize =
      gzip && data.count >= 4
      ? Int(little(data, data.count - 4, 4))
      : data.withUnsafeBytes { spotify_zstd_size($0.baseAddress, $0.count) }
    if knownSize > maxBody { throw SpotifyFailure(message: "Compressed cache entry is too large.") }
    var output = Data(count: knownSize > 0 ? knownSize : maxBody + 1)
    let n = output.withUnsafeMutableBytes { out in
      data.withUnsafeBytes { input in
        gzip
          ? spotify_gzip_decode(out.baseAddress, out.count, input.baseAddress, input.count)
          : spotify_zstd_decode(out.baseAddress, out.count, input.baseAddress, input.count)
      }
    }
    guard n > 0, n <= maxBody else {
      throw SpotifyFailure(message: "Invalid compressed cache entry.")
    }
    output.count = n
    return output
  }
  @discardableResult func index() throws -> Int {
    let known = Dictionary(
      uniqueKeysWithValues: ((try? store.rows("SELECT path,stamp FROM desktop")) ?? []).map {
        (text($0["path"]), Int64(number($0["stamp"])))
      })
    var imported = 0
    for file
      in (try? FileManager.default.contentsOfDirectory(
        at: paths.desktop, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    where file.lastPathComponent.hasSuffix("_0") {
      let stamp = Int64(
        ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
          .timeIntervalSince1970 ?? 0) * 1_000_000_000)
      if known[file.path] == stamp { continue }
      do {
        let (url, offset, length) = try Self.entry(file)
        if let path = URL(string: url)?.path, path.hasPrefix("/metadata/4/") {
          let kind = path.split(separator: "/")[2]
          let data = try Self.unpack(Self.body(file, offset, length))
          let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
          if let item = json.flatMap({ fromDesktop($0, kind: String(kind)) })
            ?? fromProto(data, kind: String(kind))
          {
            try store.putItem(item)
            for child in (item["tracks"] as? [JSONObject] ?? [])
              + (item["artists"] as? [JSONObject] ?? [])
            { try store.putItem(child) }
            if let album = item["album"] as? JSONObject, !album.isEmpty { try store.putItem(album) }
            imported += 1
          }
        }
        try store.execute(
          "INSERT OR REPLACE INTO desktop VALUES(?,?,?,?,?)",
          [file.path, stamp, url, offset, length])
      } catch { continue }
    }
    return imported
  }
  func image(_ url: String, download: Bool) throws -> String? {
    guard Self.imageURL(url) else { return nil }
    // Local previews never wait for a network request on another queue.
    guard download else { return try loadImage(url, download: false) }
    imageCondition.lock()
    if let pending = imageRequests[url] {
      while pending.result == nil { imageCondition.wait() }
      let result = pending.result!
      imageCondition.unlock()
      return try result.get()
    }
    let pending = ImageRequest()
    imageRequests[url] = pending
    imageCondition.unlock()
    let result = Result { try loadImage(url, download: true) }
    imageCondition.lock()
    pending.result = result
    imageRequests.removeValue(forKey: url)
    imageCondition.broadcast()
    imageCondition.unlock()
    return try result.get()
  }
  private func loadImage(_ url: String, download: Bool) throws -> String? {
    let output = paths.cache.appendingPathComponent("artwork/" + sha256(Data(url.utf8)) + ".img")
    if FileManager.default.fileExists(atPath: output.path) {
      // Coarse access timestamps keep the cleanup pass from evicting art
      // in use without adding a write on every preview or keystroke.
      if let modified = try? output.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate,
        Date().timeIntervalSince(modified) > 3600
      {
        try? FileManager.default.setAttributes(
          [.modificationDate: Date()], ofItemAtPath: output.path)
      }
      return output.path
    }
    let evicted = "evicted-art:" + output.lastPathComponent
    if store.get(evicted, stale: true) != nil {
      try store.execute("DELETE FROM responses WHERE key=?", [evicted])
    }
    var matches = try store.rows(
      "SELECT path,offset,length FROM desktop WHERE url=? ORDER BY stamp DESC", [url])
    if let parsed = URL(string: url), parsed.host == "i.scdn.co",
      parsed.lastPathComponent.count == 40
    {
      let id = parsed.lastPathComponent
      matches += try store.rows(
        "SELECT path,offset,length FROM desktop WHERE url LIKE ? ORDER BY stamp DESC",
        ["https://i.scdn.co/image/" + id.prefix(8) + "%" + id.suffix(24)])
    }
    var bytes: Data?
    for match in matches {
      if let data = try? Self.body(
        URL(fileURLWithPath: text(match["path"])), Int(number(match["offset"])),
        Int(number(match["length"]))), Self.isImage(data)
      {
        bytes = data
        break
      }
    }
    if bytes == nil, download, store.get("missing-image:" + url) == nil {
      let ready = DispatchSemaphore(value: 0)
      var result: Data?
      var failed = false
      let task = session.dataTask(with: URL(string: url)!) { data, response, error in
        failed = error != nil
        if let response = response as? HTTPURLResponse, response.statusCode == 200,
          Self.imageURL(response.url?.absoluteString ?? ""), let data = data, Self.isImage(data)
        {
          result = data
        }
        ready.signal()
      }
      task.resume()
      guard ready.wait(timeout: .now() + 7) == .success else {
        task.cancel()
        throw SpotifyFailure(message: "Could not load artwork while offline.", isNetworkError: true)
      }
      if failed {
        throw SpotifyFailure(message: "Could not load artwork while offline.", isNetworkError: true)
      }
      bytes = result
      if bytes == nil { try store.put("missing-image:" + url, true, ttl: 60) }
    }
    guard let data = bytes, Self.isImage(data) else { return nil }
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try data.write(to: output, options: .atomic)
    chmod(output.path, 0o600)
    return output.path
  }
}

// Reads immutable SST blocks and complete WAL records. It never opens or locks
// Spotify's live LevelDB. The root record supplies the custom playlist order.
enum PlaylistOrder {
  static let prefix = Data("!pl#slc#2spotify:user:".utf8)
  static func snappy(_ data: Data) throws -> Data {
    var r = Bytes(data)
    let expected = Int(try r.varint())
    guard expected <= 16 * 1024 * 1024 else {
      throw SpotifyFailure(message: "Cache block too large.")
    }
    var out = [UInt8]()
    out.reserveCapacity(expected)
    while r.position < r.bytes.count {
      let tag = Int(try r.take(1).first!)
      let type = tag & 3
      if type == 0 {
        var count = tag >> 2
        if count < 60 {
          count += 1
        } else {
          let extra = count - 59
          count = Int(little(try r.take(extra), 0, extra)) + 1
        }
        out += try r.take(count)
      } else {
        let count: Int
        let offset: Int
        if type == 1 {
          count = 4 + ((tag >> 2) & 7)
          offset = ((tag & 224) << 3) | Int(try r.take(1).first!)
        } else {
          count = 1 + (tag >> 2)
          offset = Int(little(try r.take(type == 2 ? 2 : 4), 0, type == 2 ? 2 : 4))
        }
        guard offset > 0, offset <= out.count, out.count + count <= expected else {
          throw SpotifyFailure(message: "Invalid cache block.")
        }
        for _ in 0..<count { out.append(out[out.count - offset]) }
      }
      guard out.count <= expected else {
        throw SpotifyFailure(message: "Invalid cache block size.")
      }
    }
    guard out.count == expected else { throw SpotifyFailure(message: "Incomplete cache block.") }
    return Data(out)
  }
  static func entries(_ block: Data) throws -> [(Data, Data)] {
    guard block.count >= 4 else { return [] }
    let end = block.count - 4 - Int(little(block, block.count - 4, 4)) * 4
    guard end >= 0 else { throw SpotifyFailure(message: "Invalid cache restarts.") }
    var reader = Bytes(block)
    var previous = Data()
    var result: [(Data, Data)] = []
    while reader.position < end {
      let shared = Int(try reader.varint())
      let next = Int(try reader.varint())
      let count = Int(try reader.varint())
      guard shared <= previous.count, next + count <= end - reader.position else {
        throw SpotifyFailure(message: "Invalid cache key.")
      }
      let key = previous.prefix(shared) + (try reader.take(next))
      let value = try reader.take(count)
      result.append((key, value))
      previous = key
    }
    return result
  }
  static func decode(_ value: Data) -> [String]? {
    guard let root = try? Proto(value), let contents = root.values[5]?.first,
      let list = try? Proto(contents), (list.integers[1]?.first ?? 0) == 0,
      (list.integers[2]?.first ?? 0) == 0
    else { return nil }
    let uris = (list.values[3] ?? []).compactMap { try? Proto($0).string(1) }.filter {
      $0.hasPrefix("spotify:playlist:") && validURI($0)
    }
    var seen = Set<String>()
    return uris.filter { seen.insert($0).inserted }
  }
  static func read(_ directory: URL) -> [String]? {
    DesktopDatabase.read(directory, prefixes: [prefix]).filter {
      $0.key.suffix(10) == Data(":rootlist#".utf8)
    }
    .sorted { $0.value.sequence > $1.value.sequence }.compactMap { decode($0.value.value) }.first {
      !$0.isEmpty
    }
  }
  static func desktopDirectory() -> URL? {
    if let override = ProcessInfo.processInfo.environment["SPOTIFY_DESKTOP_USER_CACHE"] {
      return URL(fileURLWithPath: override)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let root = home.appendingPathComponent(
      "Library/Application Support/Spotify/PersistentCache/Users")
    let dirs =
      ((try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter {
        $0.lastPathComponent.hasSuffix("-user")
      }
    let prefs =
      (try? String(
        contentsOf: home.appendingPathComponent("Library/Application Support/Spotify/prefs"),
        encoding: .utf8)) ?? ""
    if let line = prefs.split(separator: "\n").first(where: { $0.hasPrefix("app.last-username=") }),
      let user = line.split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first,
      let match = dirs.first(where: { $0.lastPathComponent == String(user) + "-user" })
    {
      return match.appendingPathComponent("primary.ldb")
    }
    return dirs.max {
      ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? .distantPast)
        < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast)
    }?.appendingPathComponent("primary.ldb")
  }
}
