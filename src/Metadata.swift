import Foundation

func writeWorkflowMetadata(_ root: URL, stage: URL) throws {
    let original = try Data(contentsOf: root.appendingPathComponent("workflow/info.plist"))
    var workflow = try PropertyListSerialization.propertyList(from: original, format: nil) as! JSONObject
    workflow["version"] = workflowVersion
    workflow["readme"] = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
    var objects = workflow["objects"] as! [JSONObject]
    for i in objects.indices where text(objects[i]["uid"]) == "CLEAR_ACTION" {
        var config = dict(objects[i]["config"])
        config["script"] = "exec './Spotify Mini Player.app/Contents/MacOS/SpotifyMiniPlayer' --clear-connection"
        objects[i]["config"] = config
    }
    objects.removeAll { text($0["uid"]) == "CLEAR_NOTICE" || text($0["uid"]) == "REAUTH_RESULT" }
    objects.append(["uid": "REAUTH_RESULT", "type": "alfred.workflow.input.scriptfilter", "version": 3,
                    "config": ["argumenttype": 1, "withspace": false, "alfredfiltersresults": false,
                               "script": "exec './Spotify Mini Player.app/Contents/MacOS/SpotifyMiniPlayer' --reauth-result",
                               "type": 0, "scriptargtype": 1, "escaping": 0, "queuedelaymode": 0,
                               "queuedelayimmediatelyinitially": true, "queuemode": 1,
                               "title": "Open Spotify Mini Player", "runningsubtext": ""]])
    let commands = [("like", "Like current song"), ("unlike", "Unlike current song"),
                    ("shuffle", "Turn shuffle on"), ("sequential", "Turn shuffle off"),
                    ("screenshot", "Toggle screenshot mode")]
    let commandIDs = Set(commands.flatMap { ["COMMAND_" + $0.0.uppercased(), "ACTION_" + $0.0.uppercased()] })
    objects.removeAll { commandIDs.contains(text($0["uid"])) }
    var connections = workflow["connections"] as? [String: Any] ?? [:]
    var layout = workflow["uidata"] as? [String: Any] ?? [:]
    connections.removeValue(forKey: "CLEAR_NOTICE")
    layout.removeValue(forKey: "CLEAR_NOTICE")
    connections["REAUTH"] = [["destinationuid": "CLEAR_ACTION", "modifiers": 0, "modifiersubtext": "", "vitoclose": false]]
    connections["CLEAR_ACTION"] = [["destinationuid": "REAUTH_RESULT", "modifiers": 0, "modifiersubtext": "", "vitoclose": false]]
    connections["REAUTH_RESULT"] = [["destinationuid": "PLAYER", "modifiers": 0, "modifiersubtext": "", "vitoclose": true]]
    layout["REAUTH_RESULT"] = ["xpos": 510, "ypos": 340]
    for (index, command) in commands.enumerated() {
        let input = "COMMAND_" + command.0.uppercased(), action = "ACTION_" + command.0.uppercased()
        objects.append(["uid": input, "type": "alfred.workflow.input.keyword", "version": 1,
                        "config": ["keyword": "spotify " + command.0, "argumenttype": 2,
                                   "withspace": false, "text": command.1, "subtext": command.0 == "screenshot" ? "Keep the mini player visible for screenshots; Esc exits" : "Set the current playback state"]])
        objects.append(["uid": action, "type": "alfred.workflow.action.script", "version": 2,
                        "config": ["script": "exec ./show --" + command.0, "type": 0,
                                   "scriptargtype": 1, "scriptfile": "", "escaping": 0, "concurrently": true]])
        connections[input] = [["destinationuid": action, "modifiers": 0, "modifiersubtext": "", "vitoclose": true]]
        layout[input] = ["xpos": 50, "ypos": 550 + index * 130]
        layout[action] = ["xpos": 280, "ypos": 550 + index * 130]
    }
    workflow["connections"] = connections
    workflow["uidata"] = layout
    workflow["objects"] = objects
    if var settings = workflow["userconfigurationconfig"] as? [JSONObject] {
        for i in settings.indices where text(settings[i]["variable"]) == "SPOTIFY_CLIENT_SECRET" {
            settings[i]["description"] = "Optional. PKCE sign-in does not require it."
        }
        workflow["userconfigurationconfig"] = settings
    }
    try PropertyListSerialization.data(fromPropertyList: workflow, format: .xml, options: 0).write(to: stage.appendingPathComponent("info.plist"))
    let app: JSONObject = ["CFBundleIdentifier": workflowID + ".player", "CFBundleName": "Spotify Mini Player", "CFBundleDisplayName": "Spotify Mini Player", "CFBundleExecutable": "SpotifyMiniPlayer", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": workflowVersion, "CFBundleVersion": workflowVersion, "LSUIElement": true, "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": true, "NSAppleEventsUsageDescription": "Control playback in the Spotify desktop app.", "CFBundleIconFile": "icon.png"]
    try PropertyListSerialization.data(fromPropertyList: app, format: .xml, options: 0).write(to: stage.appendingPathComponent("Spotify Mini Player.app/Contents/Info.plist"))
}

func reauthFeedback(error: String = "") -> JSONObject {
    let succeeded = error.isEmpty
    return ["items": [["title": succeeded ? "Open Spotify Mini Player" : "Could not clear Spotify sign-in",
                       "subtitle": succeeded ? "Sign-in cleared. Press Return to sign in again." : error,
                       "arg": "", "valid": succeeded, "icon": ["path": "icons/spotify.png"]]]]
}
