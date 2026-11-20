import Foundation

func stableUnique(_ items: [JSONObject]) -> [JSONObject] { var seen = Set<String>(); return items.filter { let uri = text($0["uri"]); return !uri.isEmpty && seen.insert(uri).inserted } }
func actionItem(_ name: String, _ action: String, _ extra: JSONObject = [:]) -> JSONObject { ["name": name, "kind": "action", "action": action, "uri": "action:\(action):\(name)"].merging(extra) { _, new in new } }
let homeItems = [actionItem("Playlists", "browse", ["target": ["kind": "playlists"], "symbol": "music.note.list"]), actionItem("Albums", "browse", ["target": ["kind": "albums"], "symbol": "square.stack"]), actionItem("Artists", "browse", ["target": ["kind": "artists"], "symbol": "person.fill"]), actionItem("Songs", "browse", ["target": ["kind": "songs"], "symbol": "music.note"]), actionItem("Search", "catalog", ["symbol": "magnifyingglass", "detail": "Search Spotify’s catalogue"])]

struct LibraryPath {
    let routes: [JSONObject]
    let consumed: String
}

final class MusicLibrary {
    let store: MusicStore
    let api: SpotifyAPI
    static let syncKey = "library:synced:v2"
    private let online: () -> Bool
    init(_ store: MusicStore, _ api: SpotifyAPI, online: @escaping () -> Bool = { true }) {
        self.store = store; self.api = api; self.online = online
    }
    private var followedArtists: Set<String> { Set(store.get("library:followed-artists", stale: true) as? [String] ?? []) }
    private func available(_ items: [JSONObject]) -> [JSONObject] {
        guard !online() else { return items }
        let downloaded = Set(store.get("desktop:downloaded-uris", stale: true) as? [String] ?? [])
        let followed = followedArtists
        let hasSongs = items.contains { text($0["kind"]) == "track" && downloaded.contains(text($0["uri"])) }
        return items.filter { item in
            if text(item["kind"]) == "action" {
                let uri = text(item["play_uri"])
                return uri.isEmpty || (isLikedSongsURI(uri) ? hasSongs : downloaded.contains(uri))
            }
            return downloaded.contains(text(item["uri"])) && (text(item["kind"]) != "artist" || followed.contains(text(item["uri"])))
        }
    }
    func catalog() -> [JSONObject] { available(stableUnique(orderedPlaylists() + store.items())) }
    func sync(cancellation: RequestCancellation? = nil) throws {
        let profile = dict(try api.request("/me", cancellation: cancellation))
        try store.useAccount(text(profile["id"]), cancellation: cancellation)
        var items = try api.pages("/me/tracks", cancellation: cancellation).compactMap { fromAPI(dict($0["track"]), kind: "track") }
        let albums = try api.pages("/me/albums", cancellation: cancellation).compactMap { fromAPI(dict($0["album"]), kind: "album") }
        items += albums
        let artists = try api.pages("/me/following", params: ["type": "artist"], nested: "artists", cancellation: cancellation).compactMap { fromAPI($0, kind: "artist") }
        items += artists
        let playlists = try api.pages("/me/playlists", cancellation: cancellation).compactMap { fromAPI($0, kind: "playlist") }
        items += playlists
        try store.transaction {
            if cancellation?.isCancelled == true { throw URLError(.cancelled) }
            try store.execute("DELETE FROM saved")
            for item in items {
                try store.putItem(item); try store.save(text(item["uri"]), liked: true)
                for artist in item["artists"] as? [JSONObject] ?? [] { try store.putItem(artist) }
            }
            for row in try store.rows("SELECT key,payload FROM responses WHERE key LIKE 'native:saved-recent:%' AND expires>?", [Date().timeIntervalSince1970]) {
                let uri = String(text(row["key"]).dropFirst("native:saved-recent:".count))
                if validTrack(uri) { try store.save(uri, liked: text(row["payload"]) == "true") }
            }
            try store.put("library:followed-artists", artists.map { text($0["uri"]) }, ttl: 365 * 86400)
            try store.put("library:playlist-order", playlists.map { text($0["uri"]) }, ttl: 365 * 86400)
            try store.put(Self.syncKey, Date().timeIntervalSince1970, ttl: 86400)
            if cancellation?.isCancelled == true { throw URLError(.cancelled) }
        }
    }
    func orderedPlaylists() -> [JSONObject] {
        let playlists = store.items("playlist", saved: true)
        let order = store.get("desktop:playlist-order", stale: true) as? [String] ?? store.get("library:playlist-order", stale: true) as? [String] ?? []
        let indices = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return playlists.enumerated().sorted { let lhs = indices[text($0.element["uri"])] ?? Int.max, rhs = indices[text($1.element["uri"])] ?? Int.max; return lhs == rhs ? $0.offset < $1.offset : lhs < rhs }.map { $0.element }
    }
    // Resolve only complete folder names. The remaining text stays a local filter.
    // Match whole names before splitting so names containing '/' remain usable.
    func resolvePath(_ input: String) throws -> LibraryPath {
        var remaining = input, consumed = "", routes: [JSONObject] = []
        func match(_ choices: [(String, JSONObject)]) -> (String, JSONObject)? {
            var best: (String, JSONObject)?
            for (name, route) in choices where !name.isEmpty {
                guard let range = remaining.range(of: name + "/", options: [.anchored, .caseInsensitive, .diacriticInsensitive]) else { continue }
                let raw = String(remaining[..<range.upperBound])
                if raw.count > (best?.0.count ?? 0) { best = (raw, route) }
            }
            return best
        }
        let roots = homeItems.filter { text($0["action"]) == "browse" }.flatMap { item -> [(String, JSONObject)] in
            let name = text(item["name"]), route = dict(item["target"]).merging(["name": name]) { _, new in new }
            return [(name, route), (String(name.dropLast()), route)]
        }
        if let (raw, route) = match(roots) {
            consumed += raw; remaining.removeFirst(raw.count); routes.append(route)
        }
        while remaining.contains("/") {
            let choices: [JSONObject]
            if let route = routes.last { choices = try browse(route) }
            else { choices = catalog().filter { ["playlist", "album", "artist"].contains(text($0["kind"])) } + (try browse(["kind": "albums"])) }
            let folders = choices.filter { ["playlist", "album", "artist"].contains(text($0["kind"])) }
            guard let (raw, route) = match(folders.map { (text($0["name"]), $0) }) else { break }
            consumed += raw; remaining.removeFirst(raw.count); routes.append(route)
        }
        return LibraryPath(routes: routes, consumed: consumed)
    }
    func cachedSearch(_ query: String, stale: Bool = true) -> [JSONObject]? {
        store.get("search:" + query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), stale: stale) as? [JSONObject]
    }
    func browse(_ route: JSONObject, network: Bool = false, cancellation: RequestCancellation? = nil) throws -> [JSONObject] {
        do { return available(try load(route, network: network && online(), cancellation: cancellation)) }
        catch let error as SpotifyFailure where network && error.isNetworkError {
            if text(route["kind"]) == "catalog" && cachedSearch(text(route["query"])) == nil { throw error }
            return available(try load(route, network: false, cancellation: cancellation))
        }
    }
    private func load(_ route: JSONObject, network: Bool, cancellation: RequestCancellation?) throws -> [JSONObject] {
        let kind = text(route["kind"]), uri = text(route["uri"])
        switch kind {
        case "", "home": return homeItems
        case "playlists": return orderedPlaylists()
        case "songs":
            let context = PlaybackContext.likedSongs.object
            let songs = store.items("track", saved: true).sorted { text($0["name"]).localizedStandardCompare(text($1["name"])) == .orderedAscending }
            return [actionItem("All", "play", ["play_uri": PlaybackContext.likedSongs.uri, "playback_context": context,
                                               "symbol": "play.fill", "detail": "Play all Liked Songs"])]
                + songs.map { $0.merging(["playback_context": context]) { _, new in new } }
        case "artists":
            let followed = followedArtists
            return store.items("artist", saved: true).filter { followed.contains(text($0["uri"])) }.sorted { text($0["name"]).localizedStandardCompare(text($1["name"])) == .orderedAscending }
        case "albums": return store.items("album", saved: true).sorted { text($0["name"]).localizedStandardCompare(text($1["name"])) == .orderedAscending }
        case "catalog":
            let query = text(route["query"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return [] }
            let key = "search:" + query.lowercased()
            var result = cachedSearch(query, stale: !network)
            if result == nil && network {
                let payload = dict(try api.request("/search", params: ["q": query, "type": "playlist,album,artist,track", "limit": "10"], cancellation: cancellation))
                result = ["playlist", "album", "artist", "track"].flatMap { kind in (dict(payload[kind + "s"])["items"] as? [JSONObject] ?? []).compactMap { fromAPI($0, kind: kind) } }
                try store.put(key, result ?? [], ttl: 900)
                for item in result ?? [] { try store.putItem(item) }
            }
            return result ?? []
        case "artist":
            var items = dict(store.item(uri))["albums"] as? [JSONObject] ?? []
            items += store.items("album").filter { ($0["artists"] as? [JSONObject] ?? []).contains { text($0["uri"]) == uri } }
            let key = "artist-albums:" + uri
            if let cached = store.get(key, stale: !network) as? [JSONObject] { items = cached }
            else if items.isEmpty && network {
                items = try api.pages("/artists/" + (text(route["id"]).isEmpty ? uri.components(separatedBy: ":").last! : text(route["id"])) + "/albums", params: ["include_groups": "album,single"]).compactMap { fromAPI($0, kind: "album") }
                try store.put(key, items)
                for item in items { try store.putItem(item) }
            }
            return [actionItem("Play all tracks by " + text(route["name"]), "play", ["play_uri": uri, "image": text((store.item(uri) ?? route)["image"]), "symbol": "play.fill", "playback_context": PlaybackContext(uri: uri, name: text(route["name"]))?.object ?? [:]])] + stableUnique(items)
        case "album", "playlist":
            let item = store.item(uri) ?? route, key = "contents:" + uri
            var tracks = item["tracks"] as? [JSONObject] ?? []
            if kind == "album" && tracks.isEmpty { tracks = store.items("track").filter { text(dict($0["album"])["uri"]) == uri }.sorted { (number($0["disc_number"]), number($0["track_number"])) < (number($1["disc_number"]), number($1["track_number"])) } }
            let desktop = dict(store.get("desktop:contents:" + uri, stale: true))
            let desktopComplete = desktop["complete"] as? Bool == true
            let desktopTracks = (desktop["uris"] as? [String] ?? []).compactMap(store.item)
            if desktopComplete || tracks.isEmpty { tracks = desktopTracks.isEmpty && !desktopComplete ? tracks : desktopTracks }
            if !desktopComplete, let cached = store.get(key, stale: !network) as? [JSONObject] { tracks = cached }
            else if network && !desktopComplete && (kind == "playlist" || tracks.isEmpty) {
                let id = uri.components(separatedBy: ":").last ?? ""
                do {
                    tracks = try api.pages(kind == "album" ? "/albums/\(id)/tracks" : "/playlists/\(id)/items").compactMap { value in
                        var value = kind == "playlist" ? dict(value["item"] ?? value["track"]) : value
                        if kind == "album" { value["album"] = item; value["type"] = "track" }
                        guard var track = fromAPI(value, kind: "track") else { return nil }
                        if kind == "album" { track["album"] = item; track["image"] = item["image"] }
                        return track
                    }
                    try store.put(key, tracks)
                    for track in tracks { try store.putItem(track) }
                } catch let error as SpotifyFailure where kind == "playlist" && error.status == 403 {
                    return [actionItem("Play " + text(item["name"]), "play", ["play_uri": uri, "image": text(item["image"]), "symbol": "play.fill", "detail": "Spotify limits access to this playlist’s tracks.", "playback_context": PlaybackContext(uri: uri, name: text(item["name"]))?.object ?? [:]])]
                }
            }
            let context = PlaybackContext(uri: uri, name: text(item["name"]))?.object ?? [:]
            return [actionItem("Play " + text(item["name"]), "play", ["play_uri": uri, "image": text(item["image"]), "symbol": "play.fill", "playback_context": context])] + tracks.map { $0.merging(["context": uri, "playback_context": context]) { _, new in new } }
        default: return []
        }
    }
    func playbackContext(_ state: JSONObject, network: Bool = false) -> PlaybackContext? {
        guard var context = PlaybackContext(dict(state["context"])) else { return nil }
        if context.kind == "collection" { return context }
        let item = dict(state["item"]), album = dict(item["album"])
        let artist = (item["artists"] as? [JSONObject] ?? []).first { text($0["uri"]) == context.uri }
        if let name = store.item(context.uri)?["name"] as? String, !name.isEmpty { context.name = name }
        else if text(album["uri"]) == context.uri { context.name = text(album["name"]) }
        else if let artist = artist { context.name = text(artist["name"]) }
        let key = "playback:context-name:" + context.uri
        if context.name.isEmpty { context.name = store.get(key, stale: true) as? String ?? "" }
        if network, context.name.isEmpty, store.get(key) == nil {
            let id = context.uri.components(separatedBy: ":").last!
            do {
                let item = dict(try api.request("/" + context.kind + "s/" + id))
                context.name = text(item["name"])
                try? store.put(key, context.name, ttl: context.name.isEmpty ? 3600 : 86400)
            } catch { try? store.put(key, "", ttl: 3600) }
        }
        return context
    }
    func setLiked(_ uri: String, liked: Bool) throws {
        guard validTrack(uri) else { throw SpotifyFailure(message: "Only Spotify songs can be saved to Liked Songs.") }
        guard api.canSave else { throw SpotifyFailure(message: "Run \(api.paths.command("reauth")) once to allow changes to Liked Songs, then connect again.") }
        var item = store.item(uri)
        if liked && item == nil { item = fromAPI(dict(try api.request("/tracks/" + (uri.components(separatedBy: ":").last ?? ""))), kind: "track") }
        if liked && item == nil { throw SpotifyFailure(message: "Spotify could not load this song.") }
        _ = try api.request("/me/library", params: ["uris": uri], method: liked ? "PUT" : "DELETE")
        try store.transaction {
            if let item = item { try store.putItem(item) }
            try store.save(uri, liked: liked)
            try store.put("liked:" + uri, liked, ttl: 60)
            try store.put("native:saved-recent:" + uri, liked, ttl: 60)
        }
    }
    func liked(_ uri: String) throws -> Bool {
        if let cached = store.get("liked:" + uri) as? Bool { return cached }
        guard validTrack(uri), let result = try api.request("/me/library/contains", params: ["uris": uri]) as? [Bool], result.count == 1 else { throw SpotifyFailure(message: "Spotify returned an invalid Liked Songs response.") }
        try store.save(uri, liked: result[0]); try store.put("liked:" + uri, result[0], ttl: 60); return result[0]
    }
}
