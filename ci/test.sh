#!/bin/sh
set -eu

usage() {
	cat <<'EOF'
Usage: ci/test.sh [-h | --help] [--] [WORKFLOW]

Validate an exported workflow and run its model and native UI integration tests.
WORKFLOW defaults to dist/Spotify.alfredworkflow in the project directory.
EOF
}

case ${1-} in
-h | --help)
	usage
	exit 0
	;;
--) shift ;;
-*)
	usage >&2
	exit 2
	;;
esac
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ -z "$1" ]; }; then
	usage >&2
	exit 2
fi
workflow=${1-dist/Spotify.alfredworkflow}
if [ "$#" -eq 1 ]; then
	case $workflow in /*) ;; *) workflow=$PWD/$workflow ;; esac
fi
cd "$(dirname "$0")/.."

if [ "${GITHUB_ACTIONS-}" ]; then
	brew install --cask spotify
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Spotify.app
fi
if [ ! -f "$workflow" ]; then
	printf 'Workflow not found: %s\n' "$workflow" >&2
	exit 1
fi
work=$(mktemp -d /private/tmp/spotify-tests.XXXXXX)
trap 'rm -rf "$work"' 0
ditto -x -k "$workflow" "$work"
player="$work/Spotify Mini Player.app/Contents/MacOS/SpotifyMiniPlayer"
"$player" --validate-script
"$player" --test-models
screenshot=$(mktemp -d)/alfred-spotify-native-panel.png
"$player" --test-integration "$screenshot"
printf 'Screenshot: %s\n' "$screenshot"
