import Foundation

func stableUnique(_ items: [JSONObject]) -> [JSONObject] { var seen = Set<String>(); return items.filter { let uri = text($0["uri"]); return !uri.isEmpty && seen.insert(uri).inserted } }
func actionItem(_ name: String, _ action: String, _ extra: JSONObject = [:]) -> JSONObject { ["name": name, "kind": "action", "action": action, "uri": "action:\(action):\(name)"].merging(extra) { _, new in new } }
let homeItems = [actionItem("Playlists", "browse", ["target": ["kind": "playlists"], "symbol": "music.note.list"]), actionItem("Albums", "browse", ["target": ["kind": "albums"], "symbol": "square.stack"]), actionItem("Artists", "browse", ["target": ["kind": "artists"], "symbol": "person.fill"]), actionItem("Songs", "browse", ["target": ["kind": "songs"], "symbol": "music.note"]), actionItem("Spotify", "catalog", ["symbol": "magnifyingglass", "detail": "Search Spotify’s catalogue"])]

final class MusicLibrary {
    let store: MusicStore
    let api: SpotifyAPI
    init(_ store: MusicStore, _ api: SpotifyAPI) { self.store = store; self.api = api }
    func sync() throws {
        var items = try api.pages("/me/tracks").compactMap { fromAPI(dict($0["track"]), kind: "track") }
        let albums = try api.pages("/me/albums").compactMap { fromAPI(dict($0["album"]), kind: "album") }
        items += albums
        items += try api.pages("/me/following", params: ["type": "artist"], nested: "artists").compactMap { fromAPI($0, kind: "artist") }
        let playlists = try api.pages("/me/playlists").compactMap { fromAPI($0, kind: "playlist") }
        items += playlists
        try store.transaction {
            try store.execute("DELETE FROM saved")
            for item in items {
                try store.putItem(item); try store.save(text(item["uri"]), liked: true)
                for artist in item["artists"] as? [JSONObject] ?? [] { try store.putItem(artist); try store.save(text(artist["uri"]), liked: true) }
            }
            for row in try store.rows("SELECT key,payload FROM responses WHERE key LIKE 'native:saved-recent:%' AND expires>?", [Date().timeIntervalSince1970]) {
                let uri = String(text(row["key"]).dropFirst("native:saved-recent:".count))
                if validTrack(uri) { try store.save(uri, liked: text(row["payload"]) == "true") }
            }
            try store.put("library:playlist-order", playlists.map { text($0["uri"]) }, ttl: 365 * 86400)
            try store.put("library:synced", Date().timeIntervalSince1970, ttl: 86400)
        }
    }
    func orderedPlaylists() -> [JSONObject] {
        let playlists = store.items("playlist", saved: true)
        let order = store.get("desktop:playlist-order", stale: true) as? [String] ?? store.get("library:playlist-order", stale: true) as? [String] ?? []
        let indices = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return playlists.enumerated().sorted { let lhs = indices[text($0.element["uri"])] ?? Int.max, rhs = indices[text($1.element["uri"])] ?? Int.max; return lhs == rhs ? $0.offset < $1.offset : lhs < rhs }.map { $0.element }
    }
    func cachedSearch(_ query: String, stale: Bool = true) -> [JSONObject]? {
        store.get("search:" + query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), stale: stale) as? [JSONObject]
    }
    func browse(_ route: JSONObject, network: Bool = false, cancellation: RequestCancellation? = nil) throws -> [JSONObject] {
        do { return try load(route, network: network, cancellation: cancellation) }
        catch let error as SpotifyFailure where network && error.isNetworkError {
            if text(route["kind"]) == "catalog" && cachedSearch(text(route["query"])) == nil { throw error }
            return try load(route, network: false, cancellation: cancellation)
        }
    }
    private func load(_ route: JSONObject, network: Bool, cancellation: RequestCancellation?) throws -> [JSONObject] {
        let kind = text(route["kind"]), uri = text(route["uri"])
        switch kind {
        case "", "home": return homeItems
        case "playlists": return orderedPlaylists()
        case "songs": return store.items("track", saved: true).sorted { text($0["name"]).localizedStandardCompare(text($1["name"])) == .orderedAscending }
        case "artists": return store.items("artist", saved: true).sorted { text($0["name"]).localizedStandardCompare(text($1["name"])) == .orderedAscending }
        case "albums": return stableUnique(store.items("album", saved: true) + store.items("track", saved: true).compactMap { $0["album"] as? JSONObject }).sorted { text($0["name"]).localizedStandardCompare(text($1["name"])) == .orderedAscending }
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
            return [actionItem("Play all tracks by " + text(route["name"]), "play", ["play_uri": uri, "symbol": "play.fill"])] + stableUnique(items)
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
                    return [actionItem("Play " + text(item["name"]), "play", ["play_uri": uri, "symbol": "play.fill", "detail": "Spotify limits access to this playlist’s tracks."])]
                }
            }
            return [actionItem("Play " + text(item["name"]), "play", ["play_uri": uri, "symbol": "play.fill"])] + tracks.map { $0.merging(["context": uri]) { _, new in new } }
        default: return []
        }
    }
    func setLiked(_ uri: String, liked: Bool) throws {
        guard validTrack(uri) else { throw SpotifyFailure(message: "Only Spotify songs can be saved to Liked Songs.") }
        guard api.canSave else { throw SpotifyFailure(message: "Run spotify reauth once to allow changes to Liked Songs, then connect again.") }
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
