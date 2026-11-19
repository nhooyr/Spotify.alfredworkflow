import AppKit
import Foundation

final class NativeBackend {
    var receive: ((JSONObject) -> Void)?
    private let queue = DispatchQueue(label: "spotify.library", qos: .userInitiated)
    private let work = DispatchQueue(label: "spotify.io", qos: .utility, attributes: .concurrent)
    private let likeWork = DispatchQueue(label: "spotify.likes", qos: .userInitiated)
    private let repeatWork = DispatchQueue(label: "spotify.repeat", qos: .userInitiated)
    private let playbackWork = DispatchQueue(label: "spotify.web-playback", qos: .userInteractive)
    private var repeatPolling = false
    private var playbackContextSnapshot: (state: JSONObject, request: Int)?
    private var resolvingContexts: Set<String> = []
    private let artworkWork = DispatchQueue(label: "spotify.artwork", qos: .utility)
    private var warmingArtwork = false
    private var cleaningCache = false
    private var cacheMaintenance: DispatchSourceTimer?
    private let paths: WorkflowPaths
    private var store: MusicStore!
    private var api: SpotifyAPI!
    private var playback: WebPlayback!
    private var playbackCancellation: RequestCancellation?
    private var cache: DesktopCache!
    private var library: MusicLibrary!
    private var auth: AuthorizationFlow?
    private var stack: [JSONObject] = []
    private var connection = "loading"
    private var message = ""
    private var revision = 0
    private var navigationRequest = 0
    private var catalogRequest: RequestCancellation?
    private var syncing = false
    private var lastRefresh = Date.distantPast
    private static let rowKeys: Set<String> = ["uri", "name", "kind", "context", "playback_context", "action", "target", "play_uri", "image", "query", "is_local", "is_playable"]
    private static let rowSymbols = ["playlist": "music.note.list", "album": "square.stack", "artist": "person.fill", "track": "music.note"]
    private var running = false
    private var artwork: Set<String> = []
    var pid: Int32 { running ? getpid() : 0 }
    init(_ root: URL) { paths = WorkflowPaths(root: root) }
    func start() throws {
        running = true
        queue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.paths.prepare()
                self.store = try MusicStore(self.paths.cache.appendingPathComponent("index.sqlite3"))
                self.api = SpotifyAPI(self.paths); self.cache = DesktopCache(self.paths, self.store); self.library = MusicLibrary(self.store, self.api)
                self.playback = WebPlayback(self.api, store: self.store)
                self.reloadArt()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 3600, repeating: 3600, leeway: .seconds(60))
                timer.setEventHandler { [weak self] in self?.cleanCache() }
                self.cacheMaintenance = timer
                timer.resume()
                if self.api.connected {
                    self.connection = "connected"; self.publishRows(command: "init", resetText: true); self.sendCatalog()
                    let preparation = RequestCancellation()
                    self.playbackCancellation = preparation
                    self.playbackWork.async { self.playback.prepare(cancellation: preparation) }
                    self.refresh(force: false)
                } else if self.validCredentials { self.connect() }
                else { self.connection = "credentials"; self.message = "Add your Spotify Client ID to continue"; self.publishRows(command: "init", resetText: true) }
            } catch { self.connection = "failed"; self.message = error.localizedDescription; self.running = false; self.publishRows(command: "init") }
        }
    }
    func stop() { running = false; playbackCancellation?.cancel(); auth?.cancel(); cacheMaintenance?.cancel(); cacheMaintenance = nil }
    private var validCredentials: Bool { paths.clientID().range(of: #"^[a-fA-F0-9]{32}$"#, options: .regularExpression) != nil }
    private var route: JSONObject { stack.last ?? ["kind": "home"] }
    private var prefix: String {
        if text(route["kind"]) == "catalog" { return "/" }
        return stack.map {
            if text($0["kind"]) == "catalog" { return "/" + text($0["query"]) }
            let name = text($0["name"])
            return name.isEmpty ? text($0["kind"]).capitalized : name
        }.joined(separator: "/") + (stack.isEmpty ? "" : "/")
    }
    private func output(_ value: JSONObject) { DispatchQueue.main.async { [weak self] in self?.receive?(value) } }
    private func outputError(_ error: Error) { output(["type": "error", "message": error.localizedDescription]) }
    private func reloadArt() {
        artwork = Set(((try? FileManager.default.contentsOfDirectory(at: paths.cache.appendingPathComponent("artwork"), includingPropertiesForKeys: nil)) ?? []).map { $0.lastPathComponent })
    }
    private func previewItem(_ thin: JSONObject) -> JSONObject {
        var item = thin
        if let full = store.item(text(thin["uri"])) {
            item = full.merging(thin) { _, new in new }
            if text(item["image"]).isEmpty { item["image"] = full["image"] }
        }
        if text(item["action"]) == "play", text(item["image"]).isEmpty,
           let collection = store.item(text(item["play_uri"])) { item["image"] = collection["image"] }
        return item
    }
    private func artPath(_ item: JSONObject) -> String {
        if let bundled = bundledArtwork(item, root: paths.root) { return bundled }
        let url = text(item["image"]); if url.isEmpty { return "" }
        let name = sha256(Data(url.utf8)) + ".img"
        return artwork.contains(name) ? paths.cache.appendingPathComponent("artwork/" + name).path : ""
    }
    private func nativeRow(_ item: JSONObject) -> JSONObject {
        let artists = (item["artists"] as? [JSONObject] ?? []).map { text($0["name"]) }.joined(separator: ", ")
        let albumInfo = dict(item["album"]), kind = text(item["kind"])
        let album = text(albumInfo["name"])
        let detail = kind == "track" ? [artists, album].filter { !$0.isEmpty }.joined(separator: " · ") : text(item["detail"]).isEmpty ? artists : text(item["detail"])
        return ["item": item.filter { Self.rowKeys.contains($0.key) }, "name": text(item["name"]), "uri": text(item["uri"]), "kind": kind, "detail": detail, "art": artPath(item), "symbol": item["symbol"] ?? Self.rowSymbols[kind] ?? "music.note", "artist": artists, "album": album, "album_uri": kind == "album" ? text(item["uri"]) : text(albumInfo["uri"]), "album_total": number(kind == "album" ? item["total"] : albumInfo["total"]), "match": [text(item["name"]), artists, album].joined(separator: " ")]
    }
    private func connectionItems() -> [JSONObject] {
        [actionItem(connection == "connecting" ? "Connecting to Spotify…" : "Connect to Spotify", "connect", ["symbol": "person.crop.circle", "detail": message])]
    }
    private func publishRows(command: String, resetText: Bool = false, pathPrefix: String? = nil) {
        let rows = connection == "connected" ? (try? library.browse(route)) ?? [] : connectionItems()
        var value: JSONObject = ["type": "update", "command": command, "connection": connection, "message": message, "route_kind": text(route["kind"]), "prefix": prefix, "rows": rows.map(nativeRow), "variables": [:], "navigation": navigationRequest]
        if let pathPrefix = pathPrefix { value["path_prefix"] = pathPrefix }
        if text(route["kind"]) == "catalog" {
            let query = text(route["query"])
            value["query"] = query
            value["searching"] = connection == "connected" && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && library.cachedSearch(query) == nil
        }
        if resetText { value["search_text"] = text(route["kind"]) == "catalog" ? "/" + text(route["query"]) : prefix }
        output(value)
    }
    private func sendCatalog() {
        guard store != nil else { return }; reloadArt()
        output(["type": "catalog", "rows": stableUnique(library.orderedPlaylists() + store.items()).map(nativeRow)])
    }
    private func connect() {
        if connection == "connecting", auth?.reopenBrowser({ [weak self] opened in
            guard !opened else { return }
            self?.queue.async {
                guard let self = self else { return }
                self.connection = "failed"; self.message = "Could not open your browser. Press Return to try again."
                self.publishRows(command: "connect")
            }
        }) == true { return }
        guard validCredentials else { connection = "credentials"; message = "Add your Spotify Client ID in the Workflow’s Configuration."; publishRows(command: "connect"); return }
        auth?.cancel(); auth = AuthorizationFlow(paths, api)
        connection = "connecting"; message = "Finish connecting in your browser"; publishRows(command: "connect", resetText: true)
        do {
            try auth?.start { [weak self] result in
                self?.queue.async {
                    guard let self = self else { return }
                    switch result {
                    case .success:
                        self.connection = "connected"; self.message = ""; self.stack = []; self.revision += 1
                        self.publishRows(command: "connected", resetText: true); self.sendCatalog(); self.refresh(force: true)
                    case .failure(let error): self.connection = "failed"; self.message = error.localizedDescription; self.publishRows(command: "connect")
                    }
                }
            }
        } catch { connection = "failed"; message = error.localizedDescription; publishRows(command: "connect") }
    }
    private func cleanCache() {
        guard !cleaningCache, store.get("cache:cleaned") == nil else { return }
        cleaningCache = true
        work.async { [weak self] in
            guard let self = self else { return }
            let removed = (try? self.cache.prune()) ?? 0
            try? self.store.put("cache:cleaned", true, ttl: 3600)
            self.queue.async {
                self.cleaningCache = false
                if removed > 0 { self.sendCatalog() }
            }
        }
    }
    private func warmArtwork() {
        guard !warmingArtwork else { return }
        warmingArtwork = true
        artworkWork.async { [weak self] in
            guard let self = self else { return }
            let local = (try? self.cache.preserveArtwork()) ?? 0
            let copied = local + ((try? self.cache.preserveArtwork(downloadMissing: true)) ?? 0)
            self.queue.async {
                self.warmingArtwork = false
                if copied > 0 { self.sendCatalog(); self.publishRows(command: "artwork") }
            }
        }
    }
    private func refresh(force: Bool) {
        guard !syncing, force || Date().timeIntervalSince(lastRefresh) >= 30 else { return }
        syncing = true
        lastRefresh = Date()
        let doSync = api.connected && (force || store.get("library:synced") == nil)
        work.async { [weak self] in
            guard let self = self else { return }
            var error: Error?, changed = force
            do {
                if force || self.store.get("desktop:scanned:v3") == nil {
                    changed = try self.cache.index() > 0 || changed
                    if let root = PlaylistOrder.desktopDirectory() {
                        if let order = PlaylistOrder.read(root), order != self.store.get("desktop:playlist-order", stale: true) as? [String] {
                            try self.store.put("desktop:playlist-order", order, ttl: 365 * 86400)
                            changed = true
                        }
                        changed = try DesktopMetadata.index(root, store: self.store) > 0 || changed
                    }
                    changed = try self.cache.preserveArtwork() > 0 || changed
                    try self.store.put("desktop:scanned:v3", true, ttl: 60)
                }
                // Publish local data before any network request or token refresh.
                if changed {
                    self.queue.async { self.sendCatalog(); self.publishRows(command: "refresh") }
                }
                if doSync { try self.library.sync(); changed = true }
            } catch let caught { error = caught }
            self.queue.async {
                self.syncing = false
                if changed { self.sendCatalog() }
                if self.connection == "connected", changed || error != nil {
                    self.message = (error as? SpotifyFailure)?.isNetworkError == true ? "" : error?.localizedDescription ?? ""
                    if let failure = error as? SpotifyFailure, failure.status == 401 { self.connection = "failed" }
                    self.publishRows(command: "refresh")
                }
                self.warmArtwork()
                self.cleanCache()
            }
        }
    }
    private func browseNetwork() {
        catalogRequest?.cancel()
        catalogRequest = nil
        let current = route, generation = revision
        guard ["artist", "album", "playlist", "catalog"].contains(text(current["kind"])) else { return }
        if text(current["kind"]) == "catalog" && text(current["query"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        let cancellation = text(current["kind"]) == "catalog" ? RequestCancellation() : nil
        catalogRequest = cancellation
        work.async { [weak self] in
            guard let self = self, cancellation?.isCancelled != true else { return }
            do {
                let rows = try self.library.browse(current, network: true, cancellation: cancellation)
                self.queue.async {
                    guard generation == self.revision, self.connection == "connected" else { return }
                    self.reloadArt()
                    self.output(["type": "update", "command": "browse", "connection": self.connection, "message": self.message, "route_kind": text(current["kind"]), "prefix": self.prefix, "query": text(current["query"]), "searching": false, "rows": rows.map(self.nativeRow), "variables": [:], "navigation": self.navigationRequest])
                    self.sendCatalog()
                    self.warmArtwork()
                }
            } catch {
                self.queue.async {
                    if generation == self.revision {
                        self.output(["type": "error", "message": error.localizedDescription, "route_kind": text(current["kind"]), "query": text(current["query"]), "navigation": self.navigationRequest])
                    }
                }
            }
        }
    }
    private func preview(_ thin: JSONObject) {
        var item = previewItem(thin)
        let selectedURI = text(thin["uri"])
        var title = text(item["name"]), detail = text(item["detail"])
        if text(item["kind"]) == "action", text(item["action"]) == "browse" {
            let kind = text(dict(item["target"])["kind"])
            let rows = (try? library.browse(["kind": kind])) ?? []
            let count = rows.lazy.filter { text($0["kind"]) != "action" }.count
            title = "\(count) \(text(item["name"]))"; detail = kind == "songs" ? "Liked Songs" : ""
            if let cover = rows.first(where: { !text($0["image"]).isEmpty }) { item["image"] = cover["image"] }
        } else if detail.isEmpty { detail = text(nativeRow(item)["detail"]) }
        let imageURL = text(item["image"]), previewTitle = title, previewDetail = detail
        let local = bundledArtwork(item, root: paths.root) ?? ((try? cache.image(imageURL, download: false)) ?? nil)
        var variables: JSONObject = ["preview_title": title, "preview_detail": detail]
        if let local = local { variables["preview_art"] = ["src": local] }
        output(["type": "update", "command": "preview", "connection": connection, "selected": selectedURI, "preview_complete": local != nil || imageURL.isEmpty, "variables": variables])
        if local != nil || imageURL.isEmpty { return }
        work.async { [weak self] in
            guard let self = self else { return }
            let path = (try? self.cache.image(imageURL, download: true)) ?? nil
            self.queue.async {
                self.reloadArt()
                var variables: JSONObject = ["preview_title": previewTitle, "preview_detail": previewDetail]
                if let path = path { variables["preview_art"] = ["src": path] }
                self.output(["type": "update", "command": "preview", "connection": self.connection, "selected": selectedURI, "preview_complete": true, "variables": variables])
            }
        }
    }
    private func likes(_ uri: String, target: Bool?) {
        guard validTrack(uri) else { return }
        if target == nil { output(["type": "liked", "uri": uri, "liked": store.isSaved(uri), "cached": true]) }
        likeWork.async { [weak self] in
            guard let self = self else { return }
            do {
                let liked: Bool
                if let target = target { try self.library.setLiked(uri, liked: target); liked = target }
                else { liked = try self.library.liked(uri) }
                self.output(["type": "liked", "uri": uri, "liked": liked, "changed": target != nil])
                if target != nil { self.queue.async { self.sendCatalog(); self.publishRows(command: "liked") } }
            } catch { self.output(["type": "liked", "uri": uri, "liked": self.store.isSaved(uri), "error": target != nil ? error.localizedDescription : ""]) }
        }
    }
    private func repeatCommand(_ mode: RepeatMode?, request: Int, playbackRequest: Int = 0) {
        if mode == nil {
            guard api.canReadPlayback, !repeatPolling else { return }
            repeatPolling = true
        }
        repeatWork.async { [weak self] in
            guard let self = self else { return }
            if let mode = mode {
                do {
                    try self.api.setRepeat(mode)
                    self.output(["type": "repeat", "mode": mode.rawValue, "request": request])
                } catch {
                    self.output(["type": "repeat", "mode": mode.rawValue, "request": request, "error": error.localizedDescription])
                }
            } else {
                if let state = try? self.api.playbackState() {
                    if let mode = RepeatMode(rawValue: text(state["repeat_state"])) {
                        self.output(["type": "repeat", "mode": mode.rawValue, "request": request, "poll": true])
                    }
                    self.queue.async { self.publishPlaybackContext(state, request: playbackRequest) }
                }
                self.queue.async { self.repeatPolling = false }
            }
        }
    }
    private func publishPlaybackContext(_ state: JSONObject, request: Int, resolve: Bool = true) {
        guard connection == "connected", playback.isDesktopDevice(dict(state["device"])) else { return }
        let track = text(dict(state["item"])["uri"])
        guard validTrack(track) else { return }
        playbackContextSnapshot = (state, request)
        let context = library.playbackContext(state)
        output(["type": "playback-context", "request": request, "track": track, "context": context?.object ?? [:]])
        guard resolve, let context = context, context.kind != "collection", context.name.isEmpty,
              resolvingContexts.insert(context.uri).inserted else { return }
        work.async {
            _ = self.library.playbackContext(state, network: true)
            self.queue.async {
                self.resolvingContexts.remove(context.uri)
                guard let latest = self.playbackContextSnapshot,
                      text(dict(latest.state["context"])["uri"]) == context.uri else { return }
                self.publishPlaybackContext(latest.state, request: latest.request, resolve: false)
            }
        }
    }
    static func clearConnection(_ paths: WorkflowPaths) throws {
        try paths.prepare()
        for name in ["authorization.json", "api-cooldown.json"] { try? FileManager.default.removeItem(at: paths.data.appendingPathComponent(name)) }
        let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
        try store.transaction { try store.execute("DELETE FROM saved"); try store.execute("DELETE FROM responses WHERE key NOT LIKE 'desktop:scanned%'") }
    }
    func send(_ value: JSONObject) {
        queue.async { [weak self] in
            guard let self = self, self.store != nil else { return }
            let command = text(value["command"]), args = value["args"] as? [String] ?? []
            let argument = args.first ?? ""
            if ["path", "activate", "back", "home", "catalog"].contains(command), let request = value["navigation"] as? Int {
                self.navigationRequest = request
            }
            do {
                switch command {
                case "show":
                    if !self.api.connected && self.connection == "connected" { self.connection = "cleared" }
                    if self.connection == "cleared" || self.connection == "credentials" && self.validCredentials { self.connect() }
                    else { self.publishRows(command: "show"); if self.connection == "connected" { self.refresh(force: false) } }
                case "connect": self.connect()
                case "reset":
                    self.auth?.cancel(); try Self.clearConnection(self.paths); self.connection = "cleared"; self.message = "Connection cleared"; self.stack = []; self.revision += 1
                    self.output(["type": "update", "connection": "cleared", "message": self.message, "close_player": true, "rows": self.connectionItems().map(self.nativeRow)])
                case "play":
                    let context = args.count > 1 ? args[1] : ""
                    let launched = args.count > 2 && args[2] == "started"
                    let request = args.count > 3 ? Int(args[3]) ?? 0 : 0
                    self.playbackCancellation?.cancel()
                    let cancellation = RequestCancellation()
                    self.playbackCancellation = cancellation
                    self.playbackWork.async {
                        do {
                            try self.playback.play(argument, context: context, recentlyLaunched: launched, cancellation: cancellation)
                            self.output(["type": "playback", "request": request])
                        } catch {
                            guard !cancellation.isCancelled else { return }
                            if WebPlayback.shouldUseAppleScript(error) {
                                do {
                                    let uri = try self.playback.fallbackURI(argument)
                                    self.output(["type": "playback", "request": request, "uri": uri, "context": context, "fallback": true])
                                } catch { self.output(["type": "playback", "request": request, "error": error.localizedDescription]) }
                            } else { self.output(["type": "playback", "request": request, "error": error.localizedDescription]) }
                        }
                    }
                case "repeat-state": self.repeatCommand(nil, request: Int(argument) ?? 0, playbackRequest: args.count > 1 ? Int(args[1]) ?? 0 : 0)
                case "repeat":
                    guard let mode = RepeatMode(rawValue: argument) else { throw SpotifyFailure(message: "Unknown repeat mode.") }
                    self.repeatCommand(mode, request: args.count > 1 ? Int(args[1]) ?? 0 : 0)
                case "liked": self.likes(argument, target: nil)
                case "save": self.likes(argument, target: true)
                case "unsave": self.likes(argument, target: false)
                case "image":
                    self.work.async { let path = (try? self.cache.image(argument, download: true)) ?? nil; self.output(["type": "artwork", "url": argument, "path": path ?? ""]) }
                case "preview": self.preview(argument.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSONObject } ?? [:])
                case "path":
                    guard self.connection == "connected" else { break }
                    let path = try self.library.resolvePath(argument)
                    self.stack = path.routes; self.revision += 1
                    self.publishRows(command: command, pathPrefix: path.consumed); self.browseNetwork()
                case "activate":
                    let item = argument.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSONObject } ?? [:]
                    if text(item["action"]) == "connect" { self.connect(); break }
                    let route = text(item["action"]) == "browse" ? dict(item["target"]).merging(["name": text(item["name"])]) { _, new in new } : self.store.item(text(item["uri"])) ?? item
                    guard self.connection == "connected" else { break }
                    self.stack.append(route); self.revision += 1; self.publishRows(command: command, resetText: true); self.browseNetwork()
                case "back", "home":
                    let hasFilter = command == "back" && text(self.route["kind"]) != "catalog" && argument.hasPrefix(self.prefix) && argument != self.prefix
                    if !hasFilter { if command == "home" { self.stack = [] } else if !self.stack.isEmpty { self.stack.removeLast() } }
                    self.revision += 1; self.publishRows(command: command, resetText: true); self.browseNetwork()
                case "catalog", "catalog-query":
                    guard self.connection == "connected" else { break }
                    let searching = text(self.route["kind"]) == "catalog"
                    if command == "catalog-query" && !searching { break }
                    let route: JSONObject = ["kind": "catalog", "query": argument, "name": "Spotify"]
                    if searching { self.stack[self.stack.count - 1] = route } else { self.stack.append(route) }
                    self.revision += 1
                    self.message = ""
                    self.publishRows(command: command, resetText: command == "catalog")
                    self.browseNetwork()
                case "refresh": self.message = "Refreshing Spotify…"; self.publishRows(command: command); self.refresh(force: true)
                case "configure":
                    let script = "Application('com.runningwithcrayons.Alfred').revealWorkflow('\(workflowID)', {configuration:true})"
                    self.work.async {
                        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); process.arguments = ["-l", "JavaScript", "-e", script]; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                        do { try process.run(); process.waitUntilExit(); if process.terminationStatus != 0 { throw SpotifyFailure(message: "Open Alfred Preferences → Workflows → Spotify → Configure.") }; self.output(["type": "update", "command": "configure", "connection": self.connection]) } catch { self.outputError(error) }
                    }
                default: break
                }
            } catch { self.outputError(error) }
        }
    }
}
