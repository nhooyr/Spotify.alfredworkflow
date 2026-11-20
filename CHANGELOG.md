# Changelog

## Staging (v0.5.4)

- Keep the active search editor when toggling demo on but toggling demo off now resets and hides the player exactly like Escape.
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
