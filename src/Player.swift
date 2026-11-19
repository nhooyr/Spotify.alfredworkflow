import AppKit
import Carbon
import CoreText
import Darwin

private let socketDirectory = ProcessInfo.processInfo.environment["SPOTIFY_NATIVE_SOCKET_DIR"] ?? "/tmp/spotify-alfred-\(getuid())"
private let socketPath = socketDirectory + "/player.sock"
private let applicationID = "com.runningwithcrayons.Alfred"
private var delegate: PlayerDelegate!
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
        let item = edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        item.keyEquivalentModifierMask = shifted ? [.command, .shift] : .command
    }
    let pastePlain = edit.addItem(withTitle: "Paste and Match Style", action: NSSelectorFromString("pasteAsPlainText:"), keyEquivalent: "v")
    pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]
    root.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
    editingMenu = edit
    NSApp.mainMenu = root
}

private func performEditingKey(_ event: NSEvent, responder: NSResponder?) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
    for item in editingMenu?.items ?? [] where item.keyEquivalent.lowercased() == key && item.keyEquivalentModifierMask == modifiers {
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

private func secureSocketDirectory() throws {
    try FileManager.default.createDirectory(atPath: socketDirectory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    let attributes = try FileManager.default.attributesOfItem(atPath: socketDirectory)
    guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
          (attributes[.type] as? FileAttributeType) == .typeDirectory else {
        throw NSError(domain: "Spotify", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid player socket directory."])
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
    writeMessage(["command": command, "build": Build.identifier], to: fd)
    return readMessage(fd)
}

func currentExecutable() -> URL {
    URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
}

private func workflowRoot() -> URL {
    if Bundle.main.bundleURL.pathExtension == "app" {
        return Bundle.main.bundleURL.deletingLastPathComponent()
    }
    return currentExecutable().deletingLastPathComponent()
}

private func launchServer(_ arguments: [String] = ["--serve"]) throws {
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
            throw NSError(domain: "Spotify", code: 2, userInfo: [NSLocalizedDescriptionKey: "The player is already running."])
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
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyAction?(event) == true { return true }
        if performEditingKey(event, responder: firstResponder) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { dismissAction?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SearchField: NSTextField {
    var keyAction: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyAction?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
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
    let words: [Substring]
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
        var groups = Array(repeating: [MusicItem](), count: 5)
        for item in items { groups[item.priority].append(item) }
        return groups.flatMap { $0 }
    }
    init(_ value: [String: Any]) {
        payload = value["item"] as? [String: Any] ?? [:]
        name = value["name"] as? String ?? ""
        uri = value["uri"] as? String ?? ""
        kind = value["kind"] as? String ?? ""
        detail = value["detail"] as? String ?? ""
        art = value["art"] as? String ?? ""
        symbol = value["symbol"] as? String ?? "music.note"
        words = Self.normalize(value["match"] as? String ?? name).split(whereSeparator: { $0.isWhitespace })
    }
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    func matches(_ terms: [Substring]) -> Bool {
        terms.allSatisfy { term in words.contains { $0.hasPrefix(term) } }
    }
}


private struct MusicFilter {
    private var previousTerms: [Substring] = []
    private var results: [MusicItem] = []
    private var usesCatalog = false
    private var valid = false
    mutating func reset() { valid = false; results = []; previousTerms = [] }
    mutating func matching(_ items: [MusicItem], terms: [Substring], catalog: Bool) -> [MusicItem] {
        let narrows = valid && usesCatalog == catalog && previousTerms.count <= terms.count
            && zip(previousTerms, terms).allSatisfy { $1.hasPrefix($0) }
        let candidates = narrows ? results : items
        results = terms.isEmpty ? items : candidates.filter { $0.matches(terms) }
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
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
              pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
    context.cgContext.scaleBy(x: scale, y: scale)
    original.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.bitmapData else { return nil }
    var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide where data[y * bitmap.bytesPerRow + x * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    let crop = NSRect(x: CGFloat(minX) / scale, y: size.height - CGFloat(maxY + 1) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    let result = NSImage(size: NSSize(width: height * crop.width / crop.height, height: height), flipped: false) { rect in
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
    let image = tightImage(NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: height, weight: .regular)), height: height)
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
            arrow.curve(to: NSPoint(x: 2.8, y: 8.2), controlPoint1: NSPoint(x: 0.6, y: 7.25), controlPoint2: NSPoint(x: 1.55, y: 8.2))
            arrow.line(to: NSPoint(x: 11.1, y: 8.2))
            arrow.stroke()
            let head = NSBezierPath()
            head.move(to: NSPoint(x: 10.55, y: 10.2))
            head.line(to: NSPoint(x: 13.7, y: 8.2))
            head.line(to: NSPoint(x: 10.55, y: 6.2))
            head.close()
            head.lineWidth = 0.5
            head.lineJoinStyle = .round
            head.fill(); head.stroke()
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
        stem.curve(to: NSPoint(x: 13.25, y: 7.5), controlPoint1: NSPoint(x: 12, y: 3.75), controlPoint2: NSPoint(x: 13.25, y: 5))
        stem.curve(to: NSPoint(x: 11.5, y: 9.25), controlPoint1: NSPoint(x: 13.25, y: 8.75), controlPoint2: NSPoint(x: 12.75, y: 9.25))
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

private let spotifyGreen = NSColor(srgbRed: 0x1e / 255, green: 0xd7 / 255, blue: 0x60 / 255, alpha: 1)

// NSButton's bezel metrics differ between symbols. Draw the visible glyph at
// the exact centre, retaining native target/action and keyboard accessibility.
private final class IconButton: NSButton {
    // Custom image and path drawing uses AppKit's bottom-up coordinates.
    override var isFlipped: Bool { false }
    var playbackHighlight = false
    var isPending = false { didSet { needsDisplay = true } }
    var currentTint: NSColor { isPending || playbackHighlight && cell?.isHighlighted == true ? spotifyGreen : contentTintColor ?? .secondaryLabelColor }
    private var drawingOpacity: CGFloat { isEnabled || isPending ? 1 : 0.35 }
    var showsSavedCheck = false { didSet { needsDisplay = true } }
    var showsActiveCircle = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let image = image else { return }
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if showsSavedCheck || showsActiveCircle {
            let green = cell?.isHighlighted == true ? spotifyGreen.blended(withFraction: 0.16, of: .black)! : spotifyGreen
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
        let rect = NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                          width: image.size.width, height: image.size.height)
        var imageRect = rect
        if let context = NSGraphicsContext.current?.cgContext,
           let mask = image.cgImage(forProposedRect: &imageRect, context: NSGraphicsContext.current, hints: nil) {
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
    private func center(_ label: NSTextField, x: CGFloat, width: CGFloat, glyphCentered: Bool = false) {
        label.setFrameSize(NSSize(width: width, height: ceil(label.intrinsicContentSize.height)))
        let glyph = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(label.attributedStringValue), .useGlyphPathBounds)
        let middle = glyphCentered && !label.stringValue.isEmpty ? glyph.midY : (label.font?.capHeight ?? 0) / 2
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
        NSBezierPath(roundedRect: bounds, xRadius: playerTheme.resultRadius, yRadius: playerTheme.resultRadius).fill()
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

private final class ConnectButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let fill = cell?.isHighlighted == true ? playerTheme.selection.withAlphaComponent(0.7) : playerTheme.selection
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: playerTheme.font(playerTheme.resultFont, size: 11), .foregroundColor: playerTheme.selectedText]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

private final class SpotifyCommands {
    private let queue = DispatchQueue(label: "spotify.status", qos: .utility)
    private let playbackQueue = DispatchQueue(label: "spotify.playback", qos: .userInteractive)
    private var script: NSAppleScript?
    private var polling = false
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
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
                                          returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
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
            let message = code == -1743
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
    static func playbackEvent(_ command: String, uri: String, context: String) -> NSAppleEventDescriptor? {
        let codes: [String: AEEventID] = ["play": 0x50437478, "toggle": 0x506c5073, "next": 0x4e657874, "previous": 0x50726576]
        guard let code = codes[command] else { return nil }
        let event = NSAppleEventDescriptor(eventClass: 0x73706679, eventID: code,
            targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.spotify.client"),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if command == "play" {
            event.setParam(NSAppleEventDescriptor(string: uri), forKeyword: AEKeyword(keyDirectObject))
            if !context.isEmpty { event.setParam(NSAppleEventDescriptor(string: context), forKeyword: 0x636f7478) }
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
            do { _ = try event.sendEvent(options: Self.playbackOptions, timeout: 5) }
            catch {
                let code = (error as NSError).code
                let message = code == -1743
                    ? "Allow Spotify Mini Player to control Spotify in System Settings → Privacy & Security → Automation."
                    : "Spotify could not play this selection. Try again."
                DispatchQueue.main.async { self.failed?(message) }
            }
        }
    }
    func play(_ command: String, uri: String = "", context: String = "") {
        guard ["toggle", "shuffle-on", "shuffle-off", "next", "previous", "play"].contains(command) else { return }
        if command == "play" {
            guard validURI(uri), context.isEmpty || validURI(context) else { return }
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty {
            perform(command, uri: uri, context: context)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            NSWorkspace.shared.openApplication(at: url, configuration: Self.backgroundLaunchConfiguration()) { app, error in
                guard app != nil, error == nil else {
                    DispatchQueue.main.async { self.failed?("Could not start Spotify. Open the desktop app and try again.") }; return
                }
                self.perform(command, uri: uri, context: context)
            }
        } else { failed?("Install the Spotify desktop app to play music.") }
    }
    func setShuffle(_ enabled: Bool) { play(enabled ? "shuffle-on" : "shuffle-off") }
    func currentTrack(_ completion: @escaping (String?) -> Void) {
        queue.async {
            let result = self.call("snapshot", arguments: [])
            let uri = (result?.numberOfItems ?? 0) >= 6 ? result?.atIndex(6)?.stringValue : nil
            DispatchQueue.main.async { completion(uri) }
        }
    }
    func poll() {
        guard !polling else { return }
        polling = true
        queue.async {
            let result = self.call("snapshot", arguments: [])
            let values = result.map { value in (1...max(1, value.numberOfItems)).compactMap { value.atIndex($0)?.stringValue } } ?? []
            DispatchQueue.main.async {
                self.polling = false
                if result != nil { self.status?(values) }
            }
        }
    }
}

private final class PlayerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let testMode: Bool
    private let themes = ThemeSource()
    private var themeContext: [String: String] = [:]
    private var themeSignature = ""
    private let server = IPCServer()
    private var backend = NativeBackend(workflowRoot())
    private let spotify = SpotifyCommands()
    private let panel = PlayerPanel(contentRect: NSRect(x: 0, y: 0, width: 584, height: 470), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let search = SearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let preview = NSImageView()
    private let previewTitle = NSTextField(labelWithString: "")
    private let previewDetail = NSTextField(wrappingLabelWithString: "")
    private let nowArt = NSImageView()
    private let nowTitle = NSTextField(labelWithString: "No track currently selected")
    private let nowDetail = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "Loading your Spotify library…")
    private let toggle = IconButton()
    private let like = IconButton()
    private let shuffle = IconButton()
    private let repeatButton = IconButton()
    private var currentTrackURI = ""
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
    private var lastResignedKey = Date.distantPast
    private var hotkeyHandoffAllowed = false
    private var screenshotMode = false
    private var lastLikedCheck = Date.distantPast
    private let connect = ConnectButton(title: "Connect", target: nil, action: nil)
    private var searchFilter = MusicFilter()
    private var liveSearchFilter = MusicFilter()
    private var source: [MusicItem] = [] { didSet { searchFilter.reset() } }
    private var home: [MusicItem] = []
    private var catalog: [MusicItem] = [] { didSet { searchFilter.reset(); liveSearchFilter.reset() } }
    private let catalogQueue = DispatchQueue(label: "spotify.catalog", qos: .userInitiated)
    private var catalogRevision = 0
    private var filtered: [MusicItem] = []
    private var breadcrumb = ""
    private var routeKind = "home"
    private var catalogSearchWork: DispatchWorkItem?
    private var catalogPending = false { didSet { if oldValue != catalogPending { updateSearchStatus() } } }
    private var searchStatusWork: DispatchWorkItem?
    private var searchStatusVisible = false
    private var searchStatusShownAt = Date.distantPast
    private var statusMessage = ""
    private var pendingHomeQuery: String?
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
    private var inlineError: String?
    private var statusTimer: Timer?
    private var lifeTimer: Timer?
    private var initialFiles: [String: Date] = [:]
    private var alfredPID: pid_t = 0
    private var optimisticUntil = Date.distantPast
    private var currentImageURL = ""
    private var currentArtPath = ""
    private let imageCache = NSCache<NSString, NSImage>()
    private var loadingImages: Set<String> = []
    private var artworkTestPaths: [String] = []
    private let imageQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "spotify.artwork"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var imagesRequested: Set<String> = []

    init(testMode: Bool = false) {
        self.testMode = testMode
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildPanel()
        installEditingMenu()
        backend.receive = { [weak self] value in self?.receive(value) }
        spotify.failed = { [weak self] message in self?.showError(message) }
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
            alfredPID = NSRunningApplication.runningApplications(withBundleIdentifier: applicationID).first?.processIdentifier ?? 0
            spotify.warm()
            recordFiles()
            lifeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.checkLifetime() }
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
        if let index = CommandLine.arguments.firstIndex(of: "--lifetime-pid"), CommandLine.arguments.count > index + 1 {
            lifeTimer?.invalidate()
            alfredPID = Int32(CommandLine.arguments[index + 1]) ?? 0
            recordFiles()
            lifeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkLifetime() }
        }
        if CommandLine.arguments.contains("--present") { show() }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
            demo()
            nowTitle.stringValue = "Current song"
            nowDetail.stringValue = "Artist · Album"
            nowArt.image = NSImage(contentsOf: workflowRoot().appendingPathComponent("icons/spotify.png"))
            setCurrentTrack("spotify:track:" + String(repeating: "a", count: 22))
            playing = true; updateToggle()
            likedTracks[currentTrackURI] = true; updateLike()
            shuffling = true; updateShuffle()
            repeatMode = .track; updateRepeat()
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
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .readOnly
        panel.isMovableByWindowBackground = true
        panel.title = "Spotify Mini Player"
        let root = ThemeBackground(frame: NSRect(x: 0, y: 0, width: 584, height: 470))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = root
        nowArt.frame = NSRect(x: 20, y: 369, width: 82, height: 82)
        nowArt.imageScaling = .scaleProportionallyUpOrDown
        nowArt.image = symbol("music.note", height: 64)
        nowArt.contentTintColor = .tertiaryLabelColor
        nowTitle.frame = NSRect(x: 120, y: 409, width: 254, height: 30)
        nowTitle.font = .systemFont(ofSize: 22, weight: .medium)
        nowDetail.frame = NSRect(x: 120, y: 382, width: 254, height: 24)
        nowDetail.font = .systemFont(ofSize: 15)
        nowDetail.textColor = .secondaryLabelColor
        for label in [nowTitle, nowDetail] { label.lineBreakMode = .byTruncatingTail }
        root.addSubview(nowArt); root.addSubview(nowTitle); root.addSubview(nowDetail)
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
            button.frame = NSRect(x: 460 + index * 28, y: Int(nowArt.frame.midY) - 14, width: 28, height: 28)
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
        search.frame = NSRect(x: 14, y: 314, width: 556, height: 41)
        search.font = .systemFont(ofSize: 28)
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.isEnabled = false
        search.delegate = self
        search.target = self
        search.action = #selector(activateSelection)
        search.keyAction = { [weak self] event in self?.key(event) ?? false }
        root.addSubview(search)
        scroll.frame = NSRect(x: 12, y: 35, width: 320, height: 276)
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
        root.addSubview(preview); root.addSubview(previewTitle); root.addSubview(previewDetail)
        status.frame = NSRect(x: 12, y: 10, width: 420, height: 16)
        status.font = .systemFont(ofSize: 10)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        root.addSubview(status)
        connect.frame = NSRect(x: 443, y: 7, width: 66, height: 22)
        connect.target = self; connect.action = #selector(connectSpotify)
        connect.bezelStyle = .rounded
        connect.font = .systemFont(ofSize: 11)
        connect.isHidden = true
        root.addSubview(connect)
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
        editor.insertionPointColor = playerTheme.searchText
        editor.textColor = playerTheme.searchText
        editor.selectedTextAttributes = [.foregroundColor: playerTheme.searchSelectedText, .backgroundColor: playerTheme.searchSelection]
    }
    private func applyTheme(_ theme: PlayerTheme) {
        playerTheme = theme
        (panel.contentView as? ThemeBackground)?.apply(theme)
        nowTitle.font = theme.font(theme.resultFont, size: 22, weight: .medium)
        nowDetail.font = theme.font(theme.secondaryFont, size: 15)
        previewTitle.font = theme.font(theme.resultFont, size: 13)
        previewDetail.font = theme.font(theme.secondaryFont, size: 11)
        status.font = theme.font(theme.secondaryFont, size: 10)
        search.font = theme.font(theme.searchFont, size: 28)
        search.textColor = theme.searchText
        search.drawsBackground = theme.searchBackground.alphaComponent > 0
        search.backgroundColor = theme.searchBackground
        search.wantsLayer = true
        search.layer?.cornerRadius = theme.searchRadius
        search.layer?.masksToBounds = true
        nowTitle.textColor = theme.text
        nowDetail.textColor = theme.secondary
        nowArt.contentTintColor = theme.secondary
        previewTitle.textColor = theme.text
        previewDetail.textColor = theme.secondary
        preview.contentTintColor = theme.secondary
        for button in playbackButtons { button.contentTintColor = theme.control; button.needsDisplay = true }
        updateLike(); updateShuffle(); updateRepeat(); renderStatus()
        table.enumerateAvailableRowViews { row, index in
            row.needsDisplay = true
            if self.filtered.indices.contains(index) {
                (self.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? MusicCell)?.display(self.filtered[index], index: index, selected: index == self.table.selectedRow)
            }
        }
        scroll.verticalScroller?.needsDisplay = true
        connect.needsDisplay = true
        styleEditor()
    }

    private func symbol(_ name: String, height: CGFloat) -> NSImage? {
        systemImage(name, height: height)
    }
    private func configureButton(_ button: NSButton, image: String, height: CGFloat, action: Selector) {
        button.image = symbol(image, height: height)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = self; button.action = action
        button.contentTintColor = .black
    }
    private func playerButton(_ image: String, height: CGFloat, action: Selector) -> NSButton {
        let button = IconButton()
        configureButton(button, image: image, height: height, action: action)
        return button
    }
    private func send(_ command: String, args: [String] = []) {
        if !["preview", "liked", "image"].contains(command) { inlineError = nil; renderStatus() }
        backend.send(["command": command, "args": args])
    }
    private func receive(_ value: [String: Any]) {
        let type = value["type"] as? String ?? ""
        if value["route_kind"] as? String == "catalog", routeKind == "catalog",
           let query = value["query"] as? String, value["command"] as? String != "back",
           query != String(search.stringValue.dropFirst()) { return }
        if type == "error" {
            if routeKind == "catalog" { catalogPending = false; filter() }
            showError(value["message"] as? String ?? "Could not complete the request.")
            return
        }
        if type == "repeat" {
            guard connection == "connected", let mode = RepeatMode(rawValue: value["mode"] as? String ?? "") else { return }
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
            catalogRevision += 1
            let revision = catalogRevision, rows = value["rows"] as? [[String: Any]] ?? []
            catalogQueue.async { [weak self] in
                let prepared = MusicItem.prioritized(rows.map(MusicItem.init))
                DispatchQueue.main.async {
                    guard let self = self, revision == self.catalogRevision else { return }
                    self.catalog = prepared
                    if self.breadcrumb.isEmpty && !self.search.stringValue.isEmpty { self.filter() }
                }
            }
            return
        }
        if type == "artwork" {
            let url = value["url"] as? String ?? ""
            let path = value["path"] as? String ?? ""
            if url == currentImageURL, !path.isEmpty { setNowArt(path) }
            return
        }
        let nextConnection = value["connection"] as? String ?? connection
        let signedIn = connection == "connecting" && nextConnection == "connected"
        if nextConnection != connection {
            inlineError = nil
            if nextConnection != "connected" {
                catalogRevision += 1; catalog = []
                repeatRequest += 1; repeatSessionStart = repeatRequest
                repeatPending = false; repeatMode = .off; confirmedRepeatMode = .off
            }
        }
        connection = nextConnection
        if value["close_player"] as? Bool == true { hide() }
        if let message = value["message"] as? String { statusMessage = message }
        renderStatus()
        connect.isHidden = connection == "connected" || connection == "loading"
        search.isEnabled = connection == "connected"
        for button in playbackButtons { button.isEnabled = connection == "connected" }
        shuffle.isEnabled = connection == "connected"
        updateLike()
        updateRepeat()
        if let rows = value["rows"] as? [[String: Any]] {
            if let kind = value["route_kind"] as? String { routeKind = kind }
            if routeKind == "catalog" { catalogPending = value["searching"] as? Bool == true }
            else { catalogSearchWork?.cancel(); catalogPending = false; updateSearchStatus() }
            source = routeKind == "catalog" && catalogPending
                ? localCatalogResults(value["query"] as? String ?? "") : rows.map(MusicItem.init)
            if value["route_kind"] as? String == "catalog" { source = MusicItem.prioritized(source) }
            breadcrumb = value["prefix"] as? String ?? ""
            if breadcrumb.isEmpty { home = source }
            if let text = value["search_text"] as? String {
                search.stringValue = pendingHomeQuery ?? text
                pendingHomeQuery = nil
            }
            filter()
            if value["search_text"] != nil && routeKind == "catalog" { placeSearchCaretAtEnd() }
        }
        let variables = value["variables"] as? [String: Any] ?? [:]
        let responseURI = value["selected"] as? String ?? ""
        var loaded: NSImage?
        if let art = variables["preview_art"] as? [String: Any], let path = art["src"] as? String, !path.isEmpty {
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
            } else if value["preview_complete"] as? Bool == true && previewPaths[responseURI] == nil,
                      let item = selectedItem(), item.art.isEmpty, previewIsCover {
                setPreviewImage(symbol(item.symbol, height: 150))
                previewIsCover = false
            }
        }
        if (value["command"] as? String) == "configure" { hide() }
        if signedIn {
            if !testMode { NSApp.activate(ignoringOtherApps: true) }
            show()
        }
    }

    private func image(_ path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        if let image = imageCache.object(forKey: path as NSString) { return image }
        guard loadingImages.insert(path).inserted else { return nil }
        imageQueue.addOperation { [weak self] in
            let decoded = loadArtwork(path)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loadingImages.remove(path)
                guard let decoded = decoded else { return }
                self.imageCache.setObject(decoded, forKey: path as NSString,
                    cost: max(1, Int(decoded.size.width * decoded.size.height * 4)))
                if self.currentArtPath == path { self.nowArt.image = decoded }
                if let item = self.selectedItem(), self.previewURI == item.uri,
                   (self.previewPaths[item.uri] ?? item.art) == path {
                    self.setPreviewImage(decoded)
                    self.previewIsCover = true
                }
            }
        }
        return nil
    }
    private func setNowArt(_ path: String) {
        currentArtPath = path
        if let cached = image(path) { nowArt.image = cached }
        else if path.isEmpty { nowArt.image = symbol("music.note", height: 64) }
    }
    private func filter() {
        let selection = selectedItem()?.uri
        let text = search.stringValue
        let query = text.hasPrefix(breadcrumb) ? String(text.dropFirst(breadcrumb.count)) : text
        let terms = routeKind == "catalog" ? [] : MusicItem.normalize(query).split(whereSeparator: { $0.isWhitespace })
        let usesCatalog = routeKind != "catalog" && breadcrumb.isEmpty && !terms.isEmpty && connection == "connected"
        let available = usesCatalog ? catalog : source
        filtered = searchFilter.matching(available, terms: terms, catalog: usesCatalog)
        suppressSelection = true
        table.reloadData()
        if !filtered.isEmpty {
            let index = selection.flatMap { uri in filtered.firstIndex { $0.uri == uri } } ?? 0
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        suppressSelection = false
        previewSelection(debounce: true)
    }
    private func selectedItem() -> MusicItem? {
        let index = table.selectedRow
        return filtered.indices.contains(index) ? filtered[index] : nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("musicCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? MusicCell) ?? MusicCell()
        cell.identifier = id
        cell.display(filtered[row], index: row, selected: tableView.selectedRow == row)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        for row in table.rows(in: table.visibleRect).location..<NSMaxRange(table.rows(in: table.visibleRect)) where filtered.indices.contains(row) {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? MusicCell)?.display(filtered[row], index: row, selected: table.selectedRow == row)
        }
        previewSelection()
    }
    private func setPreviewImage(_ image: NSImage?) {
        guard preview.image !== image else { return }
        preview.image = image
        previewImageChanges += 1
    }
    private func previewSelection(debounce: Bool = false) {
        previewWork?.cancel()
        previewWork = nil
        guard let item = selectedItem() else {
            if routeKind == "catalog" && catalogPending { return }
            let clear = DispatchWorkItem { [weak self] in
                guard let self = self, self.selectedItem() == nil else { return }
                self.previewURI = ""
                self.previewTitle.stringValue = ""
                let emptyQuery = self.routeKind == "catalog" && String(self.search.stringValue.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        guard selectedItem()?.uri == item.uri else { return }
        previewURI = item.uri
        previewTitle.stringValue = item.name
        previewDetail.stringValue = item.detail
        previewDetail.textColor = playerTheme.secondary
        if let cover = image(previewPaths[item.uri] ?? item.art) {
            setPreviewImage(cover)
            previewIsCover = true
        } else if preview.image == nil {
            setPreviewImage(symbol(item.symbol, height: 150))
            previewIsCover = false
        }
        if !testMode, let data = try? JSONSerialization.data(withJSONObject: item.payload),
           let text = String(data: data, encoding: .utf8) {
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
    private func placeSearchCaretAtEnd() {
        panel.makeFirstResponder(search)
        search.selectText(nil)
        if let editor = search.currentEditor() as? NSTextView {
            styleEditor()
            let end = (search.stringValue as NSString).length
            editor.setSelectedRange(NSRange(location: end, length: 0))
        }
    }
    private func enterCatalog(_ query: String) {
        catalogSearchWork?.cancel()
        pendingHomeQuery = nil
        routeKind = "catalog"
        breadcrumb = "/"
        search.stringValue = "/" + query
        source = localCatalogResults(query)
        catalogPending = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        filter()
        send("catalog", args: [query])
        placeSearchCaretAtEnd()
    }
    private func updateCatalogQuery() {
        catalogSearchWork?.cancel()
        let query = String(search.stringValue.dropFirst())
        source = localCatalogResults(query)
        catalogPending = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        statusMessage = ""
        renderStatus()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.routeKind == "catalog", self.search.stringValue == "/" + query else { return }
            self.send("catalog-query", args: [query])
        }
        catalogSearchWork = work
        if catalogPending { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work) }
        else { work.perform() }
    }
    func controlTextDidChange(_ obj: Notification) {
        if routeKind == "catalog" && search.stringValue.hasPrefix("/") {
            updateCatalogQuery()
        } else if !breadcrumb.isEmpty && !search.stringValue.hasPrefix(breadcrumb) {
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
        filter()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.command, .control, .option, .shift]) ?? []
        if modifiers.isEmpty && commandSelector == #selector(NSResponder.moveDown(_:)) { move(1); return true }
        if modifiers.isEmpty && commandSelector == #selector(NSResponder.moveUp(_:)) { move(-1); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { hide(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { activateSelection(); return true }
        if commandSelector == #selector(NSResponder.deleteBackward(_:)), !breadcrumb.isEmpty, search.stringValue == breadcrumb {
            send("back", args: [breadcrumb]); return true
        }
        return false
    }
    private func key(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers ?? ""
        if modifiers == .command {
            if let number = Int(key), number >= 1, number <= 9 {
                let index = number - 1
                if filtered.indices.contains(index) {
                    table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                    activateSelection()
                }
                return true
            }
            if key == "w" { hide(); return true }
            if key == "," { openSettings(); return true }
            if key == "r" { send("refresh"); return true }
            if key == "[" { send("back", args: [search.stringValue]); return true }
            if event.keyCode == 36 {
                let value = search.stringValue
                enterCatalog(value.hasPrefix(breadcrumb) ? String(value.dropFirst(breadcrumb.count)) : value)
                return true
            }
        }
        if modifiers == [.command, .control] {
            if event.keyCode == 125 { togglePlayback(); return true }
            if event.keyCode == 124 { nextTrack(); return true }
            if event.keyCode == 123 { previousTrack(); return true }
        }
        if modifiers.isEmpty && event.keyCode == 53 { hide(); return true }
        return false
    }
    private func move(_ offset: Int) {
        guard !filtered.isEmpty else { return }
        let index = min(filtered.count - 1, max(0, table.selectedRow + offset))
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }
    @objc private func activateSelection() {
        guard let item = selectedItem() else { return }
        let action = item.payload["action"] as? String ?? ""
        if action == "catalog" { enterCatalog(""); return }
        if item.kind == "track" || action == "play" || action == "open" {
            if item.payload["is_local"] as? Bool == true || item.payload["is_playable"] as? Bool == false {
                showError("This track cannot be played through Spotify’s catalog."); return
            }
            let uri = item.payload["play_uri"] as? String ?? item.uri
            if !testMode { spotify.play("play", uri: uri, context: item.payload["context"] as? String ?? "") }
            playing = true
            optimisticUntil = Date().addingTimeInterval(1)
            updateToggle()
            if item.kind == "track" {
                setCurrentTrack(uri)
                nowTitle.stringValue = item.name
                nowDetail.stringValue = item.detail
                setNowArt(previewPaths[item.uri] ?? item.art)
            }
        } else if let data = try? JSONSerialization.data(withJSONObject: item.payload), let text = String(data: data, encoding: .utf8) {
            send("activate", args: [text])
        }
    }
    @objc private func togglePlayback() {
        guard connection == "connected" else { return }
        playing.toggle(); optimisticUntil = Date().addingTimeInterval(1); updateToggle()
        if !testMode { spotify.play("toggle") }
    }
    @objc private func previousTrack() { if connection == "connected" && !testMode { spotify.play("previous") } }
    @objc private func nextTrack() { if connection == "connected" && !testMode { spotify.play("next") } }
    @objc private func toggleLiked() {
        guard like.isEnabled else { return }
        requestLiked(likedTracks[currentTrackURI] != true)
    }
    private func requestLiked(_ desired: Bool) {
        guard validTrack(currentTrackURI) else { return }
        pendingLikes[currentTrackURI] = desired
        updateLike()
        if !testMode { send(desired ? "save" : "unsave", args: [currentTrackURI]) }
    }
    private func setCurrentTrack(_ uri: String, refresh: Bool = true) {
        guard currentTrackURI != uri else { return }
        currentTrackURI = uri
        currentImageURL = ""
        currentArtPath = ""
        updateLike()
        if refresh { refreshCurrentLike() }
    }
    private func refreshCurrentLike() {
        lastLikedCheck = Date()
        if !testMode, currentTrackURI.range(of: #"^spotify:track:[A-Za-z0-9]{22}$"#, options: .regularExpression) != nil {
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
        like.isEnabled = connection == "connected" && currentTrackURI.range(of: #"^spotify:track:[A-Za-z0-9]{22}$"#, options: .regularExpression) != nil && pendingLikes[currentTrackURI] == nil
        like.toolTip = pendingLikes[currentTrackURI].map { $0 ? "Saving to Liked Songs…" : "Removing from Liked Songs…" } ?? (saved ? "Remove from Liked Songs" : "Save to Liked Songs")
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
        repeatButton.image = repeatMode == .track ? symbol("repeat.1", height: 10) : repeatAllImage(height: 10)
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
        if !testMode { send("repeat-state", args: [String(repeatRequest)]) }
    }
    private func performExternal(_ command: String) {
        if command == "shuffle" || command == "sequential" {
            setShuffle(command == "shuffle")
            return
        }
        let desired = command == "like"
        if testMode {
            if !validTrack(currentTrackURI) { setCurrentTrack("spotify:track:" + String(repeating: "a", count: 22), refresh: false) }
            likedTracks[currentTrackURI] = desired
            updateLike()
            return
        }
        spotify.currentTrack { [weak self] uri in
            guard let self = self else { return }
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
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            showError("Install the Spotify desktop app to open Spotify.")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            if let error = error { DispatchQueue.main.async { self?.showError(error.localizedDescription) } }
        }
    }
    private func showForHotkey(focused: Bool? = nil) {
        // Alfred may briefly take focus while dispatching its Hotkey action.
        let recentlyFocused = Date().timeIntervalSince(lastResignedKey) < 0.5
        if hotkeyHandoffAllowed && (focused ?? (panel.isKeyWindow || recentlyFocused)) { openSpotify() }
        else { show() }
    }
    @objc private func connectSpotify() { send("connect") }
    @objc private func openSettings() { send("configure") }
    private func updateToggle() {
        toggle.image = symbol(playing ? "pause.fill" : "play.fill", height: 18)
        guard let previous = playbackButtons.first, let next = playbackButtons.last else { return }
        let leftEdge = previous.frame.midX + (previous.image?.size.width ?? 0) / 2
        let rightEdge = next.frame.midX - (next.image?.size.width ?? 0) / 2
        toggle.setFrameOrigin(NSPoint(x: (leftEdge + rightEdge - toggle.frame.width) / 2, y: toggle.frame.minY))
    }
    private func updatePlayback(_ values: [String]) {
        guard Date() >= optimisticUntil else { return }
        playing = values.first == "playing"
        updateToggle()
        if values.count >= 7 { shuffling = values[6] == "true"; updateShuffle() }
        guard values.count >= 6 else { setCurrentTrack(""); return }
        setCurrentTrack(values[5])
        nowTitle.stringValue = values[1]
        nowDetail.stringValue = [values[2], values[3]].filter { !$0.isEmpty }.joined(separator: " · ")
        currentImageURL = values[4]
        if let item = catalog.first(where: { $0.uri == values[5] }), !item.art.isEmpty {
            setNowArt(item.art)
        } else if !values[4].isEmpty, !imagesRequested.contains(values[4]) {
            imagesRequested.insert(values[4]); send("image", args: [values[4]])
        }
    }
    private func renderStatus() {
        let message = inlineError ?? (routeKind == "catalog" && searchStatusVisible ? "Searching Spotify…" : statusMessage)
        if status.stringValue != message { status.stringValue = message }
        status.toolTip = message
        status.textColor = inlineError == nil && connection != "failed" ? playerTheme.secondary : .systemRed
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
        renderStatus()
    }
    private func show() {
        refreshTheme()
        hotkeyHandoffAllowed = true
        showCount += 1
        if testMode { wasShown = true; return }
        if !panel.isVisible {
            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2 + 50))
            }
            panel.makeKeyAndOrderFront(nil)
        }
        panel.makeFirstResponder(search.isEnabled ? search : connect)
        styleEditor()
        wasShown = true
        if backend.pid == 0 {
            backend = NativeBackend(workflowRoot())
            backend.receive = { [weak self] value in self?.receive(value) }
            do { try backend.start() } catch { showError(error.localizedDescription) }
        }
        send("show")
        if connection == "connected" { spotify.poll(); refreshCurrentLike(); refreshRepeat() }
    }
    private func setScreenshotMode(_ enabled: Bool) {
        screenshotMode = enabled
        panel.level = enabled ? .normal : .floating
        panel.collectionBehavior = enabled
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .managed]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
    private func toggleScreenshotMode() {
        setScreenshotMode(!screenshotMode)
        if screenshotMode && !testMode { NSApp.activate(ignoringOtherApps: true) }
        show()
    }
    private func hide() {
        hotkeyHandoffAllowed = false
        lastResignedKey = .distantPast
        setScreenshotMode(false)
        if let sheet = panel.attachedSheet { panel.endSheet(sheet) }
        panel.orderOut(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func windowDidResignKey(_ notification: Notification) {
        guard !screenshotMode else { return }
        guard hotkeyHandoffAllowed else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == applicationID else { hide(); return }
        lastResignedKey = Date()
        panel.orderOut(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private func handleIPC(_ value: [String: Any]) -> [String: Any] {
        if value["build"] as? String != Build.identifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { NSApp.terminate(nil) }
            return ["status": "restart"]
        }
        if let theme = value["theme"] as? [String: String] { themeContext = theme }
        if testMode && value["command"] as? String == "test-screenshot-mode" { return screenshotModeChecks() }
        if testMode && value["command"] as? String == "test-theme" { return themeChecks() }
        if testMode && value["command"] as? String == "test-controls" { return controlChecks() }
        if testMode && value["command"] as? String == "test-repeat" { return repeatChecks() }
        if testMode && value["command"] as? String == "test-search" { return searchChecks() }
        if testMode && value["command"] as? String == "test-catalog-mode" { return catalogModeChecks() }
        if testMode && value["command"] as? String == "test-search-result" {
            let complete = catalog.map { $0.uri } == ["latest"]
            return ["status": complete ? "ok" : "pending", "latest_catalog_applied": complete]
        }
        if testMode && value["command"] as? String == "test-artwork" { return artworkChecks() }
        if testMode && value["command"] as? String == "test-artwork-result" { return artworkCheckResult() }
        if testMode && value["command"] as? String == "test-editing" {
            return editingChecks()
        }
        if testMode && value["command"] as? String == "test-ui" {
            return previewChecks()
        }
        if testMode && value["command"] as? String == "benchmark" {
            let items = (0..<10000).map { MusicItem(["name": "Song \($0)", "match": "Song \($0) Some Artist"]) }
            let terms = MusicItem.normalize("song 12").split(separator: " ")
            let start = DispatchTime.now().uptimeNanoseconds
            let matches = items.filter { $0.matches(terms) }
            return ["status": "ok", "rows": items.count, "matches": matches.count,
                    "filter_ms": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000]
        }
        let start = DispatchTime.now().uptimeNanoseconds
        if let command = value["command"] as? String, ["like", "unlike", "shuffle", "sequential"].contains(command) { performExternal(command) }
        if value["command"] as? String == "reset" { backend.send(["command": "reset"]) }
        if value["command"] as? String == "hotkey" { showForHotkey() }
        if value["command"] as? String == "screenshot" { toggleScreenshotMode() }
        if value["command"] as? String == "show" { show() }
        if value["command"] as? String == "hide" { hide() }
        return ["status": "ok", "pid": getpid(), "backend_pid": backend.pid, "build": Build.identifier,
                "panel": String(describing: ObjectIdentifier(panel)), "shows": showCount,
                "visible": panel.isVisible, "shown_before": wasShown, "connection": connection, "rows": source.count,
                "liked": likedTracks[currentTrackURI] ?? false, "shuffling": shuffling, "screenshot_mode": screenshotMode,
                "theme": themeContext, "dispatch_ms": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000]
    }
    private func recordFiles() {
        for url in [currentExecutable(), workflowRoot().appendingPathComponent("info.plist")] {
            initialFiles[url.path] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
    }
    private func checkLifetime() {
        if alfredPID == 0 || kill(alfredPID, 0) != 0 { NSApp.terminate(nil); return }
        for (path, date) in initialFiles {
            let current = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
        lifeTimer?.invalidate(); statusTimer?.invalidate()
        server.close(); backend.stop()
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
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                               timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                               characters: character, charactersIgnoringModifiers: character,
                                               isARepeat: false, keyCode: 0) else { return false }
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
        let editSelectors = Set((editingMenu?.items ?? []).compactMap { $0.action.map(NSStringFromSelector) })
        return ["status": "ok", "select_all": selectedAll, "undo": undoWorks, "redo": redoWorks,
                "word_movement": wordMovement,
                "clipboard_bindings": ["copy:", "cut:", "paste:", "pasteAsPlainText:"].allSatisfy { editSelectors.contains($0) }]
    }
    private func inkCenterError(_ view: NSView) -> CGFloat {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2),
                pixelsHigh: Int(view.bounds.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return .infinity }
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        var top = bitmap.pixelsHigh, bottom = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                top = min(top, y); bottom = max(bottom, y)
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
        let titleOffset = abs(cell.title.frame.minY + cell.title.baselineOffsetFromBottom + (cell.title.font?.capHeight ?? 0) / 2 - cell.bounds.midY)
        let commandGlyph = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(cell.shortcut.attributedStringValue), .useGlyphPathBounds)
        let commandOffset = abs(cell.shortcut.frame.minY + cell.shortcut.baselineOffsetFromBottom + commandGlyph.midY - cell.bounds.midY)
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
        let inputClose = search.frame.minY - rowRect.maxY >= 0 && search.frame.minY - rowRect.maxY <= 5
        let compactInsets = table.effectiveStyle == .plain && cell.artwork.frame.minX <= 6 && cell.bounds.maxX - cell.shortcutNumber.frame.maxX <= 7
        let mixed = ["track", "artist", "album", "playlist"].map { MusicItem(["kind": $0]) }
        let sorted = MusicItem.prioritized(mixed).map { $0.kind } == ["playlist", "album", "artist", "track"]
        let coverA = NSImage(size: NSSize(width: 32, height: 32))
        let coverB = NSImage(size: NSSize(width: 32, height: 32))
        imageCache.setObject(coverA, forKey: "fixture-a")
        imageCache.setObject(coverB, forKey: "fixture-b")
        let itemA = MusicItem(["name": "Alpha", "uri": "track:a", "kind": "track", "match": "Alpha", "art": "fixture-a"])
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
        receive(["type": "update", "selected": "track:b", "variables": ["preview_art": ["src": "fixture-b"]]])
        let loadedChanges = previewImageChanges
        for text in ["be", "bet", "beta"] { search.stringValue = text; filter() }
        let reused = preview.image === coverB && previewImageChanges == loadedChanges
        receive(["type": "update", "selected": "track:a", "variables": ["preview_art": ["src": "fixture-a"]]])
        receive(["type": "update", "connection": "connecting", "message": "Finish connecting in your browser",
                 "sheet": ["root": ["type": "view"]]])
        showError("Connection test error")
        let inlineConnection = panel.attachedSheet == nil && status.stringValue == "Connection test error" && !connect.isHidden
        let showsBeforeSignIn = showCount
        receive(["type": "update", "connection": "connected"])
        receive(["type": "update", "connection": "connected"])
        let signInReturnsOnce = showCount == showsBeforeSignIn + 1
        return ["status": "ok", "text_center_error_pt": offsets.max() ?? 0,
                "connection_errors_inline": inlineConnection,
                "rows_align_with_cover": rowsAligned, "input_above_rows": inputClose,
                "compact_row_insets": compactInsets, "return_aligns_with_command": returnAligned,
                "search_priority": sorted, "signin_returns_once": signInReturnsOnce,
                "shortcut_digits_fit": digitsFit,
                "return_image_centered": arrowInkError <= 0.25, "return_ink_center_error_pt": arrowInkError,
                "transport_centered_on_cover": playbackButtons.allSatisfy { abs($0.frame.midY - nowArt.frame.midY) < 0.01 },
                "no_settings_button": !(panel.contentView?.subviews.contains { ($0 as? NSButton)?.action == #selector(openSettings) } ?? false),
                "same_selection_cover_stable": stable, "typing_keeps_previous_cover": held,
                "learned_cover_reused": reused, "stale_cover_ignored": preview.image === coverB,
                "no_reset_button": !(panel.contentView?.subviews.contains {
                    ($0 as? NSButton)?.title == "Reset Connection"
                } ?? false)]
    }
    private func buttonPixels(_ button: NSButton) -> (left: CGFloat, right: CGFloat, green: Int, black: Int, opacity: CGFloat) {
        let scale: CGFloat = 8
        let width = Int(button.bounds.width * scale), height = Int(button.bounds.height * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let bytes = bitmap.bitmapData else { return (0, 0, 0, 0, 0) }
        memset(bytes, 0, bitmap.bytesPerRow * height)
        bitmap.size = button.bounds.size
        button.cacheDisplay(in: button.bounds, to: bitmap)
        var left = width, right = -1, green = 0, black = 0
        var peakAlpha: CGFloat = 0
        for y in 0..<height { for x in 0..<width { peakAlpha = max(peakAlpha, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) } }
        for y in 0..<height { for x in 0..<width {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if color.alphaComponent > peakAlpha * 0.03 { left = min(left, x); right = max(right, x) }
            if color.alphaComponent > 0.2 && color.greenComponent > color.redComponent + 0.3 { green += 1 }
            if color.alphaComponent > 0.8 && max(color.redComponent, max(color.greenComponent, color.blueComponent)) < 0.1 { black += 1 }
        } }
        return (right >= left ? CGFloat(left) / scale : 0, right >= left ? CGFloat(right + 1) / scale : 0, green, black, peakAlpha)
    }
    private func tintHasNoEdgeLines() -> Bool {
        let fixture = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { _ in
            NSColor.black.setFill()
            NSRect(x: 5, y: 9, width: 13, height: 22).fill()
            return true
        }
        fixture.size = NSSize(width: 13.75, height: 15.25)
        let button = IconButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.image = fixture; button.contentTintColor = .gray
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 56, pixelsHigh: 56,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let bytes = bitmap.bitmapData else { return false }
        memset(bytes, 0, bitmap.bytesPerRow * bitmap.pixelsHigh)
        bitmap.size = button.bounds.size
        button.cacheDisplay(in: button.bounds, to: bitmap)
        var ink = 0, stray = 0
        for y in 0..<56 { for x in 0..<56 {
            if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                ink += 1
                if x >= 30 { stray += 1 }
            }
        } }
        return ink > 20 && stray == 0
    }
    private func catalogModeChecks() -> [String: Any] {
        demo()
        search.stringValue = "/literal/"
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let literalIsLocal = routeKind == "home" && !catalogPending
        search.stringValue = "initial query"
        let commandReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        _ = key(commandReturn)
        let preservesInitial = routeKind == "catalog" && search.stringValue == "/initial query"
        let entryHasNoFlash = !searchStatusVisible && status.stringValue != "Searching Spotify…"
        search.stringValue = "/changed"
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        receive(["type": "update", "command": "browse", "route_kind": "catalog", "query": "initial query", "prefix": "/", "rows": [["name": "Old result", "uri": "old-result"]]])
        let staleIgnored = source.isEmpty && search.stringValue == "/changed"
        receive(["type": "update", "command": "catalog-query", "route_kind": "catalog", "query": "changed", "searching": true, "prefix": "/", "rows": []])
        let loading = catalogPending
        revealSearchStatus()
        receive(["type": "update", "command": "preview", "variables": [:]])
        let steadyDuringPreview = status.stringValue == "Searching Spotify…"
        receive(["type": "update", "command": "browse", "route_kind": "catalog", "query": "changed", "searching": false, "prefix": "/", "rows": [["name": "Spotify ranked result", "uri": "new-result", "kind": "track"]]])
        let resultsKept = !catalogPending && filtered.first?.uri == "new-result" && search.stringValue == "/changed"
        let minimumDisplay = status.stringValue == "Searching Spotify…"
        search.stringValue = "/next"
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let steadyBetweenQueries = status.stringValue == "Searching Spotify…"
        search.stringValue = ""
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        let exits = routeKind == "home"
        demo(); search.stringValue = ""; filter()
        table.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        activateSelection()
        let menu = routeKind == "catalog" && search.stringValue == "/"
        let entryRange = (search.currentEditor() as? NSTextView)?.selectedRange()
        let caretAtEnd = entryRange == NSRange(location: 1, length: 0)
        receive(["type": "update", "command": "catalog", "route_kind": "catalog", "query": "", "prefix": "/", "search_text": "/", "rows": []])
        let replyRange = (search.currentEditor() as? NSTextView)?.selectedRange()
        let caretAfterReply = replyRange == NSRange(location: 1, length: 0)
        previewWork?.perform()
        let emptySearchPrompt = previewDetail.stringValue == "Type to search"
        search.stringValue = "/unmatched"
        filter(); previewWork?.perform()
        let noMatchesGrey = previewDetail.stringValue == "No matches" && previewDetail.textColor == .secondaryLabelColor
        demo(); search.stringValue = ""; filter()
        return ["status": "ok", "literal_slash_stays_local": literalIsLocal,
                "command_return_preserves_query": preservesInitial, "spotify_menu_enters_search": menu,
                "stale_live_search_ignored": staleIgnored, "remote_ranking_preserved": resultsKept,
                "search_loading_retains_cover": loading, "deleting_slash_exits_search": exits,
                "search_caret_after_slash": caretAtEnd && caretAfterReply,
                "search_caret_follows_theme": (search.currentEditor() as? NSTextView)?.insertionPointColor == playerTheme.searchText, "empty_search_prompt": emptySearchPrompt, "no_matches_grey": noMatchesGrey,
                "search_status_avoids_flicker": entryHasNoFlash && steadyDuringPreview && minimumDisplay && steadyBetweenQueries]
    }
    private func searchChecks() -> [String: Any] {
        let items = [
            MusicItem(["uri": "track:1", "kind": "track", "name": "Song Artist", "match": "Song Artist"]),
            MusicItem(["uri": "playlist:1", "kind": "playlist", "name": "Café Été", "match": "Café Été"]),
            MusicItem(["uri": "playlist:2", "kind": "playlist", "name": "Song Artist", "match": "Song Artist"]),
            MusicItem(["uri": "album:1", "kind": "album", "name": "Song Two", "match": "Song Two"]),
            MusicItem(["uri": "artist:1", "kind": "artist", "name": "Artist", "match": "Artist"]),
        ]
        let ordered = MusicItem.prioritized(items)
        let stable = ordered.map { $0.uri } == ["playlist:1", "playlist:2", "album:1", "artist:1", "track:1"]
        var matcher = MusicFilter(), matches = true
        for query in ["", "s", "so", "song", "song a", "song ar", "song", "a song", "c", "ca", "cafe", "café é", "é café", "z", ""] {
            let terms = MusicItem.normalize(query).split(whereSeparator: { $0.isWhitespace })
            let result = matcher.matching(ordered, terms: terms, catalog: true)
            matches = matches && result.map { $0.uri } == ordered.filter { $0.matches(terms) }.map { $0.uri }
        }
        let scoped = matcher.matching([items[0]], terms: [], catalog: false).map { $0.uri } == ["track:1"]
        matcher.reset()
        let reset = matcher.matching([items[4]], terms: [], catalog: true).map { $0.uri } == ["artist:1"]
        receive(["type": "catalog", "rows": (0..<2000).map { ["name": "Old \($0)", "uri": "old:\($0)", "kind": "track"] }])
        receive(["type": "catalog", "rows": [["name": "Latest", "uri": "latest", "kind": "playlist"]]])
        return ["status": "pending", "search_results_unchanged": matches, "category_order_stable": stable,
                "search_scope_resets": scoped && reset]
    }
    private func artworkChecks() -> [String: Any] {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spotify-artwork-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = ["first.png", "second.png"].map { directory.appendingPathComponent($0).path }
        artworkTestPaths = paths
        for (index, path) in paths.enumerated() {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
            context.setFillColor((index == 0 ? NSColor.red : NSColor.blue).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        connection = "connected"; breadcrumb = "Artwork/"; search.stringValue = breadcrumb
        source = paths.enumerated().map { MusicItem(["uri": "art:\($0.offset)", "name": "Art \($0.offset)", "art": $0.element]) }
        setCurrentTrack("spotify:track:" + String(repeating: "x", count: 22), refresh: false)
        currentImageURL = "https://old-artwork.example/image"
        filter(); previewSelection(); setNowArt(paths[0])
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        setCurrentTrack("spotify:track:" + String(repeating: "y", count: 22), refresh: false)
        previewSelection(); setNowArt(paths[1])
        receive(["type": "artwork", "url": "https://old-artwork.example/image", "path": paths[0]])
        for _ in 0..<10 { _ = image(paths[1]) }
        let coalesced = Set(paths).isSubset(of: loadingImages) && loadingImages.intersection(paths).count == 2
        return ["status": "pending", "artwork_requests_coalesced": coalesced]
    }
    private func artworkCheckResult() -> [String: Any] {
        let paths = artworkTestPaths
        guard paths.count == 2, loadingImages.intersection(paths).isEmpty else { return ["status": "pending"] }
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: paths[0]).deletingLastPathComponent()) }
        let first = imageCache.object(forKey: paths[0] as NSString), second = imageCache.object(forKey: paths[1] as NSString)
        return ["status": "ok",
                "artwork_size_bounded": first?.size == NSSize(width: 512, height: 256) && second?.size == first?.size,
                "stale_artwork_ignored": second != nil && preview.image === second && nowArt.image === second]
    }
    private func screenshotModeChecks() -> [String: Any] {
        demo()
        placeSearchCaretAtEnd()
        let previousTrack = currentTrackURI
        toggleScreenshotMode()
        let enabled = screenshotMode && hotkeyHandoffAllowed && panel.level == .normal
            && panel.collectionBehavior.contains(.managed) && !panel.collectionBehavior.contains(.transient)
        let unchangedCaret = (search.currentEditor() as? NSTextView)?.insertionPointColor == playerTheme.searchText
        windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        let keptVisible = screenshotMode && hotkeyHandoffAllowed && !panel.hidesOnDeactivate
        toggleScreenshotMode()
        let togglesOff = !screenshotMode && panel.level == .floating && panel.collectionBehavior.contains(.transient)
        toggleScreenshotMode()
        panel.cancelOperation(nil)
        return ["status": "ok", "screenshot_mode_enabled": enabled,
                "screenshot_mode_keeps_player_on_focus_loss": keptVisible,
                "screenshot_mode_preserves_content": unchangedCaret, "screenshot_mode_toggles_off": togglesOff,
                "escape_exits_screenshot_mode": !screenshotMode && !hotkeyHandoffAllowed,
                "screenshot_mode_keeps_real_track": previousTrack == currentTrackURI]
    }

    private func themeChecks() -> [String: Any] {
        let theme = PlayerTheme(["alfredtheme": [
            "window": ["color": "#17212FE6", "borderColor": "#C0D0E080", "roundness": 12, "blur": 8],
            "result": ["backgroundSelected": "#EEC847FF", "roundness": 4,
                       "text": ["color": "#EDF2F9FF", "colorSelected": "#17212FFF", "font": "Avenir"],
                       "subtext": ["color": "#90A4BDFF", "font": "Avenir"],
                       "shortcut": ["color": "#A9C7E4FF", "colorSelected": "#17212FFF", "font": "Avenir"]],
            "search": ["background": "#17212FFF", "backgroundSelected": "#37628AFF", "roundness": 5,
                       "text": ["color": "#E6F2FFFF", "colorSelected": "#FFFFFFFF", "font": "Avenir"]],
            "scrollbar": ["color": "#A9C7E4FF", "thickness": 3]]])
        defer { applyTheme(PlayerTheme()); demo(); search.stringValue = ""; filter() }
        demo(); applyTheme(theme)
        placeSearchCaretAtEnd()
        let editor = search.currentEditor() as? NSTextView
        let row = MusicCell(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
        row.display(MusicItem(["name": "Selected playlist", "kind": "playlist"]), index: 0, selected: true)
        row.layout()
        let selection = row.title.textColor == theme.selectedText && row.returnArrow.contentTintColor == theme.selectedShortcut
        row.display(MusicItem(["name": "Playlist", "kind": "playlist"]), index: 1, selected: false)
        let normal = row.title.textColor == theme.text && row.shortcut.textColor == theme.shortcut
        shuffling = true; updateShuffle()
        let pixels = buttonPixels(shuffle)
        let green = pixels.green > 10 && pixels.black > 10
        shuffling = false; updateShuffle()
        let root = panel.contentView!
        root.layoutSubtreeIfNeeded()
        let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let x = bitmap.pixelsWide / 2
        func pixel(_ row: Int) -> NSColor { bitmap.colorAt(x: x, y: row)!.usingColorSpace(.sRGB)! }
        let edge = pixel(0), inside = pixel(1), background = pixel(2)
        let visibleBorder = abs(edge.redComponent - background.redComponent) > 0.02
        let onePixelBorder = abs(inside.redComponent - background.redComponent) < 0.01
        return ["status": "ok", "theme_applied_to_rows": selection && normal,
                "theme_applied_to_header": nowTitle.textColor == theme.text && nowDetail.textColor == theme.secondary,
                "theme_applied_to_cursor": editor?.insertionPointColor == theme.searchText,
                "theme_applied_to_text_selection": editor?.selectedTextAttributes[.backgroundColor] as? NSColor == theme.searchSelection,
                "theme_font_family": row.title.font?.familyName == "Avenir" && search.font?.familyName == "Avenir",
                "theme_window_radius": panel.contentView?.layer?.cornerRadius == 12,
                "theme_border_renders_in_captures": visibleBorder, "theme_border_is_one_pixel": onePixelBorder,
                "theme_controls": toggle.contentTintColor == theme.control && shuffle.contentTintColor == theme.secondary,
                "spotify_green_preserved": green]
    }

    private func repeatChecks() -> [String: Any] {
        connection = "connected"
        repeatMode = .off; confirmedRepeatMode = .off; repeatPending = false
        updateRepeat()
        let start = repeatRequest
        let off = !repeatButton.showsActiveCircle && repeatButton.contentTintColor == .secondaryLabelColor
        cycleRepeat()
        let all = repeatMode == .context && repeatButton.showsActiveCircle && repeatButton.image === repeatAllImage(height: 10)
        cycleRepeat()
        let one = repeatMode == .track && repeatButton.showsActiveCircle && repeatButton.image === symbol("repeat.1", height: 10)
        cycleRepeat()
        let cycles = off && all && one && repeatMode == .off
        receive(["type": "repeat", "mode": "context", "request": start + 1])
        receive(["type": "repeat", "mode": "track", "request": start + 3, "poll": true])
        let staleSafe = repeatMode == .off && repeatPending
        receive(["type": "repeat", "mode": "off", "request": start + 3])
        let confirmed = repeatMode == .off && !repeatPending
        cycleRepeat()
        receive(["type": "repeat", "mode": "context", "request": repeatRequest, "error": "Repeat test failed"])
        let recovers = repeatMode == .off && !repeatPending && status.stringValue == "Repeat test failed"
        repeatButton.highlight(true)
        let heldGreen = buttonPixels(repeatButton).green > 10
        repeatButton.highlight(false)
        let next = playbackButtons.last!
        return ["status": "ok", "repeat_cycles_off_all_one_off": cycles,
                "repeat_stale_updates_ignored": staleSafe, "repeat_confirmation_applied": confirmed,
                "repeat_failure_restores_confirmed_state": recovers, "repeat_press_green": heldGreen,
                "repeat_to_right_of_next": repeatButton.frame.minX >= next.frame.maxX,
                "repeat_within_panel": repeatButton.frame.maxX <= preview.frame.maxX,
                "repeat_vertically_centered": repeatButton.frame.midY == nowArt.frame.midY,
                "repeat_symbols_available": symbol("repeat", height: 10) != nil && symbol("repeat.1", height: 10) != nil]
    }
    private func controlChecks() -> [String: Any] {
        connection = "connected"
        let previous = playbackButtons[0], next = playbackButtons[2]
        let previousRight = previous.frame.minX + buttonPixels(previous).right
        let nextLeft = next.frame.minX + buttonPixels(next).left
        func gaps() -> (CGFloat, CGFloat) {
            let pixels = buttonPixels(toggle)
            return (toggle.frame.minX + pixels.left - previousRight, nextLeft - toggle.frame.minX - pixels.right)
        }
        playing = false; updateToggle(); let playGaps = gaps()
        playing = true; updateToggle(); let pauseGaps = gaps()
        let playError = abs(playGaps.0 - playGaps.1), pauseError = abs(pauseGaps.0 - pauseGaps.1)
        let playAligned = playError <= 0.15 && pauseError <= 0.15
        var pressesGreen = true
        for button in playbackButtons {
            button.isEnabled = true; button.highlight(true)
            let heldPixels = buttonPixels(button)
            pressesGreen = pressesGreen && heldPixels.green > 10 && heldPixels.black == 0
            button.highlight(false)
            let restingPixels = buttonPixels(button)
            pressesGreen = pressesGreen && button.contentTintColor == .black && restingPixels.green == 0 && restingPixels.black > 10
        }
        let sampleURI = "spotify:track:" + String(repeating: "a", count: 22)
        let sampleContext = "spotify:playlist:" + String(repeating: "b", count: 22)
        let event = SpotifyCommands.playbackEvent("play", uri: sampleURI, context: sampleContext)
        let backgroundPlayback = event?.eventClass == 0x73706679 && event?.eventID == 0x50437478
            && event?.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue == sampleURI
            && event?.paramDescriptor(forKeyword: 0x636f7478)?.stringValue == sampleContext
            && SpotifyCommands.playbackOptions.contains(.neverInteract)
            && !SpotifyCommands.playbackOptions.contains(.canSwitchLayer)
            && !SpotifyCommands.backgroundLaunchConfiguration().activates
        let first = "spotify:track:" + String(repeating: "a", count: 22)
        let second = "spotify:track:" + String(repeating: "b", count: 22)
        setCurrentTrack(first)
        let initiallyUnsaved = like.isEnabled && likedTracks[first] != true
        like.highlight(true)
        toggleLiked()
        like.highlight(false)
        let pending = pendingLikes[first] == true && !like.isEnabled
        let pendingPixels = buttonPixels(like)
        let pendingGreen = pendingPixels.green > 10 && pendingPixels.black == 0 && pendingPixels.opacity > 0.98
        setCurrentTrack(second)
        receive(["type": "liked", "uri": first, "liked": true])
        let staleSafe = currentTrackURI == second && likedTracks[second] != true && like.toolTip == "Save to Liked Songs"
        setCurrentTrack(first)
        let saved = like.toolTip == "Remove from Liked Songs" && like.contentTintColor == spotifyGreen && like.showsSavedCheck
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
        let failure = like.isEnabled && pendingLikes[second] == nil && status.stringValue == "Save failed"
        let shuffleFrame = shuffle.frame, shuffleSize = shuffle.image?.size
        shuffling = false; toggleShuffle()
        let onPixels = buttonPixels(shuffle)
        let shuffleOn = shuffling && shuffle.showsActiveCircle && shuffle.contentTintColor == .black && onPixels.green > 10 && onPixels.black > 10
        shuffle.highlight(true)
        let heldOnPixels = buttonPixels(shuffle)
        shuffle.highlight(false)
        toggleShuffle()
        let offPixels = buttonPixels(shuffle)
        let shuffleOff = !shuffling && !shuffle.showsActiveCircle && shuffle.contentTintColor == .secondaryLabelColor && offPixels.green == 0 && offPixels.black == 0
        shuffle.highlight(true)
        let heldShufflePixels = buttonPixels(shuffle)
        let shufflePressesGreen = heldShufflePixels.green > 10 && heldShufflePixels.black == 0 && heldOnPixels.green > 10 && heldOnPixels.black > 10
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
        return ["status": "ok", "tinted_icons_have_no_edge_lines": tintHasNoEdgeLines(), "playback_stays_in_background": backgroundPlayback, "play_pause_equal_gaps": playAligned, "play_gap_difference_pt": playError, "pause_gap_difference_pt": pauseError, "held_playback_controls_green": pressesGreen, "like_unsaved": initiallyUnsaved, "like_pending": pending, "like_pending_stays_green": pendingGreen, "like_saved": saved,
                "like_stale_reply_safe": staleSafe, "checkmark_unlikes": togglesOff && unliked, "held_like_green": likePressesGreen, "held_shuffle_green": shufflePressesGreen, "shuffle_geometry_stable": shuffleStable, "like_failure_recoverable": failure,
                "shuffle_on": shuffleOn, "shuffle_off": shuffleOff, "shuffle_icon_loaded": shuffle.image != nil,
                "hotkey_opens_spotify_when_focused": hotkeyOpened,
                "hotkey_shows_when_unfocused": unfocusedShows, "escape_then_hotkey_reopens": escapeReopens,
                "second_hotkey_opens_spotify": repeatedOpens]
    }
    private func demo() {
        connection = "connected"
        for button in playbackButtons { button.isEnabled = true }
        shuffle.isEnabled = true
        updateRepeat()
        inlineError = nil
        statusMessage = ""
        routeKind = "home"
        breadcrumb = ""
        catalogPending = false
        updateSearchStatus()
        catalogSearchWork?.cancel()
        source = ["Playlists", "Albums", "Artists", "Songs", "Spotify"].enumerated().map { index, name in
            MusicItem(["name": name, "kind": "action", "uri": "action:\(name)", "symbol": ["music.note.list", "square.stack", "person.fill", "music.note", "magnifyingglass"][index], "match": name,
                       "item": ["action": index == 4 ? "catalog" : "browse"]])
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

private let args = CommandLine.arguments
if args.contains("--reauth-result") {
    let result = reauthFeedback(error: ProcessInfo.processInfo.environment["spotify_reauth_error"] ?? "")
    print(String(decoding: try! jsonData(result), as: UTF8.self))
    exit(0)
}
if args.contains("--clear-connection") {
    var errorMessage = ""
    do {
        if connectToPlayer("reset")?["status"] as? String != "ok" {
            try NativeBackend.clearConnection(WorkflowPaths(root: workflowRoot()))
        }
    } catch { errorMessage = error.localizedDescription }
    let result: JSONObject = ["alfredworkflow": ["arg": "", "variables": ["spotify_reauth_error": errorMessage]]]
    print(String(decoding: try! jsonData(result), as: UTF8.self))
    exit(0)
}
if let index = args.firstIndex(of: "--write-metadata"), args.count > index + 2 {
    do { try writeWorkflowMetadata(URL(fileURLWithPath: args[index + 1]), stage: URL(fileURLWithPath: args[index + 2])); exit(0) }
    catch { fputs("\(error)\n", stderr); exit(1) }
}
if args.contains("--test-models") { runModelTests(); exit(0) }
if args.contains("--test-integration") { runIntegrationTests(); exit(0) }

if args.contains("--validate-script") {
    if let error = SpotifyCommands().validate() { fputs("\(error)\n", stderr); exit(1) }
    print("Playback AppleScript compiled successfully.")
    exit(0)
}
if let index = args.firstIndex(of: "--relaunch-after"), args.count > index + 1, let pid = Int32(args[index + 1]) {
    for _ in 0..<400 {
        if kill(pid, 0) != 0 { break }
        usleep(10_000)
    }
}
if args.contains("--serve") || args.contains("--test-server") || args.contains("--snapshot") || args.contains("--relaunch-after") {
    let app = NSApplication.shared
    delegate = PlayerDelegate(testMode: args.contains("--test-server") || args.contains("--snapshot"))
    app.delegate = delegate
    app.run()
} else {
    let command = args.contains("--state") ? "state" : args.contains("--hide") ? "hide" : "show"
    if let result = connectToPlayer(command), result["status"] as? String == "ok" {
        if command == "state", let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
        exit(0)
    }
    if command != "show" { exit(1) }
    do {
        // A lock makes two simultaneous hotkey presses start only one server.
        try secureSocketDirectory()
        let lockFD = open(socketDirectory + "/launch.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer { if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD) } }
        for _ in 0..<50 {
            guard let state = connectToPlayer("state"), state["status"] as? String == "restart" else { break }
            usleep(10_000)
        }
        if connectToPlayer("state") == nil { try launchServer() }
        for _ in 0..<200 {
            if let result = connectToPlayer("show"), result["status"] as? String == "ok" { exit(0) }
            usleep(10_000)
        }
        fputs("Spotify Mini Player could not start. Reimport the workflow and try again.\n", stderr)
        exit(1)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
