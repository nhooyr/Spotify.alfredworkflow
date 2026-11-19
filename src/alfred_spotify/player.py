"""Spotify desktop playback. User text is passed as argv, never script source."""

import json
import subprocess

from .api import SpotifyError
from .metadata import URI

STATUS = """
function run() {
    var app = Application("com.spotify.client");
    if (!app.running()) return JSON.stringify({running: false});
    var result = {running: true, playing: app.playerState() === "playing"};
    try {
        var track = app.currentTrack();
        result.name = track.name();
        result.artist = track.artist();
        result.album = track.album();
        result.image = track.artworkUrl();
        result.uri = track.id();
    } catch (_) {}
    return JSON.stringify(result);
}
"""

ACTION = """
on run argv
    tell application id "com.spotify.client"
        set commandName to item 1 of argv
        if commandName is "toggle" then
            playpause
        else if commandName is "next" then
            next track
        else if commandName is "previous" then
            previous track
        else if commandName is "play" then
            if (count of argv) > 2 and item 3 of argv is not "" then
                play track (item 2 of argv) in context (item 3 of argv)
            else
                play track (item 2 of argv)
            end if
        end if
    end tell
end run
"""


def run(script, args=(), javascript=False):
    command = ["/usr/bin/osascript"]
    if javascript:
        command += ["-l", "JavaScript"]
    command += ["-e", script, "--", *args]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=4, check=False)
    except OSError, subprocess.TimeoutExpired:
        raise SpotifyError(
            "Spotify is not responding. Open the desktop app and try again."
        ) from None
    if result.returncode:
        if "1743" in result.stderr:
            raise SpotifyError(
                "Allow Alfred to control Spotify in Settings → Privacy & Security → Automation."
            )
        raise SpotifyError("Open the Spotify desktop app and try again.")
    return result.stdout.strip()


def status():
    try:
        return json.loads(run(STATUS, javascript=True))
    except (SpotifyError, ValueError) as error:
        return {"running": False, "message": str(error)}


def action(command, uri="", context=""):
    if command not in {"toggle", "next", "previous", "play"}:
        raise ValueError("Unknown playback command")
    if command == "play" and (not URI.fullmatch(uri) or (context and not URI.fullmatch(context))):
        raise ValueError("Invalid Spotify URI")
    run(ACTION, [command, uri, context])
