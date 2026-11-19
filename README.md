# Spotify

A Python Spotify workflow in the style of Alfred’s built-in Music Mini Player:
playback above, keyboard browsing on the left, artwork on the right.

Requires **Alfred 6 with Powerpack**, **Python 3.14+**, and the **Spotify desktop app**.
No pip packages, PHP runtime, background service, or separate installer.

**[Clear Connection](alfred://runtrigger/com.aqsnow.alfred.spotify/clear-connection/)**
clears saved authorization and pending sign-in. Your Client ID and Client Secret
stay configured. The browser opens for a fresh sign-in the next time you launch
the player. This action is also available here in **Configure Workflow**.

## Install

Build with `./build.sh`, then open
`dist/Spotify.alfredworkflow` and import it into Alfred.
If Python is missing, install it with `brew install python`.

Type **`spotify`** in Alfred. On first use, connect your Spotify account as described
below. The workflow reuses music metadata and artwork already cached by the
Spotify desktop app; the first cache scan runs in the background.

## Connect your library

There are just two workflow settings: **Client ID** and **Client Secret**.

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
   Set its redirect URI to **`http://127.0.0.1/spotify_callback`** (without a port)
   and enable the Web API. Each sign-in uses a dynamically assigned local port.
   Spotify requires a loopback IP address; `localhost` is not accepted.
2. Paste its Client ID and Client Secret into this workflow’s configuration.
3. Open `spotify`. Sign-in opens automatically when both credentials are present.
   Approve access in your browser, then return to Alfred.

Missing credentials open a setup screen. A failed or cancelled sign-in shows an
error with **Try Again** and **Workflow Settings** actions. The player stays on
the connection screen until authorization succeeds. Initial sign-in is automatic.
If you close the browser tab before finishing, reopen the player and choose
**Connect** to open a fresh sign-in tab. This recovery button disappears after
you connect successfully.

To set a global launch shortcut, open **Alfred Preferences → Workflows → Spotify**
and double-click the **Hotkey** object labelled **Launch Spotify
Mini Player**. Press your preferred key combination and save it. No shortcut is
pre-assigned, so importing the workflow does not replace another app’s hotkey.

Tokens refresh automatically. Spotify currently requires the owner of a
Development Mode app to have Premium. Additional users must be allowed in that
app’s dashboard. See Spotify’s [development-mode rules](https://developer.spotify.com/documentation/web-api/concepts/quota-modes).
The workflow never asks for your Spotify password.

## Use

| Key | Action |
| --- | --- |
| `↑` / `↓` | Select a row and preview its artwork |
| `↩` | Browse the selection or play a track |
| `⌘1` … `⌘9` | Open one of the first nine rows |
| Type | Filter the current view; search cached music from the home view |
| `⌫` at the end of a folder path | Go up one folder |
| `⌘[` | Go back, or clear the current filter |
| `⌘R` | Refresh the desktop cache index and connected library |
| `⌘,` | Open workflow settings |
| `⌃⌘↓` | Play / pause |
| `⌃⌘←` / `⌃⌘→` | Previous / next track |

Use **Search Spotify for …** at the end of home search results to search the
full catalog. Local searches do not call the Web API. Playback uses the Spotify
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
- Spotify no longer supplies genres in its desktop metadata. Genres appear only
  when your followed-artist API responses contain them; unavailable tags are
  not invented. Star ratings are not supported by Spotify.
- Spotify’s current API only returns playlist contents to the owner or a
  collaborator. Other playlists can still be opened or played.
- Client credentials stay in Alfred’s local workflow configuration. OAuth tokens
  are in a user-only file in this workflow’s data folder. Neither is included
  in the built workflow. The callback listens only on `127.0.0.1`, validates
  OAuth state, and closes after completion or three minutes.

The workflow does not read Spotify cookies, extract login tokens, or download
or decrypt cached audio. It calls only the public Spotify Web API and public
artwork URLs; private endpoints are read from existing cache files only.

The workflow bundle ID is `com.aqsnow.alfred.spotify`. Its icon is reused from
the Spotify desktop app; Spotify owns the icon and associated trademarks.

On first launch, the workflow imports data, privately saved credentials, and cache
from `com.aqsnow.alfred-spotify`, or from the original `io.nhooyr.alfred-spotify`
build if the newer source is absent. It reuses authorization, the SQLite index,
and cached artwork without overwriting newer files or deleting the originals.
Old sessions and lock files are skipped. This happens once, so clearing your
connection later cannot restore the old authorization. A cleared connection in
the newest source also takes precedence over any older authorization.

Credentials copied from your old workflow are kept in the workflow’s private
data folder and fill empty settings on the first launch after import. They are
never included in the source repository or exported workflow.

## Development

```sh
PYTHONPATH=src python3 -m unittest discover -s tests -v
./build.sh
```

Source: `src/alfred_spotify`. The native UI and workflow metadata are generated
by `scripts/build.py`. `workflow/Spotify.alfredui/run` resolves Python without
depending on shell startup files. Tests use temporary data and synthetic cache
entries; they do not control playback, log in, or modify Spotify’s files.

UI reference: [Alfred Music Mini Player](https://www.alfredapp.com/help/features/music/)
and [Alfred UI](https://www.alfredapp.com/help/alfredui/).
Cache format reference: [Chromium Simple Cache](https://chromium.googlesource.com/chromium/src/net/+/refs/heads/main/disk_cache/simple/simple_entry_format.h).
Metadata field reference: [librespot metadata.proto](https://github.com/librespot-org/librespot/blob/dev/protocol/proto/metadata.proto).
