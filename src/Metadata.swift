import Foundation

func writeWorkflowMetadata(_ root: URL, stage: URL) throws {
    let original = try Data(contentsOf: root.appendingPathComponent("workflow/info.plist"))
    var workflow = try PropertyListSerialization.propertyList(from: original, format: nil) as! JSONObject
    workflow["version"] = workflowVersion
    workflow["readme"] = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
    var settings = workflow["userconfigurationconfig"] as? [JSONObject] ?? []
    settings.removeAll { ["SPOTIFY_CLIENT_ID", "keyword"].contains(text($0["variable"])) }
    var variables = dict(workflow["variables"])
    variables.removeValue(forKey: "SPOTIFY_CLIENT_ID")
    workflow["variables"] = variables
    workflow["variablesdontexport"] = (workflow["variablesdontexport"] as? [String] ?? []).filter { $0 != "SPOTIFY_CLIENT_ID" }
    settings.append(["variable": "keyword", "label": "Keyword", "type": "textfield",
                     "description": "Shared prefix for every command. Set to spotify if you prefer.",
                     "config": ["default": defaultWorkflowKeyword, "placeholder": "", "required": false, "trim": true]])
    workflow["userconfigurationconfig"] = settings
    var objects = workflow["objects"] as! [JSONObject]
    for i in objects.indices where text(objects[i]["uid"]) == "HOTKEY" {
        var config = dict(objects[i]["config"])
        config["hotkey"] = 49; config["hotmod"] = 1310720; config["hotstring"] = "Space"
        config["action"] = 0; config["argument"] = 0; config["modsmode"] = 2
        config["relatedAppsMode"] = 0; config.removeValue(forKey: "relatedApps")
        objects[i]["config"] = config
    }
    for i in objects.indices where text(objects[i]["uid"]) == "HOTKEY_PLAYER" {
        var config = dict(objects[i]["config"]); config["script"] = "exec ./show --hotkey"
        objects[i]["config"] = config
    }
    for i in objects.indices where ["OPEN", "REAUTH"].contains(text(objects[i]["uid"])) {
        var config = dict(objects[i]["config"])
        config["keyword"] = "{var:keyword}" + (text(objects[i]["uid"]) == "REAUTH" ? " reauth" : "")
        if text(objects[i]["uid"]) == "REAUTH" {
            config["text"] = "Reset Spotify Sign-In to Reauthorize"
            config["subtext"] = "Clear sign-in and Client ID; reconnect on next open"
        }
        objects[i]["config"] = config
    }
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
    let commands = [("like", "like", "Like current song"), ("unlike", "unlike", "Unlike current song"),
                    ("shuffle", "shuf", "Turn shuffle on"), ("noshuffle", "noshuf", "Turn shuffle off"),
                    ("screenshot", "demo", "Toggle demo mode"), ("refresh", "refresh", "Refresh music library")]
    let commandIDs = Set(commands.flatMap { ["COMMAND_" + $0.0.uppercased(), "ACTION_" + $0.0.uppercased()] })
    objects.removeAll { commandIDs.contains(text($0["uid"])) }
    var connections = workflow["connections"] as? [String: Any] ?? [:]
    var layout = workflow["uidata"] as? [String: Any] ?? [:]
    connections.removeValue(forKey: "CLEAR_NOTICE")
    layout.removeValue(forKey: "CLEAR_NOTICE")
    connections["REAUTH"] = [["destinationuid": "CLEAR_ACTION", "modifiers": 0, "modifiersubtext": "", "vitoclose": false]]
    connections["CLEAR_ACTION"] = [["destinationuid": "REAUTH_RESULT", "modifiers": 0, "modifiersubtext": "", "vitoclose": false]]
    connections["REAUTH_RESULT"] = [["destinationuid": "PLAYER", "modifiers": 0, "modifiersubtext": "", "vitoclose": true]]
    for command in commands {
        let input = "COMMAND_" + command.0.uppercased(), action = "ACTION_" + command.0.uppercased()
        objects.append(["uid": input, "type": "alfred.workflow.input.keyword", "version": 1,
                        "config": ["keyword": "{var:keyword} " + command.1, "argumenttype": 2,
                                   "withspace": false, "text": command.2, "subtext": command.0 == "screenshot" ? "Keep the mini player visible for screenshots; Esc exits" : command.0 == "refresh" ? "Refresh the desktop cache index and connected library" : "Set the current playback state"]])
        objects.append(["uid": action, "type": "alfred.workflow.action.script", "version": 2,
                        "config": ["script": "exec ./show --" + command.0, "type": 0,
                                   "scriptargtype": 1, "scriptfile": "", "escaping": 0, "concurrently": true]])
        connections[input] = [["destinationuid": action, "modifiers": 0, "modifiersubtext": "", "vitoclose": true]]
    }
    var launchLayout = dict(layout["HOTKEY"])
    launchLayout["xpos"] = 50; launchLayout["ypos"] = 20
    launchLayout["note"] = "Launch Spotify Mini Player — global\nDefault: ⌃⌘Space; press again in the player to open Spotify"
    layout["HOTKEY"] = launchLayout
    layout["HOTKEY_PLAYER"] = ["xpos": 300, "ypos": 20]
    layout["PLAYER"] = ["xpos": 300, "ypos": 220]
    layout["OPEN"] = ["xpos": 50, "ypos": 220]
    layout["REAUTH"] = ["xpos": 50, "ypos": 360]
    layout["CLEAR_ACTION"] = ["xpos": 300, "ypos": 360]
    layout["REAUTH_RESULT"] = ["xpos": 550, "ypos": 360]
    var resetLayout = dict(layout["CLEAR_CONNECTION"])
    resetLayout["ypos"] = 460
    layout["CLEAR_CONNECTION"] = resetLayout
    for (index, command) in commands.enumerated() {
        layout["COMMAND_" + command.0.uppercased()] = ["xpos": 50, "ypos": 540 + index * 130]
        layout["ACTION_" + command.0.uppercased()] = ["xpos": 300, "ypos": 540 + index * 130]
    }
    workflow["connections"] = connections
    workflow["uidata"] = layout
    workflow["objects"] = objects
    try PropertyListSerialization.data(fromPropertyList: workflow, format: .xml, options: 0).write(to: stage.appendingPathComponent("info.plist"))
    let app: JSONObject = ["CFBundleIdentifier": workflowID + ".player", "CFBundleName": "Spotify Mini Player", "CFBundleDisplayName": "Spotify Mini Player", "CFBundleExecutable": "SpotifyMiniPlayer", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": workflowVersion, "CFBundleVersion": workflowVersion, "LSUIElement": true, "LSMinimumSystemVersion": "13.0", "NSHighResolutionCapable": true, "NSAppleEventsUsageDescription": "Control playback in the Spotify desktop app.", "CFBundleIconFile": "icon.png"]
    try PropertyListSerialization.data(fromPropertyList: app, format: .xml, options: 0).write(to: stage.appendingPathComponent("Spotify Mini Player.app/Contents/Info.plist"))
}

func reauthFeedback(error: String = "") -> JSONObject {
    let succeeded = error.isEmpty
    return ["items": [["title": succeeded ? "Open Spotify Mini Player" : "Could not clear Spotify sign-in",
                       "subtitle": succeeded ? "Sign-in and Client ID cleared. Press Return to reconnect." : error,
                       "arg": "", "valid": succeeded, "icon": ["path": "icon.png"]]]]
}
