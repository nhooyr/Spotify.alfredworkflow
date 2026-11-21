import AppKit
import Darwin

let version = "v0.5.5-dev"
let buildIdentifier = String(cString: spotify_build_identifier())

private var delegate: PlayerDelegate!
private let args = CommandLine.arguments
if args.contains("--reauth-result") {
  let result = reauthFeedback(
    error: ProcessInfo.processInfo.environment["spotify_reauth_error"] ?? "")
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
  let result: JSONObject = [
    "alfredworkflow": ["arg": "", "variables": ["spotify_reauth_error": errorMessage]]
  ]
  print(String(decoding: try! jsonData(result), as: UTF8.self))
  exit(0)
}
if let index = args.firstIndex(of: "--write-metadata"), args.count > index + 2 {
  do {
    try writeWorkflowMetadata(
      URL(fileURLWithPath: args[index + 1]), stage: URL(fileURLWithPath: args[index + 2]))
    exit(0)
  } catch {
    fputs("\(error)\n", stderr)
    exit(1)
  }
}
if args.contains("--test-models") {
  runModelTests()
  exit(0)
}
if let index = args.firstIndex(of: "--test-integration") {
  let screenshot = args.count > index + 1 ? URL(fileURLWithPath: args[index + 1]) : nil
  runIntegrationTests(screenshot: screenshot)
  exit(0)
}

if args.contains("--validate-script") {
  if let error = SpotifyCommands().validate() {
    fputs("\(error)\n", stderr)
    exit(1)
  }
  print("Playback AppleScript compiled successfully.")
  exit(0)
}
if let index = args.firstIndex(of: "--relaunch-after"), args.count > index + 1,
  let pid = Int32(args[index + 1])
{
  for _ in 0..<400 {
    if kill(pid, 0) != 0 { break }
    usleep(10_000)
  }
}
if args.contains("--serve") || args.contains("--test-backend") || args.contains("--test-server")
  || args.contains("--snapshot") || args.contains("--relaunch-after")
{
  let app = NSApplication.shared
  let isolated =
    args.contains("--test-server") || args.contains("--test-backend") || args.contains("--snapshot")
  delegate = PlayerDelegate(
    testMode: args.contains("--test-server") || args.contains("--snapshot"),
    credentials: isolated ? testAuthorizationStore(root: workflowRoot()) : nil)
  app.delegate = delegate
  app.run()
} else {
  let command = args.contains("--state") ? "state" : args.contains("--hide") ? "hide" : "show"
  if let result = connectToPlayer(command), result["status"] as? String == "ok" {
    if command == "state",
      let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    {
      print(String(decoding: data, as: UTF8.self))
    }
    exit(0)
  }
  if command != "show" { exit(1) }
  do {
    // A lock makes two simultaneous hotkey presses start only one server.
    try secureSocketDirectory()
    let lockFD = open(
      socketDirectory + "/launch.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    if lockFD >= 0 { flock(lockFD, LOCK_EX) }
    defer {
      if lockFD >= 0 {
        flock(lockFD, LOCK_UN)
        Darwin.close(lockFD)
      }
    }
    for _ in 0..<50 {
      guard let state = connectToPlayer("state"), state["status"] as? String == "restart" else {
        break
      }
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
