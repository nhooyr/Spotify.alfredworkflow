import Foundation
import SystemConfiguration
import Network

struct PlaybackContext: Equatable {
    let uri: String
    let kind: String
    var name: String
    static let likedSongs = PlaybackContext(uri: "spotify:collection:tracks", name: "Liked Songs")!
    init?(uri: String, name: String = "") {
        if isLikedSongsURI(uri) {
            self.kind = "collection"; self.name = "Liked Songs"
        } else {
            guard validURI(uri), !validTrack(uri) else { return nil }
            self.kind = uri.components(separatedBy: ":")[1]; self.name = name
        }
        self.uri = uri
    }
    init?(_ value: JSONObject) { self.init(uri: text(value["uri"]), name: text(value["name"])) }
    var object: JSONObject { ["uri": uri, "kind": kind, "name": name] }
    var label: String { kind == "collection" ? "Liked Songs" : name.isEmpty ? kind.capitalized : kind.capitalized + " · " + name }
}

enum DesktopAccount {
    static func currentUserID() -> String? {
        userID(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Spotify/prefs"))
    }
    static func userID(at file: URL) -> String? {
        guard let prefs = try? String(contentsOf: file, encoding: .utf8),
              let line = prefs.split(separator: "\n").first(where: { $0.hasPrefix("autologin.canonical_username=") }),
              let raw = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).last,
              let user = (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String,
              !user.isEmpty else { return nil }
        return user
    }
}

private final class NetworkAvailability {
    static let shared = NetworkAvailability()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var available = true
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock(); self.available = path.status != .unsatisfied; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "spotify.network", qos: .utility))
    }
    func isOnline() -> Bool { lock.lock(); defer { lock.unlock() }; return available }
}

// Kept on the backend's playback queue, separate from library sync and status polling.
final class WebPlayback {
    private let api: SpotifyAPI
    private let store: MusicStore?
    private let desktopUserID: () -> String?
    private let computerName: String
    private let online: () -> Bool
    private let wait: (TimeInterval) -> Void
    private var deviceID: String?

    init(_ api: SpotifyAPI, store: MusicStore? = nil, computerName: String = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ProcessInfo.processInfo.hostName,
         online: @escaping () -> Bool = WebPlayback.networkAvailable,
         wait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         desktopUserID: @escaping () -> String? = DesktopAccount.currentUserID) {
        self.api = api; self.store = store; self.computerName = computerName; self.online = online; self.wait = wait
        self.desktopUserID = desktopUserID
    }
    func isDesktopDevice(_ device: JSONObject) -> Bool {
        text(device["type"]).lowercased() == "computer"
            && text(device["name"]).compare(computerName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
    static func networkAvailable() -> Bool { NetworkAvailability.shared.isOnline() }
    static func shouldUseAppleScript(_ error: Error) -> Bool {
        guard let error = error as? SpotifyFailure else { return false }
        return error.isNetworkError || error.status == 404 || (500..<600).contains(error.status)
    }
    static func payload(_ uri: String, context: String) throws -> JSONObject {
        guard validPlaybackURI(uri), context.isEmpty || validURI(context) else {
            throw SpotifyFailure(message: "This selection cannot be played in Spotify.")
        }
        if validTrack(uri) {
            if context.hasPrefix("spotify:album:") || context.hasPrefix("spotify:playlist:") {
                return ["context_uri": context, "offset": ["uri": uri], "position_ms": 0]
            }
            return ["uris": [uri], "position_ms": 0]
        }
        return ["context_uri": uri, "position_ms": 0]
    }
    static func collectionURI(userID: String) -> String? {
        guard !userID.isEmpty, let encoded = userID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { return nil }
        return "spotify:user:" + encoded + ":collection"
    }
    private var cachedLikedSongsURI: String? {
        guard let uri = store?.get("playback:liked-songs-uri", stale: true) as? String,
              isLikedSongsURI(uri), uri != PlaybackContext.likedSongs.uri else { return nil }
        return uri
    }
    private func likedSongsURI(_ cancellation: RequestCancellation?) throws -> String {
        if let cached = cachedLikedSongsURI { return cached }
        let profile = dict(try api.request("/me", timeout: 2, cancellation: cancellation))
        guard let uri = Self.collectionURI(userID: text(profile["id"])) else {
            throw SpotifyFailure(message: "Spotify did not return an account ID for Liked Songs.")
        }
        try? store?.put("playback:liked-songs-uri", uri, ttl: 365 * 86400)
        return uri
    }
    func fallbackURI(_ uri: String) throws -> String {
        guard uri == PlaybackContext.likedSongs.uri else { return uri }
        if let id = desktopUserID(), let collection = Self.collectionURI(userID: id) { return collection }
        if let cached = cachedLikedSongsURI { return cached }
        throw SpotifyFailure(message: "Sign in to the Spotify desktop app or connect online once to play all Liked Songs.")
    }
    private func desktopDevice(_ cancellation: RequestCancellation? = nil) throws -> String {
        if let deviceID = deviceID { return deviceID }
        let devices = dict(try api.request("/me/player/devices", timeout: 2, cancellation: cancellation))["devices"] as? [JSONObject] ?? []
        let candidates = devices.filter {
            text($0["type"]) == "Computer" && $0["is_restricted"] as? Bool != true
                && text($0["name"]).compare(computerName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && !text($0["id"]).isEmpty
        }
        guard let device = candidates.first(where: { $0["is_active"] as? Bool == true }) ?? candidates.first else {
            throw SpotifyFailure(message: "Spotify’s desktop player is not available through the Web API.", status: 404)
        }
        let id = text(device["id"])
        deviceID = id
        return id
    }
    func prepare(cancellation: RequestCancellation? = nil) {
        guard online(), api.hasScope("user-read-playback-state"),
              number(dict(readJSON(api.tokenURL))["expires_at"]) > Date().timeIntervalSince1970 + 60 else { return }
        _ = try? desktopDevice(cancellation)
        _ = try? likedSongsURI(cancellation)
    }
    func play(_ uri: String, context: String = "", recentlyLaunched: Bool = false, cancellation: RequestCancellation? = nil) throws {
        var body = try Self.payload(uri, context: context)
        if cancellation?.isCancelled == true { throw URLError(.cancelled) }
        guard online() else { throw SpotifyFailure(message: "Spotify is offline.", isNetworkError: true) }
        guard api.hasScope("user-modify-playback-state"), api.hasScope("user-read-playback-state") else {
            throw SpotifyFailure(message: "Run \(api.paths.command("reauth")) to allow starting playback, then open Spotify Mini Player again.")
        }
        if uri == PlaybackContext.likedSongs.uri { body = try Self.payload(likedSongsURI(cancellation), context: context) }
        if recentlyLaunched { deviceID = nil }
        let attempts = recentlyLaunched ? 6 : 2
        let deadline = Date().addingTimeInterval(recentlyLaunched ? 4 : 2.5)
        for attempt in 0..<attempts {
            do {
                if cancellation?.isCancelled == true { throw URLError(.cancelled) }
                let id = try desktopDevice(cancellation)
                _ = try api.request("/me/player/play", params: ["device_id": id], method: "PUT", body: body, timeout: 2, expectJSON: false, cancellation: cancellation)
                return
            } catch let error as SpotifyFailure where error.status == 404 && attempt + 1 < attempts && Date() < deadline {
                deviceID = nil
                if cancellation?.isCancelled == true { throw URLError(.cancelled) }
                if recentlyLaunched { wait(0.2) }
            }
        }
    }
}
