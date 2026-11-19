import AppKit
import ImageIO

// Decode once off the UI thread, at the largest size the player displays.
func loadArtwork(_ path: String) -> NSImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
          ] as CFDictionary) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
}

// Spotify's cover: https://misc.scdn.co/liked-songs/liked-songs-640.png
func bundledArtwork(_ item: JSONObject, root: URL) -> String? {
    guard text(item["kind"]) == "action" else { return nil }
    let liked = text(item["action"]) == "play" && isLikedSongsURI(text(item["play_uri"]))
        || text(item["action"]) == "browse" && text(dict(item["target"])["kind"]) == "songs"
    guard liked else { return nil }
    let file = root.appendingPathComponent("icons/liked-songs.png")
    return FileManager.default.fileExists(atPath: file.path) ? file.path : nil
}
