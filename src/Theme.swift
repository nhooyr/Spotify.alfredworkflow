import AppKit

private func themeString(_ value: Any?) -> String { value as? String ?? "" }

struct PlayerTheme {
    var identifier = "system"
    var background = NSColor.textBackgroundColor
    var border = NSColor.separatorColor
    var text = NSColor.labelColor
    var secondary = NSColor.secondaryLabelColor
    var selection = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black }
    var selectedText = NSColor.textBackgroundColor
    var shortcut = NSColor.secondaryLabelColor
    var selectedShortcut = NSColor.textBackgroundColor
    var control = NSColor.black
    var searchBackground = NSColor.clear
    var searchText = NSColor.labelColor
    var searchSelection = NSColor.selectedTextBackgroundColor
    var searchSelectedText = NSColor.selectedTextColor
    var scrollbar = NSColor.secondaryLabelColor
    var resultFont = ""
    var secondaryFont = ""
    var shortcutFont = ""
    var searchFont = ""
    var cornerRadius: CGFloat = 0
    var resultRadius: CGFloat = 0
    var searchRadius: CGFloat = 0
    var scrollbarWidth: CGFloat = 3
    var blurred = false

    static func color(_ value: Any?) -> NSColor? {
        let string = themeString(value).trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") {
            let hex = String(string.dropFirst())
            guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
            let rgba = hex.count == 6 ? value << 8 | 255 : value
            return NSColor(srgbRed: CGFloat((rgba >> 24) & 255) / 255,
                green: CGFloat((rgba >> 16) & 255) / 255, blue: CGFloat((rgba >> 8) & 255) / 255,
                alpha: CGFloat(rgba & 255) / 255)
        }
        if string.hasPrefix("rgba("), string.hasSuffix(")") {
            let values = string.dropFirst(5).dropLast().split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard values.count == 4 else { return nil }
            return NSColor(srgbRed: CGFloat(values[0] / 255), green: CGFloat(values[1] / 255), blue: CGFloat(values[2] / 255), alpha: CGFloat(values[3]))
        }
        return nil
    }
    init(_ document: JSONObject = [:], context: [String: String] = [:]) {
        let theme = dict(document["alfredtheme"])
        let window = dict(theme["window"]), result = dict(theme["result"]), search = dict(theme["search"])
        let resultText = dict(result["text"]), subtext = dict(result["subtext"]), keys = dict(result["shortcut"])
        let input = dict(search["text"])
        identifier = context["id"] ?? themeString(theme["name"])
        background = Self.color(window["color"]) ?? Self.color(context["background"]) ?? background
        // Alfred exposes the two main colours even for built-in themes that have no JSON file.
        if let rgb = background.usingColorSpace(.sRGB), Self.color(window["color"]) != nil || Self.color(context["background"]) != nil {
            let dark = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent < 0.5
            text = dark ? .white : .black
            secondary = text.withAlphaComponent(0.65)
        }
        border = Self.color(window["borderColor"]) ?? border
        text = Self.color(resultText["color"]) ?? text
        secondary = Self.color(subtext["color"]) ?? secondary
        selection = Self.color(result["backgroundSelected"]) ?? Self.color(context["selection"]) ?? selection
        if let rgb = selection.usingColorSpace(.sRGB), Self.color(result["backgroundSelected"]) != nil || Self.color(context["selection"]) != nil {
            selectedText = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent < 0.5 ? .white : .black
        }
        selectedText = Self.color(resultText["colorSelected"]) ?? selectedText
        shortcut = Self.color(keys["color"]) ?? text
        selectedShortcut = Self.color(keys["colorSelected"]) ?? selectedText
        searchBackground = Self.color(search["background"]) ?? searchBackground
        searchText = Self.color(input["color"]) ?? text
        searchSelection = Self.color(search["backgroundSelected"]) ?? selection
        searchSelectedText = Self.color(input["colorSelected"]) ?? selectedText
        control = theme.isEmpty && context.isEmpty ? .black : searchText
        scrollbar = Self.color(dict(theme["scrollbar"])["color"]) ?? secondary
        resultFont = themeString(resultText["font"])
        secondaryFont = themeString(subtext["font"])
        shortcutFont = themeString(keys["font"])
        searchFont = themeString(input["font"])
        cornerRadius = CGFloat(min(40, max(0, number(window["roundness"]))))
        resultRadius = CGFloat(min(20, max(0, number(result["roundness"]))))
        searchRadius = CGFloat(min(20, max(0, number(search["roundness"]))))
        let width = number(dict(theme["scrollbar"])["thickness"])
        if width > 0 { scrollbarWidth = min(12, CGFloat(width)) }
        blurred = number(window["blur"]) > 0
    }
    func font(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

private struct ThemeFile {
    private var path = ""
    private var modified: Date?
    private var size: Int?
    private var value: JSONObject = [:]
    mutating func read(_ url: URL) -> JSONObject {
        let attributes = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        if path != url.path || modified != attributes?.contentModificationDate || size != attributes?.fileSize {
            path = url.path; modified = attributes?.contentModificationDate; size = attributes?.fileSize
            if let data = try? Data(contentsOf: url) {
                value = dict(url.pathExtension == "plist" ? try? PropertyListSerialization.propertyList(from: data, format: nil) : try? JSONSerialization.jsonObject(with: data))
            } else { value = [:]; if attributes != nil { path = "" } }
        }
        return value
    }
}

// Theme files are tiny. Only changed files are decoded; no work is done per keystroke.
final class ThemeSource {
    private var signature = ""
    private var cached = PlayerTheme()
    private var settingsFile = ThemeFile()
    private var appearanceFile = ThemeFile()
    func load(context: [String: String], environment: [String: String] = ProcessInfo.processInfo.environment,
              home: URL = FileManager.default.homeDirectoryForCurrentUser, dark: Bool) -> (String, PlayerTheme) {
        let settingsURL = home.appendingPathComponent("Library/Application Support/Alfred/prefs.json")
        let configuredPrefs = context["preferences"] ?? environment["alfred_preferences"]
        let configuredHash = context["localhash"] ?? environment["alfred_preferences_localhash"]
        let settings = configuredPrefs != nil && configuredHash != nil ? [:] : settingsFile.read(settingsURL)
        let prefs = configuredPrefs ?? themeString(settings["current"])
        let localHash = configuredHash ?? themeString(settings["localhash"])
        let root = prefs.isEmpty ? home.appendingPathComponent("Library/Application Support/Alfred/Alfred.alfredpreferences") : URL(fileURLWithPath: prefs)
        let appearanceURL = root.appendingPathComponent("preferences/local/\(localHash)/appearance/prefs.plist")
        let appearance = context["id"] == nil ? appearanceFile.read(appearanceURL) : [:]
        let selected = themeString(appearance[dark ? "darkthemeuid" : "lightthemeuid"])
        let id = context["id"] ?? (selected.isEmpty ? environment["alfred_theme"] ?? "" : selected)
        let file = root.appendingPathComponent("themes").appendingPathComponent(id).appendingPathComponent("theme.json")
        let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        var fallback = context
        if fallback["background"] == nil { fallback["background"] = environment["alfred_theme_background"] }
        if fallback["selection"] == nil { fallback["selection"] = environment["alfred_theme_selection_background"] }
        fallback["id"] = id
        let key = file.path + ":\(stamp):\(dark):" + fallback.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "|")
        if key != signature {
            cached = PlayerTheme(dict(readJSON(file)), context: fallback)
            signature = key
        }
        return (signature, cached)
    }
}

