import Foundation

struct Bytes {
    var bytes: [UInt8]
    var position = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard position < bytes.count else { throw SpotifyFailure(message: "Truncated cache record.") }
            let byte = bytes[position]; position += 1
            result |= UInt64(byte & 127) << shift
            if byte < 128 { return result }
        }
        throw SpotifyFailure(message: "Invalid cache integer.")
    }
    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, position <= bytes.count - count else { throw SpotifyFailure(message: "Truncated cache record.") }
        defer { position += count }; return Data(bytes[position..<position + count])
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
            let tag = try reader.varint(), key = Int(tag >> 3)
            guard key > 0 else { throw SpotifyFailure(message: "Invalid cached metadata.") }
            switch tag & 7 {
            case 0: integers[key, default: []].append(try reader.varint())
            case 1: _ = try reader.take(8)
            case 2: let length = try reader.varint(); guard length <= 16 * 1024 * 1024 else { throw SpotifyFailure(message: "Invalid cached metadata length.") }; values[key, default: []].append(try reader.take(Int(length)))
            case 5: _ = try reader.take(4)
            default: throw SpotifyFailure(message: "Unknown cached metadata format.")
            }
        }
    }
    func string(_ field: Int) -> String { values[field]?.first.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
}
func spotifyID(_ bytes: Data) -> String {
    guard bytes.count == 16 else { return "" }
    let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    var value = Array(bytes), output = ""
    while value.contains(where: { $0 != 0 }) {
        var remainder = 0
        for i in value.indices { let next = remainder * 256 + Int(value[i]); value[i] = UInt8(next / 62); remainder = next % 62 }
        output.insert(alphabet[remainder], at: output.startIndex)
    }
    return String(repeating: "0", count: max(0, 22 - output.count)) + output
}
func fromAPI(_ value: JSONObject, kind: String? = nil) -> JSONObject? {
    let uri = text(value["uri"]), kind = kind ?? text(value["type"])
    guard validURI(uri), !text(value["name"]).isEmpty else { return nil }
    var item: JSONObject = ["uri": uri, "kind": kind, "id": text(value["id"]), "name": text(value["name"])]
    let album = dict(value["album"])
    let images = value["images"] as? [JSONObject] ?? album["images"] as? [JSONObject] ?? []
    item["image"] = text(images.first?["url"])
    item["artists"] = (value["artists"] as? [JSONObject] ?? []).compactMap { fromAPI($0, kind: "artist") }
    if kind == "track" {
        item["album"] = fromAPI(album, kind: "album") ?? [:]
        for key in ["duration_ms", "disc_number", "track_number", "is_playable", "is_local"] { item[key] = value[key] }
    }
    if kind == "album" { item["year"] = String(text(value["release_date"]).prefix(4)); item["total"] = value["total_tracks"] }
    if kind == "playlist" { item["total"] = dict(value["items"] ?? value["tracks"])["total"] }
    return item
}
func fromDesktop(_ value: JSONObject, kind: String, depth: Int = 0) -> JSONObject? {
    guard depth < 8 else { return nil }
    let hex = text(value["gid"])
    guard hex.count == 32 else { return nil }
    var bytes = Data(); var offset = hex.startIndex
    while offset < hex.endIndex { let end = hex.index(offset, offsetBy: 2); guard let byte = UInt8(hex[offset..<end], radix: 16) else { return nil }; bytes.append(byte); offset = end }
    let id = spotifyID(bytes); guard !id.isEmpty, !text(value["name"]).isEmpty else { return nil }
    var item: JSONObject = ["uri": "spotify:\(kind):\(id)", "kind": kind, "id": id, "name": text(value["name"])]
    let images = dict(value[kind == "artist" ? "portrait_group" : "cover_group"])["image"] as? [JSONObject] ?? []
    item["image"] = images.reversed().compactMap { value -> String? in let id = text(value["file_id"]); return id.count == 40 ? "https://i.scdn.co/image/" + id.lowercased() : nil }.first ?? ""
    item["artists"] = (value["artist"] as? [JSONObject] ?? []).compactMap { fromDesktop($0, kind: "artist", depth: depth + 1) }
    if kind == "track" {
        let album = fromDesktop(dict(value["album"]), kind: "album", depth: depth + 1) ?? [:]
        item["album"] = album; item["image"] = text(album["image"])
        item["duration_ms"] = value["duration"]; item["track_number"] = value["number"]; item["disc_number"] = value["disc_number"]
    } else if kind == "album" {
        item["year"] = dict(value["date"])["year"].map { String(describing: $0) } ?? ""
        var tracks = (value["disc"] as? [JSONObject] ?? []).flatMap { $0["track"] as? [JSONObject] ?? [] }.compactMap { fromDesktop($0, kind: "track", depth: depth + 1) }
        for i in tracks.indices { tracks[i]["album"] = item; tracks[i]["image"] = item["image"] }
        item["tracks"] = tracks
    } else if kind == "artist" {
        item["albums"] = ["album_group", "single_group", "compilation_group"].flatMap { value[$0] as? [JSONObject] ?? [] }.flatMap { $0["album"] as? [JSONObject] ?? [] }.compactMap { fromDesktop($0, kind: "album", depth: depth + 1) }
    }
    return item
}
func fromProto(_ data: Data, kind: String, depth: Int = 0) -> JSONObject? {
    guard depth < 7, let p = try? Proto(data), let gid = p.values[1]?.first else { return nil }
    let id = spotifyID(gid); guard !id.isEmpty, !p.string(2).isEmpty else { return nil }
    var item: JSONObject = ["uri": "spotify:\(kind):\(id)", "kind": kind, "id": id, "name": p.string(2)]
    func covers(_ direct: Int, _ group: Int) -> String {
        let blobs = (p.values[direct] ?? []) + (p.values[group] ?? []).flatMap { (try? Proto($0).values[1]) ?? [] }
        return blobs.compactMap { (try? Proto($0).values[1]?.first) ?? nil }.filter { $0.count == 20 }.last.map { "https://i.scdn.co/image/" + $0.map { String(format: "%02x", $0) }.joined() } ?? ""
    }
    item["image"] = kind == "artist" ? covers(11, 17) : covers(9, 17)
    item["artists"] = (p.values[kind == "track" ? 4 : 3] ?? []).compactMap { fromProto($0, kind: "artist", depth: depth + 1) }
    if kind == "track" {
        let album = p.values[3]?.first.flatMap { fromProto($0, kind: "album", depth: depth + 1) } ?? [:]
        item["album"] = album; item["image"] = album["image"]
        for (field, key) in [(5, "track_number"), (6, "disc_number"), (7, "duration_ms")] { let n = p.integers[field]?.first ?? 0; item[key] = Int64(n >> 1) ^ -Int64(n & 1) }
    }
    if kind == "album" {
        let year = p.values[6]?.first.flatMap { try? Proto($0).integers[1]?.first } ?? 0
        item["year"] = String(year >> 1)
        var tracks = (p.values[11] ?? []).flatMap { (try? Proto($0).values[1]) ?? [] }.compactMap { fromProto($0, kind: "track", depth: depth + 1) }
        for i in tracks.indices { tracks[i]["album"] = item; tracks[i]["image"] = item["image"] }
        item["tracks"] = tracks
    }
    if kind == "artist" { item["albums"] = [5, 6, 7].flatMap { p.values[$0] ?? [] }.flatMap { (try? Proto($0).values[1]) ?? [] }.compactMap { fromProto($0, kind: "album", depth: depth + 1) } }
    return item
}

