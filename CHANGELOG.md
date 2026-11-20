# Changelog

## Unreleased

- Store manually entered Client IDs and sign-in tokens in the local macOS Keychain and cache them in memory. Existing credential files transfer automatically after a verified write.
- Prompt for the Client ID directly in the mini player; remove environment-variable and shell-based setup.
- Clear Keychain sign-in with `spot reauth`, and prevent late token refreshes from restoring cleared credentials.
- Require certificate-backed signing for the player and launcher, with Hardened Runtime enabled.
- Report credential-storage errors instead of falling back to plaintext token files.

## v0.5.2

Fiat Lux
