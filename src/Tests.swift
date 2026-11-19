import Foundation
import Darwin

import AppKit

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
}
private func tempDirectory(_ prefix: String) -> URL {
    let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(prefix + UUID().uuidString)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func encodeVarint(_ value: UInt64) -> Data { var value = value, data = Data(); repeat { let byte = UInt8(value & 127); value >>= 7; data.append(byte | (value > 0 ? 128 : 0)) } while value > 0; return data }
private func littleData(_ number: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) }) }
private func testBlock(_ key: Data, _ value: Data) -> Data { encodeVarint(0) + encodeVarint(UInt64(key.count)) + encodeVarint(UInt64(value.count)) + key + value + littleData(0, 4) + littleData(1, 4) }
private func proto(_ field: Int, _ data: Data) -> Data { encodeVarint(UInt64(field << 3 | 2)) + encodeVarint(UInt64(data.count)) + data }

final class TestURLProtocol: URLProtocol {
    static var response: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.response?(request) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class WaitingURLProtocol: URLProtocol {
    static let started = DispatchSemaphore(value: 0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started.signal() }
    override func stopLoading() {}
}

private func testThemes() {
    let root = tempDirectory("spotify-theme-tests-")
    defer { try? FileManager.default.removeItem(at: root) }
    let preferences = root.appendingPathComponent("preferences with \"quotes\".alfredpreferences")
    let file = preferences.appendingPathComponent("themes/theme.custom.fixture/theme.json")
    try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let doc: JSONObject = ["alfredtheme": ["window": ["color": "#182434CC", "borderColor": "#AABBCCFF", "roundness": 10],
        "result": ["text": ["color": "#EDF2F9FF", "colorSelected": "#102030FF", "font": "Avenir"],
                   "backgroundSelected": "#F3D257FF"], "search": ["text": ["color": "#F7F8F9FF"]]]]
    try! jsonData(doc).write(to: file)
    let source = ThemeSource()
    let context = ["id": "theme.custom.fixture", "preferences": preferences.path, "background": "rgba(255,255,255,1)"]
    let (firstKey, theme) = source.load(context: context, environment: [:], home: root, dark: false)
    check(abs(theme.background.alphaComponent - 0.8) < 0.001 && theme.cornerRadius == 10, "Alfred theme opacity and radius")
    check(theme.resultFont == "Avenir" && theme.searchText == PlayerTheme.color("#F7F8F9FF"), "Alfred theme fonts and cursor colour")
    check(source.load(context: context, environment: [:], home: root, dark: false).0 == firstKey, "Unchanged theme reuses parsed palette")
    try! jsonData(["alfredtheme": ["window": ["color": "#FFFFFFFF"]]]).write(to: file)
    try! FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)
    let (secondKey, changed) = source.load(context: context, environment: [:], home: root, dark: false)
    check(firstKey != secondKey && changed.background == PlayerTheme.color("#FFFFFFFF"), "Changed theme reloads in the resident player")
    let builtin = PlayerTheme(context: ["background": "rgba(12,20,30,0.8)", "selection": "rgba(250,240,230,1)"])
    check(builtin.text == .white && builtin.selectedText == .black && abs(builtin.background.alphaComponent - 0.8) < 0.001, "Built-in theme fallback remains legible")
    check(PlayerTheme.color("invalid") == nil && PlayerTheme.color("#xyz") == nil && PlayerTheme.color("rgba(1,2,3)") == nil, "Invalid theme colours fall back safely")
    check(PlayerTheme().font("missing-font", size: 16).pointSize == 16, "Unavailable theme font falls back to system font")
}

