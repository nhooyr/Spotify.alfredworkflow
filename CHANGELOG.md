# Changelog

## v0.7.0

- Keep Web API playback controls on Spotify’s active output device.
- Speed up album browsing, local search, menu navigation and artwork cache updates.
- Keep menu rows and selection highlighting steady while scrolling with the Up/Down keys.
- Keep Command–1 through Command–9, Command–0 and Command–Minus aligned with all visible rows and support Fn–Up/Fn–Down paging.
- Detect desktop playback immediately while play requests are pending, without reverting to the previous song or playlist.
- Show the selected song, album, artist or playlist type in artwork captions.
- Preserve typed path casing and insert lowercase browsing paths automatically.
- Use Liked Songs throughout the menus, with preferred `liked songs/` paths, existing `songs/` aliases and the same heart cover for matching playlist entries.
- Keep the now-playing header stable through incomplete metadata and empty Spotify playback-state replies.
- Add secure timestamps to Developer ID signatures for distribution.
- Show release versions with a single v prefix in Alfred.
- Signed release binaries, with optional notarization via `build.sh --notarize`.
- Prevent macOS’s “damaged app” warning when importing notarized releases into Alfred.
- Fall back to AppleScript for play/pause when Spotify supplies no playback state.

## v0.6.2

- Keep Alfred command results and workflow blocks in README order.
- Use `spot mini` to open the mini player without conflicting with the Spotify app.
- Keep Spotify’s sync indicator steady between startup requests.
- Add `spot quit` and Command–Q to stop the mini player and start fresh on its next launch.

## v0.6.1

- Restore README badges while keeping them out of Alfred’s embedded help.

## v0.6.0

- Support development version tags while keeping macOS bundle versions numeric.
- Minor Player.swift fix.

## v0.5.4

- Proper main.swift entrypoint instead of build shenanigans.
- GitHub Actions CI.
- Dismiss Alfred before showing either demo mode state.
- Prevent system input popups during demo toggles. Toggling off keeps the player open in normal mode; Escape hides it and resets demo mode.
- Remove deprecated Keychain APIs from the credential test fixture.
- README.md: Minor fixes

## v0.5.3

- Remove obsolete migration code and keep the workflow graph in its source template.
- Speed up local search and avoid rebuilding superseded catalogues or reparsing unchanged themes.
- Share concurrent cover downloads and keep cached artwork responsive during library sync.

- Store manually entered Client IDs and sign-in tokens in the local macOS Keychain and cache them in memory.
- Remove environment-variable and shell-based setup for SPOTIFY_CLIENT_ID.
- Clear Keychain sign-in with `spot reauth`, and prevent late token refreshes from restoring cleared credentials.
- Require certificate-backed signing for the player and launcher, with Hardened Runtime enabled.
- Report credential-storage errors instead of falling back to plaintext token files.

## v0.5.2

Fiat Lux
