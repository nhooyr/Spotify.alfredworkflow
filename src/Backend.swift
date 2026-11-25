import AppKit
import Foundation

final class NativeBackend {
  var receive: ((JSONObject) -> Void)?
  private let queue = DispatchQueue(label: "spotify.library", qos: .userInitiated)
  private let work = DispatchQueue(label: "spotify.io", qos: .utility, attributes: .concurrent)
  private let likeWork = DispatchQueue(label: "spotify.likes", qos: .userInitiated)
  private let repeatWork = DispatchQueue(label: "spotify.repeat", qos: .userInitiated)
  private let playbackWork = DispatchQueue(label: "spotify.web-playback", qos: .userInteractive)
  private var repeatPolling: (request: Int, playbackRequest: Int)?
  private var pendingRepeatPoll: (request: Int, playbackRequest: Int)?
  private var playbackContextSnapshot: (state: JSONObject, request: Int)?
  private var resolvingContexts: Set<String> = []
  private let artworkWork = DispatchQueue(label: "spotify.artwork", qos: .utility)
  private var warmingArtwork = false
  private var cleaningCache = false
  private var cacheMaintenance: DispatchSourceTimer?
  private var networkObserver: UUID?
  private var offline = false
  private let paths: WorkflowPaths
  private let session: URLSession?
  private let makeAuthorization: (WorkflowPaths, SpotifyAPI) -> AuthorizationFlow
  private var store: MusicStore!
  private var api: SpotifyAPI!
  private var playback: WebPlayback!
  private var playbackCancellation: RequestCancellation?
  private let transportLock = NSLock()
  private var transportCancellations: [RequestCancellation] = []
  private var cache: DesktopCache!
  private var library: MusicLibrary!
  private var auth: AuthorizationFlow?
  private var stack: [JSONObject] = []
  private var connection = "loading"
  private var messageIsError = false
  private var message = "" { didSet { messageIsError = false } }
  private var revision = 0
  private var navigationRequest = 0
  private var catalogRequest: RequestCancellation?
  private var apiRequests = 0
  private var syncing = false
  private var libraryCancellation: RequestCancellation?
  private var refreshAfterSync = false
  private var lastRefresh = Date.distantPast
  private static let rowKeys: Set<String> = [
    "uri", "name", "kind", "context", "playback_context", "action", "target", "play_uri", "image",
    "query", "is_local", "is_playable",
  ]
  private static let rowSymbols = [
    "playlist": "music.note.list", "album": "square.stack", "artist": "person.fill",
    "track": "music.note",
  ]
  private var running = false
  private var artwork: Set<String> = []
  var pid: Int32 { running ? getpid() : 0 }
  init(
    _ root: URL, environment: [String: String] = ProcessInfo.processInfo.environment,
    session: URLSession? = nil, credentials: AuthorizationStore? = nil,
    authorization: @escaping (WorkflowPaths, SpotifyAPI) -> AuthorizationFlow = {
      AuthorizationFlow($0, $1)
    }
  ) {
    paths = WorkflowPaths(root: root, environment: environment, authorization: credentials)
    self.session = session
    makeAuthorization = authorization
  }
  func start() throws {
    running = true
    queue.async { [weak self] in
      guard let self = self else { return }
      do {
        try self.paths.prepare()
        self.store = try MusicStore(self.paths.cache.appendingPathComponent("index.sqlite3"))
        self.api = SpotifyAPI(self.paths, session: self.session)
        self.cache = DesktopCache(self.paths, self.store)
        self.library = MusicLibrary(self.store, self.api, online: WebPlayback.networkAvailable)
        self.api.activity = { [weak self] active in self?.apiActivityChanged(active) }
        self.playback = WebPlayback(self.api, store: self.store)
        _ = try self.paths.authorization.load()
        try self.paths.loadClientID()
        self.offline = !WebPlayback.networkAvailable()
        self.networkObserver = NetworkAvailability.shared.observe { [weak self] online in
          self?.queue.async { self?.networkChanged(online) }
        }
        self.reloadArt()
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + 3600, repeating: 3600, leeway: .seconds(60))
        timer.setEventHandler { [weak self] in self?.cleanCache() }
        self.cacheMaintenance = timer
        timer.resume()
        if self.api.connected {
          self.connection = "connected"
          self.publishRows(command: "init", resetText: true)
          self.sendCatalog()
          let preparation = RequestCancellation()
          self.playbackCancellation = preparation
          self.playbackWork.async { self.playback.prepare(cancellation: preparation) }
          self.refresh(force: false)
        } else if self.validCredentials {
          self.connect()
        } else {
          self.connection = "credentials"
          self.message = "Enter your Spotify Client ID, then press Return."
          self.publishRows(command: "init", resetText: true)
        }
      } catch {
        self.connection = "failed"
        self.message = error.localizedDescription
        self.messageIsError = true
        self.running = false
        self.publishRows(command: "init")
      }
    }
  }
  func stop() {
    running = false
    playbackCancellation?.cancel()
    transportLock.lock()
    let transports = transportCancellations
    transportCancellations.removeAll()
    transportLock.unlock()
    for cancellation in transports { cancellation.cancel() }
    libraryCancellation?.cancel()
    auth?.cancel()
    cacheMaintenance?.cancel()
    cacheMaintenance = nil
    if let observer = networkObserver {
      NetworkAvailability.shared.removeObserver(observer)
      networkObserver = nil
    }
  }
  private func networkChanged(_ online: Bool) {
    guard offline == online, store != nil, running else { return }
    offline = !online
    revision += 1
    catalogRequest?.cancel()
    catalogRequest = nil
    sendCatalog()
    publishRows(command: "refresh")
    if connection == "connected" { refresh(force: true) }
  }
  private var validCredentials: Bool { validClientID(paths.clientID()) }
  private var route: JSONObject { stack.last ?? ["kind": "home"] }
  private var prefix: String { LibraryPath.prefix(for: stack) }
  private func output(_ value: JSONObject) {
    let value = value.merging(["offline": !WebPlayback.networkAvailable()]) { _, latest in latest }
    DispatchQueue.main.async { [weak self] in self?.receive?(value) }
  }
  private func outputError(_ error: Error) {
    output(["type": "error", "message": error.localizedDescription])
  }
  private func apiActivityChanged(_ started: Bool) {
    queue.async { [weak self] in
      guard let self = self, self.running else { return }
      let wasActive = self.apiRequests > 0
      self.apiRequests = max(0, self.apiRequests + (started ? 1 : -1))
      if wasActive != (self.apiRequests > 0) {
        self.output(["type": "api-activity", "api_active": self.apiRequests > 0])
      }
    }
  }
  private func reloadArt() {
    artwork = Set(
      ((try? FileManager.default.contentsOfDirectory(
        at: paths.cache.appendingPathComponent("artwork"), includingPropertiesForKeys: nil)) ?? [])
        .map { $0.lastPathComponent })
  }
  private func previewItem(_ thin: JSONObject) -> JSONObject {
    var item = thin
    if let full = store.item(text(thin["uri"])) {
      item = full.merging(thin) { _, new in new }
      if text(item["image"]).isEmpty { item["image"] = full["image"] }
    }
    if text(item["action"]) == "play", text(item["image"]).isEmpty,
      let collection = store.item(text(item["play_uri"]))
    {
      item["image"] = collection["image"]
    }
    return item
  }
  private func artPath(_ item: JSONObject) -> String {
    if let bundled = bundledArtwork(item, root: paths.root) { return bundled }
    let url = text(item["image"])
    if url.isEmpty { return "" }
    let name = sha256(Data(url.utf8)) + ".img"
    return artwork.contains(name) ? paths.cache.appendingPathComponent("artwork/" + name).path : ""
  }
  private func nativeRow(_ item: JSONObject) -> JSONObject {
    let artists = (item["artists"] as? [JSONObject] ?? []).map { text($0["name"]) }.joined(
      separator: ", ")
    let albumInfo = dict(item["album"])
    let kind = text(item["kind"])
    let album = text(albumInfo["name"])
    let match = text(item["match"])
    let detail =
      kind == "track"
      ? [artists, album].filter { !$0.isEmpty }.joined(separator: " · ")
      : text(item["detail"]).isEmpty ? artists : text(item["detail"])
    return [
      "item": item.filter { Self.rowKeys.contains($0.key) }, "name": text(item["name"]),
      "uri": text(item["uri"]), "kind": kind, "detail": detail, "art": artPath(item),
      "symbol": item["symbol"] ?? Self.rowSymbols[kind] ?? "music.note", "artist": artists,
      "album": album, "album_uri": kind == "album" ? text(item["uri"]) : text(albumInfo["uri"]),
      "album_total": number(kind == "album" ? item["total"] : albumInfo["total"]),
      "match": match.isEmpty ? [text(item["name"]), artists, album].joined(separator: " ") : match,
    ]
  }
  private func connectionItems() -> [JSONObject] {
    [
      actionItem(
        connection == "connecting" ? "Connecting to Spotify…" : "Connect to Spotify", "connect",
        ["symbol": "person.crop.circle", "detail": message])
    ]
  }
  private func publishRows(command: String, resetText: Bool = false, pathPrefix: String? = nil) {
    let rows = connection == "connected" ? (try? library.browse(route)) ?? [] : connectionItems()
    var value: JSONObject = [
      "type": "update", "command": command, "connection": connection, "message": message,
      "message_is_error": messageIsError, "api_active": apiRequests > 0,
      "route_kind": text(route["kind"]), "prefix": prefix, "rows": rows.map(nativeRow),
      "variables": [:], "navigation": navigationRequest,
    ]
    if let pathPrefix = pathPrefix { value["path_prefix"] = pathPrefix }
    if text(route["kind"]) == "catalog" {
      let query = text(route["query"])
      value["query"] = query
      value["searching"] =
        connection == "connected" && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && WebPlayback.networkAvailable() && library.cachedSearch(query) == nil
    }
    if resetText {
      value["search_text"] = text(route["kind"]) == "catalog" ? "/" + text(route["query"]) : prefix
    }
    output(value)
  }
  private func sendCatalog() {
    guard store != nil else { return }
    reloadArt()
    output(["type": "catalog", "rows": library.catalog().map(nativeRow)])
  }
  private func browserDidOpen(_ flow: AuthorizationFlow) {
    queue.async { [weak self, weak flow] in
      guard let self = self, let flow = flow, self.auth === flow, self.connection == "connecting"
      else { return }
      self.message = "Finish connecting in your browser"
      self.publishRows(command: "browser-opened")
      self.output(["type": "browser-opened"])
    }
  }
  private func connect() {
    do { _ = try paths.authorization.load() } catch {
      connection = "failed"
      message = error.localizedDescription
      messageIsError = true
      publishRows(command: "connect")
      return
    }
    if connection == "connecting", let pending = auth,
      pending.reopenBrowser({ [weak self, weak pending] opened in
        guard let self = self, let pending = pending else { return }
        if opened {
          self.browserDidOpen(pending)
          return
        }
        self.queue.async {
          guard self.auth === pending, self.connection == "connecting" else { return }
          self.failedSignIn(
            SpotifyFailure(message: "Could not open your browser. Try connecting again."))
        }
      }) == true
    {
      return
    }
    if !validCredentials { try? paths.loadClientID() }
    guard validCredentials else {
      connection = "credentials"
      message = "Enter your Spotify Client ID, then press Return."
      publishRows(command: "connect")
      return
    }
    auth?.cancel()
    let flow = makeAuthorization(paths, api)
    auth = flow
    connection = "connecting"
    message = "Checking Spotify Client ID…"
    publishRows(command: "connect", resetText: true)
    do {
      try flow.start(browserOpened: { [weak self, weak flow] in
        guard let flow = flow else { return }
        self?.browserDidOpen(flow)
      }) { [weak self, weak flow] result in
        self?.queue.async {
          guard let self = self, let flow = flow, self.auth === flow,
            self.connection == "connecting"
          else { return }
          switch result {
          case .success:
            self.connection = "connected"
            self.message = ""
            self.stack = []
            self.revision += 1
            self.publishRows(command: "connected", resetText: true)
            self.sendCatalog()
            self.refresh(force: true)
          case .failure(let error): self.failedSignIn(error)
          }
        }
      }
    } catch { failedSignIn(error) }
  }
  private func failedSignIn(_ error: Error) {
    auth?.cancel()
    auth = nil
    playbackCancellation?.cancel()
    catalogRequest?.cancel()
    libraryCancellation?.cancel()
    var reason = error.localizedDescription
    do { try Self.clearConnection(paths) } catch {
      reason += " Could not clear sign-in: " + error.localizedDescription
    }
    connection = "credentials"
    message = reason
    messageIsError = true
    stack = []
    revision += 1
    publishRows(command: "client-id-reset", resetText: true)
    output(["type": "error", "message": reason])
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
      let copied =
        local
        + (WebPlayback.networkAvailable()
          ? ((try? self.cache.preserveArtwork(downloadMissing: true)) ?? 0) : 0)
      self.queue.async {
        self.warmingArtwork = false
        if copied > 0 {
          self.sendCatalog()
          self.publishRows(command: "artwork")
        }
      }
    }
  }
  private func refresh(force: Bool) {
    if syncing {
      refreshAfterSync = refreshAfterSync || force
      return
    }
    guard force || Date().timeIntervalSince(lastRefresh) >= 30 else { return }
    syncing = true
    let cancellation = RequestCancellation()
    libraryCancellation = cancellation
    lastRefresh = Date()
    let doSync =
      WebPlayback.networkAvailable() && api.connected
      && (force || store.get(MusicLibrary.syncKey) == nil)
    work.async { [weak self] in
      guard let self = self else { return }
      var error: Error?
      var changed = force
      do {
        if force || self.store.get("desktop:scanned:v4") == nil {
          changed = try self.cache.index() > 0 || changed
          if let root = PlaylistOrder.desktopDirectory() {
            if let order = PlaylistOrder.read(root),
              order != self.store.get("desktop:playlist-order", stale: true) as? [String]
            {
              try self.store.put("desktop:playlist-order", order, ttl: 365 * 86400)
              changed = true
            }
            changed = try DesktopMetadata.index(root, store: self.store) > 0 || changed
          }
          changed = try self.cache.preserveArtwork() > 0 || changed
          try self.store.put("desktop:scanned:v4", true, ttl: 60)
        }
        // Publish local data before any network request or token refresh.
        if changed {
          self.queue.async {
            guard !cancellation.isCancelled else { return }
            self.sendCatalog()
            self.publishRows(command: "refresh")
          }
        }
        if doSync {
          try self.library.sync(cancellation: cancellation)
          changed = true
        }
      } catch let caught { error = caught }
      self.queue.async {
        self.syncing = false
        self.libraryCancellation = nil
        if !cancellation.isCancelled {
          if changed { self.sendCatalog() }
          if self.connection == "connected", changed || error != nil {
            self.message =
              (error as? SpotifyFailure)?.isNetworkError == true
              ? "" : error?.localizedDescription ?? ""
            self.messageIsError = error != nil && !self.message.isEmpty
            if let failure = error as? SpotifyFailure, failure.status == 401 {
              self.connection = "failed"
            }
            self.publishRows(command: "refresh")
          }
          self.warmArtwork()
          self.cleanCache()
        }
        if self.refreshAfterSync, self.running {
          self.refreshAfterSync = false
          self.refresh(force: true)
        }
      }
    }
  }
  private func browseNetwork() {
    catalogRequest?.cancel()
    catalogRequest = nil
    let current = route
    let generation = revision
    guard WebPlayback.networkAvailable(),
      ["artist", "album", "playlist", "catalog"].contains(text(current["kind"]))
    else { return }
    if text(current["kind"]) == "catalog"
      && text(current["query"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return
    }
    let cancellation = text(current["kind"]) == "catalog" ? RequestCancellation() : nil
    catalogRequest = cancellation
    work.async { [weak self] in
      guard let self = self, cancellation?.isCancelled != true else { return }
      do {
        let rows = try self.library.browse(current, network: true, cancellation: cancellation)
        self.queue.async {
          guard generation == self.revision, self.connection == "connected" else { return }
          self.reloadArt()
          self.output([
            "type": "update", "command": "browse", "connection": self.connection,
            "message": self.message, "route_kind": text(current["kind"]), "prefix": self.prefix,
            "query": text(current["query"]), "searching": false, "rows": rows.map(self.nativeRow),
            "variables": [:], "navigation": self.navigationRequest,
          ])
          self.sendCatalog()
          self.warmArtwork()
        }
      } catch {
        self.queue.async {
          if generation == self.revision {
            self.output([
              "type": "error", "message": error.localizedDescription,
              "route_kind": text(current["kind"]), "query": text(current["query"]),
              "navigation": self.navigationRequest,
            ])
          }
        }
      }
    }
  }
  private func preview(_ thin: JSONObject) {
    var item = previewItem(thin)
    let selectedURI = text(thin["uri"])
    var title = text(item["action"]) == "catalog" ? "Search Spotify" : text(item["name"])
    var detail = text(item["detail"])
    if text(item["kind"]) == "action", text(item["action"]) == "browse" {
      let kind = text(dict(item["target"])["kind"])
      let rows = (try? library.browse(["kind": kind])) ?? []
      let count = rows.lazy.filter { text($0["kind"]) != "action" }.count
      title = "\(count) \(text(item["name"]))"
      detail = kind == "songs" ? "Liked Songs" : ""
      if let cover = rows.first(where: { !text($0["image"]).isEmpty }) {
        item["image"] = cover["image"]
      }
    } else if detail.isEmpty {
      detail = text(nativeRow(item)["detail"])
    }
    let imageURL = text(item["image"])
    let previewTitle = title
    let previewDetail = detail
    let local =
      bundledArtwork(item, root: paths.root)
      ?? ((try? cache.image(imageURL, download: false)) ?? nil)
    var variables: JSONObject = ["preview_title": title, "preview_detail": detail]
    if let local = local { variables["preview_art"] = ["src": local] }
    output([
      "type": "update", "command": "preview", "connection": connection, "selected": selectedURI,
      "preview_complete": local != nil || imageURL.isEmpty, "variables": variables,
    ])
    if local != nil || imageURL.isEmpty { return }
    work.async { [weak self] in
      guard let self = self else { return }
      let path = (try? self.cache.image(imageURL, download: true)) ?? nil
      self.queue.async {
        self.reloadArt()
        var variables: JSONObject = [
          "preview_title": previewTitle, "preview_detail": previewDetail,
        ]
        if let path = path { variables["preview_art"] = ["src": path] }
        self.output([
          "type": "update", "command": "preview", "connection": self.connection,
          "selected": selectedURI, "preview_complete": true, "variables": variables,
        ])
      }
    }
  }
  private func likes(_ uri: String, target: Bool?) {
    guard validTrack(uri) else { return }
    if target == nil {
      output(["type": "liked", "uri": uri, "liked": store.isSaved(uri), "cached": true])
    }
    guard WebPlayback.networkAvailable() else {
      if target != nil {
        output([
          "type": "liked", "uri": uri, "liked": store.isSaved(uri),
          "error": "Connect to the internet to update Liked Songs.",
        ])
      }
      return
    }
    likeWork.async { [weak self] in
      guard let self = self else { return }
      do {
        let liked: Bool
        if let target = target {
          try self.library.setLiked(uri, liked: target)
          liked = target
        } else {
          liked = try self.library.liked(uri)
        }
        self.output(["type": "liked", "uri": uri, "liked": liked, "changed": target != nil])
        if target != nil {
          self.queue.async {
            self.sendCatalog()
            self.publishRows(command: "liked")
          }
        }
      } catch {
        self.output([
          "type": "liked", "uri": uri, "liked": self.store.isSaved(uri),
          "error": target != nil ? error.localizedDescription : "",
        ])
      }
    }
  }
  private func repeatCommand(_ mode: RepeatMode?, request: Int, playbackRequest: Int = 0) {
    guard WebPlayback.networkAvailable() else {
      if let mode = mode {
        output([
          "type": "repeat", "mode": mode.rawValue, "request": request,
          "error": "Connect to the internet to change repeat.",
        ])
      }
      return
    }
    if mode == nil {
      guard api.canReadPlayback else { return }
      if let current = repeatPolling {
        if current.request != request || current.playbackRequest != playbackRequest {
          pendingRepeatPoll = (request, playbackRequest)
        }
        return
      }
      repeatPolling = (request, playbackRequest)
    }
    repeatWork.async { [weak self] in
      guard let self = self else { return }
      if let mode = mode {
        do {
          try self.api.setRepeat(mode)
          self.output(["type": "repeat", "mode": mode.rawValue, "request": request])
        } catch {
          self.output([
            "type": "repeat", "mode": mode.rawValue, "request": request,
            "error": error.localizedDescription,
          ])
        }
      } else {
        if let state = try? self.api.playbackState() {
          if let mode = RepeatMode(rawValue: text(state["repeat_state"])) {
            self.output(["type": "repeat", "mode": mode.rawValue, "request": request, "poll": true])
          }
          self.queue.async {
            self.output([
              "type": "playback-state", "state": state, "request": playbackRequest,
              "remote": !dict(state["device"]).isEmpty
                && !self.playback.isDesktopDevice(dict(state["device"])),
            ])
            self.publishPlaybackContext(state, request: playbackRequest)
          }
        }
        self.queue.async {
          self.repeatPolling = nil
          if let pending = self.pendingRepeatPoll {
            self.pendingRepeatPoll = nil
            if self.running {
              self.repeatCommand(
                nil, request: pending.request, playbackRequest: pending.playbackRequest)
            }
          }
        }
      }
    }
  }
  private func publishPlaybackContext(_ state: JSONObject, request: Int, resolve: Bool = true) {
    guard connection == "connected" else { return }
    let track = text(dict(state["item"])["uri"])
    guard validTrack(track) else { return }
    playbackContextSnapshot = (state, request)
    let context = library.playbackContext(state)
    output([
      "type": "playback-context", "request": request, "track": track,
      "context": context?.object ?? [:],
    ])
    guard resolve, WebPlayback.networkAvailable(), let context = context,
      context.kind != "collection", context.name.isEmpty,
      resolvingContexts.insert(context.uri).inserted
    else { return }
    work.async {
      _ = self.library.playbackContext(state, network: true)
      self.queue.async {
        self.resolvingContexts.remove(context.uri)
        guard let latest = self.playbackContextSnapshot,
          text(dict(latest.state["context"])["uri"]) == context.uri
        else { return }
        self.publishPlaybackContext(latest.state, request: latest.request, resolve: false)
      }
    }
  }
  static func clearConnection(_ paths: WorkflowPaths) throws {
    try paths.prepare()
    try paths.clearClientID()
    for name in ["api-cooldown.json"] {
      let file = paths.data.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.removeItem(at: file)
      }
    }
    let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
    // Keep saved membership, order, browse results, and offline metadata through sign-in.
    try store.execute(
      "DELETE FROM responses WHERE key LIKE 'liked:%' OR key LIKE 'native:saved-recent:%' OR key='playback:liked-songs-uri'"
    )
  }
  func send(_ value: JSONObject) {
    queue.async { [weak self] in
      guard let self = self, self.store != nil else { return }
      let command = text(value["command"])
      let args = value["args"] as? [String] ?? []
      let argument = args.first ?? ""
      if ["path", "activate", "back", "home", "catalog"].contains(command),
        let request = value["navigation"] as? Int
      {
        self.navigationRequest = request
      }
      do {
        switch command {
        case "show":
          if !self.api.connected && self.connection == "connected" { self.connection = "cleared" }
          if self.connection == "cleared"
            || self.connection == "credentials" && self.validCredentials
          {
            self.connect()
          } else {
            self.publishRows(command: "show")
            if self.connection == "connected" { self.refresh(force: false) }
          }
        case "connect": self.connect()
        case "client-id":
          guard self.connection == "credentials" else { break }
          do {
            try self.paths.saveClientID(argument)
            self.connect()
          } catch { self.failedSignIn(error) }
        case "reset":
          self.auth?.cancel()
          self.libraryCancellation?.cancel()
          try Self.clearConnection(self.paths)
          self.connection = "cleared"
          self.message = "Sign-in and Client ID cleared"
          self.stack = []
          self.revision += 1
          self.output([
            "type": "update", "connection": "cleared", "message": self.message,
            "close_player": true, "rows": self.connectionItems().map(self.nativeRow),
          ])
        case "transport":
          let request = args.count > 1 ? Int(args[1]) ?? 0 : 0
          self.playbackCancellation?.cancel()
          let cancellation = RequestCancellation()
          self.transportLock.lock()
          self.transportCancellations.append(cancellation)
          self.transportLock.unlock()
          self.playbackWork.async {
            defer {
              self.transportLock.lock()
              self.transportCancellations.removeAll { $0 === cancellation }
              self.transportLock.unlock()
            }
            guard self.running, !cancellation.isCancelled else { return }
            do {
              var result = try self.playback.transport(argument, cancellation: cancellation)
              result["type"] = "transport"
              result["command"] = argument
              result["request"] = request
              if let state = result["state"] as? JSONObject, !dict(state["device"]).isEmpty {
                result["remote"] = !self.playback.isDesktopDevice(dict(state["device"]))
              }
              self.output(result)
            } catch {
              guard !cancellation.isCancelled else { return }
              var result: JSONObject = [
                "type": "transport", "command": argument, "request": request,
              ]
              if !WebPlayback.networkAvailable() {
                result["fallback"] = true
              } else {
                result["error"] = error.localizedDescription
              }
              self.output(result)
            }
          }
        case "play":
          let context = args.count > 1 ? args[1] : ""
          let launched = args.count > 2 && args[2] == "started"
          let request = args.count > 3 ? Int(args[3]) ?? 0 : 0
          self.playbackCancellation?.cancel()
          let cancellation = RequestCancellation()
          self.playbackCancellation = cancellation
          self.playbackWork.async {
            do {
              try self.playback.play(
                argument, context: context, recentlyLaunched: launched, cancellation: cancellation)
              self.output(["type": "playback", "request": request])
            } catch {
              guard !cancellation.isCancelled else { return }
              if !WebPlayback.networkAvailable() {
                do {
                  let uri = try self.playback.fallbackURI(argument)
                  self.output([
                    "type": "playback", "request": request, "uri": uri, "context": context,
                    "fallback": true,
                  ])
                } catch {
                  self.output([
                    "type": "playback", "request": request, "error": error.localizedDescription,
                  ])
                }
              } else if (error as? SpotifyFailure)?.requiresDesktopStart == true && !launched {
                self.output([
                  "type": "playback", "request": request, "uri": argument, "context": context,
                  "start_desktop": true,
                ])
              } else {
                self.output([
                  "type": "playback", "request": request, "error": error.localizedDescription,
                ])
              }
            }
          }
        case "repeat-state":
          self.repeatCommand(
            nil, request: Int(argument) ?? 0,
            playbackRequest: args.count > 1 ? Int(args[1]) ?? 0 : 0)
        case "repeat":
          guard let mode = RepeatMode(rawValue: argument) else {
            throw SpotifyFailure(message: "Unknown repeat mode.")
          }
          self.repeatCommand(mode, request: args.count > 1 ? Int(args[1]) ?? 0 : 0)
        case "liked": self.likes(argument, target: nil)
        case "save": self.likes(argument, target: true)
        case "unsave": self.likes(argument, target: false)
        case "image":
          self.work.async {
            let path =
              (try? self.cache.image(argument, download: WebPlayback.networkAvailable())) ?? nil
            self.output(["type": "artwork", "url": argument, "path": path ?? ""])
          }
        case "preview":
          self.preview(
            argument.data(using: .utf8).flatMap {
              try? JSONSerialization.jsonObject(with: $0) as? JSONObject
            } ?? [:])
        case "path":
          guard self.connection == "connected" else { break }
          let path = try self.library.resolvePath(argument)
          self.stack = path.routes
          self.revision += 1
          self.publishRows(command: command, pathPrefix: path.consumed)
          self.browseNetwork()
        case "activate":
          let item =
            argument.data(using: .utf8).flatMap {
              try? JSONSerialization.jsonObject(with: $0) as? JSONObject
            } ?? [:]
          if text(item["action"]) == "connect" {
            self.connect()
            break
          }
          let route =
            text(item["action"]) == "browse"
            ? dict(item["target"]).merging(["name": text(item["name"])]) { _, new in new }
            : self.store.item(text(item["uri"])) ?? item
          guard self.connection == "connected" else { break }
          self.stack.append(route)
          self.revision += 1
          self.publishRows(command: command, resetText: true)
          self.browseNetwork()
        case "back", "home":
          let hasFilter =
            command == "back" && text(self.route["kind"]) != "catalog"
            && argument.hasPrefix(self.prefix) && argument != self.prefix
          if !hasFilter {
            if command == "home" {
              self.stack = []
            } else if !self.stack.isEmpty {
              self.stack.removeLast()
            }
          }
          self.revision += 1
          self.publishRows(command: command, resetText: true)
          self.browseNetwork()
        case "catalog", "catalog-query":
          guard self.connection == "connected" else { break }
          let searching = text(self.route["kind"]) == "catalog"
          if command == "catalog-query" && !searching { break }
          let route: JSONObject = ["kind": "catalog", "query": argument, "name": "Spotify"]
          if searching {
            self.stack[self.stack.count - 1] = route
          } else {
            self.stack.append(route)
          }
          self.revision += 1
          self.message = ""
          self.publishRows(command: command, resetText: command == "catalog")
          self.browseNetwork()
        case "refresh":
          self.message = "Refreshing Spotify…"
          self.publishRows(command: command)
          self.refresh(force: true)
        case "configure":
          let script =
            "Application('com.runningwithcrayons.Alfred').revealWorkflow('\(workflowID)', {configuration:true})"
          self.work.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", "-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
              try process.run()
              process.waitUntilExit()
              if process.terminationStatus != 0 {
                throw SpotifyFailure(
                  message: "Open Alfred Preferences → Workflows → Spotify → Configure.")
              }
              self.output(["type": "update", "command": "configure", "connection": self.connection])
            } catch { self.outputError(error) }
          }
        default: break
        }
      } catch { self.outputError(error) }
    }
  }
}
