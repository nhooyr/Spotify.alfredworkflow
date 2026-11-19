# Spotify

A Python Spotify workflow with a persistent native mini player in the style of
Alfred’s Music Mini Player: playback above, keyboard browsing on the left,
artwork on the right.

Requires **Alfred 6 with Powerpack**, **Python 3.14+**, and the **Spotify desktop app**.
No pip packages, PHP runtime, or separate installer. The export includes a small
Swift/AppKit window host and a tiny native hotkey launcher.

To force a new Spotify sign-in, run **`spotify reauth`** in Alfred. It clears
the saved login and pending connection, keeps your Client ID and Client Secret,
and opens sign-in the next time you launch the player.

## Install

Build with `./build.sh`, then open
`dist/Spotify.alfredworkflow` and import it into Alfred.
If Python is missing, install it with `brew install python`.

Type **`spotify`** in Alfred. On first use, connect your Spotify account as described
below. The workflow reuses music metadata and artwork already cached by the
Spotify desktop app; the first cache scan runs in the background.

The first launch starts the player. After that, the window, search data, artwork,
and Python library worker stay loaded. The keyword and hotkey send a local show
command; they do not start Python or rebuild the window. Escape, ⌘W,
and clicking outside hide the panel. It exits when Alfred exits and automatically
restarts after the workflow is reimported.

## Connect your library

The workflow settings are **Client ID** and **Client Secret**. New connections
use PKCE and need only the Client ID; the secret remains available for refreshing
connections imported from older builds.

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
   Set its redirect URI to **`http://127.0.0.1/spotify_callback`** (without a port)
   and enable the Web API. Each sign-in uses a dynamically assigned local port.
   Spotify requires a loopback IP address; `localhost` is not accepted.
2. Paste its Client ID into this workflow’s configuration. Keep an existing Client
   Secret if you are reusing an older saved connection.
3. Open `spotify`. Sign-in opens automatically when the Client ID is present.
   Approve access in your browser. The mini player returns automatically; the
   callback tab also attempts to close itself when the browser allows it.

The player shows connection progress and errors directly. Use **Connect** to
retry and the settings gear to open workflow configuration. The player stays on
the connection screen until authorization succeeds. Initial sign-in is automatic.
If you close the browser tab before finishing, reopen the player and choose
**Connect** to open a fresh sign-in tab. This recovery button disappears after
you connect successfully.

To set a global launch shortcut, open **Alfred Preferences → Workflows → Spotify**
and double-click the **Hotkey** object labelled **Launch Spotify
Mini Player**. Press your preferred key combination and save it. Press the same hotkey while the player is focused to open Spotify itself.
No shortcut is
pre-assigned, so importing the workflow does not replace another app’s hotkey.

Tokens refresh automatically. Spotify currently requires the owner of a
Development Mode app to have Premium. Additional users must be allowed in that
app’s dashboard. See Spotify’s [development-mode rules](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).
The workflow never asks for your Spotify password.

## Use

The home menu contains **Playlists**, **Albums**, **Artists**, and **Songs**, in
that order. Search results use the same priority. **Songs** lists your Liked Songs; choose a track and press Return to play it.

| Key | Action |
| --- | --- |
| `↑` / `↓` | Select a row and preview its artwork |
| `↩` | Browse the selection or play a track |
| `Esc` / `⌘W` | Hide the player, keeping it warm |
| `⌘1` … `⌘9` | Open one of the first nine rows |
| Type | Filter the current view; search cached music from the home view |
| `⌫` at the end of a folder path | Go up one folder |
| `⌘[` | Go back, or clear the current filter |
| `⌘↩` | Search the full Spotify catalog |
| `⌘R` | Refresh the desktop cache index and connected library |
| `⌘,` | Open workflow settings |
| `spotify reauth` in Alfred | Reset Spotify sign-in; reconnect on next open |
| `⌃⌘↓` | Play / pause |
| `⌃⌘←` / `⌃⌘→` | Previous / next track |

