import AppKit
import Carbon
import CoreText
import Darwin

let socketDirectory =
  ProcessInfo.processInfo.environment["SPOTIFY_NATIVE_SOCKET_DIR"]
  ?? "/tmp/spotify-alfred-\(getuid())"
private let socketPath = socketDirectory + "/player.sock"
private let applicationID = "com.runningwithcrayons.Alfred"
private var playerTheme = PlayerTheme()

private var editingMenu: NSMenu?

private func installEditingMenu() {
  let root = NSMenu()
  let application = root.addItem(withTitle: "Spotify", action: nil, keyEquivalent: "")
  application.submenu = NSMenu(title: "Spotify")
  let edit = NSMenu(title: "Edit")
  for (title, selector, key, shifted) in [
    ("Undo", "undo:", "z", false), ("Redo", "redo:", "z", true),
    ("Cut", "cut:", "x", false), ("Copy", "copy:", "c", false),
    ("Paste", "paste:", "v", false), ("Select All", "selectAll:", "a", false),
  ] {
    let item = edit.addItem(
      withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
    item.keyEquivalentModifierMask = shifted ? [.command, .shift] : .command
  }
  let pastePlain = edit.addItem(
    withTitle: "Paste and Match Style", action: NSSelectorFromString("pasteAsPlainText:"),
    keyEquivalent: "v")
  pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
  root.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
  editingMenu = edit
  NSApp.mainMenu = root
}

private func performEditingKey(_ event: NSEvent, responder: NSResponder?) -> Bool {
  let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
  guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
  for item in editingMenu?.items ?? []
  where item.keyEquivalent.lowercased() == key && item.keyEquivalentModifierMask == modifiers {
    if let action = item.action, responder?.tryToPerform(action, with: item) == true { return true }
  }
  return false
}

private func socketAddress() -> sockaddr_un {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  withUnsafeMutableBytes(of: &address.sun_path) { bytes in
    let path = Array(socketPath.utf8) + [0]
    precondition(path.count <= bytes.count)
    bytes.copyBytes(from: path)
  }
  return address
}

func secureSocketDirectory() throws {
  try FileManager.default.createDirectory(
    atPath: socketDirectory, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  let attributes = try FileManager.default.attributesOfItem(atPath: socketDirectory)
  guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
    (attributes[.type] as? FileAttributeType) == .typeDirectory
  else {
    throw NSError(
      domain: "Spotify", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Invalid player socket directory."])
  }
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketDirectory)
}

private func writeMessage(_ value: [String: Any], to fd: Int32) {
  guard var data = try? JSONSerialization.data(withJSONObject: value) else { return }
  data.append(10)
  data.withUnsafeBytes { bytes in
    var offset = 0
    while offset < bytes.count {
      let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      if count <= 0 { break }
      offset += count
    }
  }
}

private func readMessage(_ fd: Int32) -> [String: Any]? {
  var data = Data()
  var bytes = [UInt8](repeating: 0, count: 1024)
  while data.count < 16384 {
    let count = Darwin.read(fd, &bytes, bytes.count)
    if count <= 0 { return nil }
    data.append(contentsOf: bytes.prefix(count))
    if let newline = data.firstIndex(of: 10) {
      return (try? JSONSerialization.jsonObject(with: data.prefix(upTo: newline))) as? [String: Any]
    }
  }
  return nil
}

func connectToPlayer(_ command: String) -> [String: Any]? {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  defer { Darwin.close(fd) }
  _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
  var noSignal: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
  var timeout = timeval(tv_sec: 2, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  var address = socketAddress()
  let result = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard result == 0 else { return nil }
  writeMessage(["command": command, "build": buildIdentifier], to: fd)
  return readMessage(fd)
}

func currentExecutable() -> URL {
  URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
}

func workflowRoot() -> URL {
  if Bundle.main.bundleURL.pathExtension == "app" {
    return Bundle.main.bundleURL.deletingLastPathComponent()
  }
  return currentExecutable().deletingLastPathComponent()
}

func launchServer(_ arguments: [String] = ["--serve"]) throws {
  let process = Process()
  process.executableURL = currentExecutable()
  process.arguments = arguments
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
}

private final class IPCServer {
  private var fd: Int32 = -1
  func start(handler: @escaping ([String: Any]) -> [String: Any]) throws {
    try secureSocketDirectory()
    if connectToPlayer("state") != nil {
      throw NSError(
        domain: "Spotify", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "The player is already running."])
    }
    unlink(socketPath)
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var address = socketAddress()
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0, listen(fd, 8) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    chmod(socketPath, 0o600)
    DispatchQueue(label: "spotify.show", qos: .userInteractive).async { [weak self] in
      guard let self = self else { return }
      while self.fd >= 0 {
        let client = accept(self.fd, nil, nil)
        if client < 0 { break }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        if let message = readMessage(client) {
          let reply = DispatchQueue.main.sync { handler(message) }
          writeMessage(reply, to: client)
        }
        Darwin.close(client)
      }
    }
  }
  func close() {
    if fd >= 0 {
      Darwin.close(fd)
      fd = -1
      unlink(socketPath)
    }
  }
}

private final class PlayerPanel: NSPanel {
  var keyAction: ((NSEvent) -> Bool)?
  var dismissAction: (() -> Void)?
  var interaction: ((NSEvent) -> Void)?
  var input: (() -> NSTextField?)?
  @discardableResult override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    if responder is NSTableView || responder is NSButton, let input = input?() {
      if let editor = input.currentEditor(), firstResponder === editor { return true }
      return super.makeFirstResponder(input)
    }
    return super.makeFirstResponder(responder)
  }
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, keyAction?(event) == true { return }
    interaction?(event)
    super.sendEvent(event)
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if keyAction?(event) == true { return true }
    if performEditingKey(event, responder: firstResponder) { return true }
    return super.performKeyEquivalent(with: event)
  }
  override func keyDown(with event: NSEvent) {
    if keyAction?(event) != true { super.keyDown(with: event) }
  }
  override func cancelOperation(_ sender: Any?) { dismissAction?() }
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

private final class SearchField: NSTextField {
  var keyAction: ((NSEvent) -> Bool)?
  var hint: String? { didSet { if hint != oldValue { needsDisplay = true } } }
  var hintColor = NSColor.placeholderTextColor
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard stringValue.isEmpty, (currentEditor()?.string ?? "").isEmpty, let hint = hint else {
      return
    }
    // AppKit clips Avenir's native placeholder; lay out only the hint ourselves.
    let text = NSAttributedString(
      string: hint,
      attributes: [.font: font ?? NSFont.systemFont(ofSize: 28), .foregroundColor: hintColor])
    let height = ceil(text.size().height)
    text.draw(
      in: NSRect(
        x: bounds.minX + 2, y: bounds.midY - height / 2, width: bounds.width - 4, height: height))
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if keyAction?(event) == true { return true }
    return super.performKeyEquivalent(with: event)
  }
}

private struct LaunchHotkey {
  let code: UInt16
  let modifiers: NSEvent.ModifierFlags
  static func read(_ workflow: JSONObject) -> LaunchHotkey? {
    guard
      let object = (workflow["objects"] as? [JSONObject])?.first(where: {
        text($0["uid"]) == "HOTKEY"
      }),
      text(object["type"]) == "alfred.workflow.trigger.hotkey"
    else { return nil }
    let config = dict(object["config"])
    let code = number(config["hotkey"])
    let modifiers = number(config["hotmod"])
    guard code >= 0, code <= Double(UInt16.max), modifiers >= 0, code != 0 || modifiers != 0 else {
      return nil
    }
    return LaunchHotkey(
      code: UInt16(code), modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers)))
  }
  func matches(_ event: NSEvent) -> Bool {
    event.keyCode == code
      && event.modifierFlags.intersection([.command, .control, .option, .shift]) == modifiers
  }
}

private struct MusicItem {
  let payload: [String: Any]
  let name: String
  let uri: String
  let kind: String
  let detail: String
  let art: String
  let symbol: String
  let artist: String
  let album: String
  let albumURI: String
  let albumTrackCount: Int
  let words: [Substring]
  let ascii: Bool
  var priority: Int {
    switch kind {
    case "playlist": return 0
    case "album": return 1
    case "artist": return 2
    case "track": return 3
    default: return 4
    }
  }
  static func prioritized(_ items: [MusicItem]) -> [MusicItem] {
    var groups = Array(repeating: [Int](), count: 5)
    var albumTotals: [String: Int] = [:]
    for (index, item) in items.enumerated() {
      groups[item.priority].append(index)
      if item.kind == "album", item.albumTrackCount > 0 {
        albumTotals[item.uri] = item.albumTrackCount
      }
    }
    guard !groups[1].isEmpty else { return groups.flatMap { $0.map { items[$0] } } }
    var singleTracks: [String: Int] = [:]
    for index in groups[3] {
      let track = items[index]
      guard !track.albumURI.isEmpty, singleTracks[track.albumURI] == nil else { continue }
      if albumTotals[track.albumURI] == 1
        || albumTotals[track.albumURI] == nil && track.albumTrackCount == 1
      {
        singleTracks[track.albumURI] = index
      }
    }
    var result = groups[0]
    var promoted: Set<Int> = []
    for index in groups[1] {
      if let track = singleTracks[items[index].uri], promoted.insert(track).inserted {
        result.append(track)
      }
      result.append(index)
    }
    result += groups[2]
    result += groups[3].filter { !promoted.contains($0) }
    result += groups[4]
    return result.map { items[$0] }
  }
  init(_ value: [String: Any]) {
    payload = value["item"] as? [String: Any] ?? [:]
    name = value["name"] as? String ?? ""
    uri = value["uri"] as? String ?? ""
    kind = value["kind"] as? String ?? ""
    detail = value["detail"] as? String ?? ""
    art = value["art"] as? String ?? ""
    symbol = value["symbol"] as? String ?? "music.note"
    artist = value["artist"] as? String ?? detail
    album = value["album"] as? String ?? ""
    albumURI = value["album_uri"] as? String ?? ""
    albumTrackCount = (value["album_total"] as? NSNumber)?.intValue ?? 0
    let normalized = Self.normalize(value["match"] as? String ?? name)
    words = normalized.split(whereSeparator: { $0.isWhitespace })
    ascii = normalized.utf8.allSatisfy { $0 < 128 }
  }
  private static let locale = Locale(identifier: "en_US_POSIX")
  static func normalize(_ text: String) -> String {
    text.utf8.allSatisfy { $0 < 128 }
      ? text.lowercased()
      : text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
  }
  func matches(_ terms: [Substring], ascii queryIsASCII: Bool) -> Bool {
    if ascii && queryIsASCII {
      return terms.allSatisfy { term in words.contains { $0.utf8.starts(with: term.utf8) } }
    }
    return terms.allSatisfy { term in words.contains { $0.hasPrefix(term) } }
  }
}

private struct MusicFilter {
  private var previousTerms: [Substring] = []
  private var results: [MusicItem] = []
  private var usesCatalog = false
  private var valid = false
  mutating func reset() {
    valid = false
    results = []
    previousTerms = []
  }
  mutating func matching(_ items: [MusicItem], terms: [Substring], catalog: Bool) -> [MusicItem] {
    let narrows =
      valid && usesCatalog == catalog && previousTerms.count <= terms.count
      && zip(previousTerms, terms).allSatisfy { $1.hasPrefix($0) }
    let candidates = narrows ? results : items
    let ascii = terms.allSatisfy { $0.utf8.allSatisfy { $0 < 128 } }
    results = terms.isEmpty ? items : candidates.filter { $0.matches(terms, ascii: ascii) }
    previousTerms = terms
    usesCatalog = catalog
    valid = true
    return results
  }
}

// Measure visible bounds once, retaining vector drawing at the display resolution.
private func tightImage(_ original: NSImage?, height: CGFloat) -> NSImage? {
  guard let original = original else { return nil }
  let scale: CGFloat = height <= 32 ? 8 : 2
  let size = original.size
  guard size.width > 0, size.height > 0,
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
      pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else { return nil }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
  context.cgContext.scaleBy(x: scale, y: scale)
  original.draw(in: NSRect(origin: .zero, size: size))
  NSGraphicsContext.restoreGraphicsState()
  guard let data = bitmap.bitmapData else { return nil }
  var minX = bitmap.pixelsWide
  var minY = bitmap.pixelsHigh
  var maxX = -1
  var maxY = -1
  for y in 0..<bitmap.pixelsHigh {
    for x in 0..<bitmap.pixelsWide where data[y * bitmap.bytesPerRow + x * 4 + 3] > 8 {
      minX = min(minX, x)
      maxX = max(maxX, x)
      minY = min(minY, y)
      maxY = max(maxY, y)
    }
  }
  guard maxX >= minX, maxY >= minY else { return nil }
  let crop = NSRect(
    x: CGFloat(minX) / scale, y: size.height - CGFloat(maxY + 1) / scale,
    width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
  let result = NSImage(
    size: NSSize(width: height * crop.width / crop.height, height: height), flipped: false
  ) { rect in
    original.draw(in: rect, from: crop, operation: .sourceOver, fraction: 1)
    return true
  }
  result.isTemplate = true
  return result
}

private var symbolImages: [String: NSImage] = [:]
private func systemImage(_ name: String, height: CGFloat) -> NSImage? {
  let key = "\(name):\(height)"
  if let image = symbolImages[key] { return image }
  let image = tightImage(
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
      .init(pointSize: height, weight: .regular)), height: height)
  symbolImages[key] = image
  return image
}

private func repeatAllImage(height: CGFloat) -> NSImage? {
  let key = "repeat.extended:\(height)"
  if let image = symbolImages[key] { return image }
  // Match the repeat symbol's stroke, extending both tips to the opposite tail.
  let drawing = NSImage(size: NSSize(width: 14, height: 11), flipped: false) { rect in
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: rect.minX, yBy: rect.minY)
    transform.scaleX(by: rect.width / 14, yBy: rect.height / 11)
    transform.concat()
    NSColor.black.set()
    for _ in 0..<2 {
      let arrow = NSBezierPath()
      arrow.lineWidth = 1.15
      arrow.lineCapStyle = .round
      arrow.move(to: NSPoint(x: 0.6, y: 5.2))
      arrow.line(to: NSPoint(x: 0.6, y: 6))
      arrow.curve(
        to: NSPoint(x: 2.8, y: 8.2), controlPoint1: NSPoint(x: 0.6, y: 7.25),
        controlPoint2: NSPoint(x: 1.55, y: 8.2))
      arrow.line(to: NSPoint(x: 11.1, y: 8.2))
      arrow.stroke()
      let head = NSBezierPath()
      head.move(to: NSPoint(x: 10.55, y: 10.2))
      head.line(to: NSPoint(x: 13.7, y: 8.2))
      head.line(to: NSPoint(x: 10.55, y: 6.2))
      head.close()
      head.lineWidth = 0.5
      head.lineJoinStyle = .round
      head.fill()
      head.stroke()
      let turn = NSAffineTransform()
      turn.translateX(by: 14, yBy: 11)
      turn.rotate(byDegrees: 180)
      turn.concat()
    }
    NSGraphicsContext.restoreGraphicsState()
    return true
  }
  let image = tightImage(drawing, height: height)
  symbolImages[key] = image
  return image
}

private final class ReturnGlyphView: NSView {
  var contentTintColor: NSColor = .labelColor { didSet { needsDisplay = true } }
  override func draw(_ dirtyRect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let transform = NSAffineTransform()
    transform.translateX(by: bounds.midX - 6, yBy: bounds.midY - 5)
    transform.scaleX(by: 12 / 14, yBy: 1)
    transform.concat()
    contentTintColor.set()
    let stem = NSBezierPath()
    stem.lineWidth = 1.5
    stem.lineCapStyle = .round
    stem.move(to: NSPoint(x: 3, y: 3.75))
    stem.line(to: NSPoint(x: 9.5, y: 3.75))
    stem.curve(
      to: NSPoint(x: 13.25, y: 7.5), controlPoint1: NSPoint(x: 12, y: 3.75),
      controlPoint2: NSPoint(x: 13.25, y: 5))
    stem.curve(
      to: NSPoint(x: 11.5, y: 9.25), controlPoint1: NSPoint(x: 13.25, y: 8.75),
      controlPoint2: NSPoint(x: 12.75, y: 9.25))
    stem.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 0, y: 3.75))
    head.line(to: NSPoint(x: 4.5, y: 7.5))
    head.line(to: NSPoint(x: 4.5, y: 0))
    head.close()
    head.fill()
    NSGraphicsContext.restoreGraphicsState()
  }
}

private let spotifyGreen = NSColor(
  srgbRed: 0x1e / 255, green: 0xd7 / 255, blue: 0x60 / 255, alpha: 1)

// NSButton's bezel metrics differ between symbols. Draw the visible glyph at
// the exact centre, retaining native target/action and keyboard accessibility.
private final class IconButton: NSButton {
  // Custom image and path drawing uses AppKit's bottom-up coordinates.
  override var isFlipped: Bool { false }
  var playbackHighlight = false
  var isPending = false { didSet { needsDisplay = true } }
  var currentTint: NSColor {
    isPending || playbackHighlight && cell?.isHighlighted == true
      ? spotifyGreen : contentTintColor ?? .secondaryLabelColor
  }
  private var drawingOpacity: CGFloat { isEnabled || isPending ? 1 : 0.35 }
  var showsSavedCheck = false { didSet { needsDisplay = true } }
  var showsActiveCircle = false { didSet { needsDisplay = true } }
  override func draw(_ dirtyRect: NSRect) {
    guard let image = image else { return }
    let center = NSPoint(x: bounds.midX, y: bounds.midY)
    if showsSavedCheck || showsActiveCircle {
      let green =
        cell?.isHighlighted == true
        ? spotifyGreen.blended(withFraction: 0.16, of: .black)! : spotifyGreen
      green.withAlphaComponent(drawingOpacity).setFill()
      NSBezierPath(ovalIn: NSRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22)).fill()
    }
    if showsSavedCheck {
      NSGraphicsContext.saveGraphicsState()
      NSColor.black.withAlphaComponent(drawingOpacity).setStroke()
      let check = NSBezierPath()
      check.lineWidth = 2
      check.lineCapStyle = .round
      check.lineJoinStyle = .round
      check.move(to: NSPoint(x: center.x - 4.9, y: center.y))
      check.line(to: NSPoint(x: center.x - 1.2, y: center.y - 3.7))
      check.line(to: NSPoint(x: center.x + 5.5, y: center.y + 3.7))
      check.stroke()
      NSGraphicsContext.restoreGraphicsState()
      return
    }
    let rect = NSRect(
      x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
      width: image.size.width, height: image.size.height)
    var imageRect = rect
    if let context = NSGraphicsContext.current?.cgContext,
      let mask = image.cgImage(
        forProposedRect: &imageRect, context: NSGraphicsContext.current, hints: nil)
    {
      context.saveGState()
      context.clip(to: rect, mask: mask)
      context.setAlpha(drawingOpacity)
      context.setFillColor((showsActiveCircle ? NSColor.black : currentTint).cgColor)
      context.fill(rect)
      context.restoreGState()
    }
  }
}

private final class MusicCell: NSTableCellView {
  let artwork = NSImageView()
  let title = NSTextField(labelWithString: "")
  let shortcut = NSTextField(labelWithString: "")
  let shortcutNumber = NSTextField(labelWithString: "")
  let returnArrow = ReturnGlyphView()
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    title.font = .systemFont(ofSize: 16)
    title.lineBreakMode = .byTruncatingTail
    shortcut.font = .systemFont(ofSize: 14)
    shortcut.alignment = .center
    shortcutNumber.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
    shortcutNumber.alignment = .center
    returnArrow.isHidden = true
    artwork.imageScaling = .scaleProportionallyDown
    for view in [artwork, title, shortcut, shortcutNumber, returnArrow] { addSubview(view) }
  }
  required init?(coder: NSCoder) { fatalError() }
  override func layout() {
    super.layout()
    artwork.frame = NSRect(x: 5, y: 2, width: 21, height: 21)
    returnArrow.frame = NSRect(x: bounds.width - 37, y: 0, width: 20, height: bounds.height)
    center(title, x: 33, width: max(0, bounds.width - 77))
    center(shortcut, x: bounds.width - 37, width: 20, glyphCentered: true)
    center(shortcutNumber, x: bounds.width - 22, width: 17, glyphCentered: true)
  }
  private func center(_ label: NSTextField, x: CGFloat, width: CGFloat, glyphCentered: Bool = false)
  {
    label.setFrameSize(NSSize(width: width, height: ceil(label.intrinsicContentSize.height)))
    let glyph = CTLineGetBoundsWithOptions(
      CTLineCreateWithAttributedString(label.attributedStringValue), .useGlyphPathBounds)
    let middle =
      glyphCentered && !label.stringValue.isEmpty ? glyph.midY : (label.font?.capHeight ?? 0) / 2
    let y = bounds.midY - middle - label.baselineOffsetFromBottom
    let scale = window?.backingScaleFactor ?? 2
    label.setFrameOrigin(NSPoint(x: x, y: (y * scale).rounded() / scale))
  }
  func display(_ item: MusicItem, index: Int, selected: Bool) {
    title.stringValue = item.name
    shortcut.stringValue = !selected && index < 9 ? "⌘" : ""
    returnArrow.isHidden = !selected
    shortcutNumber.stringValue = !selected && index < 9 ? String(index + 1) : ""
    title.font = playerTheme.font(playerTheme.resultFont, size: 16)
    shortcut.font = playerTheme.font(playerTheme.shortcutFont, size: 14)
    shortcutNumber.font = playerTheme.font(playerTheme.shortcutFont, size: 14)
    let color = selected ? playerTheme.selectedText : playerTheme.text
    title.textColor = color
    shortcut.textColor = selected ? playerTheme.selectedShortcut : playerTheme.shortcut
    shortcutNumber.textColor = shortcut.textColor
    returnArrow.contentTintColor = playerTheme.selectedShortcut
    artwork.contentTintColor = selected ? color : playerTheme.secondary
    artwork.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.kind)
    needsLayout = true
  }
}

private final class SelectionRow: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    playerTheme.selection.setFill()
    NSBezierPath(
      roundedRect: bounds, xRadius: playerTheme.resultRadius, yRadius: playerTheme.resultRadius
    ).fill()
  }
}

private final class ThemeScroller: NSScroller {
  override class var isCompatibleWithOverlayScrollers: Bool { true }
  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
  override func drawKnob() {
    let slot = rect(for: .knob)
    let width = min(slot.width, playerTheme.scrollbarWidth)
    let rect = NSRect(x: slot.midX - width / 2, y: slot.minY, width: width, height: slot.height)
    playerTheme.scrollbar.setFill()
    NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2).fill()
  }
}

