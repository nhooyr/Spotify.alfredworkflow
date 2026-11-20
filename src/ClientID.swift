import Foundation
import Darwin

func validClientID(_ value: String) -> Bool {
    let bytes = value.utf8
    return bytes.count == 32 && bytes.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
}

// Only the requested value leaves the shell; startup output and other variables are discarded.
enum ShellClientID {
    private static let lock = NSLock()
    private static var cached: String?
    static func load(reload: Bool = false) -> String {
        lock.lock(); defer { lock.unlock() }
        if !reload, let cached = cached { return cached }
        let value = read()
        cached = value
        return value
    }
    static func clear() {
        lock.lock(); cached = nil; lock.unlock()
    }
    static func read(environment: [String: String] = ProcessInfo.processInfo.environment, timeout: TimeInterval = 3) -> String {
        let configured = (environment["SHELL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let shell = configured.isEmpty ? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "" : configured
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else { return "" }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", #"printf '\000SPOTIFY_CLIENT_ID\000%s\000' "$SPOTIFY_CLIENT_ID""#]
        var environment = environment
        // An old Alfred configuration must not supply the new shell's value.
        environment.removeValue(forKey: "SPOTIFY_CLIENT_ID")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        defer {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        do { try process.run() } catch { return "" }
        try? pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = Date().addingTimeInterval(timeout)
        let marker = Data([0]) + Data("SPOTIFY_CLIENT_ID".utf8) + Data([0])
        var output = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let remaining = Int32(max(1, min(100, deadline.timeIntervalSinceNow * 1000)))
            if poll(&descriptor, 1, remaining) < 0 { if errno == EINTR { continue }; break }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EAGAIN || errno == EINTR { continue }; break }
            guard output.count + count <= 65536 else { return "" }
            output.append(contentsOf: buffer.prefix(count))
            if let marker = output.range(of: marker), let end = output[marker.upperBound...].firstIndex(of: 0) {
                return String(decoding: output[marker.upperBound..<end], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }
}

final class ClientIDSettings {
    private let root: URL
    let file: URL
    private let lock = NSLock()
    private var current: String
    init(root: URL, data: URL, initial: String) {
        self.root = root; file = data.appendingPathComponent("client-id.json")
        current = initial.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var value: String { lock.lock(); defer { lock.unlock() }; return current }
    private func set(_ value: String) { lock.lock(); current = value; lock.unlock() }
    func load(shellValue: String) throws {
        try removeSyncedValue()
        if validClientID(shellValue) { set(shellValue); return }
        let saved = text(dict(readJSON(file))["client_id"])
        if validClientID(saved) { set(saved); return }
        // An existing sign-in already keeps its app ID in private Workflow Data.
        let authorized = text(dict(readJSON(file.deletingLastPathComponent().appendingPathComponent("authorization.json")))["client_id"])
        if validClientID(authorized) { try save(authorized) } else { set("") }
    }
    func save(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validClientID(value) else { throw SpotifyFailure(message: "Enter the 32-character Spotify Client ID from your developer app.") }
        try writeJSON(["client_id": value], file)
        try removeSyncedValue()
        set(value)
    }
    func clear() throws {
        set("")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try removeSyncedValue()
    }
    private func removeSyncedValue() throws {
        let prefs = root.appendingPathComponent("prefs.plist")
        guard let data = try? Data(contentsOf: prefs) else { return }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var settings = try PropertyListSerialization.propertyList(from: data, format: &format) as? JSONObject,
              settings.removeValue(forKey: "SPOTIFY_CLIENT_ID") != nil else { return }
        try PropertyListSerialization.data(fromPropertyList: settings, format: format, options: 0).write(to: prefs, options: .atomic)
    }
}
