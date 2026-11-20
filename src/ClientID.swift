import Foundation

func validClientID(_ value: String) -> Bool {
    let bytes = value.utf8
    return bytes.count == 32 && bytes.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
}

final class ClientIDSettings {
    private let authorization: AuthorizationStore
    private let lock = NSLock()
    private var current = ""
    init(authorization: AuthorizationStore) { self.authorization = authorization }
    var value: String { lock.lock(); defer { lock.unlock() }; return current }
    private func set(_ value: String) { lock.lock(); current = value; lock.unlock() }
    func load() throws {
        let authorized = text(try authorization.load()["client_id"])
        set(validClientID(authorized) ? authorized : "")
    }
    func save(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validClientID(value) else { throw SpotifyFailure(message: "Enter the 32-character Spotify Client ID from your developer app.") }
        try authorization.saveClientID(value)
        set(value)
    }
    func clear() throws {
        set("")
        try authorization.clear()
    }
}
