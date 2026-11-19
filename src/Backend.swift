import AppKit
import Foundation

final class NativeBackend {
    var receive: ((JSONObject) -> Void)?
    private let queue = DispatchQueue(label: "spotify.library", qos: .userInitiated)
    private let work = DispatchQueue(label: "spotify.io", qos: .utility, attributes: .concurrent)
    private let likeWork = DispatchQueue(label: "spotify.likes", qos: .userInitiated)
    private let repeatWork = DispatchQueue(label: "spotify.repeat", qos: .userInitiated)
    private var repeatPolling = false
    private let paths: WorkflowPaths
    private var store: MusicStore!
    private var api: SpotifyAPI!
    private var cache: DesktopCache!
    private var library: MusicLibrary!
    private var auth: AuthorizationFlow?
    private var stack: [JSONObject] = []
    private var connection = "loading"
    private var message = ""
    private var revision = 0
    private var catalogRequest: RequestCancellation?
    private var syncing = false
    private var lastRefresh = Date.distantPast
    private static let rowKeys: Set<String> = ["uri", "name", "kind", "context", "action", "target", "play_uri", "query", "is_local", "is_playable"]
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
                self.reloadArt()
                if self.api.connected {
                    self.connection = "connected"; self.publishRows(command: "init", resetText: true); self.sendCatalog()
                    self.refresh(force: false)
                } else if self.validCredentials { self.connect() }
                else { self.connection = "credentials"; self.message = "Add your Client ID to continue"; self.publishRows(command: "init", resetText: true) }
            } catch { self.connection = "failed"; self.message = error.localizedDescription; self.running = false; self.publishRows(command: "init") }
        }
    }
    func stop() { running = false; auth?.cancel() }
    private var validCredentials: Bool { paths.credentials().0.range(of: #"^[a-fA-F0-9]{32}$"#, options: .regularExpression) != nil }
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
    private func artPath(_ item: JSONObject) -> String {
        let url = text(item["image"]); if url.isEmpty { return "" }
        let name = sha256(Data(url.utf8)) + ".img"
        return artwork.contains(name) ? paths.cache.appendingPathComponent("artwork/" + name).path : ""
    }
    private func nativeRow(_ item: JSONObject) -> JSONObject {
        let artists = (item["artists"] as? [JSONObject] ?? []).map { text($0["name"]) }.joined(separator: ", ")
        let album = text(dict(item["album"])["name"]), kind = text(item["kind"])
        let detail = kind == "track" ? [artists, album].filter { !$0.isEmpty }.joined(separator: " · ") : text(item["detail"]).isEmpty ? artists : text(item["detail"])
        return ["item": item.filter { Self.rowKeys.contains($0.key) }, "name": text(item["name"]), "uri": text(item["uri"]), "kind": kind, "detail": detail, "art": artPath(item), "symbol": item["symbol"] ?? Self.rowSymbols[kind] ?? "music.note", "match": [text(item["name"]), artists, album].joined(separator: " ")]
    }
    private func connectionItems() -> [JSONObject] {
        [actionItem(connection == "connecting" ? "Connecting to Spotify…" : "Connect to Spotify", "connect", ["symbol": "person.crop.circle", "detail": message])]
    }
    private func publishRows(command: String, resetText: Bool = false) {
        let rows = connection == "connected" ? (try? library.browse(route)) ?? [] : connectionItems()
        var value: JSONObject = ["type": "update", "command": command, "connection": connection, "message": message, "route_kind": text(route["kind"]), "prefix": prefix, "rows": rows.map(nativeRow), "variables": [:]]
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
        guard validCredentials else { connection = "credentials"; message = "Add your Client ID in the Workflow’s Configuration."; publishRows(command: "connect"); return }
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
    private func refresh(force: Bool) {
        guard !syncing, force || Date().timeIntervalSince(lastRefresh) >= 30 else { return }
        syncing = true
        lastRefresh = Date()
        let doSync = api.connected && (force || store.get("library:synced") == nil)
        work.async { [weak self] in
            guard let self = self else { return }
            var error: Error?
            var changed = force
            do {
                if force || self.store.get("desktop:scanned:v2") == nil {
                    changed = try self.cache.index() > 0 || changed
                    try self.store.put("desktop:scanned:v2", true, ttl: 300)
                }
                if let root = PlaylistOrder.desktopDirectory(), let order = PlaylistOrder.read(root), order != self.store.get("desktop:playlist-order", stale: true) as? [String] {
                    try self.store.put("desktop:playlist-order", order, ttl: 365 * 86400)
                    changed = true
                }
                if doSync { try self.library.sync(); changed = true }
            } catch let caught { error = caught }
            self.queue.async {
                self.syncing = false
                if changed { self.sendCatalog() }
                if self.connection == "connected", changed || error != nil {
                    self.message = error?.localizedDescription ?? ""
                    if let failure = error as? SpotifyFailure, failure.status == 401 { self.connection = "failed" }
                    self.publishRows(command: "refresh")
                }
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
                    self.output(["type": "update", "command": "browse", "connection": self.connection, "message": self.message, "route_kind": text(current["kind"]), "prefix": self.prefix, "query": text(current["query"]), "searching": false, "rows": rows.map(self.nativeRow), "variables": [:]])
                    self.sendCatalog()
                }
            } catch {
                self.queue.async {
                    if generation == self.revision {
                        self.output(["type": "error", "message": error.localizedDescription, "route_kind": text(current["kind"]), "query": text(current["query"])])
                    }
                }
            }
        }
    }
    private func preview(_ thin: JSONObject) {
        var item = thin
        if let full = store.item(text(thin["uri"])) { item = full.merging(thin) { _, new in new } }
        let selectedURI = text(thin["uri"])
        var title = text(item["name"]), detail = text(item["detail"])
        if text(item["kind"]) == "action", text(item["action"]) == "browse" {
            let kind = text(dict(item["target"])["kind"])
            let rows = (try? library.browse(["kind": kind])) ?? []
            title = "\(rows.count) \(text(item["name"]))"; detail = kind == "songs" ? "Liked Songs" : ""
            if let cover = rows.first(where: { !text($0["image"]).isEmpty }) { item["image"] = cover["image"] }
        } else if detail.isEmpty { detail = text(nativeRow(item)["detail"]) }
        let imageURL = text(item["image"]), previewTitle = title, previewDetail = detail
        let local = (try? cache.image(imageURL, download: false)) ?? nil
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
    private func repeatCommand(_ mode: RepeatMode?, request: Int) {
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
                if let mode = try? self.api.repeatState() {
                    self.output(["type": "repeat", "mode": mode.rawValue, "request": request, "poll": true])
                }
                self.queue.async { self.repeatPolling = false }
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
                case "repeat-state": self.repeatCommand(nil, request: Int(argument) ?? 0)
                case "repeat":
                    guard let mode = RepeatMode(rawValue: argument) else { throw SpotifyFailure(message: "Unknown repeat mode.") }
                    self.repeatCommand(mode, request: args.count > 1 ? Int(args[1]) ?? 0 : 0)
                case "liked": self.likes(argument, target: nil)
                case "save": self.likes(argument, target: true)
                case "unsave": self.likes(argument, target: false)
                case "image":
                    self.work.async { let path = (try? self.cache.image(argument, download: true)) ?? nil; self.output(["type": "artwork", "url": argument, "path": path ?? ""]) }
                case "preview": self.preview(argument.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSONObject } ?? [:])
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