private final class ThemeBorder: NSView {
    var strokeColor = NSColor.clear
    var cornerRadius: CGFloat = 0
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        strokeColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        path.lineWidth = 1 / (window?.backingScaleFactor ?? 1)
        path.stroke()
    }
}

// Keep the native blur behind an explicit colour layer so theme opacity is preserved.
final class ThemeBackground: NSView {
    private let effect = NSVisualEffectView()
    private let colour = NSView()
    private let outline = ThemeBorder()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        effect.frame = bounds; effect.autoresizingMask = [.width, .height]
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        addSubview(effect)
        colour.frame = bounds; colour.autoresizingMask = [.width, .height]
        colour.wantsLayer = true
        addSubview(colour)
        outline.frame = bounds
        outline.autoresizingMask = [.width, .height]
        addSubview(outline)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBorder()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBorder()
    }
    override func layout() {
        super.layout()
        updateBorder()
    }
    private func updateBorder() {
        // Centre the hairline on the window edge instead of painting a dark inset band.
        outline.frame = bounds
        outline.needsDisplay = true
    }
    func apply(_ theme: PlayerTheme) {
        effect.isHidden = !theme.blurred
        colour.layer?.backgroundColor = theme.background.cgColor
        outline.strokeColor = theme.border
        outline.cornerRadius = theme.cornerRadius
        layer?.cornerRadius = theme.cornerRadius
        layer?.masksToBounds = true
        updateBorder()
    }
}