func runModelTests() {
    testThemes()
    let root = tempDirectory("spotify-model-tests-"); defer { try? FileManager.default.removeItem(at: root) }
    do {
        let paths = WorkflowPaths(root: root, environment: ["alfred_workflow_data": root.appendingPathComponent("data").path, "alfred_workflow_cache": root.appendingPathComponent("cache").path, "SPOTIFY_DESKTOP_CACHE": root.appendingPathComponent("desktop").path])
        try paths.prepare()
        try PropertyListSerialization.data(fromPropertyList: ["SPOTIFY_CLIENT_ID": String(repeating: "a", count: 32), "SPOTIFY_CLIENT_SECRET": "test-secret"], format: .xml, options: 0).write(to: root.appendingPathComponent("prefs.plist"))
        let store = try MusicStore(paths.cache.appendingPathComponent("index.sqlite3"))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TestURLProtocol.self]
        let api = SpotifyAPI(paths, session: URLSession(configuration: config)), library = MusicLibrary(store, api)
        let track: JSONObject = ["uri": "spotify:track:" + String(repeating: "t", count: 22), "id": String(repeating: "t", count: 22), "name": "Example", "kind": "track", "image": ""]
        try store.putItem(track)
        check(store.item(text(track["uri"]))?["name"] as? String == "Example", "SQLite metadata round trip")
        try store.save(text(track["uri"]), liked: true)
        check(store.isSaved(text(track["uri"])), "Liked membership persists")
        try store.put("test:expired", ["value": 2], ttl: -1)
        check(store.get("test:expired") == nil && store.get("test:expired", stale: true) != nil, "Cache expiry and stale read")
        let ids = ["z", "a", "m"].map { "spotify:playlist:" + String(repeating: $0, count: 22) }
        for (i, id) in ids.enumerated() { try store.putItem(["uri": id, "kind": "playlist", "name": ["Zebra", "Alpha", "Middle"][i]]); try store.save(id, liked: true) }
        try store.put("library:playlist-order", ids.reversed().map { $0 })
        check(library.orderedPlaylists().map { text($0["uri"]) } == ids.reversed().map { $0 }, "API playlist order survives")
        try store.put("desktop:playlist-order", ids)
        check(library.orderedPlaylists().map { text($0["uri"]) } == ids, "Desktop custom order overrides alphabetic and API order")
        let contents = ids.reduce(Data([8, 0, 16, 0])) { $0 + proto(3, proto(1, Data($1.utf8))) }
        check(PlaylistOrder.decode(proto(5, contents)) == ids, "Cached playlist-root protobuf order")
        let rootValue = proto(5, contents)
        let tableFolder = root.appendingPathComponent("table")
        try FileManager.default.createDirectory(at: tableFolder, withIntermediateDirectories: true)
        let key = Data("!pl#slc#2spotify:user:fixture:rootlist#".utf8) + littleData(7 << 8 | 1, 8)
        let dataBlock = testBlock(key, rootValue), indexBlock = testBlock(key, encodeVarint(0) + encodeVarint(UInt64(dataBlock.count)))
        let indexOffset = dataBlock.count + 5
        var footer = encodeVarint(0) + encodeVarint(0) + encodeVarint(UInt64(indexOffset)) + encodeVarint(UInt64(indexBlock.count))
        footer += Data(repeating: 0, count: 40 - footer.count); footer += littleData(0xdb4775248b80fb57, 8)
        try (dataBlock + Data(repeating: 0, count: 5) + indexBlock + Data(repeating: 0, count: 5) + footer).write(to: tableFolder.appendingPathComponent("000001.ldb"))
        check(PlaylistOrder.read(tableFolder) == ids, "Read custom order from immutable LevelDB table")
        for compressed in ["H4sIAAAAAAAA/0tOTM5ITVHITS1JTEksSQQA6hltWQ8AAAA=", "KLUv/SAPeQAAY2FjaGVkIG1ldGFkYXRh"] {
            let decoded = try DesktopCache.unpack(Data(base64Encoded: compressed)!)
            check(decoded == Data("cached metadata".utf8), "Native gzip/Zstandard cache decoding")
        }
        let cacheURL = "https://spclient.wg.spotify.com/metadata/4/track/" + String(repeating: "0", count: 32)
        let body = try jsonData(["gid": String(repeating: "0", count: 32), "name": "Cached song"])
        let checksum = body.withUnsafeBytes { spotify_crc32($0.baseAddress, $0.count) }
        let keyData = Data(cacheURL.utf8)
        let header = littleData(0xfcfb6d1ba7725c30, 8) + littleData(5, 4) + littleData(UInt64(keyData.count), 4) + Data(repeating: 0, count: 8)
        let bodyFooter = littleData(0xf4fa6f45970d41d8, 8) + littleData(1, 4) + littleData(UInt64(checksum), 4) + Data(repeating: 0, count: 8)
        let finalFooter = littleData(0xf4fa6f45970d41d8, 8) + Data(repeating: 0, count: 16)
        try FileManager.default.createDirectory(at: paths.desktop, withIntermediateDirectories: true)
        try (header + keyData + body + bodyFooter + finalFooter).write(to: paths.desktop.appendingPathComponent("test_0"))
        let cache = DesktopCache(paths, store), imported = try cache.index()
        check(imported == 1 && store.item("spotify:track:" + String(repeating: "0", count: 22)) != nil, "Read existing Chromium metadata without HTTP requests")
        let literal = Data("cached block".utf8)
        let decodedBlock = try PlaylistOrder.snappy(encodeVarint(UInt64(literal.count)) + Data([UInt8((literal.count - 1) << 2)]) + literal)
        check(decodedBlock == literal, "Snappy literal decoding")
        check(spotifyID(Data(repeating: 0, count: 16)) == String(repeating: "0", count: 22), "Spotify base62 zero")
        check(validTrack(text(track["uri"])) && !validTrack(ids[0]), "Only track URIs can be liked")
        var tokenRequests = 0
        var libraryMethods: [String] = []
        var staleLibrary = false
        var catalogRequests = 0
        var repeatRequests: [String] = []
        var repeatResponse = (204, Data())
        var playbackResponse = (200, try! jsonData(["repeat_state": "track"]))
        TestURLProtocol.response = { request in
            if request.url!.path == "/api/token" {
                tokenRequests += 1
                check(request.value(forHTTPHeaderField: "Authorization") == nil, "PKCE sends no client secret")
            }
            if request.url!.path == "/api/token" { return (200, try! jsonData(["access_token": "test", "refresh_token": "refresh", "expires_in": 3600, "scope": SpotifyAPI.scopes])) }
            if request.url!.path == "/v1/me/player/repeat" {
                check(request.httpMethod == "PUT", "Repeat uses the playback API setter")
                let state = request.url!.queryItemsForTesting.first { $0.name == "state" }?.value ?? ""
                repeatRequests.append(state)
                return repeatResponse
            }
            if request.url!.path == "/v1/me/player" { return playbackResponse }
            if request.url!.path == "/v1/search" {
                catalogRequests += 1
                return (200, try! jsonData(["tracks": ["items": [track]]]))
            }
            if request.url!.path == "/v1/me/library/contains" { return (200, try! jsonData([false])) }
            if request.url!.path == "/v1/me/library" { libraryMethods.append(request.httpMethod ?? ""); return (200, Data()) }
            if staleLibrary && request.url!.path == "/v1/me/tracks" { return (200, try! jsonData(["items": [["track": track]]])) }
            return (200, try! jsonData(["items": []]))
        }
        _ = try api.exchange(["grant_type": "authorization_code", "code_verifier": "test-verifier"])
        check(api.connected && api.canSave, "PKCE grants and persists scopes")
        for mode in RepeatMode.allCases { try api.setRepeat(mode) }
        check(repeatRequests == ["off", "context", "track"], "Repeat supports off, all, and one")
        let currentRepeat = try api.repeatState()
        check(currentRepeat == .track, "Read repeat mode from playback state")
        for response in [(200, Data("fixture-command-id".utf8)), (200, Data(" \n".utf8)), (204, Data())] {
            repeatResponse = response
            for mode in RepeatMode.allCases { try api.setRepeat(mode) }
        }
        repeatResponse = (403, Data("Forbidden".utf8))
        do { try api.setRepeat(.context); check(false, "Repeat must preserve real HTTP failures") }
        catch { check((error as? SpotifyFailure)?.status == 403, "Repeat reports unsuccessful HTTP status") }
        playbackResponse = (200, Data("malformed-playback-state".utf8))
        do { _ = try api.repeatState(); check(false, "Playback state still requires valid JSON") }
        catch { check(!(error is SpotifyFailure), "Read responses retain JSON validation") }
        repeatResponse = (204, Data())
        playbackResponse = (200, try! jsonData(["repeat_state": "track"]))
        let liked = try library.liked(text(track["uri"]))
        check(liked == false, "Public membership read updates cache")
        try library.setLiked(text(track["uri"]), liked: true)
        check(store.isSaved(text(track["uri"])), "Public save updates local membership")
        try library.setLiked(text(track["uri"]), liked: true)
        check(store.isSaved(text(track["uri"])) && libraryMethods.suffix(2) == ["PUT", "PUT"], "Like command is idempotent")
        try library.setLiked(text(track["uri"]), liked: false)
        try library.setLiked(text(track["uri"]), liked: false)
        check(!store.isSaved(text(track["uri"])) && libraryMethods.suffix(2) == ["DELETE", "DELETE"], "Unlike command is idempotent")
        staleLibrary = true
        try library.sync()
        check(!store.isSaved(text(track["uri"])), "An in-flight library refresh cannot re-like a removed song")
        staleLibrary = false
        var token = dict(readJSON(api.tokenURL)); token["scope"] = "user-library-read"; try writeJSON(token, api.tokenURL)
        do { try library.setLiked(text(track["uri"]), liked: true); check(false, "Save must require granted scope") } catch { check(error.localizedDescription.contains("spotify reauth"), "Save permission error is actionable") }
        do { try api.setRepeat(.context); check(false, "Repeat must require playback scope") }
        catch { check(error.localizedDescription.contains("spotify reauth"), "Repeat explains the missing playback permission") }
        token["expires_at"] = 0; try writeJSON(token, api.tokenURL)
        _ = try api.accessToken()
        check(tokenRequests == 2, "Refresh PKCE without client authentication")
        let emptySearch = try library.browse(["kind": "catalog", "query": ""], network: true)
        check(emptySearch.isEmpty && catalogRequests == 0, "Empty catalogue mode sends no search request")
        let results = try library.browse(["kind": "catalog", "query": "full catalogue"], network: true)
        _ = try library.browse(["kind": "catalog", "query": "full catalogue"], network: true)
        check(results.count == 1 && catalogRequests == 1, "Live catalogue queries reuse cached Spotify results")
        let cancelled = RequestCancellation()
        cancelled.cancel()
        do { _ = try api.request("/search", cancellation: cancelled); check(false, "Cancelled search must not run") }
        catch { check((error as? URLError)?.code == .cancelled && catalogRequests == 1, "Cancelled search never reaches Spotify") }
        let waitingConfig = URLSessionConfiguration.ephemeral
        waitingConfig.protocolClasses = [WaitingURLProtocol.self]
        let waitingAPI = SpotifyAPI(paths, session: URLSession(configuration: waitingConfig))
        let inFlight = RequestCancellation(), finishedSearch = DispatchSemaphore(value: 0)
        var cancelledInFlight = false
        DispatchQueue.global().async {
            do { _ = try waitingAPI.request("/search", cancellation: inFlight) }
            catch { cancelledInFlight = (error as? URLError)?.code == .cancelled }
            finishedSearch.signal()
        }
        check(WaitingURLProtocol.started.wait(timeout: .now() + 2) == .success, "Live search starts")
        inFlight.cancel()
        check(finishedSearch.wait(timeout: .now() + 2) == .success && cancelledInFlight, "Superseded in-flight search cancels immediately")
        try NativeBackend.clearConnection(paths)
        check(!api.connected && store.items().count == 5, "Reauth preserves music metadata")
        check(paths.credentials().0 == String(repeating: "a", count: 32), "Reauth preserves Client ID")
        check(homeItems.map { text($0["name"]) } == ["Playlists", "Albums", "Artists", "Songs", "Spotify"], "Menu priority")
        let finished = DispatchSemaphore(value: 0)
        var connected = false
        let flow = AuthorizationFlow(paths, api, browser: { _ in true })
        try flow.start { result in if case .success = result { connected = true }; finished.signal() }
        let query = Dictionary(flow.authorizationURL!.queryItemsForTesting.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        func callback(_ state: String) -> Int {
            var url = URLComponents(string: query["redirect_uri"]!)!
            url.queryItems = [URLQueryItem(name: "state", value: state), URLQueryItem(name: "code", value: "test-code")]
            let ready = DispatchSemaphore(value: 0); var status = 0
            URLSession.shared.dataTask(with: url.url!) { _, response, _ in status = (response as? HTTPURLResponse)?.statusCode ?? 0; ready.signal() }.resume()
            _ = ready.wait(timeout: .now() + 3); return status
        }
        check(callback("invalid") == 400 && !api.connected, "Reject invalid callback state")
        check(callback(query["state"]!) == 200, "Accept valid loopback callback")
        check(finished.wait(timeout: .now() + 2) == .success && connected && api.connected, "PKCE callback returns a usable native connection")
        if ProcessInfo.processInfo.environment["SPOTIFY_TEST_REAL_CACHE"] == "1", let directory = PlaylistOrder.desktopDirectory() {
            let start = Date(), order = PlaylistOrder.read(directory)
            check(!(order ?? []).isEmpty, "Read real desktop custom order")
            print("Desktop order verified: \(order!.count) playlists in \(Int(Date().timeIntervalSince(start) * 1000)) ms (read-only).")
        }
        print("Native model checks passed: themes, storage, cache, playlist ordering, PKCE, likes, repeat, and reset.")
    } catch { fputs("FAILED: \(error)\n", stderr); exit(1) }
}