final class SpotifyCommands {
  private let queue = DispatchQueue(label: "spotify.status", qos: .utility)
  private let playbackQueue = DispatchQueue(label: "spotify.playback", qos: .userInteractive)
  private var script: NSAppleScript?
  private var polling = false
  private var statusGeneration = 0
  private var launchedAt = Date.distantPast
  func validate() -> String? {
    let candidate = NSAppleScript(source: source)
    var error: NSDictionary?
    if candidate?.compileAndReturnError(&error) != true {
      return error?[NSAppleScript.errorMessage] as? String ?? "Could not compile playback script."
    }
    return nil
  }
  var status: (([String]) -> Void)?
  var failed: ((String) -> Void)?
  private let source = """
    on perform(commandName, trackURI, contextURI)
        if commandName is "shuffle-on" then
            tell application id "com.spotify.client" to set shuffling to true
        else if commandName is "shuffle-off" then
            tell application id "com.spotify.client" to set shuffling to false
        end if
    end perform
    on snapshot()
        if application id "com.spotify.client" is not running then return {}
        tell application id "com.spotify.client"
            try
                return {player state as text, name of current track, artist of current track, album of current track, artwork url of current track, id of current track, shuffling as text}
            on error
                return {player state as text}
            end try
        end tell
    end snapshot
    """
  private func call(_ name: String, arguments: [String]) -> NSAppleEventDescriptor? {
    if script == nil { script = NSAppleScript(source: source) }
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
      targetDescriptor: nil,
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
    )
    event.setParam(NSAppleEventDescriptor(string: name), forKeyword: AEKeyword(keyASSubroutineName))
    let list = NSAppleEventDescriptor.list()
    for (index, argument) in arguments.enumerated() {
      list.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
    }
    event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
    var error: NSDictionary?
    let result = script?.executeAppleEvent(event, error: &error)
    if let error = error {
      let code = error[NSAppleScript.errorNumber] as? Int ?? 0
      let message =
        code == -1743
        ? "Allow Spotify Mini Player to control Spotify in System Settings → Privacy & Security → Automation."
        : "Spotify is not responding. Open the Spotify desktop app and try again."
      DispatchQueue.main.async { self.failed?(message) }
      return nil
    }
    return result
  }
  func warm() {
    queue.async {
      self.script = NSAppleScript(source: self.source)
      var error: NSDictionary?
      _ = self.script?.compileAndReturnError(&error)
    }
  }
  static let playbackOptions: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract]
  static func backgroundLaunchConfiguration() -> NSWorkspace.OpenConfiguration {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    return configuration
  }
  static func playbackEvent(_ command: String, uri: String, context: String)
    -> NSAppleEventDescriptor?
  {
    let codes: [String: AEEventID] = [
      "play": 0x5043_7478, "toggle": 0x506c_5073, "next": 0x4e65_7874, "previous": 0x5072_6576,
    ]
    guard let code = codes[command] else { return nil }
    let event = NSAppleEventDescriptor(
      eventClass: 0x7370_6679, eventID: code,
      targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.spotify.client"),
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
    )
    if command == "play" {
      event.setParam(NSAppleEventDescriptor(string: uri), forKeyword: AEKeyword(keyDirectObject))
      if !context.isEmpty {
        event.setParam(NSAppleEventDescriptor(string: context), forKeyword: 0x636f_7478)
      }
    }
    return event
  }
  private func perform(_ command: String, uri: String, context: String) {
    if command == "shuffle-on" || command == "shuffle-off" {
      queue.async { _ = self.call("perform", arguments: [command, uri, context]) }
      return
    }
    playbackQueue.async {
      guard let event = Self.playbackEvent(command, uri: uri, context: context) else { return }
      do { _ = try event.sendEvent(options: Self.playbackOptions, timeout: 5) } catch {
        let code = (error as NSError).code
        let message =
          code == -1743
          ? "Allow Spotify Mini Player to control Spotify in System Settings → Privacy & Security → Automation."
          : "Spotify could not play this selection. Try again."
        DispatchQueue.main.async { self.failed?(message) }
      }
    }
  }
  func ensureRunning(_ completion: @escaping (Bool) -> Void) {
    if let app = NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.spotify.client"
    ).first {
      completion(!app.isFinishedLaunching || Date().timeIntervalSince(launchedAt) < 5)
    } else if let url = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: "com.spotify.client")
    {
      launchedAt = Date()
      NSWorkspace.shared.openApplication(
        at: url, configuration: Self.backgroundLaunchConfiguration()
      ) { app, error in
        DispatchQueue.main.async {
          guard app != nil, error == nil else {
            self.failed?("Could not start Spotify. Open the desktop app and try again.")
            return
          }
          completion(true)
        }
      }
    } else {
      failed?("Install the Spotify desktop app to play music.")
    }
  }
  func play(_ command: String, uri: String = "", context: String = "") {
    guard ["toggle", "shuffle-on", "shuffle-off", "next", "previous", "play"].contains(command)
    else { return }
    if command == "play" {
      guard validPlaybackURI(uri), context.isEmpty || validURI(context) else { return }
    }
    ensureRunning { _ in self.perform(command, uri: uri, context: context) }
  }
  func setShuffle(_ enabled: Bool) { play(enabled ? "shuffle-on" : "shuffle-off") }
  func currentTrack(_ completion: @escaping (String?) -> Void) {
    queue.async {
      let result = self.call("snapshot", arguments: [])
      let uri = (result?.numberOfItems ?? 0) >= 6 ? result?.atIndex(6)?.stringValue : nil
      DispatchQueue.main.async { completion(uri) }
    }
  }
  func invalidateStatus() { statusGeneration += 1 }
  func poll() {
    guard !polling else { return }
    let generation = statusGeneration
    polling = true
    queue.async {
      let result = self.call("snapshot", arguments: [])
      let values =
        result.map { value in
          (1...max(1, value.numberOfItems)).compactMap { value.atIndex($0)?.stringValue }
        } ?? []
      DispatchQueue.main.async {
        self.polling = false
        if result != nil, generation == self.statusGeneration { self.status?(values) }
      }
    }
  }
}

