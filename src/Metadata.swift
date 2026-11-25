import Foundation

func writeWorkflowMetadata(_ root: URL, stage: URL) throws {
  let nativeVersion = try appBundleVersion(version)
  let original = try Data(contentsOf: root.appendingPathComponent("workflow/info.plist"))
  var workflow =
    try PropertyListSerialization.propertyList(from: original, format: nil) as! JSONObject
  workflow["version"] = alfredVersion(version)
  let readme = try String(contentsOf: stage.appendingPathComponent("README.md"), encoding: .utf8)
  workflow["readme"] = readme.replacingOccurrences(
    of:
      #"[ \t]*\[?!\[[^\]\r\n]*\]\(https://(?:github\.com/[^)\r\n]*/badge\.svg(?:\?[^)\r\n]*)?|img\.shields\.io/[^)\r\n]*)\)(?:\]\([^)\r\n]*\))?"#,
    with: "", options: .regularExpression)
  try PropertyListSerialization.data(fromPropertyList: workflow, format: .xml, options: 0).write(
    to: stage.appendingPathComponent("info.plist"))
  let app: JSONObject = [
    "CFBundleIdentifier": workflowID + ".player", "CFBundleName": "Spotify Mini Player",
    "CFBundleDisplayName": "Spotify Mini Player", "CFBundleExecutable": "SpotifyMiniPlayer",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": nativeVersion,
    "CFBundleVersion": nativeVersion, "LSUIElement": true, "LSMinimumSystemVersion": "13.0",
    "NSHighResolutionCapable": true,
    "NSAppleEventsUsageDescription": "Control playback in the Spotify desktop app.",
    "CFBundleIconFile": "icon.png",
  ]
  try PropertyListSerialization.data(fromPropertyList: app, format: .xml, options: 0).write(
    to: stage.appendingPathComponent("Spotify Mini Player.app/Contents/Info.plist"))
}

func alfredVersion(_ version: String) -> String {
  String(version.dropFirst(version.hasPrefix("v") ? 1 : 0))
}

func appBundleVersion(_ version: String) throws -> String {
  let numeric = String(
    alfredVersion(version).prefix { $0 != "-" && $0 != "+" })
  guard numeric.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
    throw SpotifyFailure(
      message: "Invalid version. Use X.Y.Z with an optional v prefix and development suffix.")
  }
  return numeric
}

func reauthFeedback(error: String = "") -> JSONObject {
  let succeeded = error.isEmpty
  return [
    "items": [
      [
        "title": succeeded ? "Open Spotify Mini Player" : "Could not clear Spotify sign-in",
        "subtitle": succeeded ? "Sign-in and Client ID cleared. Press Return to reconnect." : error,
        "arg": "", "valid": succeeded, "icon": ["path": "icon.png"],
      ]
    ]
  ]
}
