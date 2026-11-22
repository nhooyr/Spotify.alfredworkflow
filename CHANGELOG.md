# Changelog

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
