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
