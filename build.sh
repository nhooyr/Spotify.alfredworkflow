#!/bin/sh
set -eu
cd "$(dirname "$0")"
project_dir=$PWD
output=dist/Spotify.alfredworkflow
identifier=$(find src -type f -exec shasum -a 256 {} + | LC_ALL=C sort | shasum -a 256)
identifier=${identifier%% *}
work=$(mktemp -d "${TMPDIR:-/tmp}/spotify-build.XXXXXX")
trap 'rm -rf "$work"' 0
stage=$work/stage
app="$stage/Spotify Mini Player.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$stage/docs" "$stage/licenses" dist
cp workflow/*.png "$stage/"
cp workflow/icon.png "$app/Contents/Resources/icon.png"
cp docs/*.png "$stage/docs/"
cp README.md "$stage/README.md"
cp src/vendor/ZSTD-LICENSE "$stage/licenses/Zstandard.txt"
printf 'enum Build { static let identifier = "%s" }\n' "$identifier" > "$work/Build.swift"
cp src/Player.swift "$work/main.swift"
for arch in arm64 x86_64; do
    xcrun clang -O3 -arch "$arch" -mmacosx-version-min=13.0 -c src/vendor/zstddeclib.c -o "$work/zstd-$arch.o"
    xcrun clang -O3 -Wall -Wextra -Werror -arch "$arch" -mmacosx-version-min=13.0 -c src/CacheCodec.c -o "$work/codec-$arch.o"
    xcrun swiftc -O -whole-module-optimization -swift-version 5 -target "$arch-apple-macosx13.0" \
        -module-cache-path "${TMPDIR:-/tmp}/spotify-swift-module-cache" \
        -import-objc-header "$project_dir/src/CacheCodec.h" \
        "$work/main.swift" "$work/Build.swift" \
        src/version.swift src/Core.swift src/Theme.swift src/Artwork.swift src/Cache.swift src/DesktopMetadata.swift src/Library.swift src/Playback.swift src/Authorization.swift src/Backend.swift src/Metadata.swift src/Tests.swift \
        "$work/zstd-$arch.o" "$work/codec-$arch.o" \
        -framework AppKit -framework ImageIO -framework Carbon -framework Security -framework SystemConfiguration -framework Network -lsqlite3 -lz -o "$work/player-$arch"
    xcrun clang -Os -Wall -Wextra -Werror -arch "$arch" -mmacosx-version-min=13.0 \
        "-DBUILD_ID=\"$identifier\"" src/launcher.c -o "$work/show-$arch"
done
xcrun lipo -create "$work/player-arm64" "$work/player-x86_64" -output "$app/Contents/MacOS/SpotifyMiniPlayer"
xcrun lipo -create "$work/show-arm64" "$work/show-x86_64" -output "$stage/show"
"$app/Contents/MacOS/SpotifyMiniPlayer" --write-metadata "$project_dir" "$stage"
cp "$stage/info.plist" workflow/info.plist
codesign --force --sign - --timestamp=none "$app" 2>/dev/null
ditto -c -k --norsrc "$stage" "$output"
printf '%s\n' "$output"
