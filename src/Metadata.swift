import Foundation

func writeWorkflowMetadata(_ root: URL, stage: URL) throws {
  let original = try Data(contentsOf: root.appendingPathComponent("workflow/info.plist"))
  var workflow =
    try PropertyListSerialization.propertyList(from: original, format: nil) as! JSONObject
  workflow["version"] = workflowVersion
  workflow["readme"] = try String(
    contentsOf: stage.appendingPathComponent("README.md"), encoding: .utf8)
  try PropertyListSerialization.data(fromPropertyList: workflow, format: .xml, options: 0).write(
    to: stage.appendingPathComponent("info.plist"))
  let app: JSONObject = [
    "CFBundleIdentifier": workflowID + ".player", "CFBundleName": "Spotify Mini Player",
    "CFBundleDisplayName": "Spotify Mini Player", "CFBundleExecutable": "SpotifyMiniPlayer",
    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": workflowVersion,
    "CFBundleVersion": workflowVersion, "LSUIElement": true, "LSMinimumSystemVersion": "13.0",
    "NSHighResolutionCapable": true,
    "NSAppleEventsUsageDescription": "Control playback in the Spotify desktop app.",
    "CFBundleIconFile": "icon.png",
  ]
  try PropertyListSerialization.data(fromPropertyList: app, format: .xml, options: 0).write(
    to: stage.appendingPathComponent("Spotify Mini Player.app/Contents/Info.plist"))
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
