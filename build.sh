#!/bin/sh
set -eu

usage() {
	cat <<'EOF'
Usage: build.sh [-h | --help] [--test] [--] [OUTPUT]

Build the universal Spotify.alfredworkflow using Xcode Command Line Tools
and an Apple Development or Developer ID Application signing identity.
OUTPUT defaults to dist/Spotify.alfredworkflow in the project directory.
Parent directories are created automatically.
Use --test for an ad hoc signed test export without a certificate or Finder reveal.

Native binaries are cached in ~/Library/Caches/ca.aqsnow.alfred.spotify/build.
EOF
}

test_build=false
if [ "${1-}" = --test ]; then
	test_build=true
	shift
fi
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
output_display=${1-dist/Spotify.alfredworkflow}
output=$output_display
if [ "$#" -eq 1 ]; then
	case $output in /*) ;; *) output=$PWD/$output ;; esac
fi
cd "$(dirname "$0")"
case $output in
*/)
	usage >&2
	exit 2
	;;
esac
if [ -d "$output" ]; then
	printf 'Output is a directory: %s\n' "$output_display" >&2
	exit 2
fi
mkdir -p "$(dirname "$output")"
printf 'building %s into %s\n' "$(awk -F '"' '/^let version = / { print $2 }' src/main.swift)" \
	"$output_display" >&2

project_dir=$PWD
signing_identity=-
if [ "$test_build" = false ]; then
	identities=$(security find-identity -v -p codesigning)
	signing_identity=$(printf '%s\n' "$identities" | awk '
        /"Developer ID Application:/ && !distribution { distribution=$2 }
        /"Apple Development:/ && !development { development=$2 }
        END { print distribution ? distribution : development }
    ')
	if [ -z "$signing_identity" ]; then
		printf 'No signing identity found. Create an Apple Development or Developer ID Application certificate in Xcode.\n' >&2
		exit 1
	fi
fi
identifier=$(find src -type f -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256)
identifier=${identifier%% *}
swift_version=$(xcrun swiftc --version 2>&1)
clang_version=$(xcrun clang --version)
sdk_path=$(xcrun --show-sdk-path)
sdk_build=$(xcrun --show-sdk-build-version)
cache_key=$({
	printf '%s\n' "$identifier" "$swift_version" "$clang_version" "$sdk_path" "$sdk_build"
	shasum -a 256 build.sh
} | shasum -a 256)
cache_key=${cache_key%% *}
cache_root=$HOME/Library/Caches/ca.aqsnow.alfred.spotify/build
binaries=$cache_root/$cache_key
work=$(mktemp -d "${TMPDIR:-/tmp}/spotify-build.XXXXXX")
cache_work=$work/native
trap 'rm -rf "$work" "$cache_work"' 0
stage=$work/stage
app="$stage/Spotify Mini Player.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$stage/docs" "$stage/licenses" "$binaries"
cp workflow/*.png "$stage/"
cp workflow/icon.png "$app/Contents/Resources/icon.png"
cp docs/*.png "$stage/docs/"
cp README.md "$stage/README.md"
cp src/vendor/ZSTD-LICENSE "$stage/licenses/Zstandard.txt"
if [ -x "$binaries/player" ] && [ -x "$binaries/show" ]; then
	printf 'using cached native binaries\n' >&2
else
	cache_work=$(mktemp -d "$cache_root/.native.XXXXXX")
	for arch in arm64 x86_64; do
		xcrun clang -O3 -arch "$arch" -mmacosx-version-min=13.0 -c src/vendor/zstddeclib.c -o "$work/zstd-$arch.o"
		xcrun clang -O3 -Wall -Wextra -Werror -arch "$arch" -mmacosx-version-min=13.0 \
			"-DBUILD_ID=\"$identifier\"" -c src/Bridge.c -o "$work/bridge-$arch.o"
		xcrun swiftc -O -whole-module-optimization -swift-version 5 -target "$arch-apple-macosx13.0" \
			-module-cache-path "$cache_root/modules" \
			-import-objc-header "$project_dir/src/Bridge.h" \
			src/*.swift \
			"$work/zstd-$arch.o" "$work/bridge-$arch.o" \
			-framework AppKit -framework ImageIO -framework Carbon -framework Security -framework SystemConfiguration -framework Network -lsqlite3 -lz -o "$work/player-$arch"
		xcrun clang -Os -Wall -Wextra -Werror -arch "$arch" -mmacosx-version-min=13.0 \
			"-DBUILD_ID=\"$identifier\"" src/launcher.c -o "$work/show-$arch"
	done
	xcrun lipo -create "$work/player-arm64" "$work/player-x86_64" -output "$cache_work/player"
	xcrun lipo -create "$work/show-arm64" "$work/show-x86_64" -output "$cache_work/show"
	mv -f "$cache_work/player" "$binaries/player"
	mv -f "$cache_work/show" "$binaries/show"
fi
cp "$binaries/player" "$app/Contents/MacOS/SpotifyMiniPlayer"
cp "$binaries/show" "$stage/show"
"$app/Contents/MacOS/SpotifyMiniPlayer" --write-metadata "$project_dir" "$stage"
sign() {
	if ! codesign --force --sign "$signing_identity" --timestamp=none --options runtime "$@" 2>"$work/signing.log"; then
		cat "$work/signing.log" >&2
		return 1
	fi
}
sign --identifier ca.aqsnow.alfred.spotify.launcher "$stage/show"
sign --entitlements src/Entitlements.plist "$app"
ditto -c -k --norsrc "$stage" "$output"

printf '%s\n' "$output_display"
if [ "$test_build" = false ]; then open -R "$output"; fi
