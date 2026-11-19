import AppKit
import Carbon
import CoreText
import Darwin

private let socketDirectory = ProcessInfo.processInfo.environment["SPOTIFY_NATIVE_SOCKET_DIR"] ?? "/tmp/spotify-alfred-\(getuid())"
private let socketPath = socketDirectory + "/player.sock"
private let applicationID = "com.runningwithcrayons.Alfred"
private var delegate: PlayerDelegate!

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

private func connectToPlayer(_ command: String) -> [String: Any]? {
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

private func currentExecutable() -> URL {
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
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyAction?(event) == true { return true }
        if performEditingKey(event, responder: firstResponder) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
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
        items.enumerated().sorted {
            $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority < $1.element.priority
        }.map { $0.element }
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


// Strip transparent font bearings once, so layout uses visible icon bounds.
private func tightImage(_ original: NSImage?, height: CGFloat) -> NSImage? {
    guard let original = original else { return nil }
    let scale: CGFloat = 2
    let size = original.size
    guard size.width > 0, size.height > 0,
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
              pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
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
    guard maxX >= minX, maxY >= minY,
          let cg = bitmap.cgImage?.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { return nil }
    let result = NSImage(cgImage: cg, size: NSSize(width: height * CGFloat(cg.width) / CGFloat(cg.height), height: height))
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
    var preservesColors = false
    var showsSavedCheck = false { didSet { needsDisplay = true } }
    var activeDot = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let image = image else { return }
        if showsSavedCheck {
            NSGraphicsContext.saveGraphicsState()
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            spotifyGreen.withAlphaComponent(isEnabled ? 1 : 0.35).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)).fill()
            NSColor.black.withAlphaComponent(isEnabled ? 1 : 0.35).setStroke()
            let check = NSBezierPath()
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.move(to: NSPoint(x: center.x - 4, y: center.y))
            check.line(to: NSPoint(x: center.x - 1, y: center.y - 3))
            check.line(to: NSPoint(x: center.x + 4.5, y: center.y + 3))
            check.stroke()
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let rect = NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                          width: image.size.width, height: image.size.height)
        let color = contentTintColor ?? .secondaryLabelColor
        let tinted = preservesColors ? image : NSImage(size: image.size, flipped: false) { area in
            color.setFill()
            area.fill()
            image.draw(in: area, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.35)
        if activeDot {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 1.5, y: 0.5, width: 3, height: 3)).fill()
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
        let color = selected ? NSColor.textBackgroundColor : NSColor.labelColor
        title.textColor = color
        shortcut.textColor = selected ? color : .secondaryLabelColor
        shortcutNumber.textColor = shortcut.textColor
        returnArrow.contentTintColor = color
        artwork.contentTintColor = selected ? color : .secondaryLabelColor
        artwork.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.kind)
    }
}

private final class SelectionRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        (dark ? NSColor.white : NSColor.black).setFill()
        bounds.fill()
    }
}

private final class BackendPipe {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let sendQueue = DispatchQueue(label: "spotify.backend.input")
    private var buffer = Data()
    var receive: (([String: Any]) -> Void)?
    var failed: ((String) -> Void)?
    var pid: Int32 { process.isRunning ? process.processIdentifier : 0 }

    func start() throws {
        let root = workflowRoot()
        let environment = ProcessInfo.processInfo.environment
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] +
            (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/python3" }
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "Spotify", code: 3, userInfo: [NSLocalizedDescriptionKey: "Python 3.14 or newer is required. Install it with: brew install python"])
        }
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", "-m", "alfred_spotify", "resident"]
        process.currentDirectoryURL = root
        process.environment = environment.merging(["PYTHONPATH": root.appendingPathComponent("lib").path + ":" + root.appendingPathComponent("src").path]) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.buffer.append(data)
            while let end = self.buffer.firstIndex(of: 10) {
                let line = self.buffer.prefix(upTo: end)
                let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                self.buffer.removeSubrange(...end)
                if let value = value { DispatchQueue.main.async { self.receive?(value) } }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.failed?("The Spotify library worker stopped. Reopen the player to restart it.") }
        }
        try process.run()
    }
    func send(_ value: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        data.append(10)
        sendQueue.async { [weak self] in
            try? self?.input.fileHandleForWriting.write(contentsOf: data)
        }
    }
    func stop() {
        process.terminationHandler = nil
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}