final class PlayerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
  NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate
{
  private let testMode: Bool
  private let themes = ThemeSource()
  private var themeContext: [String: String] = [:]
  private var themeSignature = ""
  private let server = IPCServer()
  private let credentials: AuthorizationStore?
  private var backend: NativeBackend
  private let spotify = SpotifyCommands()
  private let panel = PlayerPanel(
    contentRect: NSRect(x: 0, y: 0, width: 592, height: 470),
    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
  private let search = SearchField()
  private let table = NSTableView()
  private let scroll = NSScrollView()
  private let preview = NSImageView()
  private let previewTitle = NSTextField(labelWithString: "")
  private let previewDetail = NSTextField(wrappingLabelWithString: "")
  private let nowArt = NSImageView()
  private let nowTitle = NSTextField(labelWithString: "No track")
  private let nowDetail = NSTextField(labelWithString: "")
  private let nowContext = NSTextField(labelWithString: "")
  private var currentPlaybackContext: PlaybackContext?
  private var selectedSourceTrack = ""
  private var observedPlaybackContext: (track: String, context: PlaybackContext?)?
  private let status = NSTextField(labelWithString: "Loading your Spotify library…")
  private let activityStatus = NSTextField(labelWithString: "")
  private var offline = false
  private var apiActive = false
  private var apiActivityVisible = false
  private var apiActivityShownAt = Date.distantPast
  private var apiActivityWork: DispatchWorkItem?
  private let toggle = IconButton()
  private let like = IconButton()
  private let shuffle = IconButton()
  private let repeatButton = IconButton()
  private var currentTrackURI = ""
  private var currentTrackArtist = ""
  private var currentTrackAlbum = ""
  private var likedTracks: [String: Bool] = [:]
  private var pendingLikes: [String: Bool] = [:]
  private var shuffling = false
  private var repeatMode = RepeatMode.off
  private var confirmedRepeatMode = RepeatMode.off
  private var repeatRequest = 0
  private var repeatSessionStart = 0
  private var repeatPending = false
  private var lastRepeatPoll = Date.distantPast
  private var openedSpotify = 0
  private var lastTransportCommand = ""
  private var transportCommands = 0
  private var refreshRequests = 0
  private var launchHotkey: LaunchHotkey?
  private var launchHotkeyStamp: Date?
  private var loadedLaunchHotkey = false
  private var lastResignedKey = Date.distantPast
  private var hotkeyHandoffAllowed = false
  private var screenshotMode = false
  private var lastLikedCheck = Date.distantPast
  private var searchFilter = MusicFilter()
  private var liveSearchFilter = MusicFilter()
  private var source: [MusicItem] = [] { didSet { searchFilter.reset() } }
  private var home: [MusicItem] = []
  private var catalog: [MusicItem] = [] {
    didSet {
      searchFilter.reset()
      liveSearchFilter.reset()
    }
  }
  private let catalogQueue = DispatchQueue(label: "spotify.catalog", qos: .userInitiated)
  private var catalogRevision = 0
  private var catalogPreparation: RequestCancellation?
  private var filtered: [MusicItem] = []
  private var breadcrumb = ""
  private var navigationSelections: [String: (uri: String, query: String)] = [:]
  private var restoreOpeningSelection = false
  private var routeKind = "home"
  private var catalogSearchWork: DispatchWorkItem?
  private var catalogPending = false {
    didSet { if oldValue != catalogPending { updateSearchStatus() } }
  }
  private var searchStatusWork: DispatchWorkItem?
  private var searchStatusVisible = false
  private var searchStatusShownAt = Date.distantPast
  private var statusMessage = ""
  private var statusIsError = false
  private var pendingHomeQuery: String?
  private var lastPlaintextPath: String?
  private var pendingPlaintextPath: String?
  private var navigationRequest = 0
  private var updatingSearchField = false
  private var previewWork: DispatchWorkItem?
  private var previewURI = ""
  private var previewPaths: [String: String] = [:]
  private var previewIsCover = false
  private var previewImageChanges = 0
  private var playbackButtons: [NSButton] = []
  private var connection = "loading"
  private var playing = false
  private var suppressSelection = false
  private var wasShown = false
  private var showCount = 0
  private var screenshotModeTestResult: [String: Any]?
  private var inlineError: String?
  private var statusTimer: Timer?
  private var lifeTimer: Timer?
  private var initialFiles: [String: Date] = [:]
  private var alfredPID: pid_t = 0
  private var optimisticUntil = Date.distantPast
  private var playbackRequest = 0
  private var currentImageURL = ""
  private var currentArtPath = ""
  private let imageCache = NSCache<NSString, NSImage>()
  private var loadingImages: Set<String> = []
  private var artworkTestPaths: [String] = []
  private var playArtworkTestPath = ""
  private var missingArtworkTestPath = ""
  private var failedImages: Set<String> = []
  private var artworkPaths: [String: String] = [:]
  private let imageQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "spotify.artwork"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 2
    return queue
  }()
  private var imagesRequested: Set<String> = []
  private var sentTestCommands: [String] = []

  init(testMode: Bool = false, credentials: AuthorizationStore? = nil) {
    self.testMode = testMode
    self.credentials = credentials
    backend = NativeBackend(workflowRoot(), credentials: credentials)
    super.init()
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    buildPanel()
    refreshLaunchHotkey()
    installEditingMenu()
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(activeSpaceChanged(_:)),
      name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    backend.receive = { [weak self] value in self?.receive(value) }
    spotify.failed = { [weak self] message in
      guard let self = self, self.connection == "connected" else { return }
      self.showError(message)
    }
    spotify.status = { [weak self] values in self?.updatePlayback(values) }
    do {
      try server.start { [weak self] message in self?.handleIPC(message) ?? [:] }
      if !testMode { try backend.start() }
    } catch {
      if !testMode { showError(error.localizedDescription) }
      NSApp.terminate(nil)
      return
    }
    if !testMode {
      alfredPID =
        NSRunningApplication.runningApplications(withBundleIdentifier: applicationID).first?
        .processIdentifier ?? 0
      spotify.warm()
      recordFiles()
      lifeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        self?.checkLifetime()
      }
      statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        guard let self = self, self.panel.isVisible else { return }
        self.refreshTheme()
        if self.connection == "connected" {
          self.spotify.poll()
          if Date().timeIntervalSince(self.lastLikedCheck) >= 60 { self.refreshCurrentLike() }
          if Date().timeIntervalSince(self.lastRepeatPoll) >= 5 { self.refreshRepeat() }
        }
      }
    }
    if let index = CommandLine.arguments.firstIndex(of: "--lifetime-pid"),
      CommandLine.arguments.count > index + 1
    {
      lifeTimer?.invalidate()
      alfredPID = Int32(CommandLine.arguments[index + 1]) ?? 0
      recordFiles()
      lifeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
        self?.checkLifetime()
      }
    }
    if CommandLine.arguments.contains("--present") { show() }
    if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
      CommandLine.arguments.count > index + 1
    {
      demo()
      nowTitle.stringValue = "Current song"
      currentTrackArtist = "Artist"
      currentTrackAlbum = "Album"
      currentPlaybackContext = PlaybackContext(
        uri: "spotify:playlist:" + String(repeating: "p", count: 22), name: "Example Playlist")
      updateContextLabel()
      nowArt.image = NSImage(contentsOf: workflowRoot().appendingPathComponent("icon.png"))
      setCurrentTrack("spotify:track:" + String(repeating: "a", count: 22))
      playing = true
      updateToggle()
      likedTracks[currentTrackURI] = true
      updateLike()
      shuffling = true
      updateShuffle()
      repeatMode = .track
      updateRepeat()
      if let path = ProcessInfo.processInfo.environment["SPOTIFY_TEST_THEME_PATH"] {
        applyTheme(PlayerTheme(dict(readJSON(URL(fileURLWithPath: path)))))
      }
      snapshot(CommandLine.arguments[index + 1])
      NSApp.terminate(nil)
    }
  }

  private func buildPanel() {
    imageCache.countLimit = 128
    imageCache.totalCostLimit = 96 * 1024 * 1024
    panel.delegate = self
    panel.keyAction = { [weak self] event in self?.key(event) ?? false }
    panel.dismissAction = { [weak self] in self?.hide() }
    panel.interaction = { [weak self] event in self?.handleInteraction(event) }
    panel.input = { [weak self] in
      guard let self = self, self.search.isEnabled else { return nil }
      return self.search
    }
    panel.level = .floating
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
    panel.isReleasedWhenClosed = false
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.sharingType = .readOnly
    panel.isMovableByWindowBackground = true
    panel.title = "Spotify Mini Player"
    let root = ThemeBackground(frame: NSRect(x: 0, y: 0, width: 592, height: 470))
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.contentView = root
    nowArt.frame = NSRect(x: 20, y: 369, width: 82, height: 82)
    nowArt.imageScaling = .scaleProportionallyUpOrDown
    nowArt.image = symbol("questionmark", height: 64)
    nowArt.contentTintColor = .tertiaryLabelColor
    nowTitle.frame = NSRect(x: 120, y: 409, width: 254, height: 30)
    nowTitle.font = .systemFont(ofSize: 22, weight: .medium)
    nowDetail.frame = NSRect(x: 120, y: 382, width: 254, height: 24)
    nowDetail.font = .systemFont(ofSize: 15)
    nowDetail.textColor = .secondaryLabelColor
    nowContext.frame = NSRect(x: 120, y: 373, width: 254, height: 18)
    nowContext.font = .systemFont(ofSize: 11)
    nowContext.textColor = .secondaryLabelColor
    nowContext.isHidden = true
    for label in [nowTitle, nowDetail, nowContext] { label.lineBreakMode = .byTruncatingTail }
    root.addSubview(nowArt)
    root.addSubview(nowTitle)
    root.addSubview(nowDetail)
    root.addSubview(nowContext)
    let previous = playerButton("backward.fill", height: 12, action: #selector(previousTrack))
    configureButton(toggle, image: "play.fill", height: 18, action: #selector(togglePlayback))
    let next = playerButton("forward.fill", height: 12, action: #selector(nextTrack))
    playbackButtons = [previous, toggle, next]
    for button in playbackButtons {
      button.contentTintColor = .black
      (button as? IconButton)?.playbackHighlight = true
    }
    for (index, button) in playbackButtons.enumerated() {
      button.isEnabled = testMode
      button.frame = NSRect(
        x: 460 + index * 28, y: Int(nowArt.frame.midY) - 14, width: 28, height: 28)
      root.addSubview(button)
    }
    updateToggle()
    configureButton(like, image: "plus.circle", height: 22, action: #selector(toggleLiked))
    like.frame = NSRect(x: 395, y: nowArt.frame.midY - 14, width: 28, height: 28)
    like.playbackHighlight = true
    like.isEnabled = false
    like.toolTip = "Save to Liked Songs"
    like.setAccessibilityLabel("Save to Liked Songs")
    root.addSubview(like)
    configureButton(shuffle, image: "shuffle", height: 10, action: #selector(toggleShuffle))
    shuffle.frame = NSRect(x: 432, y: nowArt.frame.midY - 14, width: 28, height: 28)
    shuffle.playbackHighlight = true
    shuffle.isEnabled = false
    updateShuffle()
    root.addSubview(shuffle)
    configureButton(repeatButton, image: "repeat", height: 10, action: #selector(cycleRepeat))
    repeatButton.frame = NSRect(x: 544, y: nowArt.frame.midY - 14, width: 28, height: 28)
    repeatButton.playbackHighlight = true
    updateRepeat()
    root.addSubview(repeatButton)
    search.frame = NSRect(x: 14, y: 0, width: root.bounds.width - 28, height: 41)
    search.font = .systemFont(ofSize: 28)
    search.isBordered = false
    search.drawsBackground = false
    search.focusRingType = .none
    search.maximumNumberOfLines = 1
    search.cell?.usesSingleLineMode = true
    search.cell?.isScrollable = true
    search.isEnabled = false
    search.delegate = self
    search.target = self
    search.action = #selector(activateSelection)
    search.keyAction = { [weak self] event in self?.key(event) ?? false }
    root.addSubview(search)
    scroll.frame = NSRect(x: 12, y: 35, width: 320, height: 276)
    search.setFrameOrigin(
      NSPoint(
        x: search.frame.minX, y: (nowArt.frame.minY + scroll.frame.maxY - search.frame.height) / 2))
    scroll.hasVerticalScroller = true
    scroll.verticalScroller = ThemeScroller()
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    table.style = .plain
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("music"))
    column.width = 320
    column.minWidth = 280
    table.addTableColumn(column)
    table.frame = NSRect(x: 0, y: 0, width: 320, height: 276)
    table.autoresizingMask = [.width]
    table.headerView = nil
    table.rowHeight = 25
    table.intercellSpacing = .zero
    table.backgroundColor = .clear
    table.selectionHighlightStyle = .regular
    table.delegate = self
    table.dataSource = self
    table.target = self
    table.doubleAction = #selector(activateSelection)
    table.focusRingType = .none
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    scroll.documentView = table
    root.addSubview(scroll)
    preview.frame = NSRect(x: 342, y: 81, width: 230, height: 230)
    preview.imageScaling = .scaleProportionallyUpOrDown
    preview.contentTintColor = .tertiaryLabelColor
    previewTitle.frame = NSRect(x: 342, y: 57, width: 230, height: 20)
    previewTitle.font = .systemFont(ofSize: 13)
    previewTitle.alignment = .center
    previewTitle.lineBreakMode = .byTruncatingTail
    previewDetail.frame = NSRect(x: 342, y: 24, width: 230, height: 32)
    previewDetail.font = .systemFont(ofSize: 11)
    previewDetail.alignment = .center
    previewDetail.textColor = playerTheme.secondary
    root.addSubview(preview)
    root.addSubview(previewTitle)
    root.addSubview(previewDetail)
    status.frame = NSRect(x: 12, y: 10, width: 420, height: 16)
    status.font = .systemFont(ofSize: 10)
    status.textColor = .secondaryLabelColor
    status.lineBreakMode = .byTruncatingTail
    root.addSubview(status)
    activityStatus.frame = NSRect(x: 12, y: 10, width: 134, height: 16)
    activityStatus.font = .systemFont(ofSize: 10)
    activityStatus.alignment = .left
    activityStatus.isHidden = true
    activityStatus.setAccessibilityLabel("Spotify activity")
    root.addSubview(activityStatus)
    applyTheme(PlayerTheme())
    refreshTheme()
    // Force layout and raster caches now; showing this panel never rebuilds it.
    root.layoutSubtreeIfNeeded()
    panel.displayIfNeeded()
  }

  private func refreshTheme() {
    guard !testMode else { return }
    let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    let (signature, theme) = themes.load(context: themeContext, dark: dark)
    guard signature != themeSignature else { return }
    themeSignature = signature
    applyTheme(theme)
  }
  private func styleEditor() {
    guard let editor = search.currentEditor() as? NSTextView else { return }
    editor.allowsUndo = true
    // The search field already paints the themed background; don't cover its hint.
    editor.drawsBackground = false
    (editor.superview as? NSClipView)?.drawsBackground = false
    editor.insertionPointColor = playerTheme.searchText
    editor.textColor = playerTheme.searchText
    editor.selectedTextAttributes = [
      .foregroundColor: playerTheme.searchSelectedText,
      .backgroundColor: playerTheme.searchSelection,
    ]
  }
  private func applyTheme(_ theme: PlayerTheme) {
    playerTheme = theme
    (panel.contentView as? ThemeBackground)?.apply(theme)
    nowTitle.font = theme.font(theme.resultFont, size: 22, weight: .medium)
    nowDetail.font = theme.font(theme.secondaryFont, size: 15)
    nowContext.font = theme.font(theme.secondaryFont, size: 11)
    previewTitle.font = theme.font(theme.resultFont, size: 13)
    previewDetail.font = theme.font(theme.secondaryFont, size: 11)
    status.font = theme.font(theme.secondaryFont, size: 10)
    activityStatus.font = theme.font(theme.secondaryFont, size: 10)
    activityStatus.textColor = theme.secondary
    search.font = theme.font(theme.searchFont, size: 28)
    search.textColor = theme.searchText
    search.hintColor = theme.secondary.withAlphaComponent(theme.secondary.alphaComponent * 0.7)
    search.needsDisplay = true
    search.drawsBackground = theme.searchBackground.alphaComponent > 0
    search.backgroundColor = theme.searchBackground
    search.wantsLayer = true
    search.layer?.cornerRadius = theme.searchRadius
    search.layer?.masksToBounds = true
    nowTitle.textColor = currentTrackURI.isEmpty ? theme.secondary : theme.text
    nowDetail.textColor = theme.secondary
    nowContext.textColor = theme.secondary
    nowArt.contentTintColor = theme.secondary
    previewTitle.textColor = theme.text
    previewDetail.textColor = theme.secondary
    updatePreviewTint()
    for button in playbackButtons {
      button.contentTintColor = theme.control
      button.needsDisplay = true
    }
    updateLike()
    updateShuffle()
    updateRepeat()
    renderStatus()
    table.enumerateAvailableRowViews { row, index in
      row.needsDisplay = true
      if self.filtered.indices.contains(index) {
        (self.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? MusicCell)?.display(
          self.filtered[index], index: index, selected: index == self.table.selectedRow)
      }
    }
    scroll.verticalScroller?.needsDisplay = true
    styleEditor()
  }

  private func symbol(_ name: String, height: CGFloat) -> NSImage? {
    systemImage(name, height: height)
  }
  private func configureButton(_ button: NSButton, image: String, height: CGFloat, action: Selector)
  {
    button.image = symbol(image, height: height)
    button.imagePosition = .imageOnly
    button.isBordered = false
    button.target = self
    button.action = action
    button.contentTintColor = .black
  }
  private func playerButton(_ image: String, height: CGFloat, action: Selector) -> NSButton {
    let button = IconButton()
    configureButton(button, image: image, height: height, action: action)
    return button
  }
  private func send(_ command: String, args: [String] = []) {
    if testMode { sentTestCommands.append(command) }
    if command == "refresh" {
      failedImages.removeAll()
      artworkPaths = artworkPaths.filter { !$0.value.isEmpty }
      imagesRequested = Set(artworkPaths.keys)
    }
    if !["preview", "liked", "image"].contains(command) {
      inlineError = nil
      renderStatus()
    }
    if ["path", "activate", "back", "home", "catalog"].contains(command) {
      navigationRequest += 1
      if command != "path" { pendingPlaintextPath = nil }
    }
    backend.send(["command": command, "args": args, "navigation": navigationRequest])
  }
  private func receive(_ value: [String: Any]) {
    let type = value["type"] as? String ?? ""
    if let offline = value["offline"] as? Bool {
      self.offline = offline
      if offline { catalogPending = false }
      renderStatus()
    }
    if let active = value["api_active"] as? Bool { updateAPIActivity(active) }
    if type == "api-activity" { return }
    let nextConnection = value["connection"] as? String ?? connection
    if nextConnection == connection {
      if let request = value["navigation"] as? Int, request != navigationRequest { return }
      // A queued home refresh must not turn an in-flight catalogue query into
      // a literal local search when the panel is reopened.
      if routeKind == "catalog", search.stringValue.hasPrefix("/"),
        let incoming = value["route_kind"] as? String, incoming != "catalog",
        ["show", "refresh", "artwork", "liked"].contains(value["command"] as? String ?? "")
      {
        return
      }
      if value["route_kind"] as? String == "catalog", routeKind != "catalog",
        pendingHomeQuery != nil
      {
        return
      }
      if value["route_kind"] as? String == "catalog", routeKind == "catalog",
        let query = value["query"] as? String, value["command"] as? String != "back",
        query != String(search.stringValue.dropFirst())
      {
        return
      }
    }
    if type == "browser-opened" {
      if connection == "connecting" { hide() }
      return
    }
    if type == "error" {
      pendingPlaintextPath = nil
      if routeKind == "catalog" {
        catalogPending = false
        filter()
      }
      showError(value["message"] as? String ?? "Could not complete the request.")
      return
    }
    if type == "playback-context" {
      guard connection == "connected", value["request"] as? Int == playbackRequest,
        Date() >= optimisticUntil
      else { return }
      let track = value["track"] as? String ?? ""
      let context = PlaybackContext(dict(value["context"]))
      observedPlaybackContext = (track, context)
      if !track.isEmpty, track == currentTrackURI { applyPlaybackContext(context, track: track) }
      return
    }
    if type == "playback" {
      guard connection == "connected", value["request"] as? Int == playbackRequest else { return }
      if let error = value["error"] as? String {
        optimisticUntil = .distantPast
        currentPlaybackContext = nil
        selectedSourceTrack = ""
        updateContextLabel()
        showError(error)
        if !testMode { spotify.poll() }
      }
      if value["fallback"] as? Bool == true, !testMode {
        spotify.play(
          "play", uri: value["uri"] as? String ?? "", context: value["context"] as? String ?? "")
      }
      return
    }
    if type == "repeat" {
      guard connection == "connected",
        let mode = RepeatMode(rawValue: value["mode"] as? String ?? "")
      else { return }
      let request = (value["request"] as? Int) ?? 0
      guard request >= repeatSessionStart else { return }
      let error = value["error"] as? String
      if value["poll"] as? Bool == true {
        guard !repeatPending, request == repeatRequest else { return }
        repeatMode = mode
        confirmedRepeatMode = mode
      } else {
        if error == nil { confirmedRepeatMode = mode }
        guard request == repeatRequest else { return }
        repeatPending = false
        repeatMode = error == nil ? mode : confirmedRepeatMode
        if let error = error { showError(error) }
      }
      updateRepeat()
      return
    }
    if type == "liked" {
      guard connection == "connected" else { return }
      let uri = value["uri"] as? String ?? ""
      likedTracks[uri] = value["liked"] as? Bool ?? false
      if value["cached"] as? Bool != true { pendingLikes.removeValue(forKey: uri) }
      if uri == currentTrackURI {
        updateLike()
        if let error = value["error"] as? String, !error.isEmpty { showError(error) }
      }
      return
    }
    if type == "catalog" {
      guard connection == "connected" else { return }
      catalogRevision += 1
      catalogPreparation?.cancel()
      let preparation = RequestCancellation()
      catalogPreparation = preparation
      let revision = catalogRevision
      let rows = value["rows"] as? [[String: Any]] ?? []
      catalogQueue.async { [weak self] in
        var items: [MusicItem] = []
        items.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
          if index.isMultiple(of: 256), preparation.isCancelled { return }
          items.append(MusicItem(row))
        }
        guard !preparation.isCancelled else { return }
        let prepared = MusicItem.prioritized(items)
        DispatchQueue.main.async {
          guard let self = self, self.connection == "connected", revision == self.catalogRevision
          else { return }
          self.catalog = prepared
          if self.offline && self.routeKind == "catalog" {
            self.source = self.localCatalogResults(String(self.search.stringValue.dropFirst()))
            self.filter()
          } else if self.breadcrumb.isEmpty && !self.search.stringValue.isEmpty {
            self.filter()
          }
        }
      }
      return
    }
    if type == "artwork" {
      let url = value["url"] as? String ?? ""
      let path = value["path"] as? String ?? ""
      if !url.isEmpty { artworkPaths[url] = path }
      if !path.isEmpty { failedImages.remove(path) }
      if connection == "connected", url == currentImageURL { setNowArt(path) }
      return
    }
    let signedIn = connection == "connecting" && nextConnection == "connected"
    let disconnected = connection != nextConnection && nextConnection != "connected"
    if nextConnection != connection { inlineError = nil }
    connection = nextConnection
    if disconnected { clearDisconnectedState() }
    if value["close_player"] as? Bool == true { hide() }
    if let message = value["message"] as? String {
      statusMessage = message
      statusIsError = value["message_is_error"] as? Bool == true
      inlineError = nil
    }
    renderStatus()
    if connection != "connected" { clearPreview() }
    search.isEnabled = connection == "connected" || connection == "credentials"
    search.hint = connection == "credentials" ? "Spotify Client ID" : nil
    search.setAccessibilityLabel(connection == "credentials" ? "Spotify Client ID" : "Search music")
    for button in playbackButtons { button.isEnabled = connection == "connected" }
    shuffle.isEnabled = connection == "connected"
    updateLike()
    updateRepeat()
    if connection != "connected" {
      routeKind = "home"
      breadcrumb = ""
      if connection != "credentials" || value["command"] as? String == "client-id-reset" {
        setSearchText("")
      }
      catalogPending = false
      updateSearchStatus()
      source = ((value["rows"] as? [[String: Any]])?.map(MusicItem.init) ?? source)
        .filter { $0.payload["action"] as? String == "connect" }
      home = source
      filter(resetSelection: true)
      if connection == "credentials", panel.isKeyWindow || testMode {
        focusSearch(selectAll: false)
      }
      if value["command"] as? String == "configure" { hide() }
      if value["command"] as? String == "client-id-reset" {
        if !testMode { NSApp.activate(ignoringOtherApps: true) }
        show()
      }
      return
    }
    if let rows = value["rows"] as? [[String: Any]] {
      if let kind = value["route_kind"] as? String { routeKind = kind }
      if routeKind == "catalog" {
        catalogPending = value["searching"] as? Bool == true
      } else {
        catalogSearchWork?.cancel()
        catalogPending = false
        updateSearchStatus()
      }
      source =
        routeKind == "catalog" && (catalogPending || offline)
        ? localCatalogResults(value["query"] as? String ?? "") : rows.map(MusicItem.init)
      if value["route_kind"] as? String == "catalog" { source = MusicItem.prioritized(source) }
      breadcrumb = value["prefix"] as? String ?? ""
      if value["command"] as? String == "path", let raw = value["path_prefix"] as? String {
        pendingPlaintextPath = nil
        let current = search.stringValue
        if current.hasPrefix(raw) {
          let resolved = breadcrumb + String(current.dropFirst(raw.count))
          if resolved != current { setSearchText(resolved) }
        }
        lastPlaintextPath = plaintextPathKey(search.stringValue)
      }
      if breadcrumb.isEmpty { home = source }
      if let text = value["search_text"] as? String {
        setSearchText(pendingHomeQuery ?? text)
        pendingHomeQuery = nil
      }
      if ["refresh", "artwork"].contains(value["command"] as? String ?? "") { previewURI = "" }
      let command = value["command"] as? String ?? ""
      let opening = ["activate", "catalog"].contains(command) && value["search_text"] != nil
      let restore = command == "back" || opening && restoreOpeningSelection
      let restored = restore ? navigationSelections[breadcrumb] : nil
      if opening { restoreOpeningSelection = false }
      if let restored = restored { setSearchText(restored.query) }
      filter(
        preferredURI: restored?.uri,
        resetSelection: value["search_text"] != nil || command == "path")
      if value["search_text"] != nil { placeSearchCaretAtEnd() }
    }
    let variables = value["variables"] as? [String: Any] ?? [:]
    let responseURI = value["selected"] as? String ?? ""
    var loaded: NSImage?
    if let art = variables["preview_art"] as? [String: Any], let path = art["src"] as? String,
      !path.isEmpty
    {
      previewPaths[responseURI] = path
      loaded = image(path)
    }
    // A late reply may warm the cache, but only the current selection can paint the preview.
    if responseURI == selectedItem()?.uri && responseURI == previewURI {
      if let title = variables["preview_title"] as? String { previewTitle.stringValue = title }
      if let detail = variables["preview_detail"] as? String {
        previewDetail.stringValue = detail
        previewDetail.textColor = playerTheme.secondary
      }
      if let cover = loaded {
        setPreviewImage(cover)
        previewIsCover = true
      } else if value["preview_complete"] as? Bool == true, let item = selectedItem() {
        let path = previewPaths[responseURI] ?? item.art
        if path.isEmpty || failedImages.contains(path) {
          setPreviewImage(previewPlaceholder(item))
          previewIsCover = false
        }
      }
    }
    if (value["command"] as? String) == "configure" { hide() }
    if signedIn {
      if !testMode { NSApp.activate(ignoringOtherApps: true) }
      show()
    }
  }

  private func clearDisconnectedState() {
    spotify.invalidateStatus()
    playbackRequest += 1
    repeatRequest += 1
    repeatSessionStart = repeatRequest
    repeatPending = false
    repeatMode = .off
    confirmedRepeatMode = .off
    pendingLikes.removeAll()
    likedTracks.removeAll()
    playing = false
    shuffling = false
    optimisticUntil = .distantPast
    currentTrackArtist = ""
    currentTrackAlbum = ""
    setCurrentTrack("", refresh: false)
    currentImageURL = ""
    currentArtPath = ""
    nowTitle.stringValue = "No track"
    setNowArt("")
    updateToggle()
    updateShuffle()
    updateRepeat()
    lastLikedCheck = .distantPast
    lastRepeatPoll = .distantPast
    catalogSearchWork?.cancel()
    catalogSearchWork = nil
    catalogPending = false
    pendingPlaintextPath = nil
    lastPlaintextPath = nil
    pendingHomeQuery = nil
    navigationSelections.removeAll()
    restoreOpeningSelection = false
    routeKind = "home"
    breadcrumb = ""
    setSearchText("")
    catalogPreparation?.cancel()
    catalogPreparation = nil
    catalogRevision += 1
    catalog = []
    home = []
    source = []
    filter(resetSelection: true)
  }

  private func image(_ path: String) -> NSImage? {
    guard !path.isEmpty else { return nil }
    if let image = imageCache.object(forKey: path as NSString) { return image }
    guard !failedImages.contains(path), loadingImages.insert(path).inserted else { return nil }
    imageQueue.addOperation { [weak self] in
      let decoded = loadArtwork(path)
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.loadingImages.remove(path)
        if let decoded = decoded {
          self.imageCache.setObject(
            decoded, forKey: path as NSString,
            cost: max(1, Int(decoded.size.width * decoded.size.height * 4)))
        } else {
          self.failedImages.insert(path)
        }
        if self.connection == "connected", self.currentArtPath == path {
          self.nowArt.image = decoded ?? self.symbol("questionmark", height: 64)
        }
        if self.connection == "connected", let item = self.selectedItem(),
          self.previewURI == item.uri,
          (self.previewPaths[item.uri] ?? item.art) == path
        {
          self.setPreviewImage(decoded ?? self.previewPlaceholder(item))
          self.previewIsCover = decoded != nil
        }
      }
    }
    return nil
  }
  private func setNowArt(_ path: String) {
    currentArtPath = path
    if let cached = image(path) {
      nowArt.image = cached
    } else if path.isEmpty || failedImages.contains(path) {
      nowArt.image = symbol("questionmark", height: 64)
    }
  }
  private func filter(preferredURI: String? = nil, resetSelection: Bool = false) {
    guard pendingPlaintextPath == nil else { return }
    let selection = preferredURI ?? (resetSelection ? nil : selectedItem()?.uri)
    let text = connection == "connected" ? search.stringValue : ""
    let query = text.hasPrefix(breadcrumb) ? String(text.dropFirst(breadcrumb.count)) : text
    let terms =
      routeKind == "catalog"
      ? [] : MusicItem.normalize(query).split(whereSeparator: { $0.isWhitespace })
    let usesCatalog =
      routeKind != "catalog" && breadcrumb.isEmpty && !terms.isEmpty && connection == "connected"
    let available = usesCatalog ? catalog : source
    filtered = searchFilter.matching(available, terms: terms, catalog: usesCatalog)
    suppressSelection = true
    table.reloadData()
    if !filtered.isEmpty {
      let index = selection.flatMap { uri in filtered.firstIndex { $0.uri == uri } } ?? 0
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      table.scrollRowToVisible(index)
    }
    suppressSelection = false
    previewSelection(debounce: true)
  }
  private func selectedItem() -> MusicItem? {
    let index = table.selectedRow
    return filtered.indices.contains(index) ? filtered[index] : nil
  }
  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    SelectionRow()
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    let id = NSUserInterfaceItemIdentifier("musicCell")
    let cell = (tableView.makeView(withIdentifier: id, owner: self) as? MusicCell) ?? MusicCell()
    cell.identifier = id
    cell.display(filtered[row], index: row, selected: tableView.selectedRow == row)
    return cell
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !suppressSelection else { return }
    collapseSearchSelection()
    for row in table.rows(in: table.visibleRect)
      .location..<NSMaxRange(table.rows(in: table.visibleRect)) where filtered.indices.contains(row)
    {
      (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MusicCell)?.display(
        filtered[row], index: row, selected: table.selectedRow == row)
    }
    previewSelection()
  }
  private func previewPlaceholder(_ item: MusicItem) -> NSImage? {
    symbol(
      item.payload["action"] as? String == "catalog" ? item.symbol : "questionmark", height: 150)
  }
  private func updatePreviewTint() {
    let isSearch =
      selectedItem()?.payload["action"] as? String == "catalog" && preview.image?.isTemplate == true
    preview.contentTintColor = isSearch ? .black : playerTheme.secondary
  }
  private func setPreviewImage(_ image: NSImage?) {
    if preview.image !== image {
      preview.image = image
      previewImageChanges += 1
    }
    updatePreviewTint()
  }
  private func clearPreview() {
    previewWork?.cancel()
    previewWork = nil
    previewURI = ""
    previewIsCover = false
    previewTitle.stringValue = ""
    previewDetail.stringValue = ""
    setPreviewImage(nil)
  }
  private func previewSelection(debounce: Bool = false) {
    guard connection == "connected" else {
      clearPreview()
      return
    }
    previewWork?.cancel()
    previewWork = nil
    guard let item = selectedItem() else {
      if routeKind == "catalog" && catalogPending { return }
      let clear = DispatchWorkItem { [weak self] in
        guard let self = self, self.selectedItem() == nil else { return }
        self.previewURI = ""
        self.previewTitle.stringValue = ""
        let emptyQuery =
          self.routeKind == "catalog"
          && String(self.search.stringValue.dropFirst()).trimmingCharacters(
            in: .whitespacesAndNewlines
          ).isEmpty
        self.previewDetail.stringValue = emptyQuery ? "Type to search" : "No matches"
        self.previewDetail.textColor = playerTheme.secondary
        self.setPreviewImage(nil)
        self.previewIsCover = false
      }
      previewWork = clear
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: clear)
      return
    }
    guard item.uri != previewURI else { return }
    if debounce {
      // Keep the current cover during a burst of typing. Arrow-key selection is immediate.
      let work = DispatchWorkItem { [weak self] in self?.applyPreview(item) }
      previewWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    } else {
      applyPreview(item)
    }
  }
  private func applyPreview(_ item: MusicItem) {
    guard connection == "connected", selectedItem()?.uri == item.uri else { return }
    previewURI = item.uri
    previewTitle.stringValue =
      item.payload["action"] as? String == "catalog" ? "Search Spotify" : item.name
    previewDetail.stringValue = item.detail
    previewDetail.textColor = playerTheme.secondary
    let path = previewPaths[item.uri] ?? item.art
    if let cover = image(path) {
      setPreviewImage(cover)
      previewIsCover = true
    } else if !previewIsCover || failedImages.contains(path) {
      setPreviewImage(previewPlaceholder(item))
      previewIsCover = false
    }
    if !testMode, let data = try? JSONSerialization.data(withJSONObject: item.payload),
      let text = String(data: data, encoding: .utf8)
    {
      send("preview", args: [text])
    }
  }
  func controlTextDidBeginEditing(_ obj: Notification) {
    styleEditor()
  }
  private func localCatalogResults(_ query: String) -> [MusicItem] {
    let terms = MusicItem.normalize(query).split(whereSeparator: { $0.isWhitespace })
    return terms.isEmpty ? [] : liveSearchFilter.matching(catalog, terms: terms, catalog: true)
  }
  private func singleLineQuery(_ text: String) -> String {
    guard text.rangeOfCharacter(from: .newlines) != nil else { return text }
    return text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
      .joined(separator: " ")
  }
  private func setSearchText(_ value: String) {
    let text = singleLineQuery(value)
    updatingSearchField = true
    defer { updatingSearchField = false }
    search.stringValue = text
    search.needsDisplay = true
    if let editor = search.currentEditor() as? NSTextView {
      if editor.string != text { editor.string = text }
      editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }
  }
  private func focusSearch(selectAll: Bool) {
    guard search.isEnabled else { return }
    let text = search.stringValue
    updatingSearchField = true
    defer { updatingSearchField = false }
    // Re-entering an active field editor can reopen AppKit's text-input popup.
    if search.currentEditor() == nil { panel.makeFirstResponder(search) }
    if search.currentEditor() == nil { search.selectText(nil) }
    search.stringValue = text
    search.needsDisplay = true
    if let editor = search.currentEditor() as? NSTextView {
      if editor.string != text { editor.string = text }
      styleEditor()
      let length = (text as NSString).length
      editor.setSelectedRange(
        NSRange(location: selectAll ? 0 : length, length: selectAll ? length : 0))
    }
  }
  private func collapseSearchSelection() {
    guard let editor = search.currentEditor() as? NSTextView, editor.selectedRange().length > 0
    else { return }
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
  }
  private func handleInteraction(_ event: NSEvent) {
    guard [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].contains(event.type),
      !search.bounds.contains(search.convert(event.locationInWindow, from: nil))
    else { return }
    collapseSearchSelection()
  }
  private func finishSearchInput() {
    if let editor = search.currentEditor() as? NSTextView, editor.string != search.stringValue {
      setSearchText(editor.string)
    }
    // Commit the latest query before show can request the backend's state.
    if let work = catalogSearchWork, routeKind == "catalog", search.stringValue.hasPrefix("/") {
      work.cancel()
      catalogSearchWork = nil
      send("catalog-query", args: [String(search.stringValue.dropFirst())])
    }
  }
  private func placeSearchCaretAtEnd() { focusSearch(selectAll: false) }
  private func enterCatalog(_ requestedQuery: String, preservingSelection: Bool = false) {
    guard connection == "connected" else { return }
    if routeKind != "catalog" { rememberSelection() }
    let restored = preservingSelection ? navigationSelections["/"] : nil
    let query = restored.map { String($0.query.dropFirst()) } ?? requestedQuery
    restoreOpeningSelection = preservingSelection
    catalogSearchWork?.cancel()
    pendingHomeQuery = nil
    routeKind = "catalog"
    breadcrumb = "/"
    setSearchText("/" + query)
    source = localCatalogResults(query)
    catalogPending = !offline && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    filter(preferredURI: restored?.uri, resetSelection: !preservingSelection)
    send("catalog", args: [query])
    placeSearchCaretAtEnd()
  }
  private func updateCatalogQuery() {
    guard connection == "connected" else { return }
    catalogSearchWork?.cancel()
    let query = String(search.stringValue.dropFirst())
    source = localCatalogResults(query)
    catalogPending = !offline && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    renderStatus()
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, self.routeKind == "catalog", self.search.stringValue == "/" + query
      else { return }
      self.catalogSearchWork = nil
      self.send("catalog-query", args: [query])
    }
    catalogSearchWork = work
    if catalogPending {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    } else {
      work.perform()
    }
  }
  private func plaintextPathKey(_ text: String) -> String? {
    guard !text.hasPrefix("/"), let slash = text.lastIndex(of: "/") else { return nil }
    return String(text[...slash])
  }
  @discardableResult private func resolvePlaintextPath(force: Bool = false) -> Bool {
    guard connection == "connected", let path = plaintextPathKey(search.stringValue) else {
      lastPlaintextPath = nil
      return false
    }
    guard path != breadcrumb || pendingPlaintextPath != nil else {
      lastPlaintextPath = path
      return false
    }
    guard force || path != lastPlaintextPath else { return false }
    lastPlaintextPath = path
    pendingPlaintextPath = path
    catalogSearchWork?.cancel()
    catalogSearchWork = nil
    catalogPending = false
    pendingHomeQuery = nil
    send("path", args: [search.stringValue])
    return true
  }
  func controlTextDidChange(_ obj: Notification) {
    guard !updatingSearchField else { return }
    search.needsDisplay = true
    if connection == "credentials" {
      let text = singleLineQuery(search.stringValue)
      if text != search.stringValue { setSearchText(text) }
      renderStatus()
      return
    }
    guard connection == "connected" else { return }
    let text = singleLineQuery(search.stringValue)
    if text != search.stringValue { setSearchText(text) }
    restoreOpeningSelection = false
    if search.stringValue.hasPrefix("/") {
      let wasResolvingPath = pendingPlaintextPath != nil
      lastPlaintextPath = nil
      pendingPlaintextPath = nil
      if routeKind == "catalog" && !wasResolvingPath {
        updateCatalogQuery()
      } else {
        enterCatalog(String(search.stringValue.dropFirst()))
      }
    } else if resolvePlaintextPath()
      || pendingPlaintextPath != nil && plaintextPathKey(search.stringValue) != nil
    {
      // The path reply will filter the latest text, including continued typing.
    } else if pendingPlaintextPath != nil || routeKind == "catalog"
      || !breadcrumb.isEmpty && !search.stringValue.hasPrefix(breadcrumb)
    {
      catalogSearchWork?.cancel()
      routeKind = "home"
      catalogPending = false
      pendingHomeQuery = search.stringValue
      breadcrumb = ""
      source = home
      send("home")
    } else if pendingHomeQuery != nil {
      pendingHomeQuery = search.stringValue
    }
    filter(resetSelection: true)
  }
  private func rememberSelection() {
    if let item = selectedItem() {
      navigationSelections[breadcrumb] = (item.uri, search.stringValue)
    }
  }
  private func navigateUp() {
    guard connection == "connected" else { return }
    if pendingPlaintextPath != nil {
      setSearchText("")
      controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
      return
    }
    rememberSelection()
    restoreOpeningSelection = false
    collapseSearchSelection()
    catalogSearchWork?.cancel()
    catalogSearchWork = nil
    if breadcrumb.isEmpty {
      setSearchText("")
      filter(resetSelection: true)
    } else {
      send("back", args: [breadcrumb])
    }
    placeSearchCaretAtEnd()
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    let modifiers =
      NSApp.currentEvent?.modifierFlags.intersection([.command, .control, .option, .shift]) ?? []
    return handleInputCommand(commandSelector, editor: textView, modifiers: modifiers)
  }
  private func handleInputCommand(
    _ commandSelector: Selector, editor textView: NSTextView, modifiers: NSEvent.ModifierFlags
  ) -> Bool {
    if connection != "connected" {
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        hide()
        return true
      }
      if [
        #selector(NSResponder.insertNewline(_:)),
        #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
        #selector(NSResponder.insertLineBreak(_:)),
        #selector(NSResponder.insertParagraphSeparator(_:)),
      ].contains(commandSelector) {
        if modifiers.isEmpty && commandSelector == #selector(NSResponder.insertNewline(_:)) {
          activateSelection()
        }
        return true
      }
      return connection != "credentials"
    }
    if modifiers.isEmpty && commandSelector == #selector(NSResponder.moveDown(_:)) {
      move(1)
      return true
    }
    if modifiers.isEmpty && commandSelector == #selector(NSResponder.moveUp(_:)) {
      move(-1)
      return true
    }
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      hide()
      return true
    }
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      openSelection(preservingSelection: false, playDirectly: modifiers == .option)
      return true
    }
    if commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
      if modifiers == .option { openSelection(preservingSelection: false, playDirectly: true) }
      return true
    }
    if commandSelector == #selector(NSResponder.insertLineBreak(_:))
      || commandSelector == #selector(NSResponder.insertParagraphSeparator(_:))
    {
      return true
    }
    if modifiers.isEmpty, commandSelector == #selector(NSResponder.deleteBackward(_:)),
      textView.selectedRange().length == 0, !breadcrumb.isEmpty, search.stringValue == breadcrumb
    {
      navigateUp()
      return true
    }
    return false
  }
  private func refreshLaunchHotkey() {
    let file = workflowRoot().appendingPathComponent("info.plist")
    let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate
    guard !loadedLaunchHotkey || stamp != launchHotkeyStamp else { return }
    let workflow =
      (try? Data(contentsOf: file)).flatMap {
        try? PropertyListSerialization.propertyList(from: $0, format: nil) as? JSONObject
      } ?? [:]
    launchHotkey = LaunchHotkey.read(workflow)
    launchHotkeyStamp = stamp
    loadedLaunchHotkey = true
  }
  private func key(_ event: NSEvent) -> Bool {
    if launchHotkey?.matches(event) == true {
      collapseSearchSelection()
      showForHotkey(focused: true)
      return true
    }
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let key = event.charactersIgnoringModifiers ?? ""
    if modifiers.isEmpty && event.keyCode == 53 {
      hide()
      return true
    }
    if modifiers == .command && key == "w" {
      hide()
      return true
    }
    if modifiers == .command && key == "," {
      openSettings()
      return true
    }
    guard connection == "connected" else {
      if [36, 76].contains(event.keyCode) {
        if modifiers.isEmpty { activateSelection() }
        return true
      }
      guard connection == "credentials" else { return true }
      if modifiers == .command, ["s", "p", "n", "r"].contains(key.lowercased()) { return true }
      if modifiers.contains(.command),
        modifiers.contains(.control) || Int(key) != nil || [125, 126].contains(event.keyCode)
      {
        return true
      }
      return false
    }
    if modifiers == .option && [36, 76].contains(event.keyCode) {
      openSelection(preservingSelection: false, playDirectly: true)
      return true
    }
    let transport: String?
    if modifiers == .command {
      switch key.lowercased() {
      case "s": transport = "toggle"
      case "p": transport = "previous"
      case "n": transport = "next"
      case "r": transport = "refresh"
      default: transport = nil
      }
    } else if modifiers == [.control, .command] {
      switch event.keyCode {
      case 123: transport = "previous"
      case 124: transport = "next"
      case 125, 126: transport = "toggle"
      default: transport = nil
      }
    } else {
      transport = nil
    }
    if let transport = transport {
      collapseSearchSelection()
      performExternal(transport)
      return true
    }
    if modifiers == .command {
      if event.keyCode == 126 {
        navigateUp()
        return true
      }
      if event.keyCode == 125 {
        openSelection(preservingSelection: true)
        return true
      }
      if let number = Int(key), number >= 1, number <= 9 {
        let index = number - 1
        if filtered.indices.contains(index) {
          table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
          activateSelection()
        }
        return true
      }
      if event.keyCode == 36 {
        let value = search.stringValue
        enterCatalog(
          value.hasPrefix(breadcrumb) ? String(value.dropFirst(breadcrumb.count)) : value)
        return true
      }
    }
    if modifiers.isEmpty && event.keyCode == 36 && !search.isEnabled {
      activateSelection()
      return true
    }
    return false
  }
  private func move(_ offset: Int) {
    collapseSearchSelection()
    guard !filtered.isEmpty else { return }
    let index = min(filtered.count - 1, max(0, table.selectedRow + offset))
    table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    table.scrollRowToVisible(index)
  }
  @objc private func activateSelection() { openSelection(preservingSelection: false) }
  private func openSelection(preservingSelection: Bool, playDirectly: Bool = false) {
    collapseSearchSelection()
    guard pendingPlaintextPath == nil, let item = selectedItem() else { return }
    let action = item.payload["action"] as? String ?? ""
    if action == "connect" {
      if connection == "credentials",
        !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        let value = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validClientID(value) else {
          setSearchText("")
          showError("Enter the 32-character Spotify Client ID from your developer app.")
          focusSearch(selectAll: false)
          return
        }
        send("client-id", args: [value])
      } else {
        send("connect")
      }
      return
    }
    guard connection == "connected" else { return }
    if action == "catalog" {
      enterCatalog("", preservingSelection: preservingSelection)
      return
    }
    let directURI: String?
    if playDirectly, ["album", "artist", "playlist"].contains(item.kind), validURI(item.uri) {
      directURI = item.uri
    } else if playDirectly, action == "browse",
      text(dict(item.payload["target"])["kind"]) == "songs"
    {
      directURI = PlaybackContext.likedSongs.uri
    } else {
      directURI = nil
    }
    if item.kind == "track" || action == "play" || action == "open" || directURI != nil {
      if item.payload["is_local"] as? Bool == true || item.payload["is_playable"] as? Bool == false
      {
        showError("This track cannot be played through Spotify’s catalog.")
        return
      }
      let uri = directURI ?? item.payload["play_uri"] as? String ?? item.uri
      playbackRequest += 1
      observedPlaybackContext = nil
      if !testMode {
        let request = playbackRequest
        let context = item.payload["context"] as? String ?? ""
        spotify.ensureRunning { [weak self] started in
          guard let self = self, self.connection == "connected", request == self.playbackRequest
          else { return }
          self.send("play", args: [uri, context, started ? "started" : "running", String(request)])
        }
      }
      playing = true
      optimisticUntil = Date().addingTimeInterval(1)
      updateToggle()
      if item.kind == "track" {
        currentTrackArtist = item.artist
        currentTrackAlbum = item.album
        setCurrentTrack(uri)
        nowTitle.stringValue = item.name
        setNowArt(previewPaths[item.uri] ?? item.art)
      }
      let contextURI = item.payload["context"] as? String ?? (validTrack(uri) ? "" : uri)
      currentPlaybackContext =
        directURI.flatMap { PlaybackContext(uri: $0, name: item.name) }
        ?? PlaybackContext(dict(item.payload["playback_context"]))
        ?? PlaybackContext(
          uri: contextURI, name: catalog.first { $0.uri == contextURI }?.name ?? "")
      selectedSourceTrack = currentPlaybackContext?.kind == "collection" ? uri : ""
      updateContextLabel()
    } else if let data = try? JSONSerialization.data(withJSONObject: item.payload),
      let text = String(data: data, encoding: .utf8)
    {
      rememberSelection()
      restoreOpeningSelection = preservingSelection
      send("activate", args: [text])
    }
  }
  @objc private func togglePlayback() {
    guard connection == "connected" else { return }
    playing.toggle()
    optimisticUntil = Date().addingTimeInterval(1)
    updateToggle()
    if !testMode { spotify.play("toggle") }
  }
  @objc private func previousTrack() {
    if connection == "connected" && !testMode { spotify.play("previous") }
  }
  @objc private func nextTrack() {
    if connection == "connected" && !testMode { spotify.play("next") }
  }
  @objc private func toggleLiked() {
    guard like.isEnabled else { return }
    requestLiked(likedTracks[currentTrackURI] != true)
  }
  private func requestLiked(_ desired: Bool) {
    guard connection == "connected", validTrack(currentTrackURI) else { return }
    pendingLikes[currentTrackURI] = desired
    updateLike()
    if !testMode { send(desired ? "save" : "unsave", args: [currentTrackURI]) }
  }
  private func setCurrentTrack(_ uri: String, refresh: Bool = true) {
    nowTitle.textColor = uri.isEmpty ? playerTheme.secondary : playerTheme.text
    if uri.isEmpty {
      currentPlaybackContext = nil
      selectedSourceTrack = ""
      observedPlaybackContext = nil
      updateContextLabel()
    }
    guard currentTrackURI != uri else { return }
    currentTrackURI = uri
    if !uri.isEmpty {
      if selectedSourceTrack != uri && selectedSourceTrack != PlaybackContext.likedSongs.uri {
        selectedSourceTrack = ""
      }
      if let observed = observedPlaybackContext, observed.track == uri {
        applyPlaybackContext(observed.context, track: uri)
      }
    }
    updateContextLabel()
    currentImageURL = ""
    currentArtPath = ""
    updateLike()
    if refresh { refreshCurrentLike() }
  }
  private func applyPlaybackContext(_ context: PlaybackContext?, track: String) {
    // Spotify may omit collection context. Keep an explicit saved-song source
    // for that track, or All across tracks, until a real context replaces it.
    if context != nil
      || selectedSourceTrack != track && selectedSourceTrack != PlaybackContext.likedSongs.uri
    {
      currentPlaybackContext = context
      if context != nil { selectedSourceTrack = "" }
    }
    updateContextLabel()
  }
  private func updateContextLabel() {
    let label = currentPlaybackContext?.label ?? ""
    nowContext.stringValue = label
    nowDetail.stringValue = [currentTrackArtist, currentTrackAlbum]
      .filter { !$0.isEmpty }.joined(separator: " · ")
    nowContext.toolTip = label.isEmpty ? nil : "Playing from " + label
    nowContext.setAccessibilityLabel(label.isEmpty ? nil : "Playing from " + label)
    nowContext.isHidden = label.isEmpty
    nowTitle.frame.origin.y = label.isEmpty ? 409 : 418
    nowDetail.frame.origin.y = label.isEmpty ? 382 : 393
  }
  private func refreshCurrentLike() {
    lastLikedCheck = Date()
    if !testMode, connection == "connected",
      currentTrackURI.range(of: #"^spotify:track:[A-Za-z0-9]{22}$"#, options: .regularExpression)
        != nil
    {
      send("liked", args: [currentTrackURI])
    }
  }
  private func updateLike() {
    let saved = likedTracks[currentTrackURI] == true
    let pending = pendingLikes[currentTrackURI] != nil
    like.isPending = pending
    like.image = symbol(saved ? "checkmark.circle.fill" : "plus.circle", height: 22)
    like.showsSavedCheck = saved
    like.contentTintColor = saved || pending ? spotifyGreen : playerTheme.control
    like.needsDisplay = true
    like.isEnabled =
      connection == "connected"
      && currentTrackURI.range(of: #"^spotify:track:[A-Za-z0-9]{22}$"#, options: .regularExpression)
        != nil
      && pendingLikes[currentTrackURI] == nil
    like.toolTip =
      pendingLikes[currentTrackURI].map {
        $0 ? "Saving to Liked Songs…" : "Removing from Liked Songs…"
      } ?? (saved ? "Remove from Liked Songs" : "Save to Liked Songs")
    like.setAccessibilityLabel(like.toolTip)
    like.setAccessibilityValue(saved ? "Saved" : "Not saved")
  }
  @objc private func toggleShuffle() {
    guard connection == "connected" else { return }
    setShuffle(!shuffling)
  }
  private func setShuffle(_ enabled: Bool) {
    shuffling = enabled
    updateShuffle()
    optimisticUntil = Date().addingTimeInterval(0.5)
    if !testMode { spotify.setShuffle(enabled) }
  }
  private func updateShuffle() {
    shuffle.contentTintColor = shuffling ? .black : playerTheme.secondary
    shuffle.showsActiveCircle = shuffling
    shuffle.toolTip = shuffling ? "Turn shuffle off" : "Turn shuffle on"
    shuffle.setAccessibilityLabel(shuffle.toolTip)
    shuffle.setAccessibilityValue(shuffling ? "On" : "Off")
  }
  @objc private func cycleRepeat() {
    guard connection == "connected" else { return }
    repeatMode = repeatMode.next
    repeatRequest += 1
    repeatPending = true
    updateRepeat()
    if !testMode { send("repeat", args: [repeatMode.rawValue, String(repeatRequest)]) }
  }
  private func updateRepeat() {
    repeatButton.image =
      repeatMode == .track ? symbol("repeat.1", height: 10) : repeatAllImage(height: 10)
    repeatButton.showsActiveCircle = repeatMode != .off
    repeatButton.contentTintColor = repeatMode == .off ? playerTheme.secondary : .black
    repeatButton.isEnabled = connection == "connected"
    repeatButton.isPending = repeatPending
    repeatButton.toolTip = repeatMode.label + " · Click for " + repeatMode.next.label.lowercased()
    repeatButton.setAccessibilityLabel("Repeat mode")
    repeatButton.setAccessibilityValue(repeatMode.label)
  }
  private func refreshRepeat() {
    lastRepeatPoll = Date()
    if !testMode, connection == "connected" {
      send("repeat-state", args: [String(repeatRequest), String(playbackRequest)])
    }
  }
  private func performExternal(_ command: String) {
    guard connection == "connected" || command == "refresh" else { return }
    if ["toggle", "previous", "next"].contains(command) {
      lastTransportCommand = command
      transportCommands += 1
      if command == "toggle", panel.isVisible {
        playing.toggle()
        optimisticUntil = Date().addingTimeInterval(1)
        updateToggle()
      }
      if !testMode { spotify.play(command) }
      return
    }
    if command == "refresh" {
      refreshRequests += 1
      send("refresh")
      return
    }
    if command == "shuffle" || command == "noshuffle" {
      setShuffle(command == "shuffle")
      return
    }
    let desired = command == "like"
    if testMode {
      if !validTrack(currentTrackURI) {
        setCurrentTrack("spotify:track:" + String(repeating: "a", count: 22), refresh: false)
      }
      likedTracks[currentTrackURI] = desired
      updateLike()
      return
    }
    let request = playbackRequest
    spotify.currentTrack { [weak self] uri in
      guard let self = self, self.connection == "connected", request == self.playbackRequest else {
        return
      }
      guard let uri = uri, validTrack(uri) else {
        if !self.panel.isVisible { self.show() }
        self.showError("No Spotify song is currently playing.")
        return
      }
      self.setCurrentTrack(uri, refresh: false)
      self.requestLiked(desired)
    }
  }
  @objc private func openSpotify() {
    openedSpotify += 1
    hide()
    lastResignedKey = .distantPast
    if testMode { return }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client")
    else {
      showError("Install the Spotify desktop app to open Spotify.")
      return
    }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) {
      [weak self] _, error in
      if let error = error {
        DispatchQueue.main.async { self?.showError(error.localizedDescription) }
      }
    }
  }
  private func showForHotkey(focused: Bool? = nil) {
    // Alfred may briefly take focus while dispatching its Hotkey action.
    let recentlyFocused = Date().timeIntervalSince(lastResignedKey) < 0.5
    if hotkeyHandoffAllowed && (focused ?? (panel.isKeyWindow || recentlyFocused)) {
      openSpotify()
    } else {
      show()
    }
  }
  @objc private func openSettings() { send("configure") }
  private func updateToggle() {
    toggle.image = symbol(playing ? "pause.fill" : "play.fill", height: 18)
    guard let previous = playbackButtons.first, let next = playbackButtons.last else { return }
    let leftEdge = previous.frame.midX + (previous.image?.size.width ?? 0) / 2
    let rightEdge = next.frame.midX - (next.image?.size.width ?? 0) / 2
    toggle.setFrameOrigin(
      NSPoint(x: (leftEdge + rightEdge - toggle.frame.width) / 2, y: toggle.frame.minY))
  }
  private func updatePlayback(_ values: [String]) {
    guard connection == "connected", Date() >= optimisticUntil else { return }
    playing = values.first == "playing"
    updateToggle()
    if values.count >= 7 {
      shuffling = values[6] == "true"
      updateShuffle()
    }
    guard values.count >= 6 else {
      setCurrentTrack("")
      setNowArt("")
      return
    }
    currentTrackArtist = values[2]
    currentTrackAlbum = values[3]
    setCurrentTrack(values[5])
    nowTitle.stringValue = values[1]
    updateContextLabel()
    if currentImageURL != values[4] { currentArtPath = "" }
    currentImageURL = values[4]
    if let item = catalog.first(where: { $0.uri == values[5] }), !item.art.isEmpty {
      setNowArt(item.art)
    } else if values[4].isEmpty {
      setNowArt("")
    } else if let path = artworkPaths[values[4]] {
      setNowArt(path)
    } else if imagesRequested.insert(values[4]).inserted {
      send("image", args: [values[4]])
    }
  }
  private func updateAPIActivity(_ active: Bool) {
    guard active != apiActive else { return }
    apiActive = active
    apiActivityWork?.cancel()
    apiActivityWork = nil
    if active && !apiActivityVisible {
      let work = DispatchWorkItem { [weak self] in
        guard let self = self, self.apiActive else { return }
        self.apiActivityVisible = true
        self.apiActivityShownAt = Date()
        self.renderStatus()
      }
      apiActivityWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    } else if !active {
      let remaining = max(0, 0.35 - Date().timeIntervalSince(apiActivityShownAt))
      if remaining == 0 {
        apiActivityVisible = false
      } else {
        let work = DispatchWorkItem { [weak self] in
          guard let self = self, !self.apiActive else { return }
          self.apiActivityVisible = false
          self.renderStatus()
        }
        apiActivityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
      }
    }
    renderStatus()
  }
  private func renderStatus() {
    let message =
      inlineError
      ?? (routeKind == "catalog" && searchStatusVisible ? "Searching Spotify…" : statusMessage)
    let searching = inlineError == nil && routeKind == "catalog" && searchStatusVisible
    let error = !searching && (inlineError != nil || statusIsError || connection == "failed")
    let busy = !offline && apiActivityVisible && (!error || apiActive)
    let activity: String
    if offline {
      activity = "offline"
    } else if busy {
      if connection != "connected", !error, !message.isEmpty {
        activity = message
      } else {
        activity =
          routeKind == "catalog" && catalogPending ? "Searching Spotify…" : "Syncing with Spotify…"
      }
    } else {
      activity = ""
    }
    activityStatus.stringValue = activity
    activityStatus.toolTip = activity
    activityStatus.isHidden = activity.isEmpty
    // Theme-font glyphs can extend beyond AppKit's rounded intrinsic width.
    let width = activity.isEmpty ? 0 : min(200, ceil(activityStatus.intrinsicContentSize.width) + 4)
    activityStatus.frame = NSRect(x: 12, y: 10, width: width, height: 16)
    let left: CGFloat = activity.isEmpty ? 12 : activityStatus.frame.maxX + 10
    status.frame = NSRect(x: left, y: 10, width: max(0, preview.frame.maxX - left), height: 16)
    let text = busy && !error ? "" : message
    if status.stringValue != text { status.stringValue = text }
    status.toolTip = text
    status.textColor = error ? .systemRed : playerTheme.secondary
  }
  private func revealSearchStatus() {
    guard routeKind == "catalog", catalogPending else { return }
    searchStatusVisible = true
    searchStatusShownAt = Date()
    renderStatus()
  }
  private func updateSearchStatus() {
    searchStatusWork?.cancel()
    searchStatusWork = nil
    if routeKind != "catalog" {
      searchStatusVisible = false
    } else if catalogPending {
      if !searchStatusVisible {
        let work = DispatchWorkItem { [weak self] in self?.revealSearchStatus() }
        searchStatusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
      }
    } else if searchStatusVisible {
      let remaining = max(0, 0.35 - Date().timeIntervalSince(searchStatusShownAt))
      let work = DispatchWorkItem { [weak self] in
        guard let self = self, !self.catalogPending else { return }
        self.searchStatusVisible = false
        self.renderStatus()
      }
      searchStatusWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }
    renderStatus()
  }
  private func showError(_ message: String) {
    inlineError = message
    statusMessage = message
    statusIsError = true
    renderStatus()
  }
  private func show() {
    refreshLaunchHotkey()
    refreshTheme()
    hotkeyHandoffAllowed = true
    showCount += 1
    if connection == "connected", search.isEnabled, search.stringValue.hasPrefix("/"),
      routeKind != "catalog"
    {
      enterCatalog(String(search.stringValue.dropFirst()))
    } else if connection == "connected", search.isEnabled {
      resolvePlaintextPath(force: true)
    }
    let reopening = !panel.isVisible
    if reopening, !testMode, let screen = NSScreen.main {
      let frame = screen.visibleFrame
      panel.setFrameOrigin(
        NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2 + 50))
    }
    if reopening || !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
    if search.isEnabled {
      focusSearch(selectAll: reopening)
    } else {
      panel.makeFirstResponder(panel)
    }
    wasShown = true
    if testMode { return }
    if backend.pid == 0 {
      backend = NativeBackend(workflowRoot(), credentials: credentials)
      backend.receive = { [weak self] value in self?.receive(value) }
      do { try backend.start() } catch { showError(error.localizedDescription) }
    }
    send("show")
    if connection == "connected" {
      spotify.poll()
      refreshCurrentLike()
      refreshRepeat()
    }
  }
  private func setScreenshotMode(_ enabled: Bool) {
    screenshotMode = enabled
    panel.level = enabled ? .normal : .floating
    panel.collectionBehavior =
      enabled
      ? [.moveToActiveSpace, .fullScreenAuxiliary, .managed]
      : [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
  }
  private func toggleScreenshotMode() {
    if !testMode {
      NSRunningApplication.runningApplications(withBundleIdentifier: applicationID).first?.hide()
    }
    setScreenshotMode(!screenshotMode)
    if screenshotMode { NSApp.activate(ignoringOtherApps: true) }
    show()
  }
  private func hide() {
    finishSearchInput()
    collapseSearchSelection()
    hotkeyHandoffAllowed = false
    lastResignedKey = .distantPast
    setScreenshotMode(false)
    if let sheet = panel.attachedSheet { panel.endSheet(sheet) }
    panel.orderOut(nil)
  }
  @objc private func activeSpaceChanged(_ notification: Notification) {
    if hotkeyHandoffAllowed { hide() }
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hide()
    return false
  }
  func windowDidResignKey(_ notification: Notification) {
    guard !screenshotMode, !panel.isKeyWindow else { return }
    guard hotkeyHandoffAllowed else { return }
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == applicationID else {
      hide()
      return
    }
    finishSearchInput()
    collapseSearchSelection()
    lastResignedKey = Date()
    panel.orderOut(nil)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  private func handleIPC(_ value: [String: Any]) -> [String: Any] {
    if value["build"] as? String != buildIdentifier {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { NSApp.terminate(nil) }
      return ["status": "restart"]
    }
    if let theme = value["theme"] as? [String: String] { themeContext = theme }
    if testMode && value["command"] as? String == "test-demo-prepare" {
      setScreenshotMode(false)
      demo()
      search.isEnabled = true
      setSearchText("")
      NSApp.activate(ignoringOtherApps: true)
      show()
      return ["status": "ok"]
    }
    if testMode && value["command"] as? String == "test-demo-windows" {
      return [
        "status": "ok",
        "visibleWindows": NSApp.windows.filter { $0.isVisible }.map { $0.windowNumber }.sorted(),
        "editor": search.currentEditor() != nil,
        "editorID": search.currentEditor().map { String(describing: ObjectIdentifier($0)) } ?? "",
        "visible": panel.isVisible, "active": NSApp.isActive, "key": panel.isKeyWindow,
        "handoff": hotkeyHandoffAllowed, "shows": showCount, "demo": screenshotMode,
      ]
    }
    if testMode && value["command"] as? String == "test-screenshot-mode" {
      screenshotModeTestResult = nil
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        self.screenshotModeTestResult = await self.screenshotModeChecks()
      }
      return ["status": "pending"]
    }
    if testMode && value["command"] as? String == "test-screenshot-mode-result" {
      return screenshotModeTestResult ?? ["status": "pending"]
    }
    if testMode && value["command"] as? String == "test-spaces" { return spaceChecks() }
    if testMode && value["command"] as? String == "test-theme" { return themeChecks() }
    if testMode && value["command"] as? String == "test-controls" { return controlChecks() }
    if testMode && value["command"] as? String == "test-direct-play" {
      return directPlaybackChecks()
    }
    if testMode && value["command"] as? String == "test-single-line" { return singleLineChecks() }
    if testMode && value["command"] as? String == "test-offline-ui" { return offlineUIChecks() }
    if testMode && value["command"] as? String == "test-api-activity" { return apiActivityChecks() }
    if testMode && value["command"] as? String == "test-repeat" { return repeatChecks() }
    if testMode && value["command"] as? String == "test-playback-context" {
      return playbackContextChecks()
    }
    if testMode && value["command"] as? String == "test-search" { return searchChecks() }
    if testMode && value["command"] as? String == "test-catalog-mode" { return catalogModeChecks() }
    if testMode && value["command"] as? String == "test-search-result" {
      let complete = catalog.map { $0.uri } == ["latest"]
      return ["status": complete ? "ok" : "pending", "latest_catalog_applied": complete]
    }
    if testMode && value["command"] as? String == "test-missing-artwork" {
      return missingArtworkChecks()
    }
    if testMode && value["command"] as? String == "test-missing-artwork-result" {
      return missingArtworkCheckResult()
    }
    if testMode && value["command"] as? String == "test-play-artwork" { return playArtworkChecks() }
    if testMode && value["command"] as? String == "test-play-artwork-result" {
      return playArtworkCheckResult()
    }
    if testMode && value["command"] as? String == "test-artwork" { return artworkChecks() }
    if testMode && value["command"] as? String == "test-artwork-result" {
      return artworkCheckResult()
    }
    if testMode && value["command"] as? String == "test-local-bindings" {
      return localBindingChecks()
    }
    if testMode && value["command"] as? String == "test-navigation" { return navigationChecks() }
    if testMode && value["command"] as? String == "test-input-focus" { return inputFocusChecks() }
    if testMode && value["command"] as? String == "test-plaintext-paths" {
      return plaintextPathChecks()
    }
    if testMode && value["command"] as? String == "test-navigation-shortcuts" {
      return navigationShortcutChecks()
    }
    if testMode && value["command"] as? String == "test-connection-ui" {
      return connectionUIChecks()
    }
    if testMode && value["command"] as? String == "test-connection-session" {
      return connectionSessionChecks()
    }
    if testMode && value["command"] as? String == "test-client-id-input" {
      return clientIDInputChecks()
    }
    if testMode && value["command"] as? String == "test-catalog-resume" {
      return catalogResumeChecks()
    }
    if testMode && value["command"] as? String == "test-editing" {
      return editingChecks()
    }
    if testMode && value["command"] as? String == "test-ui" {
      return previewChecks()
    }
    if testMode && value["command"] as? String == "benchmark" {
      let items = (0..<10000).map {
        MusicItem(["name": "Song \($0)", "match": "Song \($0) Some Artist"])
      }
      let terms = MusicItem.normalize("song 12").split(separator: " ")
      let start = DispatchTime.now().uptimeNanoseconds
      var matcher = MusicFilter()
      let matches = matcher.matching(items, terms: terms, catalog: true)
      return [
        "status": "ok", "rows": items.count, "matches": matches.count,
        "filter_ms": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
      ]
    }
    let start = DispatchTime.now().uptimeNanoseconds
    if let command = value["command"] as? String,
      ["like", "unlike", "shuffle", "noshuffle", "refresh"].contains(command)
    {
      performExternal(command)
    }
    if value["command"] as? String == "reset" { backend.send(["command": "reset"]) }
    if value["command"] as? String == "hotkey" { showForHotkey() }
    if value["command"] as? String == "screenshot" { toggleScreenshotMode() }
    if value["command"] as? String == "show" { show() }
    if value["command"] as? String == "hide" { hide() }
    return [
      "status": "ok", "pid": getpid(), "backend_pid": backend.pid, "build": buildIdentifier,
      "panel": String(describing: ObjectIdentifier(panel)), "shows": showCount,
      "visible": panel.isVisible, "shown_before": wasShown, "connection": connection,
      "rows": source.count,
      "liked": likedTracks[currentTrackURI] ?? false, "shuffling": shuffling,
      "screenshot_mode": screenshotMode,
      "transport_command": lastTransportCommand, "transport_commands": transportCommands,
      "refresh_requests": refreshRequests,
      "theme": themeContext,
      "dispatch_ms": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
    ]
  }
  private func recordFiles() {
    for url in [currentExecutable(), workflowRoot().appendingPathComponent("info.plist")] {
      initialFiles[url.path] =
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
  }
  private func checkLifetime() {
    if alfredPID == 0 || kill(alfredPID, 0) != 0 {
      NSApp.terminate(nil)
      return
    }
    for (path, date) in initialFiles {
      let current =
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
      if current != date {
        var args = ["--relaunch-after", String(getpid())] + (panel.isVisible ? ["--present"] : [])
        if testMode {
          args += ["--test-server", "--lifetime-pid", String(alfredPID)]
        }
        try? launchServer(args)
        NSApp.terminate(nil)
        return
      }
    }
  }
  func applicationWillTerminate(_ notification: Notification) {
    lifeTimer?.invalidate()
    statusTimer?.invalidate()
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    server.close()
    backend.stop()
  }
  private func editingChecks() -> [String: Any] {
    connection = "connected"
    search.isEnabled = true
    panel.makeFirstResponder(search)
    search.selectText(nil)
    guard let editor = search.currentEditor() as? NSTextView else {
      return ["status": "error", "message": "No native field editor"]
    }
    editor.allowsUndo = true
    editor.string = "hello world"
    editor.setSelectedRange(NSRange(location: 5, length: 0))
    func key(_ character: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
      guard
        let event = NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: modifiers,
          timestamp: 0, windowNumber: panel.windowNumber, context: nil,
          characters: character, charactersIgnoringModifiers: character,
          isARepeat: false, keyCode: 0)
      else { return false }
      return performEditingKey(event, responder: editor)
    }
    let handled = key("a", .command)
    let selectedAll = handled && editor.selectedRange() == NSRange(location: 0, length: 11)
    editor.undoManager?.removeAllActions()
    editor.undoManager?.beginUndoGrouping()
    editor.insertText("edited", replacementRange: NSRange(location: 0, length: 11))
    editor.undoManager?.endUndoGrouping()
    let undoHandled = key("z", .command)
    let undoWorks = undoHandled && editor.string == "hello world"
    let redoHandled = key("z", [.command, .shift])
    let redoWorks = redoHandled && editor.string == "edited"
    editor.string = "hello world"
    editor.setSelectedRange(NSRange(location: 11, length: 0))
    editor.doCommand(by: NSSelectorFromString("moveWordLeft:"))
    let wordMovement = editor.selectedRange().location == 6
    let editSelectors = Set(
      (editingMenu?.items ?? []).compactMap { $0.action.map(NSStringFromSelector) })
    return [
      "status": "ok", "select_all": selectedAll, "undo": undoWorks, "redo": redoWorks,
      "word_movement": wordMovement,
      "clipboard_bindings": ["copy:", "cut:", "paste:", "pasteAsPlainText:"].allSatisfy {
        editSelectors.contains($0)
      },
    ]
  }
  private func localBindingChecks() -> [String: Any] {
    let original = launchHotkey
    defer { launchHotkey = original }
    // A fresh import may clear Alfred's launch key; local keys still work.
    launchHotkey = LaunchHotkey.read(["objects": []])
    demo()
    search.isEnabled = true
    placeSearchCaretAtEnd()
    let definitions: [(String, UInt16, String, NSEvent.ModifierFlags)] = [
      ("toggle", 1, "s", .command), ("previous", 35, "p", .command), ("next", 45, "n", .command),
      ("refresh", 15, "r", .command),
      ("previous", 123, "", [.control, .command]), ("next", 124, "", [.control, .command]),
      ("toggle", 125, "", [.control, .command]), ("toggle", 126, "", [.control, .command]),
    ]
    func event(_ code: UInt16, _ character: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: character,
        charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
    }
    let beforeShows = showCount
    let beforeOpened = openedSpotify
    var fixed = true
    for (command, code, character, modifiers) in definitions {
      let transports = transportCommands
      let refreshes = refreshRequests
      panel.sendEvent(event(code, character, modifiers))
      fixed =
        fixed
        && (command == "refresh"
          ? refreshRequests == refreshes + 1
          : transportCommands == transports + 1 && lastTransportCommand == command)
    }
    let objects: [JSONObject] = [
      [
        "uid": "HOTKEY", "type": "alfred.workflow.trigger.hotkey",
        "config": ["hotkey": 7, "hotmod": 1_048_576],
      ]
    ]
    launchHotkey = LaunchHotkey.read(["objects": objects])
    show()
    let opened = openedSpotify
    _ = key(event(7, "x", .command))
    let customized = openedSpotify == opened + 1
    let fixedAfterChange = key(event(1, "s", .command)) && lastTransportCommand == "toggle"
    return [
      "status": "ok", "fixed_shortcuts_work_without_alfred_assignments": fixed,
      "only_launch_hotkey_is_configurable": customized && fixedAfterChange,
      "fixed_keys_do_not_open_apps_or_rebuild_window": beforeShows + 1 == showCount
        && beforeOpened + 1 == openedSpotify,
    ]
  }
  private func navigationChecks() -> [String: Any] {
    let binding = launchHotkey
    launchHotkey = nil
    defer { launchHotkey = binding }
    demo()
    search.isEnabled = true
    routeKind = "artist"
    breadcrumb = "Artists/7!!/"
    source = [
      MusicItem(["uri": "one", "kind": "track", "name": "One"]),
      MusicItem(["uri": "two", "kind": "track", "name": "Two"]),
    ]
    setSearchText(breadcrumb)
    filter()
    hide()
    show()
    guard let editor = search.currentEditor() as? NSTextView else { return ["status": "error"] }
    let reopening =
      editor.selectedRange() == NSRange(location: 0, length: (breadcrumb as NSString).length)
    _ = handleInputCommand(#selector(NSResponder.moveDown(_:)), editor: editor, modifiers: [])
    let arrows = editor.selectedRange().length == 0 && table.selectedRow == 1
    focusSearch(selectAll: true)
    let mouse = NSEvent.mouseEvent(
      with: .leftMouseDown, location: NSPoint(x: 400, y: 400), modifierFlags: [], timestamp: 0,
      windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    handleInteraction(mouse)
    let mouseClears = editor.selectedRange().length == 0
    focusSearch(selectAll: true)
    let selectedDelete = !handleInputCommand(
      #selector(NSResponder.deleteBackward(_:)), editor: editor, modifiers: [])
    editor.deleteBackward(nil)
    let deleted =
      search.stringValue.isEmpty && editor.selectedRange().length == 0 && breadcrumb.isEmpty
    routeKind = "artist"
    breadcrumb = "Artists/7!!/"
    setSearchText(breadcrumb)
    focusSearch(selectAll: true)
    editor.insertText("new search", replacementRange: editor.selectedRange())
    let replaced = search.stringValue == "new search" && breadcrumb.isEmpty && routeKind == "home"
    routeKind = "artist"
    breadcrumb = "Artists/7!!/"
    setSearchText(breadcrumb)
    let back = handleInputCommand(
      #selector(NSResponder.deleteBackward(_:)), editor: editor, modifiers: [])
    pendingHomeQuery = nil
    receive([
      "type": "update", "command": "back", "route_kind": "artists", "prefix": "Artists/",
      "search_text": "Artists/", "rows": [],
    ])
    let caret =
      editor.selectedRange() == NSRange(location: 8, length: 0) && editor.string == "Artists/"
    func unhandled(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags) -> Bool
    {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
      return !key(event)
    }
    let removed =
      unhandled(33, "[", .command)
      && [(UInt16(35), "p"), (45, "n")].allSatisfy { unhandled($0.0, $0.1, [.control, .command]) }
    demo()
    setSearchText("")
    return [
      "status": "ok", "reopen_selects_filter": reopening, "arrows_clear_text_selection": arrows,
      "mouse_clears_text_selection": mouseClears,
      "backspace_deletes_selected_path": selectedDelete && deleted,
      "typing_replaces_selected_filter": replaced, "backspace_navigates_without_selection": back,
      "navigation_reply_leaves_caret": caret, "removed_shortcuts_are_unhandled": removed,
    ]
  }
  private func plaintextPathChecks() -> [String: Any] {
    demo()
    search.isEnabled = true
    navigationSelections = [:]
    focusSearch(selectAll: false)
    let albumRows: [[String: Any]] = ["Single", "Another Album"].enumerated().map {
      ["uri": "album:\($0.offset)", "name": $0.element, "kind": "album"]
    }
    func type(_ text: String) {
      setSearchText(text)
      controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }
    func reply(
      _ kind: String, _ prefix: String, raw: String, rows: [[String: Any]], request: Int? = nil
    ) {
      receive([
        "type": "update", "command": "path", "connection": "connected", "route_kind": kind,
        "prefix": prefix, "path_prefix": raw, "rows": rows,
        "navigation": request ?? navigationRequest,
      ])
    }
    type("Albums/")
    let requested = pendingPlaintextPath == "Albums/"
    let request = navigationRequest
    type("Albums/Si")
    let noExtraRequests = navigationRequest == request
    reply("albums", "Albums/", raw: "Albums/", rows: albumRows)
    let continuedTyping =
      routeKind == "albums" && breadcrumb == "Albums/" && search.stringValue == "Albums/Si"
      && filtered.map { $0.name } == ["Single"] && pendingPlaintextPath == nil
    let editor = search.currentEditor() as! NSTextView
    let caret = editor.selectedRange() == NSRange(location: 9, length: 0)
    type("Albums")
    let homeRequest = navigationRequest
    type("Albums/")
    receive([
      "type": "update", "command": "home", "route_kind": "home", "prefix": "", "search_text": "",
      "rows": [], "navigation": homeRequest,
    ])
    let lateHomeIgnored = pendingPlaintextPath == "Albums/" && search.stringValue == "Albums/"
    reply("albums", "Albums/", raw: "Albums/", rows: albumRows)
    let retyped = routeKind == "albums" && filtered.count == 2 && search.stringValue == "Albums/"
    var categories = true
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    for (name, kind) in [
      ("Playlists", "playlists"), ("Artists", "artists"), ("Songs", "songs"), ("Albums", "albums"),
    ] {
      type(name.lowercased() + "/")
      reply(kind, name + "/", raw: name.lowercased() + "/", rows: albumRows)
      categories =
        categories && routeKind == kind && search.stringValue == name + "/" && filtered.count == 2
        && table.selectedRow == 0
    }
    type("Artists/AC/DC/Side / A/So")
    reply(
      "album", "Artists/AC/DC/Side / A/", raw: "Artists/AC/DC/Side / A/",
      rows: [["uri": "track:1", "kind": "track", "name": "Song"]])
    let nested =
      routeKind == "album" && breadcrumb == "Artists/AC/DC/Side / A/"
      && selectedItem()?.name == "Song"
    type("Playlists/")
    let abandoned = navigationRequest
    type("plain query")
    reply("playlists", "Playlists/", raw: "Playlists/", rows: albumRows, request: abandoned)
    let deletedPending =
      pendingPlaintextPath == nil && routeKind == "home" && search.stringValue == "plain query"
    type("Albums/")
    let oldPath = navigationRequest
    type("/winter")
    reply("albums", "Albums/", raw: "Albums/", rows: albumRows, request: oldPath)
    let catalogueWins =
      routeKind == "catalog" && breadcrumb == "/" && search.stringValue == "/winter"
      && pendingPlaintextPath == nil
    demo()
    setSearchText("Albums/")
    show()
    let reopenRequestsPath = pendingPlaintextPath == "Albums/"
    reply("albums", "Albums/", raw: "Albums/", rows: albumRows)
    let reopened = reopenRequestsPath && routeKind == "albums" && filtered.count == 2
    demo()
    setSearchText("")
    return [
      "status": "ok", "typed_album_requests_navigation": requested,
      "typing_in_filter_stays_local": noExtraRequests,
      "path_reply_preserves_continued_typing": continuedTyping && caret,
      "all_categories_work_as_plaintext": categories,
      "deleting_and_retyping_path_recovers": lateHomeIgnored && retyped,
      "nested_paths_filter_their_contents": nested,
      "deleting_pending_path_cancels_navigation": deletedPending,
      "catalogue_ignores_stale_local_path": catalogueWins,
      "reopen_resolves_plaintext_path": reopened,
    ]
  }
  private func navigationShortcutChecks() -> [String: Any] {
    demo()
    search.isEnabled = true
    navigationSelections = [:]
    let parents: [[String: Any]] = (1...3).map { number in
      [
        "uri": "folder:\(number)", "name": "Folder \(number)", "kind": "playlist",
        "item": ["uri": "folder:\(number)", "kind": "playlist"],
      ]
    }
    let children: [[String: Any]] = (1...3).map {
      ["uri": "song:\($0)", "name": "Song \($0)", "kind": "track"]
    }
    catalog = parents.map(MusicItem.init)
    func enter() {
      receive([
        "type": "update", "command": "activate", "connection": "connected",
        "route_kind": "playlist",
        "prefix": "Folder 2/", "search_text": "Folder 2/", "rows": children,
      ])
    }
    func back() {
      receive([
        "type": "update", "command": "back", "connection": "connected", "route_kind": "home",
        "prefix": "", "search_text": "", "rows": parents,
      ])
    }
    func shortcut(_ code: UInt16) -> Bool {
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: code)!
      return panel.performKeyEquivalent(with: event)
    }
    back()
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    let down = shortcut(125)
    enter()
    let childStartsFirst = table.selectedRow == 0
    table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    let up = shortcut(126)
    back()
    let restoredUp = table.selectedRow == 1 && selectedItem()?.uri == "folder:2"
    _ = shortcut(125)
    enter()
    placeSearchCaretAtEnd()
    let restoredDown = table.selectedRow == 2 && selectedItem()?.uri == "song:3"
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    let editor = search.currentEditor() as! NSTextView
    let backspace = control(
      search, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:)))
    back()
    let restoredDelete = table.selectedRow == 1 && selectedItem()?.uri == "folder:2"
    _ = shortcut(125)
    enter()
    let downAfterDelete = table.selectedRow == 1 && selectedItem()?.uri == "song:2"
    _ = shortcut(126)
    back()
    activateSelection()
    enter()
    let returnStartsFirst = table.selectedRow == 0
    setSearchText("Folder 2/Song")
    filter(resetSelection: true)
    table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    _ = shortcut(126)
    back()
    _ = shortcut(125)
    enter()
    let childFilter = search.stringValue == "Folder 2/Song" && selectedItem()?.uri == "song:3"
    _ = shortcut(126)
    back()
    setSearchText("Folder")
    filter(resetSelection: true)
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    _ = shortcut(125)
    enter()
    _ = shortcut(126)
    back()
    let parentFilter = search.stringValue == "Folder" && table.selectedRow == 1
    placeSearchCaretAtEnd()
    editor.deleteBackward(nil)
    let deletionResets = search.stringValue == "Folde" && table.selectedRow == 0
    _ = shortcut(126)
    let homeCleared = search.stringValue.isEmpty && table.selectedRow == 0
    let menu =
      parents + [
        [
          "uri": "action:catalog", "name": "Spotify", "kind": "action",
          "item": ["action": "catalog"],
        ]
      ]
    receive([
      "type": "update", "command": "back", "connection": "connected", "route_kind": "home",
      "prefix": "", "search_text": "", "rows": menu,
    ])
    setSearchText("")
    filter(resetSelection: true)
    catalog = children.map(MusicItem.init)
    table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
    activateSelection()
    setSearchText("/Song")
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    receive([
      "type": "update", "command": "browse", "route_kind": "catalog", "query": "Song",
      "prefix": "/", "rows": children,
    ])
    table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    _ = shortcut(126)
    receive([
      "type": "update", "command": "back", "connection": "connected", "route_kind": "home",
      "prefix": "", "search_text": "", "rows": menu,
    ])
    _ = shortcut(125)
    receive([
      "type": "update", "command": "catalog", "route_kind": "catalog", "query": "Song",
      "prefix": "/", "search_text": "/Song", "rows": children,
    ])
    let catalogueRestored = search.stringValue == "/Song" && selectedItem()?.uri == "song:3"
    demo()
    navigationSelections = [:]
    restoreOpeningSelection = false
    setSearchText("")
    return [
      "status": "ok", "command_down_opens_selection": down,
      "new_folder_starts_first": childStartsFirst,
      "command_down_restores_child_selection": restoredDown,
      "command_down_restores_after_backspace": downAfterDelete,
      "return_opens_first_item": returnStartsFirst,
      "command_down_restores_child_filter": childFilter,
      "command_down_restores_catalogue_selection": catalogueRestored,
      "command_up_restores_parent_selection": up && restoredUp,
      "backspace_restores_parent_selection": backspace && restoredDelete,
      "parent_filter_restored": parentFilter, "deleting_filter_selects_first": deletionResets,
      "command_up_clears_home_filter": homeCleared,
    ]
  }
  private func playbackContextChecks() -> [String: Any] {
    demo()
    optimisticUntil = .distantPast
    let first = "spotify:track:" + String(repeating: "a", count: 22)
    let second = "spotify:track:" + String(repeating: "b", count: 22)
    let playlist = PlaybackContext(
      uri: "spotify:playlist:" + String(repeating: "p", count: 22), name: "True Love")!
    let album = PlaybackContext(
      uri: "spotify:album:" + String(repeating: "c", count: 22), name: "Example Album")!
    let artist = PlaybackContext(
      uri: "spotify:artist:" + String(repeating: "d", count: 22), name: "Example Artist")!
    func reply(_ context: PlaybackContext?, track: String, request: Int? = nil) {
      receive([
        "type": "playback-context", "request": request ?? playbackRequest, "track": track,
        "context": context?.object ?? [:],
      ])
    }
    currentTrackArtist = "Example Artist"
    currentTrackAlbum = "Example Album"
    setCurrentTrack(first, refresh: false)
    reply(playlist, track: first)
    let playlistDetail = nowDetail.stringValue == "Example Artist · Example Album"
    let playlistShown = nowContext.stringValue == "Playlist · True Love" && !nowContext.isHidden
    let layout =
      nowContext.frame.minY >= nowArt.frame.minY && nowTitle.frame.maxY <= nowArt.frame.maxY
      && nowContext.frame.maxY <= nowDetail.frame.minY
      && nowDetail.frame.maxY <= nowTitle.frame.minY
    let themed = nowContext.textColor == playerTheme.secondary && nowContext.font?.pointSize == 11
    reply(album, track: first)
    let albumShown = nowContext.stringValue == "Album · Example Album"
    updatePlayback([
      "playing", "Example Song", "Example Artist", "Example Album", "", first, "false",
    ])
    let albumDetail = nowDetail.stringValue == "Example Artist · Example Album"
    reply(artist, track: second)
    let waitsForTrack = nowContext.stringValue == "Album · Example Album"
    setCurrentTrack(second, refresh: false)
    let artistShown = nowContext.stringValue == "Artist · Example Artist"
    let otherDetailsRestored = nowDetail.stringValue == "Example Artist · Example Album"
    reply(playlist, track: second, request: playbackRequest - 1)
    let staleIgnored = nowContext.stringValue == "Artist · Example Artist"
    reply(nil, track: second)
    let cleared =
      nowContext.isHidden && nowContext.stringValue.isEmpty && nowTitle.frame.minY == 409
      && nowDetail.frame.minY == 382
    receive([
      "type": "update", "command": "activate", "connection": "connected", "route_kind": "songs",
      "prefix": "Songs/", "search_text": "Songs/",
      "rows": [
        [
          "uri": first, "name": "Saved Song", "kind": "track", "artist": "Example Artist",
          "album": "Example Album",
          "item": ["uri": first, "playback_context": PlaybackContext.likedSongs.object],
        ]
      ],
    ])
    activateSelection()
    let likedImmediate = nowContext.stringValue == "Liked Songs"
    optimisticUntil = .distantPast
    reply(nil, track: first)
    let nullKeepsLiked = nowContext.stringValue == "Liked Songs"
    setCurrentTrack(second, refresh: false)
    let offlineKeepsSource = nowContext.stringValue == "Liked Songs"
    reply(nil, track: second)
    let unrelatedSongClears = nowContext.isHidden
    receive([
      "type": "update", "command": "activate", "connection": "connected", "route_kind": "songs",
      "prefix": "Songs/", "search_text": "Songs/",
      "rows": [
        [
          "uri": "action:play:All", "name": "All", "kind": "action",
          "item": [
            "action": "play", "play_uri": PlaybackContext.likedSongs.uri,
            "playback_context": PlaybackContext.likedSongs.object,
          ],
        ],
        ["uri": first, "name": "Saved Song", "kind": "track", "item": ["uri": first]],
      ],
    ])
    activateSelection()
    let allStartsCollection =
      playing && nowContext.stringValue == "Liked Songs" && routeKind == "songs"
      && selectedItem()?.name == "All" && search.stringValue == "Songs/"
    optimisticUntil = .distantPast
    setCurrentTrack(first, refresh: false)
    reply(nil, track: first)
    setCurrentTrack(second, refresh: false)
    reply(nil, track: second)
    let allKeepsSource = nowContext.stringValue == "Liked Songs"
    reply(playlist, track: second)
    let actualContextWins = nowContext.stringValue == "Playlist · True Love"
    let collection = "spotify:user:fixture:collection"
    let event = SpotifyCommands.playbackEvent("play", uri: collection, context: "")
    let collectionFallback =
      event?.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue == collection
    source = [
      MusicItem([
        "uri": "play-album", "name": "Play Example Album", "kind": "action",
        "item": ["action": "play", "play_uri": album.uri, "playback_context": album.object],
      ])
    ]
    setSearchText(breadcrumb)
    filter(resetSelection: true)
    activateSelection()
    let containerImmediate = nowContext.stringValue == "Album · Example Album"
    hide()
    show()
    let keptOnReopen = nowContext.stringValue == "Album · Example Album"
    receive(["type": "playback", "request": playbackRequest, "error": "Fixture playback error"])
    let failureClearsSource = nowContext.isHidden
    setCurrentTrack("", refresh: false)
    currentPlaybackContext = album
    updateContextLabel()
    setCurrentTrack("", refresh: false)
    let emptyTrackClears = nowContext.isHidden
    currentPlaybackContext = album
    updatePlayback(["playing", "Autoplay Song", "Next Artist", "Next Album", "", second, "false"])
    reply(album, track: second)
    let autoplayAlbum =
      nowDetail.stringValue == "Next Artist · Next Album"
      && nowContext.stringValue == "Album · Example Album"
    demo()
    setSearchText("")
    optimisticUntil = .distantPast
    return [
      "status": "ok", "playlist_context_shown": playlistShown, "album_context_shown": albumShown,
      "artist_context_matches_track": waitsForTrack && artistShown,
      "stale_context_request_ignored": staleIgnored,
      "current_song_album_always_shown": albumDetail,
      "autoplay_keeps_song_album_distinct_from_source": autoplayAlbum,
      "other_sources_keep_album_by_artist": playlistDetail && otherDetailsRestored,
      "all_starts_collection_without_leaving_songs": allStartsCollection,
      "all_keeps_liked_source_across_tracks": allKeepsSource,
      "actual_context_replaces_collection": actualContextWins,
      "offline_collection_event_preserves_full_uri": collectionFallback,
      "null_context_restores_two_line_header": cleared,
      "liked_songs_source_is_immediate": likedImmediate,
      "liked_songs_survive_null_api_context": nullKeepsLiked,
      "offline_keeps_last_known_source": offlineKeepsSource,
      "unrelated_standalone_track_clears_source": unrelatedSongClears,
      "container_source_is_immediate": containerImmediate,
      "source_survives_reopen": keptOnReopen, "source_follows_theme": themed,
      "three_header_lines_fit_cover_height": layout,
      "failed_playback_clears_optimistic_source": failureClearsSource,
      "no_track_clears_source": emptyTrackClears,
    ]
  }
  private func connectionUIChecks() -> [String: Any] {
    let row: [String: Any] = [
      "uri": "action:connect", "name": "Connecting to Spotify…", "kind": "action",
      "symbol": "person.crop.circle", "item": ["action": "connect"],
    ]
    receive([
      "type": "update", "connection": "connecting", "message": "Finish connecting in your browser",
      "route_kind": "home", "prefix": "", "rows": [row],
    ])
    let emptyPreview =
      preview.image == nil && previewTitle.stringValue.isEmpty && previewDetail.stringValue.isEmpty
    let noButton =
      panel.contentView?.subviews.contains { ($0 as? NSButton)?.title == "Connect" } != true
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: panel.windowNumber, context: nil, characters: "\r",
      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    let enter = key(event) && selectedItem()?.payload["action"] as? String == "connect"
    let inlineStatus = status.stringValue == "Finish connecting in your browser"
    show()
    let waitsForBrowser = hotkeyHandoffAllowed
    receive(["type": "browser-opened"])
    let browserHandoff = !hotkeyHandoffAllowed && !panel.isVisible && connection == "connecting"
    demo()
    search.isEnabled = true
    focusSearch(selectAll: false)
    return [
      "status": "ok", "connection_has_no_cover_preview": emptyPreview,
      "no_connect_button": noButton,
      "return_activates_connection_row": enter, "connection_status_is_inline": inlineStatus,
      "player_waits_for_browser_launch": waitsForBrowser,
      "browser_launch_hides_player": browserHandoff,
    ]
  }
  private func clientIDInputChecks() -> [String: Any] {
    let originalTheme = playerTheme
    let originalAlpha = panel.alphaValue
    defer {
      applyTheme(originalTheme)
      panel.alphaValue = originalAlpha
    }
    panel.alphaValue = 0
    let row: [String: Any] = [
      "name": "Connect to Spotify", "uri": "connect", "kind": "action",
      "item": ["action": "connect"],
    ]
    receive([
      "type": "update", "connection": "credentials", "rows": [row],
      "message": "Enter your Spotify Client ID, then press Return.",
    ])
    let prompt = search.isEnabled && search.hint == "Spotify Client ID" && preview.image == nil
    func inputBitmap() -> NSBitmapImageRep? {
      guard let root = panel.contentView else { return nil }
      root.layoutSubtreeIfNeeded()
      let frame = search.convert(search.bounds, to: root)
      guard let bitmap = root.bitmapImageRepForCachingDisplay(in: frame) else { return nil }
      root.cacheDisplay(in: frame, to: bitmap)
      return bitmap
    }
    func inputInkFits() -> Bool {
      guard let bitmap = inputBitmap() else { return false }
      var ink = false
      for y in 0..<bitmap.pixelsHigh {
        // Inspect glyphs, excluding the empty-field caret on the left and the end caret after a full ID.
        for x in stride(from: 12, to: bitmap.pixelsWide / 2, by: 3) {
          guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
            color.alphaComponent > 0.9,
            min(color.redComponent, color.greenComponent, color.blueComponent) < 0.85
          else { continue }
          if y < 2 || y >= bitmap.pixelsHigh - 2 { return false }
          ink = true
          break
        }
      }
      return ink
    }
    func darkestInputPixel(from start: Int = 12) -> CGFloat {
      guard let bitmap = inputBitmap() else { return 0 }
      var darkest: CGFloat = 1
      for y in 2..<(bitmap.pixelsHigh - 2) {
        for x in stride(from: start, to: bitmap.pixelsWide / 2, by: 3) {
          guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
            color.alphaComponent > 0.9
          else { continue }
          darkest = min(darkest, color.redComponent, color.greenComponent, color.blueComponent)
        }
      }
      return darkest
    }
    let id = String(repeating: "b", count: 32)
    var placeholderFits = true
    var textFits = true
    var legibleHint = true
    for font in ["", "Avenir"] {
      panel.makeFirstResponder(panel)
      var theme = PlayerTheme()
      theme.searchFont = font
      theme.secondary = NSColor(srgbRed: 0.3, green: 0.3, blue: 0.3, alpha: 1)
      theme.searchBackground = NSColor.white.withAlphaComponent(0.95)
      applyTheme(theme)
      setSearchText("")
      panel.makeKeyAndOrderFront(nil)
      focusSearch(selectAll: false)
      placeholderFits = inputInkFits() && placeholderFits
      let shade = darkestInputPixel()
      legibleHint = legibleHint && shade > 0.35 && shade < 0.75
      setSearchText(id)
      textFits = inputInkFits() && textFits
    }
    setSearchText(id)
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    let noSearch =
      filtered.count == 1 && routeKind == "home" && !catalogPending && preview.image == nil
    receive(["type": "update", "connection": "credentials", "rows": [row]])
    let draft = search.stringValue == id
    panel.makeKeyAndOrderFront(nil)
    focusSearch(selectAll: false)
    func event(_ code: UInt16, _ character: String, _ modifiers: NSEvent.ModifierFlags = [])
      -> NSEvent
    {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: character,
        charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
    }
    let selectHandled = panel.performKeyEquivalent(with: event(0, "a", .command))
    let selection =
      selectHandled && (search.currentEditor() as? NSTextView)?.selectedRange().length == 32
    panel.sendEvent(event(8, "c"))
    let typing = search.stringValue == "c" && filtered.count == 1 && routeKind == "home"
    let noHintAfterTyping = darkestInputPixel(from: 80) > 0.99
    _ = panel.performKeyEquivalent(with: event(0, "a", .command))
    panel.sendEvent(event(51, "\u{7f}"))
    let hintRestored = search.stringValue.isEmpty && darkestInputPixel() < 0.75 && inputInkFits()
    setSearchText("bad")
    var commands = sentTestCommands.count
    panel.sendEvent(event(36, "\r"))
    let validationMessage = "Enter the 32-character Spotify Client ID from your developer app."
    let invalid =
      sentTestCommands.count == commands && inlineError == validationMessage
      && search.stringValue.isEmpty && search.hint != nil
    setSearchText(id)
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    let typingKeepsValidation =
      status.stringValue == validationMessage && inlineError == validationMessage
    commands = sentTestCommands.count
    panel.sendEvent(event(36, "\r"))
    let saved = Array(sentTestCommands.dropFirst(commands)) == ["client-id"] && inlineError == nil
    receive(["type": "update", "connection": "connecting", "rows": [row]])
    let connecting =
      !search.isEnabled && search.stringValue.isEmpty && search.hint == nil && preview.image == nil
    hide()
    let beforeFailure = showCount
    receive([
      "type": "update", "command": "client-id-reset", "connection": "credentials", "rows": [row],
    ])
    let failurePrompts =
      showCount == beforeFailure + 1 && search.stringValue.isEmpty && search.hint != nil
      && search.isEnabled
    setSearchText(id)
    let rejectionMessage = "Spotify rejected the previously entered Client ID"
    receive([
      "type": "update", "command": "client-id-reset", "connection": "credentials", "rows": [row],
      "message": rejectionMessage,
    ])
    let failureClearsDraft = search.stringValue.isEmpty
    receive(["type": "error", "message": rejectionMessage])
    focusSearch(selectAll: false)
    panel.sendEvent(event(8, "c"))
    let typingKeepsFailure =
      search.stringValue == "c" && status.stringValue == rejectionMessage
      && inlineError == rejectionMessage
    let cancelledMessage = "Spotify could not complete sign-in. Try again. (access_denied)"
    receive([
      "type": "update", "command": "client-id-reset", "connection": "credentials", "rows": [row],
      "message": cancelledMessage, "message_is_error": true,
    ])
    let signInErrorRed = status.stringValue == cancelledMessage && status.textColor == .systemRed
    hide()
    show()
    receive([
      "type": "update", "command": "show", "connection": "credentials", "rows": [row],
      "message": cancelledMessage, "message_is_error": true,
    ])
    let reopenedErrorRed = status.stringValue == cancelledMessage && status.textColor == .systemRed
    focusSearch(selectAll: false)
    panel.sendEvent(event(8, "c"))
    let typedErrorRed = status.textColor == .systemRed
    receive([
      "type": "update", "connection": "credentials", "rows": [row],
      "message": "Latest sign-in status", "message_is_error": false,
    ])
    let latestStatusWins =
      status.stringValue == "Latest sign-in status" && inlineError == nil
      && status.textColor == playerTheme.secondary
    demo()
    search.isEnabled = true
    setSearchText("")
    return [
      "status": "ok", "inline_setup_prompt": prompt, "typing_does_not_search": noSearch && typing,
      "updates_preserve_draft": draft, "standard_select_all_works": selection,
      "placeholder_not_clipped_with_system_or_avenir": placeholderFits,
      "entered_id_not_clipped": textFits,
      "placeholder_legible_on_translucent_background": legibleHint,
      "first_character_removes_placeholder": noHintAfterTyping,
      "empty_input_restores_placeholder": hintRestored,
      "invalid_id_stays_inline": invalid, "return_submits_id": saved,
      "connecting_clears_input": connecting,
      "failed_sign_in_reopens_prompt": failurePrompts,
      "failure_clears_rejected_draft": failureClearsDraft,
      "typing_keeps_format_validation": typingKeepsValidation,
      "typing_keeps_spotify_rejection": typingKeepsFailure,
      "new_status_replaces_previous_error": latestStatusWins,
      "sign_in_errors_are_red": signInErrorRed,
      "reopened_sign_in_errors_stay_red": reopenedErrorRed, "typing_keeps_error_red": typedErrorRed,
    ]
  }
  private func connectionSessionChecks() -> [String: Any] {
    demo()
    search.isEnabled = true
    optimisticUntil = .distantPast
    let uri = "spotify:track:" + String(repeating: "t", count: 22)
    let cover = NSImage(size: NSSize(width: 20, height: 20))
    imageCache.setObject(cover, forKey: "old-session-cover")
    artworkPaths["old-session-url"] = "old-session-cover"
    updatePlayback([
      "playing", "Old title", "Old artist", "Old album", "old-session-url", uri, "true",
    ])
    currentPlaybackContext = PlaybackContext(
      uri: "spotify:playlist:" + String(repeating: "p", count: 22), name: "Old playlist")
    likedTracks[uri] = true
    pendingLikes[uri] = true
    repeatMode = .track
    updateLike()
    updateRepeat()
    updateContextLabel()
    routeKind = "catalog"
    breadcrumb = "/"
    setSearchText("/old query")
    let row: JSONObject = [
      "uri": "action:connect", "name": "Connecting to Spotify…", "kind": "action",
      "item": ["action": "connect"],
    ]
    let oldPlayback = playbackRequest
    let oldRepeat = repeatRequest
    receive([
      "type": "update", "command": "refresh", "connection": "connecting",
      "navigation": navigationRequest - 1,
      "message": "Finish connecting in your browser", "route_kind": "home", "prefix": "",
      "rows": [row],
    ])
    func blankHeader() -> Bool {
      nowTitle.stringValue == "No track" && nowTitle.textColor == playerTheme.secondary
        && nowArt.contentTintColor == playerTheme.secondary && nowDetail.stringValue.isEmpty
        && nowContext.isHidden
        && currentTrackURI.isEmpty && currentImageURL.isEmpty && currentArtPath.isEmpty
        && nowArt.image !== cover
        && !playing && !shuffling && repeatMode == .off && pendingLikes.isEmpty
        && likedTracks.isEmpty
    }
    let cleared =
      connection == "connecting" && blankHeader() && playbackRequest > oldPlayback
      && repeatRequest > oldRepeat
    updatePlayback([
      "playing", "Late title", "Late artist", "Late album", "old-session-url", uri, "true",
    ])
    receive(["type": "liked", "uri": uri, "liked": true])
    receive(["type": "artwork", "url": "old-session-url", "path": "old-session-cover"])
    receive(["type": "repeat", "mode": "track", "request": oldRepeat])
    receive(["type": "playback", "request": oldPlayback, "error": "Old playback error"])
    let staleIgnored = blankHeader() && inlineError == nil
    func event(_ code: UInt16, _ character: String = "", _ modifiers: NSEvent.ModifierFlags = [])
      -> NSEvent
    {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: character,
        charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
    }
    let blocked: [(UInt16, String, NSEvent.ModifierFlags)] = [
      (36, "\r", .command), (36, "\r", .option), (125, "", .command), (126, "", .command),
      (18, "1", .command),
      (1, "s", .command), (35, "p", .command), (45, "n", .command), (15, "r", .command),
      (123, "", [.control, .command]), (124, "", [.control, .command]),
      (125, "", [.control, .command]), (126, "", [.control, .command]),
    ]
    var inactive = true
    for state in ["connecting", "credentials", "cleared", "failed", "loading"] {
      receive([
        "type": "update", "command": "connect", "connection": state, "route_kind": "catalog",
        "prefix": "/", "query": "leftover query", "search_text": "/leftover query", "rows": [row],
      ])
      let commands = sentTestCommands.count
      let navigation = navigationRequest
      let transports = transportCommands
      let refreshes = refreshRequests
      for (code, character, modifiers) in blocked {
        panel.sendEvent(event(code, character, modifiers))
      }
      inactive =
        inactive && sentTestCommands.count == commands && navigationRequest == navigation
        && transportCommands == transports && refreshRequests == refreshes
        && routeKind == "home" && search.stringValue.isEmpty && filtered.count == 1
        && selectedItem()?.payload["action"] as? String == "connect"
        && search.isEnabled == (state == "credentials") && blankHeader()
    }
    let commands = sentTestCommands.count
    panel.sendEvent(event(36, "\r"))
    let enter = Array(sentTestCommands.dropFirst(commands)) == ["connect"]
    let original = launchHotkey
    launchHotkey = LaunchHotkey(code: 49, modifiers: [.control, .command])
    hotkeyHandoffAllowed = false
    let shows = showCount
    panel.sendEvent(event(49, " ", [.control, .command]))
    let global = showCount == shows + 1 && hotkeyHandoffAllowed
    panel.sendEvent(event(53))
    let escape = !hotkeyHandoffAllowed
    launchHotkey = original
    receive([
      "type": "update", "connection": "connected", "route_kind": "home", "prefix": "", "rows": [],
    ])
    updatePlayback(["playing", "Fresh title", "Fresh artist", "Fresh album", "", uri, "false"])
    let resumes =
      nowTitle.stringValue == "Fresh title" && nowTitle.textColor == playerTheme.text
      && currentTrackURI == uri && search.isEnabled
    demo()
    return [
      "status": "ok", "disconnect_clears_header_and_playback_session": cleared,
      "late_playback_likes_and_artwork_are_ignored": staleIgnored,
      "all_player_shortcuts_inactive_until_connected": inactive,
      "return_reopens_signin": enter, "global_launch_still_works": global,
      "escape_still_hides": escape,
      "fresh_connected_updates_resume": resumes,
    ]
  }
  private func inputFocusChecks() -> [String: Any] {
    demo()
    search.isEnabled = true
    setSearchText("filter")
    focusSearch(selectAll: false)
    guard let editor = search.currentEditor() as? NSTextView else { return ["status": "error"] }
    let caret = editor.selectedRange()
    let tableRequest = panel.makeFirstResponder(table)
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    let rowsKeepInput =
      tableRequest && panel.firstResponder === editor && search.currentEditor() === editor
    let buttonRequest = panel.makeFirstResponder(toggle)
    let buttonsKeepInput =
      buttonRequest && panel.firstResponder === editor && editor.selectedRange() == caret
    editor.moveLeft(nil)
    let left = editor.selectedRange().location == 5 && panel.firstResponder === editor
    editor.moveRight(nil)
    let right = editor.selectedRange().location == 6 && panel.firstResponder === editor
    editor.deleteBackward(nil)
    let backspace = search.stringValue == "filte" && panel.firstResponder === editor
    setSearchText("")
    filter()
    focusSearch(selectAll: false)
    _ = control(search, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
    let browse = table.selectedRow == 1 && panel.firstResponder === editor
    demo()
    setSearchText("")
    return [
      "status": "ok", "row_click_keeps_text_focus": rowsKeepInput,
      "control_click_keeps_text_focus": buttonsKeepInput,
      "left_edits_input_after_row_click": left, "right_edits_input_after_row_click": right,
      "backspace_edits_input_after_row_click": backspace, "browsing_keeps_text_focus": browse,
    ]
  }
  private func catalogResumeChecks() -> [String: Any] {
    demo()
    search.isEnabled = true
    setSearchText("/winter")
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    let automatic = routeKind == "catalog" && breadcrumb == "/"
    hide()
    show()
    guard let editor = search.currentEditor() as? NSTextView else { return ["status": "error"] }
    let resumed =
      routeKind == "catalog" && breadcrumb == "/" && editor.string == "/winter"
      && editor.selectedRange() == NSRange(location: 0, length: 7)
    receive(["type": "update", "command": "show", "route_kind": "home", "prefix": "", "rows": []])
    let lateHome = routeKind == "catalog" && breadcrumb == "/" && search.stringValue == "/winter"
    receive([
      "type": "update", "command": "show", "route_kind": "catalog", "prefix": "/",
      "query": "winter", "rows": [],
    ])
    let reply = editor.selectedRange() == NSRange(location: 0, length: 7) && routeKind == "catalog"
    move(1)
    editor.insertText(" bird", replacementRange: editor.selectedRange())
    let pending = catalogSearchWork != nil && search.stringValue == "/winter bird"
    hide()
    let committed = catalogSearchWork == nil
    show()
    let quickReopen = routeKind == "catalog" && breadcrumb == "/" && editor.string == "/winter bird"
    receive([
      "type": "update", "command": "browse", "route_kind": "catalog", "prefix": "/",
      "query": "winter", "rows": [],
    ])
    let stale = search.stringValue == "/winter bird" && routeKind == "catalog"
    _ = control(search, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
    let navigated = routeKind == "catalog" && editor.selectedRange().length == 0
    setSearchText("local query")
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    receive([
      "type": "update", "command": "browse", "route_kind": "catalog", "prefix": "/",
      "query": "winter bird", "rows": [],
    ])
    let leftCatalog = routeKind == "home" && search.stringValue == "local query"
    demo()
    setSearchText("/meow")
    hide()
    show()
    let inferredOnOpen = routeKind == "catalog" && breadcrumb == "/" && editor.string == "/meow"
    demo()
    setSearchText("")
    return [
      "status": "ok", "leading_slash_activates_catalogue": automatic,
      "leading_slash_restores_catalogue_on_open": inferredOnOpen,
      "leaving_catalogue_ignores_old_replies": leftCatalog, "catalogue_resumes_with_query": resumed,
      "late_home_cannot_change_search_scope": lateHome,
      "show_reply_preserves_replacement_selection": reply,
      "pending_query_committed_on_hide": pending && committed,
      "quick_reopen_preserves_catalogue_mode": quickReopen,
      "old_search_reply_ignored_after_reopen": stale,
      "navigation_clears_highlight_without_leaving_catalogue": navigated,
    ]
  }
  private func inkCenterError(_ view: NSView) -> CGFloat {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
        pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      )
    else { return .infinity }
    bitmap.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    var top = bitmap.pixelsHigh
    var bottom = -1
    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
        top = min(top, y)
        bottom = max(bottom, y)
      }
    }
    guard bottom >= top else { return .infinity }
    let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
    return abs(CGFloat(top + bottom + 1) / (2 * scale) - view.bounds.midY)
  }
  private func previewChecks() -> [String: Any] {
    let cell = MusicCell(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
    cell.title.stringValue = "Stuck"
    cell.shortcut.stringValue = "⌘"
    cell.layout()
    let titleOffset = abs(
      cell.title.frame.minY + cell.title.baselineOffsetFromBottom
        + (cell.title.font?.capHeight ?? 0) / 2 - cell.bounds.midY)
    let commandGlyph = CTLineGetBoundsWithOptions(
      CTLineCreateWithAttributedString(cell.shortcut.attributedStringValue), .useGlyphPathBounds)
    let commandOffset = abs(
      cell.shortcut.frame.minY + cell.shortcut.baselineOffsetFromBottom + commandGlyph.midY
        - cell.bounds.midY)
    let offsets = [titleOffset, commandOffset]
    cell.display(MusicItem(["name": "Example"]), index: 1, selected: false)
    cell.layout()
    let commandX = cell.shortcut.frame.midX
    let digitsFit = cell.shortcutNumber.fittingSize.width <= cell.shortcutNumber.frame.width
    cell.display(MusicItem(["name": "Example"]), index: 1, selected: true)
    cell.layout()
    let returnAligned = abs(commandX - cell.returnArrow.frame.midX) < 0.01
    let arrowInkError = inkCenterError(cell.returnArrow)
    demo()
    panel.contentView?.layoutSubtreeIfNeeded()
    scroll.layoutSubtreeIfNeeded()
    let rowRect = table.convert(table.rect(ofRow: 0), to: panel.contentView)
    let rowsAligned = abs(rowRect.maxY - preview.frame.maxY) < 0.5
    let inputCentered = abs(search.frame.midY - (nowArt.frame.minY + rowRect.maxY) / 2) <= 0.25
    let compactInsets =
      table.effectiveStyle == .plain && cell.artwork.frame.minX <= 6
      && cell.bounds.maxX - cell.shortcutNumber.frame.maxX <= 7
    let mixed = ["track", "artist", "album", "playlist"].map { MusicItem(["kind": $0]) }
    let sorted =
      MusicItem.prioritized(mixed).map { $0.kind } == ["playlist", "album", "artist", "track"]
    let coverA = NSImage(size: NSSize(width: 32, height: 32))
    let coverB = NSImage(size: NSSize(width: 32, height: 32))
    imageCache.setObject(coverA, forKey: "fixture-a")
    imageCache.setObject(coverB, forKey: "fixture-b")
    let itemA = MusicItem([
      "name": "Alpha", "uri": "track:a", "kind": "track", "match": "Alpha", "art": "fixture-a",
    ])
    let itemB = MusicItem(["name": "Beta", "uri": "track:b", "kind": "track", "match": "Beta"])
    connection = "connected"
    breadcrumb = ""
    catalog = [itemA, itemB]
    source = catalog
    search.stringValue = "a"
    filter()
    previewSelection()
    let initialChanges = previewImageChanges
    for text in ["al", "alp", "alph", "alpha"] {
      search.stringValue = text
      filter()
    }
    let stable = preview.image === coverA && previewImageChanges == initialChanges
    search.stringValue = "b"
    filter()
    let held = preview.image === coverA
    previewSelection()
    receive([
      "type": "update", "selected": "track:b", "variables": ["preview_art": ["src": "fixture-b"]],
    ])
    let loadedChanges = previewImageChanges
    for text in ["be", "bet", "beta"] {
      search.stringValue = text
      filter()
    }
    let reused = preview.image === coverB && previewImageChanges == loadedChanges
    receive([
      "type": "update", "selected": "track:a", "variables": ["preview_art": ["src": "fixture-a"]],
    ])
    let staleIgnored = preview.image === coverB
    receive([
      "type": "update", "connection": "connecting", "message": "Finish connecting in your browser",
      "sheet": ["root": ["type": "view"]],
    ])
    showError("Connection test error")
    let inlineConnection =
      panel.attachedSheet == nil && status.stringValue == "Connection test error"
      && preview.image == nil
    let showsBeforeSignIn = showCount
    receive(["type": "update", "connection": "connected"])
    receive(["type": "update", "connection": "connected"])
    let signInReturnsOnce = showCount == showsBeforeSignIn + 1
    return [
      "status": "ok", "text_center_error_pt": offsets.max() ?? 0,
      "connection_errors_inline": inlineConnection,
      "rows_align_with_cover": rowsAligned, "input_centered_between_art_and_rows": inputCentered,
      "compact_row_insets": compactInsets, "return_aligns_with_command": returnAligned,
      "search_priority": sorted, "signin_returns_once": signInReturnsOnce,
      "shortcut_digits_fit": digitsFit,
      "return_image_centered": arrowInkError <= 0.25, "return_ink_center_error_pt": arrowInkError,
      "transport_centered_on_cover": playbackButtons.allSatisfy {
        abs($0.frame.midY - nowArt.frame.midY) < 0.01
      },
      "no_settings_button":
        !(panel.contentView?.subviews.contains {
          ($0 as? NSButton)?.action == #selector(openSettings)
        } ?? false),
      "same_selection_cover_stable": stable, "typing_keeps_previous_cover": held,
      "learned_cover_reused": reused, "stale_cover_ignored": staleIgnored,
      "no_reset_button":
        !(panel.contentView?.subviews.contains {
          ($0 as? NSButton)?.title == "Reset Connection"
        } ?? false),
    ]
  }
  private func buttonPixels(_ button: NSButton) -> (
    left: CGFloat, right: CGFloat, green: Int, black: Int, opacity: CGFloat
  ) {
    let scale: CGFloat = 8
    let width = Int(button.bounds.width * scale)
    let height = Int(button.bounds.height * scale)
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0), let bytes = bitmap.bitmapData
    else { return (0, 0, 0, 0, 0) }
    memset(bytes, 0, bitmap.bytesPerRow * height)
    bitmap.size = button.bounds.size
    button.cacheDisplay(in: button.bounds, to: bitmap)
    var left = width
    var right = -1
    var green = 0
    var black = 0
    var peakAlpha: CGFloat = 0
    for y in 0..<height {
      for x in 0..<width {
        peakAlpha = max(peakAlpha, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
      }
    }
    for y in 0..<height {
      for x in 0..<width {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if color.alphaComponent > peakAlpha * 0.03 {
          left = min(left, x)
          right = max(right, x)
        }
        if color.alphaComponent > 0.2 && color.greenComponent > color.redComponent + 0.3 {
          green += 1
        }
        if color.alphaComponent > 0.8
          && max(color.redComponent, max(color.greenComponent, color.blueComponent)) < 0.1
        {
          black += 1
        }
      }
    }
    return (
      right >= left ? CGFloat(left) / scale : 0, right >= left ? CGFloat(right + 1) / scale : 0,
      green, black, peakAlpha
    )
  }
  private func tintHasNoEdgeLines() -> Bool {
    let fixture = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { _ in
      NSColor.black.setFill()
      NSRect(x: 5, y: 9, width: 13, height: 22).fill()
      return true
    }
    fixture.size = NSSize(width: 13.75, height: 15.25)
    let button = IconButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    button.image = fixture
    button.contentTintColor = .gray
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 56, pixelsHigh: 56,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let bytes = bitmap.bitmapData
    else { return false }
    memset(bytes, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
    bitmap.size = button.bounds.size
    button.cacheDisplay(in: button.bounds, to: bitmap)
    var ink = 0
    var stray = 0
    for y in 0..<56 {
      for x in 0..<56 {
        if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
          ink += 1
          if x >= 30 { stray += 1 }
        }
      }
    }
    return ink > 20 && stray == 0
  }
  private func catalogModeChecks() -> [String: Any] {
    demo()
    search.stringValue = "/literal/"
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    let slashIsCatalog = routeKind == "catalog" && catalogPending && breadcrumb == "/"
    search.stringValue = "initial query"
    let commandReturn = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command,
      timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "\r",
      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    _ = key(commandReturn)
    let preservesInitial = routeKind == "catalog" && search.stringValue == "/initial query"
    let entryHasNoFlash = !searchStatusVisible && status.stringValue != "Searching Spotify…"
    search.stringValue = "/changed"
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    receive([
      "type": "update", "command": "browse", "route_kind": "catalog", "query": "initial query",
      "prefix": "/", "rows": [["name": "Old result", "uri": "old-result"]],
    ])
    let staleIgnored = source.isEmpty && search.stringValue == "/changed"
    receive([
      "type": "update", "command": "catalog-query", "route_kind": "catalog", "query": "changed",
      "searching": true, "prefix": "/", "rows": [],
    ])
    let loading = catalogPending
    revealSearchStatus()
    receive(["type": "update", "command": "preview", "variables": [:]])
    let steadyDuringPreview = status.stringValue == "Searching Spotify…"
    receive([
      "type": "update", "command": "browse", "route_kind": "catalog", "query": "changed",
      "searching": false, "prefix": "/",
      "rows": [["name": "Spotify ranked result", "uri": "new-result", "kind": "track"]],
    ])
    let resultsKept =
      !catalogPending && filtered.first?.uri == "new-result" && search.stringValue == "/changed"
    let minimumDisplay = status.stringValue == "Searching Spotify…"
    search.stringValue = "/next"
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    let steadyBetweenQueries = status.stringValue == "Searching Spotify…"
    search.stringValue = ""
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    let exits = routeKind == "home"
    demo()
    search.stringValue = ""
    filter()
    table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
    activateSelection()
    let menu = routeKind == "catalog" && search.stringValue == "/"
    let entryRange = (search.currentEditor() as? NSTextView)?.selectedRange()
    let caretAtEnd = entryRange == NSRange(location: 1, length: 0)
    receive([
      "type": "update", "command": "catalog", "route_kind": "catalog", "query": "", "prefix": "/",
      "search_text": "/", "rows": [],
    ])
    let replyRange = (search.currentEditor() as? NSTextView)?.selectedRange()
    let caretAfterReply = replyRange == NSRange(location: 1, length: 0)
    previewWork?.perform()
    let emptySearchPrompt = previewDetail.stringValue == "Type to search"
    search.stringValue = "/unmatched"
    filter()
    previewWork?.perform()
    let noMatchesGrey =
      previewDetail.stringValue == "No matches" && previewDetail.textColor == .secondaryLabelColor
    showError("Latest catalogue status")
    search.stringValue = "/retrying"
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    catalogSearchWork?.perform()
    let typingKeepsStatus = status.stringValue == "Latest catalogue status"
    demo()
    search.stringValue = ""
    filter()
    return [
      "status": "ok", "leading_slash_enters_catalogue": slashIsCatalog,
      "command_return_preserves_query": preservesInitial, "spotify_menu_enters_search": menu,
      "stale_live_search_ignored": staleIgnored, "remote_ranking_preserved": resultsKept,
      "search_loading_retains_cover": loading, "deleting_slash_exits_search": exits,
      "search_caret_after_slash": caretAtEnd && caretAfterReply,
      "search_caret_follows_theme": (search.currentEditor() as? NSTextView)?.insertionPointColor
        == playerTheme.searchText, "empty_search_prompt": emptySearchPrompt,
      "no_matches_grey": noMatchesGrey,
      "search_status_avoids_flicker": entryHasNoFlash && steadyDuringPreview && minimumDisplay
        && steadyBetweenQueries,
      "typing_keeps_latest_catalogue_status": typingKeepsStatus,
    ]
  }
  private func searchChecks() -> [String: Any] {
    let items = [
      MusicItem(["uri": "track:1", "kind": "track", "name": "Song Artist", "match": "Song Artist"]),
      MusicItem(["uri": "playlist:1", "kind": "playlist", "name": "Café Été", "match": "Café Été"]),
      MusicItem([
        "uri": "playlist:2", "kind": "playlist", "name": "Song Artist", "match": "Song Artist",
      ]),
      MusicItem(["uri": "album:1", "kind": "album", "name": "Song Two", "match": "Song Two"]),
      MusicItem(["uri": "artist:1", "kind": "artist", "name": "Artist", "match": "Artist"]),
    ]
    let ordered = MusicItem.prioritized(items)
    let stable =
      ordered.map { $0.uri } == ["playlist:1", "playlist:2", "album:1", "artist:1", "track:1"]
    func row(_ uri: String, _ kind: String, album: String = "", total: Int = 0) -> [String: Any] {
      ["uri": uri, "kind": kind, "name": "Single", "album_uri": album, "album_total": total]
    }
    func ranked(_ rows: [[String: Any]]) -> [String] {
      MusicItem.prioritized(rows.map(MusicItem.init)).map { $0.uri }
    }
    let singleAlbum = row("album:single", "album", total: 1)
    let singleSong = row("track:single", "track", album: "album:single")
    let normalAlbum = row("album:normal", "album", total: 12)
    let unrelatedSong = row("track:unrelated", "track", album: "album:other", total: 1)
    let rankingRows = [
      unrelatedSong, row("playlist:single", "playlist"), normalAlbum, singleAlbum, singleSong,
      row("artist:single", "artist"),
    ]
    let singleFirst =
      ranked(rankingRows) == [
        "playlist:single", "album:normal", "track:single", "album:single", "artist:single",
        "track:unrelated",
      ]
    let unknownAlbum = row("album:single", "album")
    let unknownCount = ranked([singleSong, unknownAlbum]) == ["album:single", "track:single"]
    let knownFromTrack =
      ranked([row("track:single", "track", album: "album:single", total: 1), unknownAlbum]) == [
        "track:single", "album:single",
      ]
    let conflictingCounts =
      ranked([row("track:normal", "track", album: "album:normal", total: 1), normalAlbum]) == [
        "album:normal", "track:normal",
      ]
    let withoutAlbum =
      ranked([singleSong, row("artist:single", "artist")]) == ["artist:single", "track:single"]
    let duplicates =
      ranked([singleSong, singleAlbum, singleSong]) == [
        "track:single", "album:single", "track:single",
      ]
    var singleMatcher = MusicFilter()
    let singleOrdered = MusicItem.prioritized(rankingRows.map(MusicItem.init))
    let filteredSingle = ["s", "si", "single", "s", ""].allSatisfy { query in
      singleMatcher.matching(
        singleOrdered, terms: MusicItem.normalize(query).split(whereSeparator: { $0.isWhitespace }),
        catalog: true
      ).map { $0.uri } == singleOrdered.map { $0.uri }
    }
    var matcher = MusicFilter()
    var matches = true
    for query in [
      "", "s", "so", "song", "song a", "song ar", "song", "a song", "c", "ca", "cafe", "café é",
      "é café", "z", "",
    ] {
      let terms = MusicItem.normalize(query).split(whereSeparator: { $0.isWhitespace })
      let result = matcher.matching(ordered, terms: terms, catalog: true)
      matches =
        matches
        && result.map { $0.uri }
          == ordered.filter { item in
            terms.allSatisfy { term in item.words.contains { $0.hasPrefix(term) } }
          }.map { $0.uri }
    }
    let names = [
      "ASCII Artist SONG 123", "Café Été", "Cafe\u{301} E\u{301}te\u{301}", "Straße", "İstanbul",
      "夜に駆ける", "Луна", "أغنية", "ＫＫ", "👩🏽‍💻 Night", "Ångström", "I ı İ i", "A\tB\nC",
    ]
    let unicodeItems = names.enumerated().map {
      MusicItem(["uri": "unicode:\($0.offset)", "name": $0.element])
    }
    let locale = Locale(identifier: "en_US_POSIX")
    func reference(_ value: String) -> String {
      value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }
    let normalized = names.allSatisfy { MusicItem.normalize($0) == reference($0) }
    var unicodeMatcher = MusicFilter()
    let queries =
      names.flatMap { name in (0...min(5, name.count)).map { String(name.prefix($0)) } } + [
        "cafe ete", "strass", "artist song", "夜", "night 👩🏽‍💻", "", "not found",
      ]
    let unicodeMatches = queries.allSatisfy { query in
      let terms = reference(query).split(whereSeparator: { $0.isWhitespace })
      let expected = unicodeItems.filter { item in
        let words = reference(item.name).split(whereSeparator: { $0.isWhitespace })
        return terms.allSatisfy { term in words.contains { $0.hasPrefix(term) } }
      }.map { $0.uri }
      return unicodeMatcher.matching(
        unicodeItems, terms: MusicItem.normalize(query).split(whereSeparator: { $0.isWhitespace }),
        catalog: true
      ).map { $0.uri } == expected
    }
    let scoped =
      matcher.matching([items[0]], terms: [], catalog: false).map { $0.uri } == ["track:1"]
    matcher.reset()
    let reset =
      matcher.matching([items[4]], terms: [], catalog: true).map { $0.uri } == ["artist:1"]
    receive([
      "type": "catalog",
      "rows": (0..<2000).map { ["name": "Old \($0)", "uri": "old:\($0)", "kind": "track"] },
    ])
    receive(["type": "catalog", "rows": [["name": "Latest", "uri": "latest", "kind": "playlist"]]])
    return [
      "status": "pending", "search_results_unchanged": matches, "category_order_stable": stable,
      "unicode_matching_preserved": unicodeMatches, "normalization_matches_foundation": normalized,
      "single_song_precedes_its_album": singleFirst,
      "single_song_order_survives_filtering": filteredSingle,
      "unknown_album_counts_are_not_guessed": unknownCount,
      "single_count_can_come_from_track_metadata": knownFromTrack,
      "full_album_count_overrides_stale_track_metadata": conflictingCounts,
      "unmatched_single_does_not_jump_categories": withoutAlbum,
      "search_does_not_drop_duplicate_rows": duplicates,
      "search_scope_resets": scoped && reset,
    ]
  }
  private func playArtworkChecks() -> [String: Any] {
    demo()
    routeKind = "songs"
    breadcrumb = "Songs/"
    setSearchText(breadcrumb)
    let albumCover = NSImage(size: NSSize(width: 32, height: 32))
    let playlistCover = NSImage(size: NSSize(width: 32, height: 32))
    imageCache.setObject(albumCover, forKey: "fixture-play-album")
    imageCache.setObject(playlistCover, forKey: "fixture-play-playlist")
    let all = actionItem("All", "play", ["play_uri": PlaybackContext.likedSongs.uri])
    guard let likedCover = bundledArtwork(all, root: workflowRoot()) else {
      return ["status": "error"]
    }
    playArtworkTestPath = likedCover
    imageCache.removeObject(forKey: likedCover as NSString)
    failedImages.remove(likedCover)
    source = [
      MusicItem([
        "uri": "action:album-art", "kind": "action", "name": "Play Album",
        "art": "fixture-play-album", "symbol": "play.fill", "item": ["action": "play"],
      ]),
      MusicItem([
        "uri": "action:playlist-art", "kind": "action", "name": "Play Playlist",
        "art": "fixture-play-playlist", "symbol": "play.fill", "item": ["action": "play"],
      ]),
      MusicItem([
        "uri": text(all["uri"]), "kind": "action", "name": "All", "art": likedCover,
        "symbol": "play.fill", "item": all,
      ]),
    ]
    filter(resetSelection: true)
    previewSelection()
    let album =
      preview.image === albumCover && previewIsCover && previewTitle.stringValue == "Play Album"
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    let playlist =
      preview.image === playlistCover && previewIsCover
      && previewTitle.stringValue == "Play Playlist"
    let songs = homeItems.first { text(dict($0["target"])["kind"]) == "songs" }!
    let rootCover = bundledArtwork(songs, root: workflowRoot()) == likedCover
    let songKeepsAlbum =
      bundledArtwork(
        ["kind": "track", "playback_context": PlaybackContext.likedSongs.object],
        root: workflowRoot()) == nil
    table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
    return [
      "status": "pending", "album_play_action_shows_cover": album,
      "playlist_play_action_shows_cover": playlist,
      "songs_menu_uses_liked_cover": rootCover,
      "individual_liked_songs_keep_their_album_art": songKeepsAlbum,
    ]
  }
  private func playArtworkCheckResult() -> [String: Any] {
    if loadingImages.contains(playArtworkTestPath) { return ["status": "pending"] }
    let cover = imageCache.object(forKey: playArtworkTestPath as NSString)
    let liked =
      cover != nil && preview.image === cover && previewIsCover && previewTitle.stringValue == "All"
    let bounded = cover?.size == NSSize(width: 512, height: 512)
    demo()
    setSearchText("")
    return [
      "status": "ok", "all_songs_shows_bundled_liked_art_offline": liked,
      "liked_cover_decodes_at_bounded_size": bounded,
    ]
  }
  private func artworkChecks() -> [String: Any] {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "spotify-artwork-" + UUID().uuidString)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let paths = ["first.png", "second.png"].map { directory.appendingPathComponent($0).path }
    artworkTestPaths = paths
    for (index, path) in paths.enumerated() {
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 512, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
      let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
      context.setFillColor((index == 0 ? NSColor.red : NSColor.blue).cgColor)
      context.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
      try! bitmap.representation(using: .png, properties: [:])!.write(
        to: URL(fileURLWithPath: path))
    }
    connection = "connected"
    breadcrumb = "Artwork/"
    setSearchText(breadcrumb)
    source = paths.enumerated().map {
      MusicItem(["uri": "art:\($0.offset)", "name": "Art \($0.offset)", "art": $0.element])
    }
    setCurrentTrack("spotify:track:" + String(repeating: "x", count: 22), refresh: false)
    currentImageURL = "https://old-artwork.example/image"
    filter()
    previewSelection()
    setNowArt(paths[0])
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    setCurrentTrack("spotify:track:" + String(repeating: "y", count: 22), refresh: false)
    previewSelection()
    setNowArt(paths[1])
    receive(["type": "artwork", "url": "https://old-artwork.example/image", "path": paths[0]])
    for _ in 0..<10 { _ = image(paths[1]) }
    let coalesced =
      Set(paths).isSubset(of: loadingImages) && loadingImages.intersection(paths).count == 2
    return ["status": "pending", "artwork_requests_coalesced": coalesced]
  }
  private func artworkCheckResult() -> [String: Any] {
    let paths = artworkTestPaths
    guard paths.count == 2, loadingImages.intersection(paths).isEmpty else {
      return ["status": "pending"]
    }
    defer {
      try? FileManager.default.removeItem(
        at: URL(fileURLWithPath: paths[0]).deletingLastPathComponent())
    }
    let first = imageCache.object(forKey: paths[0] as NSString)
    let second = imageCache.object(forKey: paths[1] as NSString)
    return [
      "status": "ok",
      "artwork_size_bounded": first?.size == NSSize(width: 512, height: 256)
        && second?.size == first?.size,
      "stale_artwork_ignored": second != nil && preview.image === second && nowArt.image === second,
    ]
  }
  private func missingArtworkChecks() -> [String: Any] {
    optimisticUntil = .distantPast
    let cover = NSImage(size: NSSize(width: 20, height: 20))
    nowArt.image = cover
    let uri = "spotify:track:" + String(repeating: "m", count: 22)
    updatePlayback(["paused", "No cover", "Artist", "Album", "", uri])
    let missingHeader = nowArt.image === symbol("questionmark", height: 64)
    currentImageURL = "https://example.invalid/missing-art"
    nowArt.image = cover
    receive(["type": "artwork", "url": currentImageURL, "path": ""])
    let missingDownload = nowArt.image === symbol("questionmark", height: 64)
    let cachedURL = "https://example.invalid/cached-art"
    artworkPaths[cachedURL] = "fixture-reused-cover"
    imageCache.setObject(cover, forKey: "fixture-reused-cover")
    catalog = []
    updatePlayback(["paused", "Known cover", "Artist", "Album", cachedURL, uri])
    let reused = nowArt.image === cover
    let item = MusicItem(["uri": uri, "kind": "track", "name": "No cover"])
    breadcrumb = "Missing/"
    routeKind = "songs"
    setSearchText(breadcrumb)
    source = [item]
    filter()
    previewSelection()
    setPreviewImage(cover)
    previewIsCover = true
    receive(["selected": uri, "preview_complete": true, "variables": [:]])
    let missingPreview = preview.image === symbol("questionmark", height: 150) && !previewIsCover
    receive([
      "type": "update", "command": "artwork", "connection": "connected", "route_kind": "songs",
      "prefix": breadcrumb,
      "rows": [
        ["uri": uri, "kind": "track", "name": "Newly cached cover", "art": "fixture-reused-cover"]
      ],
    ])
    previewSelection()
    let newlyCached = preview.image === cover
    let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
      "spotify-invalid-art-" + UUID().uuidString)
    try! Data("Not an image".utf8).write(to: path)
    missingArtworkTestPath = path.path
    let invalidURI = "spotify:track:" + String(repeating: "j", count: 22)
    setCurrentTrack(invalidURI, refresh: false)
    source = [
      MusicItem(["uri": invalidURI, "kind": "track", "name": "Invalid cover", "art": path.path])
    ]
    previewURI = ""
    filter()
    previewSelection()
    nowArt.image = cover
    setNowArt(path.path)
    return [
      "status": "pending", "missing_header_art_uses_placeholder": missingHeader,
      "failed_download_uses_placeholder": missingDownload,
      "missing_preview_art_uses_placeholder": missingPreview,
      "known_cover_url_reused": reused, "newly_cached_cover_updates_selection": newlyCached,
    ]
  }
  private func missingArtworkCheckResult() -> [String: Any] {
    let path = missingArtworkTestPath
    guard !path.isEmpty, !loadingImages.contains(path) else { return ["status": "pending"] }
    defer {
      try? FileManager.default.removeItem(atPath: path)
      missingArtworkTestPath = ""
    }
    return [
      "status": "ok", "invalid_art_decode_failed": failedImages.contains(path),
      "invalid_header_uses_placeholder": nowArt.image === symbol("questionmark", height: 64),
      "invalid_preview_uses_placeholder": preview.image === symbol("questionmark", height: 150)
        && !previewIsCover,
    ]
  }

  private func directPlaybackChecks() -> [String: Any] {
    demo()
    search.isEnabled = true
    let event = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
      windowNumber: panel.windowNumber, context: nil, characters: "\r",
      charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    var result: [String: Any] = ["status": "ok"]
    for kind in ["track", "album", "playlist", "artist"] {
      for searchResult in [false, true] {
        let uri = "spotify:" + kind + ":" + String(repeating: "a", count: 22)
        routeKind = searchResult ? "catalog" : kind + "s"
        breadcrumb = searchResult ? "/" : kind.capitalized + "s/"
        let query = breadcrumb + (searchResult ? "Example" : "")
        setSearchText(query)
        source = [
          MusicItem([
            "uri": uri, "name": "Example", "kind": kind,
            "item": ["uri": uri, "kind": kind, "name": "Example"],
          ])
        ]
        filter(resetSelection: true)
        placeSearchCaretAtEnd()
        let before = playbackRequest
        panel.sendEvent(event)
        result[kind + (searchResult ? "_search_plays_directly" : "_browse_plays_directly")] =
          playbackRequest == before + 1 && search.stringValue == query
          && (kind == "track" ? currentTrackURI == uri : currentPlaybackContext?.uri == uri)
      }
    }
    routeKind = "home"
    breadcrumb = ""
    setSearchText("")
    source = [
      MusicItem([
        "uri": "action:Songs", "name": "Songs", "kind": "action",
        "item": ["action": "browse", "target": ["kind": "songs"]],
      ])
    ]
    filter(resetSelection: true)
    let before = playbackRequest
    placeSearchCaretAtEnd()
    panel.sendEvent(event)
    result["home_songs_plays_liked_collection"] =
      playbackRequest == before + 1
      && currentPlaybackContext == PlaybackContext.likedSongs && breadcrumb.isEmpty
    source = [
      MusicItem([
        "uri": "action:Search", "name": "Search", "kind": "action", "item": ["action": "catalog"],
      ])
    ]
    filter(resetSelection: true)
    placeSearchCaretAtEnd()
    panel.sendEvent(event)
    result["search_falls_back_to_enter"] =
      routeKind == "catalog" && search.stringValue == "/"
      && playbackRequest == before + 1
    demo()
    return result
  }
  private func singleLineChecks() -> [String: Any] {
    demo()
    search.isEnabled = true
    setSearchText("one\r\ntwo\u{2028}three")
    placeSearchCaretAtEnd()
    guard let editor = search.currentEditor() as? NSTextView, panel.firstResponder === editor else {
      return ["status": "error", "message": "Search editor must have focus"]
    }
    let normalized = search.stringValue == "one two three" && editor.string == search.stringValue
    editor.insertText(
      "four\nfive\r\nsix",
      replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
    controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    let paste =
      search.stringValue.rangeOfCharacter(from: .newlines) == nil
      && editor.string.rangeOfCharacter(from: .newlines) == nil
    let query = search.stringValue
    var ignored = true
    for selector in [
      #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
      #selector(NSResponder.insertLineBreak(_:)),
      #selector(NSResponder.insertParagraphSeparator(_:)),
    ] {
      ignored = control(search, textView: editor, doCommandBy: selector) && ignored
    }
    let noSeparators = ignored && search.stringValue == query && editor.string == query
    let uri = "spotify:album:" + String(repeating: "k", count: 22)
    routeKind = "catalog"
    breadcrumb = "/"
    setSearchText("/Album")
    source = [
      MusicItem([
        "uri": uri, "name": "Album", "kind": "album",
        "item": ["uri": uri, "name": "Album", "kind": "album"],
      ])
    ]
    filter(resetSelection: true)
    placeSearchCaretAtEnd()
    let before = playbackRequest
    let enter = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .option, timestamp: 0,
      windowNumber: panel.windowNumber, context: nil, characters: "\u{3}",
      charactersIgnoringModifiers: "\u{3}", isARepeat: false, keyCode: 76)!
    panel.sendEvent(enter)
    let keypad =
      playbackRequest == before + 1 && currentPlaybackContext?.uri == uri
      && search.stringValue == "/Album"
    demo()
    return [
      "status": "ok", "programmatic_queries_are_single_line": normalized,
      "pasted_queries_are_single_line": paste, "line_separator_commands_are_consumed": noSeparators,
      "option_keypad_enter_plays_from_focused_editor": keypad,
    ]
  }
  private func offlineUIChecks() -> [String: Any] {
    let originalTheme = playerTheme
    defer { applyTheme(originalTheme) }
    demo()
    receive(["type": "update", "offline": true])
    var glyphsFit = true
    for font in ["", "Avenir"] {
      var theme = originalTheme
      theme.secondaryFont = font
      applyTheme(theme)
      let frame = activityStatus.frame
      func bitmap(_ width: CGFloat) -> NSBitmapImageRep {
        activityStatus.setFrameSize(NSSize(width: width, height: frame.height))
        let image = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(ceil(width * 2)),
          pixelsHigh: Int(ceil(frame.height * 2)), bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
          bitsPerPixel: 0)!
        image.size = activityStatus.bounds.size
        memset(image.bitmapData!, 255, image.bytesPerRow * image.pixelsHigh)
        activityStatus.cacheDisplay(in: activityStatus.bounds, to: image)
        return image
      }
      let actual = bitmap(frame.width)
      let reference = bitmap(frame.width + 12)
      for y in 0..<reference.pixelsHigh {
        for x in 0..<reference.pixelsWide {
          for channel in 0..<4 {
            let expected = reference.bitmapData![y * reference.bytesPerRow + x * 4 + channel]
            let drawn =
              x < actual.pixelsWide
              ? actual.bitmapData![y * actual.bytesPerRow + x * 4 + channel] : 255
            if abs(Int(expected) - Int(drawn)) > 1 { glyphsFit = false }
          }
        }
      }
      activityStatus.frame = frame
    }
    applyTheme(originalTheme)
    let visible =
      !activityStatus.isHidden && activityStatus.stringValue == "offline"
      && activityStatus.textColor == playerTheme.secondary
      && activityStatus.alignment == .left && activityStatus.frame.minX == 12
      && status.frame.minX > activityStatus.frame.maxX
    enterCatalog("downloaded")
    let noLoading =
      !catalogPending && !searchStatusVisible && status.stringValue != "Searching Spotify…"
    receive(["type": "update", "offline": false])
    let hidden = activityStatus.isHidden
    demo()
    return [
      "status": "ok", "offline_label_small_and_left_aligned": visible,
      "offline_label_not_clipped_with_system_or_avenir": glyphsFit,
      "offline_search_has_no_network_loading_status": noLoading,
      "online_hides_offline_label": hidden,
    ]
  }
  private func apiActivityChecks() -> [String: Any] {
    demo()
    setSearchText("")
    let cachedSilent = activityStatus.isHidden
    receive(["type": "api-activity", "api_active": true])
    let shortRequestsQuiet = activityStatus.isHidden
    apiActivityWork?.perform()
    let library =
      !activityStatus.isHidden && activityStatus.stringValue == "Syncing with Spotify…"
      && activityStatus.frame.minX == 12 && activityStatus.textColor == playerTheme.secondary
    enterCatalog("query")
    let search = activityStatus.stringValue == "Searching Spotify…"
    showError("Spotify request failed")
    let errorVisible =
      status.stringValue == "Spotify request failed" && status.textColor == .systemRed
      && status.frame.minX > activityStatus.frame.maxX
    receive(["type": "update", "offline": true])
    let offlineWins = activityStatus.stringValue == "offline" && activityStatus.frame.minX == 12
    receive(["type": "update", "offline": false])
    receive(["type": "api-activity", "api_active": false])
    apiActivityWork?.perform()
    let finished =
      activityStatus.isHidden && status.stringValue == "Spotify request failed"
      && status.textColor == .systemRed
    demo()
    receive(["type": "api-activity", "api_active": true])
    let cancelled = apiActivityWork
    receive(["type": "api-activity", "api_active": false])
    cancelled?.perform()
    let fastRequestNoFlash = activityStatus.isHidden
    demo()
    return [
      "status": "ok", "cached_results_have_no_activity": cachedSilent,
      "short_requests_avoid_flicker": shortRequestsQuiet && fastRequestNoFlash,
      "library_activity_on_bottom_left": library, "catalogue_search_shows_api_activity": search,
      "errors_remain_visible_beside_activity": errorVisible,
      "offline_takes_priority_on_left": offlineWins,
      "completion_hides_activity_and_retains_error": finished,
    ]
  }
  private func spaceChecks() -> [String: Any] {
    demo()
    setSearchText("keep my filter")
    show()
    let window = ObjectIdentifier(panel)
    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    let hidden =
      !hotkeyHandoffAllowed && !panel.isVisible
      && search.stringValue == "keep my filter"
      && !panel.collectionBehavior.contains(.canJoinAllSpaces)
      && panel.collectionBehavior.contains(.moveToActiveSpace)
    let before = openedSpotify
    showForHotkey(focused: true)
    let reopens =
      hotkeyHandoffAllowed && openedSpotify == before && ObjectIdentifier(panel) == window
    setScreenshotMode(true)
    NSWorkspace.shared.notificationCenter.post(
      name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    let demoHides = !hotkeyHandoffAllowed && !screenshotMode
    return [
      "status": "ok", "space_change_hides_without_losing_filter": hidden,
      "reopening_reuses_warm_panel": reopens, "demo_mode_also_hides_on_space_change": demoHides,
    ]
  }
  @MainActor
  private func screenshotModeChecks() async -> [String: Any] {
    @MainActor
    func waitForFocus(_ condition: @MainActor () -> Bool) async -> Bool {
      let deadline = Date().addingTimeInterval(0.5)
      while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
      }
      return condition()
    }
    demo()
    search.isEnabled = true
    placeSearchCaretAtEnd()
    let previousTrack = currentTrackURI
    toggleScreenshotMode()
    let activated = await waitForFocus { NSApp.isActive && panel.isKeyWindow }
    let enabled =
      activated && screenshotMode && hotkeyHandoffAllowed && panel.level == .normal
      && panel.collectionBehavior.contains(.managed)
      && !panel.collectionBehavior.contains(.transient)
    let unchangedCaret =
      (search.currentEditor() as? NSTextView)?.insertionPointColor == playerTheme.searchText
    windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
    let keptVisible = screenshotMode && hotkeyHandoffAllowed && !panel.hidesOnDeactivate
    let other = PlayerPanel(
      contentRect: NSRect(x: 0, y: 0, width: 20, height: 20),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    defer { other.orderOut(nil) }
    panel.makeKeyAndOrderFront(nil)
    other.makeKeyAndOrderFront(nil)
    let visibleWithoutFocus = await waitForFocus { panel.isVisible && other.isKeyWindow }
    let showsBeforeOff = showCount
    toggleScreenshotMode()
    let togglesOff =
      !screenshotMode && panel.level == .floating && panel.collectionBehavior.contains(.transient)
    let opensNormally =
      await waitForFocus { panel.isVisible && panel.isKeyWindow } && visibleWithoutFocus
      && hotkeyHandoffAllowed && showCount == showsBeforeOff + 1
    windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
    let ignoresStaleFocusLoss = panel.isVisible && panel.isKeyWindow && !screenshotMode
    other.makeKeyAndOrderFront(nil)
    let hidesOnFirstFocusLoss = await waitForFocus { !panel.isVisible } && !screenshotMode
    show()
    let reopened = await waitForFocus { panel.isVisible && panel.isKeyWindow }
    other.makeKeyAndOrderFront(nil)
    let firstReopenNormal = await waitForFocus { !panel.isVisible } && reopened && !screenshotMode
    toggleScreenshotMode()
    _ = await waitForFocus { panel.isKeyWindow }
    panel.cancelOperation(nil)
    let escapeExits =
      !screenshotMode && !panel.isVisible && !hotkeyHandoffAllowed
      && panel.level == .floating && panel.collectionBehavior.contains(.transient)
    toggleScreenshotMode()
    let escapeThenDemoEnables = await waitForFocus {
      screenshotMode && panel.isVisible && panel.isKeyWindow
    }
    hide()
    return [
      "status": "ok", "screenshot_mode_enabled": enabled,
      "screenshot_mode_keeps_player_on_focus_loss": keptVisible,
      "screenshot_mode_preserves_content": unchangedCaret,
      "screenshot_mode_toggles_off": togglesOff,
      "demo_toggle_off_opens_normal_player": opensNormally && togglesOff,
      "demo_off_hides_on_first_focus_loss": hidesOnFirstFocusLoss,
      "escape_then_demo_enables_new_session": escapeExits && escapeThenDemoEnables,
      "stale_focus_loss_does_not_hide_reopened_player": ignoresStaleFocusLoss,
      "first_reopen_after_demo_off_is_normal": firstReopenNormal,
      "escape_exits_screenshot_mode": escapeExits,
      "screenshot_mode_keeps_real_track": previousTrack == currentTrackURI,
    ]
  }

  private func themeChecks() -> [String: Any] {
    let theme = PlayerTheme([
      "alfredtheme": [
        "window": ["color": "#17212FE6", "borderColor": "#C0D0E080", "roundness": 12, "blur": 8],
        "result": [
          "backgroundSelected": "#EEC847FF", "roundness": 4,
          "text": ["color": "#EDF2F9FF", "colorSelected": "#17212FFF", "font": "Avenir"],
          "subtext": ["color": "#90A4BDFF", "font": "Avenir"],
          "shortcut": ["color": "#A9C7E4FF", "colorSelected": "#17212FFF", "font": "Avenir"],
        ],
        "search": [
          "background": "#17212FFF", "backgroundSelected": "#37628AFF", "roundness": 5,
          "text": ["color": "#E6F2FFFF", "colorSelected": "#FFFFFFFF", "font": "Avenir"],
        ],
        "scrollbar": ["color": "#A9C7E4FF", "thickness": 3],
      ]
    ])
    defer {
      applyTheme(PlayerTheme())
      demo()
      search.stringValue = ""
      filter()
    }
    demo()
    setCurrentTrack("", refresh: false)
    applyTheme(theme)
    let emptyTitleThemed = nowTitle.textColor == theme.secondary
    setCurrentTrack("spotify:track:" + String(repeating: "h", count: 22), refresh: false)
    nowTitle.stringValue = "Theme song"
    placeSearchCaretAtEnd()
    let editor = search.currentEditor() as? NSTextView
    let row = MusicCell(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
    row.display(
      MusicItem(["name": "Selected playlist", "kind": "playlist"]), index: 0, selected: true)
    row.layout()
    let selection =
      row.title.textColor == theme.selectedText
      && row.returnArrow.contentTintColor == theme.selectedShortcut
    row.display(MusicItem(["name": "Playlist", "kind": "playlist"]), index: 1, selected: false)
    let normal = row.title.textColor == theme.text && row.shortcut.textColor == theme.shortcut
    shuffling = true
    updateShuffle()
    let pixels = buttonPixels(shuffle)
    let green = pixels.green > 10 && pixels.black > 10
    shuffling = false
    updateShuffle()
    let root = panel.contentView!
    root.layoutSubtreeIfNeeded()
    let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
    root.cacheDisplay(in: root.bounds, to: bitmap)
    let x = bitmap.pixelsWide / 2
    func pixel(_ row: Int) -> NSColor { bitmap.colorAt(x: x, y: row)!.usingColorSpace(.sRGB)! }
    let edge = pixel(0)
    let inside = pixel(1)
    let background = pixel(2)
    let visibleBorder = abs(edge.redComponent - background.redComponent) > 0.02
    let onePixelBorder = abs(inside.redComponent - background.redComponent) < 0.01
    previewIsCover = false
    previewURI = ""
    table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
    previewSelection()
    applyTheme(theme)
    let searchBlack =
      preview.image === symbol("magnifyingglass", height: 150) && preview.contentTintColor == .black
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    previewSelection()
    let otherPreviewsThemed = preview.contentTintColor == theme.secondary
    return [
      "status": "ok", "theme_applied_to_rows": selection && normal,
      "theme_applied_to_header": nowTitle.textColor == theme.text
        && nowDetail.textColor == theme.secondary,
      "empty_track_title_follows_secondary_color": emptyTitleThemed,
      "theme_applied_to_cursor": editor?.insertionPointColor == theme.searchText,
      "theme_applied_to_text_selection": editor?.selectedTextAttributes[.backgroundColor]
        as? NSColor == theme.searchSelection,
      "theme_font_family": row.title.font?.familyName == "Avenir"
        && search.font?.familyName == "Avenir",
      "theme_window_radius": panel.contentView?.layer?.cornerRadius == 12,
      "theme_border_renders_in_captures": visibleBorder,
      "theme_border_is_one_pixel": onePixelBorder,
      "theme_controls": toggle.contentTintColor == theme.control
        && shuffle.contentTintColor == theme.secondary,
      "spotify_green_preserved": green, "large_search_preview_stays_black": searchBlack,
      "other_preview_symbols_follow_theme": otherPreviewsThemed,
    ]
  }

  private func repeatChecks() -> [String: Any] {
    connection = "connected"
    repeatMode = .off
    confirmedRepeatMode = .off
    repeatPending = false
    updateRepeat()
    let start = repeatRequest
    let off =
      !repeatButton.showsActiveCircle && repeatButton.contentTintColor == .secondaryLabelColor
    cycleRepeat()
    let all =
      repeatMode == .context && repeatButton.showsActiveCircle
      && repeatButton.image === repeatAllImage(height: 10)
    cycleRepeat()
    let one =
      repeatMode == .track && repeatButton.showsActiveCircle
      && repeatButton.image === symbol("repeat.1", height: 10)
    cycleRepeat()
    let cycles = off && all && one && repeatMode == .off
    receive(["type": "repeat", "mode": "context", "request": start + 1])
    receive(["type": "repeat", "mode": "track", "request": start + 3, "poll": true])
    let staleSafe = repeatMode == .off && repeatPending
    receive(["type": "repeat", "mode": "off", "request": start + 3])
    let confirmed = repeatMode == .off && !repeatPending
    cycleRepeat()
    receive([
      "type": "repeat", "mode": "context", "request": repeatRequest, "error": "Repeat test failed",
    ])
    let recovers =
      repeatMode == .off && !repeatPending && status.stringValue == "Repeat test failed"
    repeatButton.highlight(true)
    let heldGreen = buttonPixels(repeatButton).green > 10
    repeatButton.highlight(false)
    let next = playbackButtons.last!
    return [
      "status": "ok", "repeat_cycles_off_all_one_off": cycles,
      "repeat_stale_updates_ignored": staleSafe, "repeat_confirmation_applied": confirmed,
      "repeat_failure_restores_confirmed_state": recovers, "repeat_press_green": heldGreen,
      "repeat_to_right_of_next": repeatButton.frame.minX >= next.frame.maxX,
      "repeat_within_panel": repeatButton.frame.maxX <= preview.frame.maxX,
      "repeat_vertically_centered": repeatButton.frame.midY == nowArt.frame.midY,
      "repeat_symbols_available": symbol("repeat", height: 10) != nil
        && symbol("repeat.1", height: 10) != nil,
    ]
  }
  private func controlChecks() -> [String: Any] {
    connection = "connected"
    let previous = playbackButtons[0]
    let next = playbackButtons[2]
    let previousRight = previous.frame.minX + buttonPixels(previous).right
    let nextLeft = next.frame.minX + buttonPixels(next).left
    func gaps() -> (CGFloat, CGFloat) {
      let pixels = buttonPixels(toggle)
      return (
        toggle.frame.minX + pixels.left - previousRight, nextLeft - toggle.frame.minX - pixels.right
      )
    }
    playing = false
    updateToggle()
    let playGaps = gaps()
    playing = true
    updateToggle()
    let pauseGaps = gaps()
    let playError = abs(playGaps.0 - playGaps.1)
    let pauseError = abs(pauseGaps.0 - pauseGaps.1)
    let playAligned = playError <= 0.15 && pauseError <= 0.15
    var pressesGreen = true
    for button in playbackButtons {
      button.isEnabled = true
      button.highlight(true)
      let heldPixels = buttonPixels(button)
      pressesGreen = pressesGreen && heldPixels.green > 10 && heldPixels.black == 0
      button.highlight(false)
      let restingPixels = buttonPixels(button)
      pressesGreen =
        pressesGreen && button.contentTintColor == .black && restingPixels.green == 0
        && restingPixels.black > 10
    }
    let sampleURI = "spotify:track:" + String(repeating: "a", count: 22)
    let sampleContext = "spotify:playlist:" + String(repeating: "b", count: 22)
    let event = SpotifyCommands.playbackEvent("play", uri: sampleURI, context: sampleContext)
    let backgroundPlayback =
      event?.eventClass == 0x7370_6679 && event?.eventID == 0x5043_7478
      && event?.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue == sampleURI
      && event?.paramDescriptor(forKeyword: 0x636f_7478)?.stringValue == sampleContext
      && SpotifyCommands.playbackOptions.contains(.neverInteract)
      && !SpotifyCommands.playbackOptions.contains(.canSwitchLayer)
      && !SpotifyCommands.backgroundLaunchConfiguration().activates
    let transportEvents = [
      ("toggle", AEEventID(0x506c_5073)), ("previous", AEEventID(0x5072_6576)),
      ("next", AEEventID(0x4e65_7874)),
    ].allSatisfy { command, code in
      guard let event = SpotifyCommands.playbackEvent(command, uri: "", context: ""),
        let target = event.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr))
      else { return false }
      return event.eventClass == 0x7370_6679 && event.eventID == code
        && String(data: target.data, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
          == "com.spotify.client"
    }
    let first = "spotify:track:" + String(repeating: "a", count: 22)
    let second = "spotify:track:" + String(repeating: "b", count: 22)
    setCurrentTrack(first)
    let initiallyUnsaved = like.isEnabled && likedTracks[first] != true
    like.highlight(true)
    toggleLiked()
    like.highlight(false)
    let pending = pendingLikes[first] == true && !like.isEnabled
    let pendingPixels = buttonPixels(like)
    let pendingGreen =
      pendingPixels.green > 10 && pendingPixels.black == 0 && pendingPixels.opacity > 0.98
    setCurrentTrack(second)
    receive(["type": "liked", "uri": first, "liked": true])
    let staleSafe =
      currentTrackURI == second && likedTracks[second] != true
      && like.toolTip == "Save to Liked Songs"
    setCurrentTrack(first)
    let saved =
      like.toolTip == "Remove from Liked Songs" && like.contentTintColor == spotifyGreen
      && like.showsSavedCheck
    toggleLiked()
    let togglesOff = pendingLikes[first] == false
    receive(["type": "liked", "uri": first, "liked": false])
    let unliked = like.isEnabled && !like.showsSavedCheck
    like.highlight(true)
    let likePressesGreen = buttonPixels(like).green > 10
    like.highlight(false)
    setCurrentTrack(second)
    toggleLiked()
    receive(["type": "liked", "uri": second, "liked": false, "error": "Save failed"])
    let failure =
      like.isEnabled && pendingLikes[second] == nil && status.stringValue == "Save failed"
    let shuffleFrame = shuffle.frame
    let shuffleSize = shuffle.image?.size
    shuffling = false
    toggleShuffle()
    let onPixels = buttonPixels(shuffle)
    let shuffleOn =
      shuffling && shuffle.showsActiveCircle && shuffle.contentTintColor == .black
      && onPixels.green > 10 && onPixels.black > 10
    shuffle.highlight(true)
    let heldOnPixels = buttonPixels(shuffle)
    shuffle.highlight(false)
    toggleShuffle()
    let offPixels = buttonPixels(shuffle)
    let shuffleOff =
      !shuffling && !shuffle.showsActiveCircle && shuffle.contentTintColor == .secondaryLabelColor
      && offPixels.green == 0 && offPixels.black == 0
    shuffle.highlight(true)
    let heldShufflePixels = buttonPixels(shuffle)
    let shufflePressesGreen =
      heldShufflePixels.green > 10 && heldShufflePixels.black == 0 && heldOnPixels.green > 10
      && heldOnPixels.black > 10
    shuffle.highlight(false)
    let shuffleStable = shuffle.frame == shuffleFrame && shuffle.image?.size == shuffleSize
    show()
    let openedBefore = openedSpotify
    showForHotkey(focused: true)
    let hotkeyOpened = openedSpotify == openedBefore + 1
    showForHotkey(focused: false)
    let unfocusedShows = openedSpotify == openedBefore + 1
    panel.cancelOperation(nil)
    windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    let showsAfterEscape = showCount
    showForHotkey(focused: true)
    let escapeReopens = openedSpotify == openedBefore + 1 && showCount == showsAfterEscape + 1
    showForHotkey(focused: true)
    let repeatedOpens = openedSpotify == openedBefore + 2
    return [
      "status": "ok", "tinted_icons_have_no_edge_lines": tintHasNoEdgeLines(),
      "local_fallback_uses_background_delivery": backgroundPlayback,
      "transport_events_target_spotify_only": transportEvents, "play_pause_equal_gaps": playAligned,
      "play_gap_difference_pt": playError, "pause_gap_difference_pt": pauseError,
      "held_playback_controls_green": pressesGreen, "like_unsaved": initiallyUnsaved,
      "like_pending": pending, "like_pending_stays_green": pendingGreen, "like_saved": saved,
      "like_stale_reply_safe": staleSafe, "checkmark_unlikes": togglesOff && unliked,
      "held_like_green": likePressesGreen, "held_shuffle_green": shufflePressesGreen,
      "shuffle_geometry_stable": shuffleStable, "like_failure_recoverable": failure,
      "shuffle_on": shuffleOn, "shuffle_off": shuffleOff,
      "shuffle_icon_loaded": shuffle.image != nil,
      "hotkey_opens_spotify_when_focused": hotkeyOpened,
      "hotkey_shows_when_unfocused": unfocusedShows, "escape_then_hotkey_reopens": escapeReopens,
      "second_hotkey_opens_spotify": repeatedOpens,
    ]
  }
  private func demo() {
    connection = "connected"
    pendingPlaintextPath = nil
    lastPlaintextPath = nil
    pendingHomeQuery = nil
    currentPlaybackContext = nil
    selectedSourceTrack = ""
    observedPlaybackContext = nil
    updateContextLabel()
    for button in playbackButtons { button.isEnabled = true }
    shuffle.isEnabled = true
    updateRepeat()
    inlineError = nil
    statusMessage = ""
    statusIsError = false
    apiActivityWork?.cancel()
    apiActivityWork = nil
    apiActive = false
    apiActivityVisible = false
    apiActivityShownAt = .distantPast
    offline = false
    activityStatus.isHidden = true
    routeKind = "home"
    breadcrumb = ""
    catalogPending = false
    updateSearchStatus()
    catalogSearchWork?.cancel()
    source = ["Playlists", "Albums", "Artists", "Songs", "Search"].enumerated().map { index, name in
      MusicItem([
        "name": name, "kind": "action", "uri": "action:\(name)",
        "symbol": [
          "music.note.list", "square.stack", "person.fill", "music.note", "magnifyingglass",
        ][index], "match": name,
        "item": ["action": index == 4 ? "catalog" : "browse"],
      ])
    }
    home = source
    filter()
    previewSelection()
  }
  private func snapshot(_ path: String) {
    guard let root = panel.contentView else { return }
    root.layoutSubtreeIfNeeded()
    guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
    root.cacheDisplay(in: root.bounds, to: bitmap)
    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }
}
