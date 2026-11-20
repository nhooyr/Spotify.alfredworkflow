#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

if [ "${GITHUB_ACTIONS-}" ]; then
	brew install shfmt
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' 0
shfmt -f=0 . | xargs -0 -n1 sh -n
cp src/Player.swift "$work/main.swift"
printf 'enum Build { static let identifier = "lint" }\n' >"$work/Build.swift"
set -- "$work/main.swift" "$work/Build.swift"
for source in src/*.swift; do
	if [ "$source" != src/Player.swift ]; then set -- "$@" "$source"; fi
done
for arch in arm64 x86_64; do
	xcrun swiftc -typecheck -warnings-as-errors -swift-version 5 -target "$arch-apple-macosx13.0" \
		-module-cache-path "$HOME/Library/Caches/ca.aqsnow.alfred.spotify/build/modules" \
		-import-objc-header "$PWD/src/CacheCodec.h" "$@"
	xcrun clang -fsyntax-only -Wall -Wextra -Werror -arch "$arch" -mmacosx-version-min=13.0 src/*.c
	xcrun clang -fsyntax-only -arch "$arch" -mmacosx-version-min=13.0 src/vendor/zstddeclib.c
done
for source in src/*.c; do
	xcrun clang --analyze --analyzer-output text -Xanalyzer -analyzer-werror \
		-Wall -Wextra -Werror -o /dev/null "$source"
done