private final class SpotifyCommands {
    private let queue = DispatchQueue(label: "spotify.playback", qos: .userInteractive)
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
        tell application id "com.spotify.client"
            if commandName is "toggle" then
                playpause
            else if commandName is "shuffle" then
                set shuffling to not shuffling
            else if commandName is "next" then
                next track
            else if commandName is "previous" then
                previous track
            else if commandName is "play" then
                if contextURI is not "" then
                    play track trackURI in context contextURI
                else
                    play track trackURI
                end if
            end if
        end tell
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
    func play(_ command: String, uri: String = "", context: String = "") {
        guard ["toggle", "shuffle", "next", "previous", "play"].contains(command) else { return }
        if command == "play" {
            guard uri.range(of: #"^spotify:(track|album|artist|playlist):[A-Za-z0-9]+$"#, options: .regularExpression) != nil,
                  context.isEmpty || context.range(of: #"^spotify:(album|artist|playlist):[A-Za-z0-9]+$"#, options: .regularExpression) != nil else { return }
        }
        queue.async { _ = self.call("perform", arguments: [command, uri, context]) }
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
    private let server = IPCServer()
    private var backend = BackendPipe()
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
    private let settings = IconButton()
    private let openSpotifyButton = IconButton()
    private var currentTrackURI = ""
    private var likedTracks: [String: Bool] = [:]
    private var savingTracks: Set<String> = []
    private var shuffling = false
    private var openedSpotify = 0
    private var lastResignedKey = Date.distantPast
    private var lastLikedCheck = Date.distantPast
    private let connect = NSButton(title: "Connect", target: nil, action: nil)
    private var source: [MusicItem] = []
    private var home: [MusicItem] = []
    private var catalog: [MusicItem] = []
    private var filtered: [MusicItem] = []
    private var breadcrumb = ""
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
    private var requestID = 0
    private var inlineError: String?
    private var statusTimer: Timer?
    private var lifeTimer: Timer?
    private var initialFiles: [String: Date] = [:]
    private var alfredPID: pid_t = 0
    private var optimisticUntil = Date.distantPast
    private var currentImageURL = ""
    private let imageCache = NSCache<NSString, NSImage>()
    private var imagesRequested: Set<String> = []
    private var terminating = false

    init(testMode: Bool = false) {
        self.testMode = testMode
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildPanel()
        installEditingMenu()
        backend.receive = { [weak self] value in self?.receive(value) }
        backend.failed = { [weak self] message in
            guard let self = self, !self.terminating else { return }
            self.connection = "failed"
            self.status.stringValue = message
            if self.panel.isVisible { self.showError(message) }
        }
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
                if let self = self, self.panel.isVisible && self.connection == "connected" {
                    self.spotify.poll()
                    if Date().timeIntervalSince(self.lastLikedCheck) >= 60 { self.refreshCurrentLike() }
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
            nowArt.image = NSImage(contentsOf: workflowRoot().appendingPathComponent("icon.png"))
            setCurrentTrack("spotify:track:" + String(repeating: "a", count: 22))
            playing = true; updateToggle()
            snapshot(CommandLine.arguments[index + 1])
            NSApp.terminate(nil)
        }
    }

    private func buildPanel() {
        imageCache.countLimit = 128
        imageCache.totalCostLimit = 96 * 1024 * 1024
        panel.delegate = self
        panel.keyAction = { [weak self] event in self?.key(event) ?? false }
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.title = "Spotify Mini Player"
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 584, height: 470))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        root.layer?.borderColor = NSColor.separatorColor.cgColor
        root.layer?.borderWidth = 1
        panel.contentView = root
        nowArt.frame = NSRect(x: 20, y: 369, width: 82, height: 82)
        nowArt.imageScaling = .scaleProportionallyUpOrDown
        nowArt.image = symbol("music.note", height: 64)
        nowArt.contentTintColor = .tertiaryLabelColor
        nowTitle.frame = NSRect(x: 120, y: 409, width: 282, height: 21)
        nowTitle.font = .systemFont(ofSize: 13)
        nowDetail.frame = NSRect(x: 120, y: 390, width: 282, height: 18)
        nowDetail.font = .systemFont(ofSize: 11)
        nowDetail.textColor = .secondaryLabelColor
        for label in [nowTitle, nowDetail] { label.lineBreakMode = .byTruncatingTail }
        root.addSubview(nowArt); root.addSubview(nowTitle); root.addSubview(nowDetail)
        let previous = playerButton("backward.fill", height: 12, action: #selector(previousTrack))
        configureButton(toggle, image: "play.fill", height: 18, action: #selector(togglePlayback))
        let next = playerButton("forward.fill", height: 12, action: #selector(nextTrack))
        playbackButtons = [previous, toggle, next]
        for (index, button) in playbackButtons.enumerated() {
            button.isEnabled = testMode
            button.frame = NSRect(x: 478 + index * 28, y: Int(nowArt.frame.midY) - 14, width: 28, height: 28)
            root.addSubview(button)
        }
        configureButton(like, image: "plus.circle", height: 18, action: #selector(saveSong))
        like.frame = NSRect(x: 413, y: nowArt.frame.midY - 14, width: 28, height: 28)
        like.isEnabled = false
        like.toolTip = "Save to Liked Songs"
        like.setAccessibilityLabel("Save to Liked Songs")
        root.addSubview(like)
        configureButton(shuffle, image: "shuffle", height: 16, action: #selector(toggleShuffle))
        shuffle.image = tightImage(NSImage(contentsOf: workflowRoot().appendingPathComponent("icons/shuffle.pdf")), height: 16)
        shuffle.frame = NSRect(x: 450, y: nowArt.frame.midY - 14, width: 28, height: 28)
        shuffle.isEnabled = false
        updateShuffle()
        root.addSubview(shuffle)
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
        previewDetail.textColor = .secondaryLabelColor
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
        configureButton(openSpotifyButton, image: "music.note", height: 18, action: #selector(openSpotify))
        openSpotifyButton.preservesColors = true
        openSpotifyButton.image = NSImage(contentsOf: workflowRoot().appendingPathComponent("icon.png"))
        openSpotifyButton.image?.size = NSSize(width: 18, height: 18)
        openSpotifyButton.frame = NSRect(x: 527, y: 7, width: 28, height: 22)
        openSpotifyButton.toolTip = "Open Spotify"
        openSpotifyButton.setAccessibilityLabel("Open Spotify")
        root.addSubview(openSpotifyButton)
        configureButton(settings, image: "gearshape", height: 14, action: #selector(openSettings))
        settings.frame = NSRect(x: preview.frame.maxX - 21, y: 7, width: 28, height: 22)
        settings.toolTip = "Workflow settings (⌘,)"
        root.addSubview(settings)
        // Force layout and raster caches now; showing this panel never rebuilds it.
        root.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    private func symbol(_ name: String, height: CGFloat) -> NSImage? {
        systemImage(name, height: height)
    }
    private func configureButton(_ button: NSButton, image: String, height: CGFloat, action: Selector) {
        button.image = symbol(image, height: height)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.target = self; button.action = action
        button.contentTintColor = .secondaryLabelColor
    }
    private func playerButton(_ image: String, height: CGFloat, action: Selector) -> NSButton {
        let button = IconButton()
        configureButton(button, image: image, height: height, action: action)
        return button
    }
    private func send(_ command: String, args: [String] = []) {
        if !["preview", "liked", "image"].contains(command) { inlineError = nil }
        requestID += 1
        backend.send(["command": command, "args": args, "request": requestID])
    }
    private func receive(_ value: [String: Any]) {
        let type = value["type"] as? String ?? ""
        if type == "error" { showError(value["message"] as? String ?? "Could not complete the request."); return }
        if type == "liked" {
            let uri = value["uri"] as? String ?? ""
            likedTracks[uri] = value["liked"] as? Bool ?? false
            if value["cached"] as? Bool != true { savingTracks.remove(uri) }
            if uri == currentTrackURI {
                updateLike()
                if let error = value["error"] as? String, !error.isEmpty { showError(error) }
            }
            return
        }
        if type == "catalog" {
            catalog = MusicItem.prioritized((value["rows"] as? [[String: Any]] ?? []).map(MusicItem.init))
            if breadcrumb.isEmpty && !search.stringValue.isEmpty { filter() }
            return
        }
        if type == "artwork" {
            let url = value["url"] as? String ?? ""
            let path = value["path"] as? String ?? ""
            if url == currentImageURL, let image = image(path) { nowArt.image = image }
            return
        }
        let nextConnection = value["connection"] as? String ?? connection
        let signedIn = connection == "connecting" && nextConnection == "connected"
        if nextConnection != connection { inlineError = nil }
        connection = nextConnection
        if value["close_player"] as? Bool == true { hide() }
        status.stringValue = inlineError ?? (value["message"] as? String ?? "")
        status.toolTip = status.stringValue
        status.textColor = inlineError == nil && connection != "failed" ? .secondaryLabelColor : .systemRed
        connect.isHidden = connection == "connected" || connection == "loading"
        search.isEnabled = connection == "connected"
        for button in playbackButtons { button.isEnabled = connection == "connected" }
        shuffle.isEnabled = connection == "connected"
        updateLike()
        if let rows = value["rows"] as? [[String: Any]] {
            source = rows.map(MusicItem.init)
            if value["route_kind"] as? String == "catalog" { source = MusicItem.prioritized(source) }
            breadcrumb = value["prefix"] as? String ?? ""
            if breadcrumb.isEmpty { home = source }
            if let text = value["search_text"] as? String {
                search.stringValue = pendingHomeQuery ?? text
                pendingHomeQuery = nil
            }
            filter()
        }
        let variables = value["variables"] as? [String: Any] ?? [:]
        let responseURI = value["selected"] as? String ?? ""
        var loaded: NSImage?
        if let art = variables["preview_art"] as? [String: Any], let path = art["src"] as? String,
           let cover = image(path) {
            previewPaths[responseURI] = path
            loaded = cover
        }
        // A late reply may warm the cache, but only the current selection can paint the preview.
        if responseURI == selectedItem()?.uri && responseURI == previewURI {
            if let title = variables["preview_title"] as? String { previewTitle.stringValue = title }
            if let detail = variables["preview_detail"] as? String { previewDetail.stringValue = detail }
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
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        imageCache.setObject(image, forKey: path as NSString,
                             cost: max(1, Int(image.size.width * image.size.height * 4)))
        return image
    }
    private func filter() {
        let selection = selectedItem()?.uri
        let text = search.stringValue
        let query = text.hasPrefix(breadcrumb) ? String(text.dropFirst(breadcrumb.count)) : text
        let terms = MusicItem.normalize(query).split(whereSeparator: { $0.isWhitespace })
        let available = breadcrumb.isEmpty && !terms.isEmpty && connection == "connected" ? catalog : source
        filtered = terms.isEmpty ? available : available.filter { $0.matches(terms) }
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
            let clear = DispatchWorkItem { [weak self] in
                guard let self = self, self.selectedItem() == nil else { return }
                self.previewURI = ""
                self.previewTitle.stringValue = ""
                self.previewDetail.stringValue = "No matches"
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
        (search.currentEditor() as? NSTextView)?.allowsUndo = true
    }
    func controlTextDidChange(_ obj: Notification) {
        if !breadcrumb.isEmpty && !search.stringValue.hasPrefix(breadcrumb) {
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
            if event.keyCode == 36 { send("catalog", args: [search.stringValue]); return true }
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
        if item.kind == "track" || action == "play" {
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
                nowArt.image = image(item.art) ?? symbol("music.note", height: 64)
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
    @objc private func saveSong() {
        guard like.isEnabled, likedTracks[currentTrackURI] != true else { return }
        savingTracks.insert(currentTrackURI)
        updateLike()
        if !testMode { send("save", args: [currentTrackURI]) }
    }
    private func setCurrentTrack(_ uri: String) {
        guard currentTrackURI != uri else { return }
        currentTrackURI = uri
        updateLike()
        refreshCurrentLike()
    }
    private func refreshCurrentLike() {
        lastLikedCheck = Date()
        if !testMode, currentTrackURI.range(of: #"^spotify:track:[A-Za-z0-9]{22}$"#, options: .regularExpression) != nil {
            send("liked", args: [currentTrackURI])
        }
    }
    private func updateLike() {
        let saved = likedTracks[currentTrackURI] == true
        like.image = symbol(saved ? "checkmark.circle.fill" : "plus.circle", height: 18)
        like.showsSavedCheck = saved
        like.contentTintColor = saved ? spotifyGreen : .secondaryLabelColor
        like.needsDisplay = true
        like.isEnabled = connection == "connected" && currentTrackURI.range(of: #"^spotify:track:[A-Za-z0-9]{22}$"#, options: .regularExpression) != nil && !savingTracks.contains(currentTrackURI)
        like.toolTip = saved ? "Saved to Liked Songs" : savingTracks.contains(currentTrackURI) ? "Saving to Liked Songs…" : "Save to Liked Songs"
        like.setAccessibilityLabel(like.toolTip)
        like.setAccessibilityValue(saved ? "Saved" : "Not saved")
    }
    @objc private func toggleShuffle() {
        guard connection == "connected" else { return }
        shuffling.toggle()
        updateShuffle()
        optimisticUntil = Date().addingTimeInterval(0.5)
        if !testMode { spotify.play("shuffle") }
    }
    private func updateShuffle() {
        shuffle.contentTintColor = shuffling ? spotifyGreen : .secondaryLabelColor
        shuffle.activeDot = shuffling
        shuffle.toolTip = shuffling ? "Turn shuffle off" : "Turn shuffle on"
        shuffle.setAccessibilityLabel(shuffle.toolTip)
        shuffle.setAccessibilityValue(shuffling ? "On" : "Off")
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
        if focused ?? (panel.isKeyWindow || recentlyFocused) { openSpotify() } else { show() }
    }
    @objc private func connectSpotify() { send("connect") }
    @objc private func openSettings() { send("configure") }
    private func updateToggle() { toggle.image = symbol(playing ? "pause.fill" : "play.fill", height: 18) }
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
        if let item = catalog.first(where: { $0.uri == values[5] }), let art = image(item.art) {
            nowArt.image = art
        } else if !values[4].isEmpty, !imagesRequested.contains(values[4]) {
            imagesRequested.insert(values[4]); send("image", args: [values[4]])
        }
    }
    private func showError(_ message: String) {
        inlineError = message
        status.stringValue = message
        status.toolTip = message
        status.textColor = .systemRed
    }
    private func show() {
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
        wasShown = true
        if backend.pid == 0 {
            backend = BackendPipe()
            backend.receive = { [weak self] value in self?.receive(value) }
            backend.failed = { [weak self] message in self?.showError(message) }
            do { try backend.start() } catch { showError(error.localizedDescription) }
        }
        send("show")
        if connection == "connected" { spotify.poll(); refreshCurrentLike() }
    }
    private func hide() {
        if let sheet = panel.attachedSheet { panel.endSheet(sheet) }
        panel.orderOut(nil)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func windowDidResignKey(_ notification: Notification) {
        lastResignedKey = Date()
        hide()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private func handleIPC(_ value: [String: Any]) -> [String: Any] {
        if value["build"] as? String != Build.identifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { NSApp.terminate(nil) }
            return ["status": "restart"]
        }
        if testMode && value["command"] as? String == "test-controls" { return controlChecks() }
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
        if value["command"] as? String == "hotkey" { showForHotkey() }
        if value["command"] as? String == "show" { show() }
        if value["command"] as? String == "hide" { hide() }
        return ["status": "ok", "pid": getpid(), "backend_pid": backend.pid, "build": Build.identifier,
                "panel": String(describing: ObjectIdentifier(panel)), "shows": showCount,
                "visible": panel.isVisible, "shown_before": wasShown, "connection": connection, "rows": source.count,
                "dispatch_ms": Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000]
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
        terminating = true
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
                "gear_aligned_with_cover": abs(settings.frame.midX + (settings.image?.size.width ?? 0) / 2 - preview.frame.maxX) < 0.5,
                "same_selection_cover_stable": stable, "typing_keeps_previous_cover": held,
                "learned_cover_reused": reused, "stale_cover_ignored": preview.image === coverB,
                "no_reset_button": !(panel.contentView?.subviews.contains {
                    ($0 as? NSButton)?.title == "Reset Connection"
                } ?? false)]
    }
    private func spotifyIconIsUpright() -> Bool {
        guard let data = try? Data(contentsOf: workflowRoot().appendingPathComponent("icon.png")),
              let source = NSBitmapImageRep(data: data),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 56, pixelsHigh: 44,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        bitmap.size = openSpotifyButton.bounds.size
        openSpotifyButton.cacheDisplay(in: openSpotifyButton.bounds, to: bitmap)
        var uprightError: CGFloat = 0, invertedError: CGFloat = 0
        for y in 0..<36 {
            for x in 0..<36 {
                let sx = min(source.pixelsWide - 1, Int((CGFloat(x) + 0.5) * CGFloat(source.pixelsWide) / 36))
                let sy = min(source.pixelsHigh - 1, Int((CGFloat(y) + 0.5) * CGFloat(source.pixelsHigh) / 36))
                guard let normal = source.colorAt(x: sx, y: sy)?.usingColorSpace(.deviceRGB),
                      let inverted = source.colorAt(x: sx, y: source.pixelsHigh - sy - 1)?.usingColorSpace(.deviceRGB),
                      let actual = bitmap.colorAt(x: 10 + x, y: 4 + y)?.usingColorSpace(.deviceRGB),
                      normal.alphaComponent > 0.98 && inverted.alphaComponent > 0.98 else { continue }
                uprightError += abs(actual.greenComponent - normal.greenComponent)
                invertedError += abs(actual.greenComponent - inverted.greenComponent)
            }
        }
        return uprightError < invertedError * 0.5
    }
    private func controlChecks() -> [String: Any] {
        connection = "connected"
        let first = "spotify:track:" + String(repeating: "a", count: 22)
        let second = "spotify:track:" + String(repeating: "b", count: 22)
        setCurrentTrack(first)
        let initiallyUnsaved = like.isEnabled && likedTracks[first] != true
        saveSong()
        let pending = savingTracks.contains(first) && !like.isEnabled
        setCurrentTrack(second)
        receive(["type": "liked", "uri": first, "liked": true])
        let staleSafe = currentTrackURI == second && likedTracks[second] != true && like.toolTip == "Save to Liked Songs"
        setCurrentTrack(first)
        let saved = like.toolTip == "Saved to Liked Songs" && like.contentTintColor == spotifyGreen && like.showsSavedCheck
        setCurrentTrack(second)
        saveSong()
        receive(["type": "liked", "uri": second, "liked": false, "error": "Save failed"])
        let failure = like.isEnabled && !savingTracks.contains(second) && status.stringValue == "Save failed"
        shuffling = false; toggleShuffle()
        let shuffleOn = shuffling && shuffle.activeDot
        toggleShuffle()
        let shuffleOff = !shuffling && !shuffle.activeDot
        let openedBefore = openedSpotify
        showForHotkey(focused: true)
        let hotkeyOpened = openedSpotify == openedBefore + 1
        showForHotkey(focused: false)
        return ["like_unsaved": initiallyUnsaved, "like_pending": pending, "like_saved": saved,
                "like_stale_reply_safe": staleSafe, "like_failure_recoverable": failure,
                "shuffle_on": shuffleOn, "shuffle_off": shuffleOff, "shuffle_icon_loaded": shuffle.image != nil,
                "spotify_button_loaded": openSpotifyButton.image != nil,
                "spotify_icon_upright": spotifyIconIsUpright(),
                "spotify_icon_close_to_settings": abs(settings.frame.midX - openSpotifyButton.frame.midX - 24) < 0.1, "hotkey_opens_spotify_when_focused": hotkeyOpened,
                "hotkey_shows_when_unfocused": openedSpotify == openedBefore + 1]
    }
    private func demo() {
        connection = "connected"
        status.stringValue = ""
        source = ["Playlists", "Albums", "Artists", "Songs"].enumerated().map { index, name in
            MusicItem(["name": name, "kind": "action", "uri": "action:\(name)", "symbol": ["music.note.list", "square.stack", "person.fill", "music.note"][index], "match": name])
        }
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
        fputs("Spotify Mini Player could not start. Reopen the workflow or check that Python 3.14+ is installed.\n", stderr)
        exit(1)
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