private extension URL { var queryItemsForTesting: [URLQueryItem] { URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems ?? [] } }

private func spawnClient(_ url: URL, _ arguments: [String] = [], environment: [String: String]) {
    var argv = ([url.path] + arguments).map { strdup($0) } + [nil]
    var env = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
    defer { for p in argv { free(p) }; for p in env { free(p) } }
    var pid: pid_t = 0
    let result = argv.withUnsafeMutableBufferPointer { args in env.withUnsafeMutableBufferPointer { vars in posix_spawn(&pid, url.path, nil, nil, args.baseAddress!, vars.baseAddress!) } }
    check(result == 0, "Spawn native launcher")
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    check(status == 0, "Native launcher succeeded")
}

@discardableResult private func run(_ url: URL, _ args: [String] = [], environment: [String: String]) -> String {
    let process = Process(), output = Pipe(); process.executableURL = url; process.arguments = args; process.environment = environment; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { check(false, "Could not launch test child"); return "" }
    let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    check(process.terminationStatus == 0, "Test child exited with \(process.terminationStatus)")
    return String(decoding: data, as: UTF8.self)
}
func runIntegrationTests() {
    let root = tempDirectory("spotify-ui-tests-"); defer { try? FileManager.default.removeItem(at: root) }
    let executable = currentExecutable(), workflow = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let info = try! PropertyListSerialization.propertyList(from: Data(contentsOf: workflow.appendingPathComponent("info.plist")), format: nil) as! JSONObject
    let objects = info["objects"] as! [JSONObject]
    let keywords = objects.compactMap { dict($0["config"])["keyword"] as? String }
    for command in ["like", "unlike", "shuffle", "sequential", "screenshot"] { check(keywords.contains("spotify " + command), "Alfred keyword for " + command) }
    check(Set(objects.map { text($0["uid"]) }).count == objects.count, "Workflow object identifiers remain unique")
    check(!objects.contains { text($0["type"]) == "alfred.workflow.output.notification" }, "Reauth has no notification output")
    let feedback = objects.first { text($0["uid"]) == "REAUTH_RESULT" }
    check(text(feedback?["type"]) == "alfred.workflow.input.scriptfilter", "Reauth returns to Alfred results")
    let links = dict(info["connections"])
    check((links["CLEAR_ACTION"] as? [JSONObject])?.first?["destinationuid"] as? String == "REAUTH_RESULT", "Clearing sign-in shows the inline result")
    check((links["REAUTH_RESULT"] as? [JSONObject])?.first?["destinationuid"] as? String == "PLAYER", "Return on reauth result opens the player")
    let success = (reauthFeedback()["items"] as! [JSONObject])[0]
    check(text(success["title"]) == "Open Spotify Mini Player" && success["valid"] as? Bool == true, "Reauth result clearly offers the player")
    let failure = (reauthFeedback(error: "Fixture error")["items"] as! [JSONObject])[0]
    check(text(failure["subtitle"]) == "Fixture error" && failure["valid"] as? Bool == false, "Reauth errors stay visible in Alfred")
    var env = ProcessInfo.processInfo.environment
    env["SPOTIFY_NATIVE_SOCKET_DIR"] = root.appendingPathComponent("ipc").path
    env["alfred_workflow_data"] = root.appendingPathComponent("data").path
    env["alfred_workflow_cache"] = root.appendingPathComponent("cache").path
    env["SPOTIFY_DESKTOP_CACHE"] = root.appendingPathComponent("desktop").path
    env["SPOTIFY_DESKTOP_USER_CACHE"] = root.appendingPathComponent("empty").path
    env["SPOTIFY_CLIENT_ID"] = ""; env["SPOTIFY_CLIENT_SECRET"] = ""
    env["alfred_theme"] = "theme.custom.quoted\"\\name\nfixture"
    let ready = dict(try! JSONSerialization.jsonObject(with: Data(run(executable, ["--reauth-result"], environment: env).utf8)))
    check(((ready["items"] as? [JSONObject])?.first?["title"] as? String) == "Open Spotify Mini Player", "Inline reauth CLI emits valid Alfred JSON")
    var failedEnvironment = env; failedEnvironment["spotify_reauth_error"] = "Fixture error"
    let failed = dict(try! JSONSerialization.jsonObject(with: Data(run(executable, ["--reauth-result"], environment: failedEnvironment).utf8)))
    check(((failed["items"] as? [JSONObject])?.first?["valid"] as? Bool) == false, "Inline reauth errors cannot open a falsely successful result")
    let parent = Process(); parent.executableURL = URL(fileURLWithPath: "/bin/sleep"); parent.arguments = ["60"]; try! parent.run()
    let server = Process(); server.executableURL = executable; server.arguments = ["--test-server", "--lifetime-pid", String(parent.processIdentifier)]; server.environment = env; server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice; try! server.run()
    defer { if parent.isRunning { parent.terminate(); parent.waitUntilExit() }; if server.isRunning { server.terminate(); server.waitUntilExit() } }
    func request(_ command: String) -> JSONObject {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = env["SPOTIFY_NATIVE_SOCKET_DIR"]! + "/player.sock"
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if connected != 0 { return [:] }
        let packet = try! jsonData(["command": command, "build": Build.identifier]) + Data([10])
        _ = packet.withUnsafeBytes { write(fd, $0.baseAddress, packet.count) }
        var bytes = [UInt8](repeating: 0, count: 8192), data = Data()
        while !data.contains(10) { let n = read(fd, &bytes, bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }
        return dict(try? JSONSerialization.jsonObject(with: data))
    }
    let deadline = Date().addingTimeInterval(6)
    var initial: JSONObject = [:]
    while Date() < deadline { initial = request("state"); if initial["pid"] != nil { break }; usleep(20000) }
    check(initial["pid"] != nil, "Native test host started")
    var timings: [Double] = []
    for _ in 0..<50 { let start = DispatchTime.now().uptimeNanoseconds; spawnClient(workflow.appendingPathComponent("show"), environment: env); timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
    check(number(request("state")["pid"]) == number(initial["pid"]), "Hotkey keeps the same process")
    check(dict(request("state")["theme"])["id"] as? String == env["alfred_theme"], "C launcher safely forwards theme context")
    for command in ["test-ui", "test-editing", "test-controls", "test-repeat", "test-theme", "test-screenshot-mode", "test-search", "test-artwork", "test-catalog-mode"] {
        let initial = request(command)
        var result = initial
        let deadline = Date().addingTimeInterval(3)
        while text(result["status"]) == "pending" && Date() < deadline {
            usleep(10000)
            result = initial.merging(request(command + "-result")) { _, latest in latest }
        }
        for (key, value) in result where key != "status" { if let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { check(value.boolValue, command + ": " + key) } }
        check(text(result["status"]) == "ok", command + " completed")
        print("\(command): \(String(decoding: try! jsonData(result), as: UTF8.self))")
    }
    let showsBeforeCommands = number(request("state")["shows"])
    for (command, key, expected) in [("like", "liked", true), ("unlike", "liked", false), ("shuffle", "shuffling", true), ("sequential", "shuffling", false)] {
        spawnClient(workflow.appendingPathComponent("show"), ["--" + command], environment: env)
        spawnClient(workflow.appendingPathComponent("show"), ["--" + command], environment: env)
        check(request("state")[key] as? Bool == expected, "Repeated " + command + " command is idempotent")
    }
    check(number(request("state")["shows"]) == showsBeforeCommands, "State commands do not open the player")
    print("Idempotent like, unlike, shuffle, and sequential launcher commands passed.")
    spawnClient(workflow.appendingPathComponent("show"), ["--screenshot"], environment: env)
    check(request("state")["screenshot_mode"] as? Bool == true, "Screenshot command enables persistent visibility")
    _ = request("hide")
    check(request("state")["screenshot_mode"] as? Bool == false, "Hiding exits screenshot mode")
    let benchmark = request("benchmark"); check(number(benchmark["matches"]) == 111, "Native filter matches expected rows")
    print("50 launches: median \(timings.sorted()[25]) ms; 10,000-row filter \(number(benchmark["filter_ms"])) ms")
    parent.terminate(); parent.waitUntilExit(); server.waitUntilExit()
    check(!FileManager.default.fileExists(atPath: env["SPOTIFY_NATIVE_SOCKET_DIR"]! + "/player.sock"), "Host exits with Alfred lifetime")
    let liveParent = Process(); liveParent.executableURL = URL(fileURLWithPath: "/bin/sleep"); liveParent.arguments = ["20"]; try! liveParent.run()
    let live = Process(); live.executableURL = executable; live.arguments = ["--serve", "--lifetime-pid", String(liveParent.processIdentifier)]; live.environment = env; live.standardOutput = FileHandle.nullDevice; live.standardError = FileHandle.nullDevice; try! live.run()
    var liveState: JSONObject = [:]
    let liveDeadline = Date().addingTimeInterval(6)
    repeat { liveState = request("state"); if text(liveState["connection"]) == "credentials" { break }; usleep(20000) } while Date() < liveDeadline
    check(text(liveState["connection"]) == "credentials" && number(liveState["rows"]) == 1, "Native backend initializes without credentials or network")
    check(number(liveState["backend_pid"]) == number(liveState["pid"]), "Library backend runs in the same native process")
    liveParent.terminate(); liveParent.waitUntilExit(); live.waitUntilExit()
    let snapshot = root.appendingPathComponent("player.png")
    _ = run(executable, ["--snapshot", snapshot.path], environment: env)
    if let destination = env["SPOTIFY_TEST_SCREENSHOT"] { try? FileManager.default.removeItem(atPath: destination); try! FileManager.default.copyItem(at: snapshot, to: URL(fileURLWithPath: destination)) }
    print("Native integration checks passed.")
}
