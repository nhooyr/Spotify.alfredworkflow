import Foundation
import Security

protocol CredentialStorage {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func remove() throws
}

final class KeychainCredentialStorage: CredentialStorage {
    private let service: String
    private let keychain: SecKeychain?
    init(service: String = workflowID, keychain: SecKeychain? = nil) {
        self.service = service; self.keychain = keychain
    }
    private var query: [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: "authorization",
                                   kSecAttrSynchronizable as String: false]
        if let keychain = keychain { value[kSecMatchSearchList as String] = [keychain] }
        return value
    }
    private func check(_ status: OSStatus, _ action: String) throws {
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            throw SpotifyFailure(message: "Could not \(action) Spotify sign-in in Keychain: \(reason)")
        }
    }
    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, "read")
        guard let data = result as? Data else { throw SpotifyFailure(message: "Spotify sign-in in Keychain could not be read.") }
        return data
    }
    func write(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecItemNotFound { try check(status, "save"); return }
        var request = query
        request.removeValue(forKey: kSecMatchSearchList as String)
        if let keychain = keychain { request[kSecUseKeychain as String] = keychain }
        request[kSecAttrLabel as String] = "Spotify Mini Player Sign-In"
        request[kSecValueData as String] = data
        // The login Keychain’s default access controls trust only the creating signed app.
        let added = SecItemAdd(request as CFDictionary, nil)
        if added == errSecDuplicateItem {
            try check(SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary), "save")
        } else { try check(added, "save") }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status, "clear") }
    }
}

final class AuthorizationStore {
    struct Snapshot { let token: JSONObject; let generation: Int }
    private let storage: CredentialStorage
    let legacyURL: URL
    let legacyClientIDURL: URL
    private let lock = NSRecursiveLock()
    private var cached: JSONObject?
    private var clearError: Error?
    private var generation = 0
    init(data: URL, storage: CredentialStorage = KeychainCredentialStorage()) {
        legacyURL = data.appendingPathComponent("authorization.json")
        legacyClientIDURL = data.appendingPathComponent("client-id.json"); self.storage = storage
    }
    private func decode(_ data: Data) throws -> JSONObject {
        guard let token = try JSONSerialization.jsonObject(with: data) as? JSONObject,
              validClientID(text(token["client_id"])),
              ["access_token", "refresh_token"].allSatisfy({ token[$0] == nil || token[$0] is String }) else {
            throw SpotifyFailure(message: "Stored Spotify sign-in is damaged. Clear sign-in to reauthorize.")
        }
        return token
    }
    private func removeLegacy() throws {
        for file in [legacyURL, legacyClientIDURL] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
    func snapshot() throws -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        if let clearError = clearError { throw clearError }
        if let cached = cached { return Snapshot(token: cached, generation: generation) }
        let token: JSONObject
        if let data = try storage.read() {
            token = try decode(data)
            try removeLegacy()
        } else if FileManager.default.fileExists(atPath: legacyURL.path) || FileManager.default.fileExists(atPath: legacyClientIDURL.path) {
            var previous = FileManager.default.fileExists(atPath: legacyURL.path) ? try decode(Data(contentsOf: legacyURL)) : [:]
            let savedID = text(dict(readJSON(legacyClientIDURL))["client_id"])
            if validClientID(savedID), savedID != text(previous["client_id"]) { previous = ["client_id": savedID] }
            if previous.isEmpty {
                token = [:]
            } else {
                let data = try jsonData(previous)
                try storage.write(data)
                guard try storage.read() == data else { throw SpotifyFailure(message: "Spotify sign-in could not be verified in Keychain. The previous sign-in files were kept.") }
                try removeLegacy()
                token = previous
            }
        } else { token = [:] }
        cached = token
        return Snapshot(token: token, generation: generation)
    }
    func load() throws -> JSONObject { try snapshot().token }
    func save(_ token: JSONObject, generation expected: Int? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        if let clearError = clearError { throw clearError }
        if let expected = expected, expected != generation { throw SpotifyFailure(message: "This sign-in was cleared. Connect again.") }
        let data = try jsonData(token)
        _ = try decode(data)
        try storage.write(data)
        try removeLegacy()
        cached = token
    }
    func saveClientID(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard validClientID(id) else { throw SpotifyFailure(message: "Enter the 32-character Spotify Client ID from your developer app.") }
        let previous = try load()
        if text(previous["client_id"]) != id { generation += 1 }
        try save(text(previous["client_id"]) == id ? previous : ["client_id": id])
    }
    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        cached = [:]
        do { try storage.remove(); try removeLegacy(); clearError = nil }
        catch { clearError = error; throw error }
    }
}
