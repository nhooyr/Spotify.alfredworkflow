import AppKit
import CryptoKit
import Darwin
import Foundation

final class AuthorizationFlow {
  static let defaultCallbackPort: UInt16 = 8765
  private let callbackPort: UInt16
  private let timeout: TimeInterval
  private let paths: WorkflowPaths
  private let api: SpotifyAPI
  private var descriptor: Int32 = -1
  private let lock = NSLock()
  private var generation = ""
  private var browserReady = false
  private var validation: RequestCancellation?
  private let browser: (URL) -> Bool
  private(set) var authorizationURL: URL?
  init(
    _ paths: WorkflowPaths, _ api: SpotifyAPI,
    callbackPort: UInt16 = AuthorizationFlow.defaultCallbackPort, timeout: TimeInterval = 180,
    browser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
  ) {
    self.paths = paths
    self.api = api
    self.callbackPort = callbackPort
    self.timeout = timeout
    self.browser = browser
  }
  deinit { cancel() }
  func cancel() {
    lock.lock()
    let fd = descriptor
    let pending = validation
    descriptor = -1
    generation = ""
    browserReady = false
    validation = nil
    lock.unlock()
    pending?.cancel()
    if fd >= 0 {
      Darwin.shutdown(fd, SHUT_RDWR)
      Darwin.close(fd)
    }
  }
  @discardableResult func reopenBrowser(_ completion: @escaping (Bool) -> Void = { _ in }) -> Bool {
    lock.lock()
    let pending = descriptor >= 0
    let gen = generation
    let url = pending && browserReady ? authorizationURL : nil
    lock.unlock()
    guard pending else { return false }
    if let url = url {
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.lock.lock()
        let active = self.generation == gen && self.descriptor >= 0
        self.lock.unlock()
        if active { completion(self.browser(url)) }
      }
    }
    return true
  }
  func start(
    browserOpened: @escaping () -> Void = {}, _ completion: @escaping (Result<Void, Error>) -> Void
  ) throws {
    cancel()
    let id = paths.clientID()
    guard validClientID(id) else {
      throw SpotifyFailure(message: "Open Spotify Mini Player and enter your Spotify Client ID.")
    }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SpotifyFailure(message: "Could not start Spotify sign-in.") }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = callbackPort.bigEndian
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, 4) == 0 else {
      Darwin.close(fd)
      throw SpotifyFailure(
        message:
          "Could not open sign-in port \(callbackPort). Close any other connection attempt and try again."
      )
    }
    var size = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
    }
    let port = UInt16(bigEndian: address.sin_port)
    let host = "127.0.0.1:\(port)"
    let redirect = "http://\(host)/spotify_callback"
    let state = randomToken()
    let verifier = randomToken(64)
    let gen = UUID().uuidString
    let validation = RequestCancellation()
    lock.lock()
    descriptor = fd
    generation = gen
    self.validation = validation
    browserReady = false
    lock.unlock()
    var parts = URLComponents(string: "https://accounts.spotify.com/authorize")!
    parts.queryItems = [
      "client_id": id, "response_type": "code", "redirect_uri": redirect,
      "scope": SpotifyAPI.scopes, "state": state, "code_challenge_method": "S256",
      "code_challenge": base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))),
    ].map { URLQueryItem(name: $0.key, value: $0.value) }
    let url = parts.url!
    authorizationURL = url
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }
      func current() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.generation == gen && self.descriptor == fd
      }
      do { try self.api.validateClientID(id, redirect: redirect, cancellation: validation) } catch {
        guard current() else { return }
        self.cancel()
        completion(.failure(error))
        return
      }
      guard current() else { return }
      self.lock.lock()
      self.browserReady = true
      self.validation = nil
      self.lock.unlock()
      DispatchQueue.main.async { [weak self] in
        guard let self = self, current() else { return }
        if self.browser(url) {
          browserOpened()
        } else {
          self.cancel()
          completion(
            .failure(SpotifyFailure(message: "Could not open your browser. Try connecting again.")))
        }
      }
      let deadline = Date().addingTimeInterval(self.timeout)
      func respond(_ client: Int32, status: String, body: String, html: Bool = false) {
        let bytes = Data(body.utf8)
        let header =
          "HTTP/1.1 \(status)\r\nContent-Type: \(html ? "text/html" : "text/plain"); charset=utf-8\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        let packet = Data(header.utf8) + bytes
        packet.withUnsafeBytes { pointer in
          var offset = 0
          while offset < pointer.count {
            let count = Darwin.send(
              client, pointer.baseAddress!.advanced(by: offset), pointer.count - offset, 0)
            if count <= 0 { break }
            offset += count
          }
        }
      }
      while current() && Date() < deadline {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&pollFD, 1, 250) <= 0 { continue }
        guard current() else { return }
        let client = accept(fd, nil, nil)
        if client < 0 { continue }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request = Data()
        var bytes = [UInt8](repeating: 0, count: 2048)
        while request.count < 16384 {
          let n = Darwin.read(client, &bytes, bytes.count)
          if n <= 0 { break }
          request.append(contentsOf: bytes.prefix(n))
          if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        let lines = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        let suppliedHost = lines.first(where: { $0.lowercased().hasPrefix("host:") })?.dropFirst(5)
          .trimmingCharacters(in: .whitespaces)
        let parsed =
          first.count > 1 ? URLComponents(string: "http://" + host + String(first[1])) : nil
        let query = Dictionary(
          (parsed?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
          uniquingKeysWith: { first, _ in first })
        guard first.first == "GET", suppliedHost == host, parsed?.path == "/spotify_callback",
          query["state"] == state
        else {
          respond(client, status: "400 Bad Request", body: "Invalid sign-in callback.")
          Darwin.close(client)
          continue
        }
        do {
          if let reason = query["error"] {
            let sanitized =
              reason.range(of: #"^[a-zA-Z0-9_.-]{1,80}$"#, options: .regularExpression) != nil
              ? reason : "unknown_error"
            throw SpotifyFailure(
              message: sanitized == "server_error"
                ? "Spotify’s sign-in server encountered an error. Try again. (server_error)"
                : "Spotify could not complete sign-in. Try again. (\(sanitized))")
          }
          guard let code = query["code"], !code.isEmpty, current() else {
            throw SpotifyFailure(message: "This sign-in was cancelled. Connect again.")
          }
          _ = try self.api.exchange(
            [
              "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
              "redirect_uri": redirect,
            ], valid: current)
          guard current() else {
            Darwin.close(client)
            return
          }
          respond(
            client, status: "200 OK",
            body:
              "<!doctype html><meta charset=utf-8><title>Spotify connected</title><p>Opening Spotify Mini Player…</p><script>history.replaceState(null,'',location.pathname);window.close();</script>",
            html: true)
          Darwin.close(client)
          self.cancel()
          completion(.success(()))
          return
        } catch {
          guard current() else {
            Darwin.close(client)
            return
          }
          respond(client, status: "200 OK", body: error.localizedDescription)
          Darwin.close(client)
          self.cancel()
          completion(.failure(error))
          return
        }
      }
      if current() {
        self.cancel()
        completion(
          .failure(SpotifyFailure(message: "Spotify sign-in timed out. Press Return to try again."))
        )
      }
    }
  }
}
