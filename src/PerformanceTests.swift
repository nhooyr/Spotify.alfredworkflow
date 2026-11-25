import Foundation

private final class PerformanceCredentials: CredentialStorage {
  func read() throws -> Data? { nil }
  func write(_ data: Data) throws {}
  func remove() throws {}
}

private final class PerformanceArtworkProtocol: URLProtocol {
  static let lock = NSLock()
  private static var urls: [String] = []
  static let image = Data([137, 80, 78, 71, 13, 10, 26, 10])
  static func requests(reset: Bool = false) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    let result = urls
    if reset { urls.removeAll() }
    return result
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock()
    Self.urls.append(request.url!.absoluteString)
    Self.lock.unlock()
    client?.urlProtocol(
      self,
      didReceive: HTTPURLResponse(
        url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
      cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.image)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

func runLibraryPerformanceRegressionTests() throws {
  func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else {
      throw SpotifyFailure(message: "Library performance regression test: " + message)
    }
  }
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "spotify-library-regression-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try MusicStore(root.appendingPathComponent("library.sqlite3"))
  let paths = WorkflowPaths(
    root: root,
    environment: [
      "alfred_workflow_cache": root.appendingPathComponent("cache").path,
      "alfred_workflow_data": root.appendingPathComponent("data").path,
      "SPOTIFY_DESKTOP_CACHE": root.appendingPathComponent("desktop").path,
    ], authorization: AuthorizationStore(storage: PerformanceCredentials()))
  try paths.prepare()
  let albumURI = "spotify:album:" + String(repeating: "a", count: 22)
  let otherAlbumURI = "spotify:album:" + String(repeating: "b", count: 22)
  let urls = ["a", "b", "c", "d"].map {
    "https://i.scdn.co/image/" + String(repeating: $0, count: 40)
  }
  try store.putItem(["uri": albumURI, "kind": "album", "name": "Selected Album", "image": urls[0]])
  try store.putItem([
    "uri": otherAlbumURI, "kind": "album", "name": "Other Album", "image": urls[1],
  ])
  func track(_ id: String, album: String, disc: Int, number: Int, image: String) -> JSONObject {
    [
      "uri": "spotify:track:" + String(repeating: id, count: 22), "kind": "track", "name": id,
      "album": ["uri": album], "disc_number": disc, "track_number": number, "image": image,
    ]
  }
  let discTwo = track("c", album: albumURI, disc: 2, number: 1, image: urls[2])
  let second = track("d", album: albumURI, disc: 1, number: 2, image: urls[0])
  let first = track("e", album: albumURI, disc: 1, number: 1, image: urls[3])
  let other = track("f", album: otherAlbumURI, disc: 1, number: 1, image: urls[2])
  for item in [discTwo, second, first, other] { try store.putItem(item) }
  try store.save(text(second["uri"]), liked: true)
  try store.save(text(first["uri"]), liked: true)
  let library = MusicLibrary(store, SpotifyAPI(paths), online: { true })
  let selected = try library.browse(["kind": "album", "uri": albumURI, "name": "Selected Album"])
  try require(
    Array(selected.dropFirst()).map { text($0["uri"]) }
      == [text(first["uri"]), text(second["uri"]), text(discTwo["uri"])],
    "album selection preserves disc/track order and excludes other albums")
  try require(
    selected.first.map { text($0["play_uri"]) } == albumURI
      && selected.dropFirst().allSatisfy { text($0["context"]) == albumURI },
    "indexed album browsing preserves the play row and playback context")
  var moved = other
  moved["album"] = ["uri": albumURI]
  try store.putItem(moved)
  try require(
    store.tracks(inAlbum: albumURI).count == 4 && store.tracks(inAlbum: otherAlbumURI).isEmpty,
    "album index follows metadata updates immediately")
  try store.execute("DELETE FROM items WHERE uri=?", [text(moved["uri"])])
  try require(
    store.tracks(inAlbum: albumURI).count == 3, "album index follows removals immediately")
  var seen = Set<String>()
  let projected = store.artworkURLs().filter {
    DesktopCache.imageURL($0) && seen.insert($0).inserted
  }
  let expectedArt = [urls[0], urls[3], urls[1], urls[2]]
  try require(
    projected == expectedArt, "artwork projection keeps saved-track priority and insertion order")
  let configuration = URLSessionConfiguration.ephemeral
  configuration.protocolClasses = [PerformanceArtworkProtocol.self]
  let session = URLSession(configuration: configuration)
  defer { session.invalidateAndCancel() }
  _ = PerformanceArtworkProtocol.requests(reset: true)
  let cache = DesktopCache(paths, store, session: session)
  try require(
    try cache.preserveArtwork(downloadMissing: true) == 4,
    "artwork warming preserves every distinct cover")
  try require(
    PerformanceArtworkProtocol.requests() == expectedArt,
    "artwork requests retain saved-track-first order")
  try require(
    try cache.preserveArtwork(downloadMissing: true) == 0, "cached artwork needs no further copies")
  try require(
    PerformanceArtworkProtocol.requests() == expectedArt, "cached artwork does not download again")
  func varint(_ input: UInt64) -> Data {
    var value = input
    var result = Data()
    repeat {
      let byte = UInt8(value & 127)
      value >>= 7
      result.append(byte | (value == 0 ? 0 : 128))
    } while value != 0
    return result
  }
  func proto(_ field: Int, _ value: Data) -> Data {
    varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value
  }
  func little(_ value: UInt64, _ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }
  let native = root.appendingPathComponent("metadata.ldb")
  try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
  let playlistURI = "spotify:playlist:" + String(repeating: "p", count: 22)
  let nativeTracks = (1...3).map {
    "spotify:track:" + spotifyID(Data(repeating: UInt8($0), count: 16))
  }
  let cover = "https://i.scdn.co/image/" + String(repeating: "09", count: 20)
  let album =
    proto(1, Data(repeating: 8, count: 16)) + proto(2, Data("Native album".utf8))
    + proto(9, proto(1, Data(repeating: 9, count: 20)))
  func nativeTrack(_ byte: UInt8) -> Data {
    let item =
      proto(1, Data(repeating: byte, count: 16)) + proto(2, Data("Native song".utf8))
      + proto(3, album)
    return proto(
      2, proto(1, Data("type.googleapis.com/spotify.metadata.Track".utf8)) + proto(2, item))
  }
  let contents =
    Data([8, 0, 16, 0])
    + nativeTracks.reduce(Data()) { $0 + proto(3, proto(1, Data($1.utf8))) }
  let list = Data([16, 3]) + proto(3, proto(1, Data("Native playlist".utf8))) + proto(5, contents)
  let records =
    [(DesktopMetadata.playlistKey(playlistURI), list)]
    + nativeTracks.enumerated().map {
      (DesktopMetadata.trackKey($0.element), nativeTrack(UInt8($0.offset + 1)))
    }
  var batch = little(1, 8) + little(UInt64(records.count), 4)
  for (key, value) in records {
    batch += Data([1]) + varint(UInt64(key.count)) + key + varint(UInt64(value.count)) + value
  }
  try (little(0, 4) + little(UInt64(batch.count), 2) + Data([1]) + batch)
    .write(to: native.appendingPathComponent("000001.log"))
  try store.put("desktop:playlist-order", [playlistURI])
  try store.putItem([
    "uri": nativeTracks[0], "kind": "track", "name": "Keep cached metadata", "image": urls[0],
  ])
  try store.putItem([
    "uri": nativeTracks[1], "kind": "track", "name": "Repair missing cover", "image": "",
  ])
  try store.save(nativeTracks[1], liked: true)
  _ = try DesktopMetadata.index(native, store: store)
  try require(
    text(store.item(nativeTracks[0])?["name"]) == "Keep cached metadata"
      && text(store.item(nativeTracks[0])?["image"]) == urls[0],
    "batch metadata lookup leaves complete cached tracks intact")
  try require(
    text(store.item(nativeTracks[1])?["image"]) == cover
      && text(store.item(nativeTracks[2])?["image"]) == cover
      && store.isSaved(nativeTracks[1]) && !store.isSaved(nativeTracks[2]),
    "batch metadata lookup repairs saved tracks and imports uncached playlist tracks")
  let playlist = try library.browse(["kind": "playlist", "uri": playlistURI])
  try require(
    Array(playlist.dropFirst()).map { text($0["uri"]) } == nativeTracks,
    "metadata batching preserves complete playlist order")
  try require(
    try DesktopMetadata.index(native, store: store) == 0,
    "unchanged native metadata is not reimported")
  print(
    "Library performance regression tests passed: indexed album membership, ordering, context, and prioritized artwork projection."
  )
}
