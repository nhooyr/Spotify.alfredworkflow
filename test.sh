#!/bin/sh
set -eu
cd "$(dirname "$0")"
work="$(mktemp -d /private/tmp/spotify-tests.XXXXXX)"
trap 'rm -rf "$work"' 0
ditto -x -k dist/Spotify.alfredworkflow "$work"
player="$work/Spotify Mini Player.app/Contents/MacOS/SpotifyMiniPlayer"
"$player" --validate-script
"$player" --test-models
SPOTIFY_TEST_SCREENSHOT="${SPOTIFY_TEST_SCREENSHOT:-/private/tmp/spotify-native-panel.png}" "$player" --test-integration
