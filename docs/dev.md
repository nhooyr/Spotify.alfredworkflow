# Development

The workflow uses C and Swift, with no interpreter or package installation at runtime.
Build with `./build.sh` using Xcode Command Line Tools and an installed code-signing
identity (create one in Xcode → Settings → Accounts → Manage Certificates). The universal macOS app and
C launcher are packaged into `dist/Spotify.alfredworkflow`, or the output file passed
as the first argument. Its parent directories are created automatically.
Run `./test.sh [WORKFLOW]` to check an export. Both scripts support `-h` and `--help`.

Native binaries are cached in `~/Library/Caches/ca.aqsnow.alfred.spotify/build`.
Source, build-script, compiler, or SDK changes invalidate the binaries. Documentation,
images, and workflow configuration are always repackaged without recompiling.
Delete the cache directory to force a clean build. Other intermediate files live
in a temporary directory.

The build signs the app and launcher with an available Developer ID Application
identity, otherwise an Apple Development identity. It requires certificate-backed
signing; ad hoc signing is not used. Both executables enable Hardened Runtime;
only the app receives the Apple Events entitlement needed to control Spotify.
Keep the same signing identity across builds so Keychain recognizes app updates.

`workflow/info.plist` is a source template. The build inserts the staged README
and the version into the exported plist without changing the template. Set
`workflowVersion` in `src/version.swift` for a release.

`src/Player.swift` owns the persistent AppKit panel. `src/Backend.swift` keeps
library navigation and I/O off the main thread. Storage, the public Spotify API,
PKCE sign-in, and the read-only desktop cache adapter are in the other Swift files.
The small C launcher sends a Unix socket message to show the existing window.
It does not start the application again on each hotkey press.

The cache adapter reads Chromium metadata and images, plus playlist snapshots,
track metadata, and the playlist root in Spotify’s immutable LevelDB tables and
complete journal records. It reads only the needed key ranges and never writes to
or locks Spotify’s database. The saved playlist root supplies custom order; the
public API supplies library membership. Local results are published before network
refreshes, and expired browse results remain usable offline. Covers are copied
into the workflow cache before Spotify can evict them; a background pass fetches
missing images when online. Playback stays in Spotify’s desktop app, which owns
the downloaded audio. Existing tokens and cache formats retain their paths.
An hourly maintenance check removes old, unreferenced workflow artwork only if
our cache exceeds 1 GB. Saved and downloaded-library covers and art used within
the last day are protected, so the size limit is deliberately soft. Spotify’s
cache is never cleaned or modified.

Manually entered Client IDs, access and refresh tokens, their expiry and scopes live in
a local, non-synchronizing macOS Keychain item. Its access controls trust only the
signed player app. One shared, locked memory cache serves warm credential reads;
network replies cannot restore a sign-in cleared while the request was running.
Storage failures remain visible and never fall back to credential files. Reauth
deletes the Keychain item while retaining library metadata and artwork.

Sign-in and token refresh use PKCE. The mini player prompts for a Spotify Client ID
when its Keychain item has no saved ID. Manually entered IDs persist in Keychain
before browser authorization; environment variables and shell configuration are
never consulted. Setup and Keychain access stay off the UI thread. Reauth clears
sign-in and the Client ID; the next open prompts again. Artwork, saved library
membership, playlist order, and cached browse results are retained even if Spotify
rate limits the next refresh. Only a confirmed change of Spotify account clears
account-specific library state; refreshes replace membership only after every
page succeeds. Resetting sign-in cancels an in-flight library refresh.
Unregistered Client IDs are checked with a deliberately unissued PKCE grant before
opening the browser. Failed sign-in attempts clear the ID and return to the inline
prompt. The app does not import data from other workflows.

`src/vendor/zstddeclib.c` is the decoder-only amalgamation from Zstandard v1.5.7,
used for compressed desktop cache entries. Its BSD license is included in the
source and exported workflow. Other native dependencies are macOS system libraries.

Tests use temporary files, memory credential stores, a uniquely named temporary
Keychain item containing dummy credentials, a mock HTTPS transport, and native panels.
The temporary item is deleted after the test; the real Spotify sign-in is untouched.
They do not operate Alfred or Spotify or change the user’s library. The integration
screenshot is saved as `alfred-spotify-native-panel.png` in a new temporary directory;
`test.sh` prints its path.

File-based icons live in `workflow`. The build generates the copies required
by Alfred and the app bundle. Player controls use Apple’s SF Symbols and native vector paths for the extended
repeat arrows and selection indicator, drawn at the display’s native resolution.

Catalogue normalization and sorting run off the UI thread; superseded work is
cancelled instead of delaying the latest library state. Typing narrows previous
results, with a byte-prefix fast path for ASCII and full Unicode matching elsewhere.
Theme preferences are decoded only when their files change. Cover images decode
off-thread at up to 512 pixels and are cached for reuse. Concurrent requests for
one cover share its download; local cache hits never wait for the library database.
Playback commands have their own queue so status polling cannot delay them.
Selections use the Web API with this Mac’s cached device ID. Spotify starts in
the background when needed; a cold launch waits briefly for its Connect device.
Offline playback, unavailable desktop devices, and service outages fall back to
AppleScript, which may bring Spotify forward. Superseded selections cancel their
requests. Accessibility and clipboard automation are not used.
The same playback-state request refreshes repeat mode and the header’s source
label. Names come from existing metadata or a cached background lookup; source
metadata on browse rows lets offline selections update the label immediately.
Automatic refreshes are coalesced for 30 seconds and only rebuild the catalogue
when data changes; ⌘R always forces a refresh. Actual API requests share an activity
counter across library sync, catalogue search, playback, and sign-in. The bottom-left
footer debounces brief requests and bridges gaps between pages to avoid flicker;
cached responses and requests blocked by a cooldown produce no activity. Offline
state takes precedence, and errors remain visible beside the activity label.

Custom Alfred themes supply the native panel’s colours, opacity, corner radii,
scrollbar, and font families. The mini-player layout keeps its own sizes. Built-in
themes fall back to Alfred’s exported background and selection colours with
contrasting text. Theme changes are checked when opening and while visible;
active playback controls keep Spotify green.

The bundled Liked Songs cover in `workflow/spotify-liked-songs.png` comes from
[Spotify’s public collection artwork](https://misc.scdn.co/liked-songs/liked-songs-640.png)
and is available offline without duplicating it in the artwork cache.

Only the launch Hotkey is configurable in Alfred. Playback, refresh, navigation,
and Option–Return shortcuts are handled directly by the focused native panel.
The panel reads the launch binding from `info.plist` to support pressing it again
to open Spotify. Playback events target Spotify directly. Switching Spaces hides
the window without destroying it; the next launch shows the same warm panel in
the current Space.
