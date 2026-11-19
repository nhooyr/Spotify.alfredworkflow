# Development

The workflow uses C and Swift, with no interpreter or package installation at runtime.
Build with `./build.sh` using Xcode Command Line Tools. The universal macOS app and
C launcher are packaged directly into `dist/Spotify.alfredworkflow`; intermediate
files live in a temporary directory. Set `workflowVersion` in `src/version.swift`
for a release. Run `./test.sh` to check the exported build.

`src/Player.swift` owns the persistent AppKit panel. `src/Backend.swift` keeps
library navigation and I/O off the main thread. Storage, the public Spotify API,
PKCE sign-in, and the read-only desktop cache adapter are in the other Swift files.
The small C launcher sends a Unix socket message to show the existing window.
It does not start the application again on each hotkey press.

The cache adapter reads Chromium cache entries and the playlist-root record in
Spotify’s immutable LevelDB tables and complete journal records. It never opens
Spotify’s database for writing. The saved playlist root supplies custom order;
the public API supplies membership and missing metadata. Existing workflow tokens,
SQLite data, and extracted covers retain their paths and formats.

Sign-in and token refresh use PKCE. Credentials come from the Workflow’s
Configuration; the app does not import data from other workflows.

`src/vendor/zstddeclib.c` is the decoder-only amalgamation from Zstandard v1.5.7,
used for compressed desktop cache entries. Its BSD license is included in the
source and exported workflow. Other native dependencies are macOS system libraries.

Tests use temporary files, a mock HTTPS transport, and hidden native panels.
They do not operate Alfred or Spotify or change the user’s library.

File-based icons live in `workflow/icons`. The build generates the copies required
by Alfred and the app bundle. Player controls use Apple’s SF Symbols and native vector paths for the extended
repeat arrows and selection indicator, drawn at the display’s native resolution.

Catalogue normalization and sorting run off the UI thread. Typing narrows the
previous results when possible, retaining the same Unicode matching and category
order. Cover images decode off-thread at up to 512 pixels and are cached for reuse.
Playback commands have their own queue so status polling cannot delay them.
Automatic refreshes are coalesced for 30 seconds and only rebuild the catalogue
when data changes; ⌘R always forces a refresh.

Custom Alfred themes supply the native panel’s colours, opacity, corner radii,
scrollbar, and font families. The mini-player layout keeps its own sizes. Built-in
themes fall back to Alfred’s exported background and selection colours with
contrasting text. Theme changes are checked when opening and while visible;
active playback controls keep Spotify green.