The **＋** beside the current song saves it to Liked Songs and becomes a green
checkmark when saved. Existing connections need **`spotify reauth`** once to grant
the new save permission. The shuffle button toggles shuffle on/off, with a green
icon and dot when enabled. The Spotify icon beside the settings gear opens the
desktop app. These controls keep browsing and typing responsive during requests.

Press **⌘Return** after typing a query to search the full Spotify catalog.
Local filtering runs inside the native panel and does not call the Web API. Playback uses the Spotify
desktop app and stays in the player. A configurable launch hotkey is available
in Alfred’s workflow editor.

## Cache behavior and limits

- Spotify’s desktop cache is **read-only**. A small SQLite index contains the
  names, Spotify URIs, and file offsets needed for browsing. The original HTTP
  cache is not copied. Only artwork that is displayed is extracted into a file
  Alfred can load; existing cached artwork is preferred over a download.
- Library membership comes from the public API after connecting. Previously
  cached metadata and artwork are reused to avoid unnecessary requests. The
  full library refreshes at most daily, or when you press `⌘R`.
- The adapter understands Chromium Simple Cache v5 and Spotify’s cached JSON
  and protobuf music metadata. Missing, evicted, truncated, or unknown formats
  fall back to available indexed data and the public API.
- Spotify’s current API only returns playlist contents to the owner or a
  collaborator. Other playlists can still be opened or played.
- Client credentials stay in Alfred’s local workflow configuration. OAuth tokens
  are in a user-only file in this workflow’s data folder. Neither is included
  in the built workflow. The callback listens only on `127.0.0.1`, validates
  OAuth state and a per-sign-in PKCE proof, and closes after completion or three minutes.

The workflow does not read Spotify cookies, extract login tokens, or download
or decrypt cached audio. It calls only the public Spotify Web API and public
artwork URLs; private endpoints are read from existing cache files only.

The workflow bundle ID is `ca.aqsnow.alfred.spotify`. Its icon is reused from
the Spotify desktop app; Spotify owns the icon and associated trademarks.

On first launch, the workflow imports data, privately saved credentials, and cache
from `com.aqsnow.alfred.spotify`, then `com.aqsnow.alfred-spotify` or the original
`io.nhooyr.alfred-spotify` build if newer sources are absent. Current settings
from the source workflow take precedence over previously imported credentials. It reuses authorization, the SQLite index,
and cached artwork without overwriting newer files or deleting the originals.
Old sessions and lock files are skipped. This happens once, so clearing your
connection later cannot restore the old authorization. A cleared connection in
the newest source also takes precedence over any older authorization. Imported
connections keep using their original refresh method; new sign-ins use PKCE.

Credentials copied from your old workflow are kept in the workflow’s private
data folder and fill empty settings on the first launch after import. They are
never included in the source repository or exported workflow.

## Development

```sh
PYTHONPATH=src python3 -m unittest discover -s tests -v
./build.sh
```

Python library and authentication code: `src/alfred_spotify`. The persistent
window and in-memory playback script are in `native/Player.swift`; the show-only
hotkey client is `native/launcher.c`. Building requires Xcode Command Line Tools.
`./build.sh` compiles universal Apple Silicon/Intel binaries into a temporary
directory and packages them directly into `dist/Spotify.alfredworkflow`.

Tests use temporary data and synthetic cache entries; they do not control
playback, log in, or modify Spotify’s files. `scripts/test-native.py` checks the
actual native IPC and lifecycle with a hidden test panel and a disposable parent
process, without controlling Alfred or Spotify.

UI reference: [Alfred Music Mini Player](https://www.alfredapp.com/help/features/music/)
and [Alfred UI](https://www.alfredapp.com/help/alfredui/).
Cache format reference: [Chromium Simple Cache](https://chromium.googlesource.com/chromium/src/net/+/refs/heads/main/disk_cache/simple/simple_entry_format.h).
Metadata field reference: [librespot metadata.proto](https://github.com/librespot-org/librespot/blob/dev/protocol/proto/metadata.proto).