final class DesktopCache {
    static let maxBody = 8 * 1024 * 1024
    let paths: WorkflowPaths
    let store: MusicStore
    init(_ paths: WorkflowPaths, _ store: MusicStore) { self.paths = paths; self.store = store }
    static func imageURL(_ string: String) -> Bool {
        guard let url = URL(string: string), url.scheme == "https" else { return false }
        return ["i.scdn.co", "mosaic.scdn.co", "i.spotifycdn.com", "image-cdn-ak.spotifycdn.com", "image-cdn-fa.spotifycdn.com", "pickasso.spotifycdn.com"].contains(url.host ?? "")
    }
    static func entry(_ url: URL) throws -> (String, Int, Int) {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let size = try handle.seekToEnd(); try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 24) ?? Data()
        guard header.count == 24, little(header, 0, 8) == 0xfcfb6d1ba7725c30, little(header, 8, 4) == 5 else { throw SpotifyFailure(message: "Unknown cache format.") }
        let length = Int(little(header, 12, 4)); guard length > 0, length < 16384, size > UInt64(length + 72) else { throw SpotifyFailure(message: "Invalid cache entry.") }
        let key = String(decoding: try handle.read(upToCount: length) ?? Data(), as: UTF8.self)
        let pattern = #"https://[^\s\u0000]+"#
        let re = try NSRegularExpression(pattern: pattern)
        guard let range = re.matches(in: key, range: NSRange(key.startIndex..., in: key)).last?.range, let swiftRange = Range(range, in: key) else { throw SpotifyFailure(message: "No cached URL.") }
        let string = String(key[swiftRange]); guard let parsed = URL(string: string), imageURL(string) || (parsed.host == "spclient.wg.spotify.com" && parsed.path.range(of: #"^/metadata/4/(track|album|artist)/[a-f0-9]{32}$"#, options: .regularExpression) != nil) else { throw SpotifyFailure(message: "Not a music cache entry.") }
        try handle.seek(toOffset: size - 24)
        let footer = try handle.read(upToCount: 24) ?? Data()
        guard little(footer, 0, 8) == 0xf4fa6f45970d41d8 else { throw SpotifyFailure(message: "Incomplete cache entry.") }
        let flags = little(footer, 8, 4)
        let end = Int(size) - 24 - (flags & 2 == 0 ? 0 : 32) - Int(little(footer, 16, 4)) - 24
        let offset = 24 + length
        guard flags & ~3 == 0, end >= offset, end - offset <= maxBody else { throw SpotifyFailure(message: "Invalid cache body.") }
        return (string, offset, end - offset)
    }
    static func body(_ url: URL, _ offset: Int, _ length: Int) throws -> Data {
        guard offset >= 0, length >= 0, length <= maxBody else { throw SpotifyFailure(message: "Invalid cached body size.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: length) ?? Data(), footer = try handle.read(upToCount: 24) ?? Data()
        guard data.count == length, footer.count == 24, little(footer, 0, 8) == 0xf4fa6f45970d41d8 else { throw SpotifyFailure(message: "Cache changed while reading.") }
        if little(footer, 8, 4) & 1 != 0 {
            let sum = data.withUnsafeBytes { spotify_crc32($0.baseAddress, data.count) }
            guard UInt64(sum) == little(footer, 12, 4) else { throw SpotifyFailure(message: "Cache checksum mismatch.") }
        }
        return data
    }
    static func unpack(_ data: Data) throws -> Data {
        let gzip = data.starts(with: [0x1f, 0x8b]), zstd = data.starts(with: [0x28, 0xb5, 0x2f, 0xfd])
        if !gzip && !zstd { return data }
        let knownSize = gzip && data.count >= 4 ? Int(little(data, data.count - 4, 4)) : data.withUnsafeBytes { spotify_zstd_size($0.baseAddress, $0.count) }
        if knownSize > maxBody { throw SpotifyFailure(message: "Compressed cache entry is too large.") }
        var output = Data(count: knownSize > 0 ? knownSize : maxBody + 1)
        let n = output.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in gzip ? spotify_gzip_decode(out.baseAddress, out.count, input.baseAddress, input.count) : spotify_zstd_decode(out.baseAddress, out.count, input.baseAddress, input.count) } }
        guard n > 0, n <= maxBody else { throw SpotifyFailure(message: "Invalid compressed cache entry.") }
        output.count = n; return output
    }
    @discardableResult func index() throws -> Int {
        let known = Dictionary(uniqueKeysWithValues: ((try? store.rows("SELECT path,stamp FROM desktop")) ?? []).map { (text($0["path"]), Int64(number($0["stamp"]))) })
        var imported = 0
        for file in (try? FileManager.default.contentsOfDirectory(at: paths.desktop, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where file.lastPathComponent.hasSuffix("_0") {
            let stamp = Int64(((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0) * 1_000_000_000)
            if known[file.path] == stamp { continue }
            do {
                let (url, offset, length) = try Self.entry(file)
                if let path = URL(string: url)?.path, path.hasPrefix("/metadata/4/") {
                    let kind = path.split(separator: "/")[2], data = try Self.unpack(Self.body(file, offset, length))
                    let json = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
                    if let item = json.flatMap({ fromDesktop($0, kind: String(kind)) }) ?? fromProto(data, kind: String(kind)) {
                        try store.putItem(item)
                        for child in (item["tracks"] as? [JSONObject] ?? []) + (item["artists"] as? [JSONObject] ?? []) { try store.putItem(child) }
                        if let album = item["album"] as? JSONObject, !album.isEmpty { try store.putItem(album) }
                        imported += 1
                    }
                }
                try store.execute("INSERT OR REPLACE INTO desktop VALUES(?,?,?,?,?)", [file.path, stamp, url, offset, length])
            } catch { continue }
        }
        return imported
    }
    func image(_ url: String, download: Bool) throws -> String? {
        guard Self.imageURL(url) else { return nil }
        let output = paths.cache.appendingPathComponent("artwork/" + sha256(Data(url.utf8)) + ".img")
        if FileManager.default.fileExists(atPath: output.path) { return output.path }
        var matches = try store.rows("SELECT path,offset,length FROM desktop WHERE url=? ORDER BY stamp DESC", [url])
        if let parsed = URL(string: url), parsed.host == "i.scdn.co", parsed.lastPathComponent.count == 40 {
            let id = parsed.lastPathComponent
            matches += try store.rows("SELECT path,offset,length FROM desktop WHERE url LIKE ? ORDER BY stamp DESC", ["https://i.scdn.co/image/" + id.prefix(8) + "%" + id.suffix(24)])
        }
        var bytes: Data?
        for match in matches { if let data = try? Self.body(URL(fileURLWithPath: text(match["path"])), Int(number(match["offset"])), Int(number(match["length"]))) { bytes = data; break } }
        if bytes == nil, download, store.get("missing-image:" + url) == nil {
            let ready = DispatchSemaphore(value: 0)
            var result: Data?
            let task = URLSession.shared.dataTask(with: URL(string: url)!) { data, response, _ in
                if let response = response as? HTTPURLResponse, response.statusCode == 200, Self.imageURL(response.url?.absoluteString ?? ""), let data = data, data.count <= Self.maxBody { result = data }
                ready.signal()
            }
            task.resume(); if ready.wait(timeout: .now() + 6) != .success { task.cancel() }
            bytes = result
            if bytes == nil { try store.put("missing-image:" + url, true, ttl: 60) }
        }
        guard let data = bytes, data.count <= Self.maxBody, data.starts(with: [0xff, 0xd8, 0xff]) || data.starts(with: [137,80,78,71,13,10,26,10]) || (data.starts(with: Data("RIFF".utf8)) && data.count > 12 && data[8..<12] == Data("WEBP".utf8)) else { return nil }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: output, options: .atomic); chmod(output.path, 0o600); return output.path
    }
}

// Reads immutable SST blocks and complete WAL records. It never opens or locks
// Spotify's live LevelDB, and only decodes the playlist-root record.
enum PlaylistOrder {
    static let prefix = Data("!pl#slc#2spotify:user:".utf8)
    static func snappy(_ data: Data) throws -> Data {
        var r = Bytes(data); let expected = Int(try r.varint()); guard expected <= 16 * 1024 * 1024 else { throw SpotifyFailure(message: "Cache block too large.") }
        var out = [UInt8](); out.reserveCapacity(expected)
        while r.position < r.bytes.count {
            let tag = Int(try r.take(1).first!), type = tag & 3
            if type == 0 {
                var count = tag >> 2
                if count < 60 { count += 1 } else { let extra = count - 59; count = Int(little(try r.take(extra), 0, extra)) + 1 }
                out += try r.take(count)
            } else {
                let count: Int, offset: Int
                if type == 1 { count = 4 + ((tag >> 2) & 7); offset = ((tag & 224) << 3) | Int(try r.take(1).first!) }
                else { count = 1 + (tag >> 2); offset = Int(little(try r.take(type == 2 ? 2 : 4), 0, type == 2 ? 2 : 4)) }
                guard offset > 0, offset <= out.count, out.count + count <= expected else { throw SpotifyFailure(message: "Invalid cache block.") }
                for _ in 0..<count { out.append(out[out.count - offset]) }
            }
            guard out.count <= expected else { throw SpotifyFailure(message: "Invalid cache block size.") }
        }
        guard out.count == expected else { throw SpotifyFailure(message: "Incomplete cache block.") }; return Data(out)
    }
    static func entries(_ block: Data) throws -> [(Data, Data)] {
        guard block.count >= 4 else { return [] }
        let end = block.count - 4 - Int(little(block, block.count - 4, 4)) * 4
        guard end >= 0 else { throw SpotifyFailure(message: "Invalid cache restarts.") }
        var reader = Bytes(block), previous = Data(), result: [(Data, Data)] = []
        while reader.position < end {
            let shared = Int(try reader.varint()), next = Int(try reader.varint()), count = Int(try reader.varint())
            guard shared <= previous.count, next + count <= end - reader.position else { throw SpotifyFailure(message: "Invalid cache key.") }
            let key = previous.prefix(shared) + (try reader.take(next)), value = try reader.take(count)
            result.append((key, value)); previous = key
        }
        return result
    }
    static func decode(_ value: Data) -> [String]? {
        guard let root = try? Proto(value), let contents = root.values[5]?.first, let list = try? Proto(contents), (list.integers[1]?.first ?? 0) == 0, (list.integers[2]?.first ?? 0) == 0 else { return nil }
        let uris = (list.values[3] ?? []).compactMap { try? Proto($0).string(1) }.filter { $0.hasPrefix("spotify:playlist:") && validURI($0) }
        var seen = Set<String>(); return uris.filter { seen.insert($0).inserted }
    }
    static func read(_ directory: URL) -> [String]? {
        var best: (UInt64, [String])?
        func record(_ key: Data, _ value: Data, sequence: UInt64) {
            guard key.starts(with: prefix), key.suffix(10) == Data(":rootlist#".utf8), let list = decode(value), !list.isEmpty, best == nil || sequence > best!.0 else { return }
            best = (sequence, list)
        }
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }; defer { try? handle.close() }
            if file.pathExtension == "ldb" || file.pathExtension == "sst" {
                do {
                    let size = try handle.seekToEnd(); guard size >= 48 else { continue }; try handle.seek(toOffset: size - 48)
                    let footer = try handle.read(upToCount: 48) ?? Data(); guard little(footer, 40, 8) == 0xdb4775248b80fb57 else { continue }
                    func block(_ descriptor: Data) throws -> Data {
                        var reader = Bytes(descriptor); let offset = try reader.varint(), size = Int(try reader.varint())
                        guard size <= 16 * 1024 * 1024 else { throw SpotifyFailure(message: "Invalid cache block.") }
                        try handle.seek(toOffset: offset); let data = try handle.read(upToCount: size + 5) ?? Data()
                        guard data.count == size + 5 else { throw SpotifyFailure(message: "Incomplete cache block.") }
                        return data[size] == 1 ? try snappy(Data(data.prefix(size))) : data[size] == 0 ? Data(data.prefix(size)) : Data()
                    }
                    var f = Bytes(footer); _ = try f.varint(); _ = try f.varint()
                    let index = try entries(block(Data(footer.dropFirst(f.position))))
                    var previous = Data()
                    for (key, descriptor) in index {
                        let upper = Data(key.dropLast(8)), high = Data("!pl#slc#3".utf8)
                        if !upper.lexicographicallyPrecedes(prefix) && (previous.isEmpty || previous.lexicographicallyPrecedes(high)) {
                            for (key, value) in try entries(block(descriptor)) where key.count >= 8 {
                                let trailer = little(key, key.count - 8, 8)
                                if trailer & 255 == 1 { record(Data(key.dropLast(8)), value, sequence: trailer >> 8) }
                            }
                        }
                        previous = upper
                    }
                } catch { continue }
            } else if file.pathExtension == "log" {
                guard let data = try? handle.readToEnd(), data.count < 32 * 1024 * 1024 else { continue }
                var offset = 0, fragments = Data()
                while offset + 7 <= data.count {
                    let remaining = 32768 - offset % 32768
                    if remaining < 7 { offset += remaining; continue }
                    let length = Int(little(data, offset + 4, 2)), type = data[offset + 6]
                    guard length <= remaining - 7, offset + 7 + length <= data.count else { break }
                    let chunk = data.subdata(in: offset + 7..<offset + 7 + length); offset += 7 + length
                    if type == 1 || type == 2 { fragments = chunk } else if type == 3 || type == 4 { fragments += chunk } else { continue }
                    if type != 1 && type != 4 { continue }
                    do {
                        guard fragments.count >= 12 else { continue }
                        let sequence = little(fragments, 0, 8), count = Int(little(fragments, 8, 4)); guard count < 100000 else { continue }
                        var reader = Bytes(fragments); reader.position = 12
                        for i in 0..<count {
                            let type = try reader.take(1).first!, key = try reader.take(Int(reader.varint()))
                            let value = type == 1 ? try reader.take(Int(reader.varint())) : Data()
                            if type == 1 { record(key, value, sequence: sequence + UInt64(i)) }
                        }
                    } catch { continue }
                }
            }
        }
        return best?.1
    }
    static func desktopDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["SPOTIFY_DESKTOP_USER_CACHE"] { return URL(fileURLWithPath: override) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("Library/Application Support/Spotify/PersistentCache/Users")
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.lastPathComponent.hasSuffix("-user") }
        let prefs = (try? String(contentsOf: home.appendingPathComponent("Library/Application Support/Spotify/prefs"), encoding: .utf8)) ?? ""
        if let line = prefs.split(separator: "\n").first(where: { $0.hasPrefix("app.last-username=") }), let user = line.split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first,
           let match = dirs.first(where: { $0.lastPathComponent == String(user) + "-user" }) { return match.appendingPathComponent("primary.ldb") }
        return dirs.max { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }?.appendingPathComponent("primary.ldb")
    }
}
