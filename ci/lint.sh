#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

if [ "${GITHUB_ACTIONS-}" ]; then
	brew install shfmt
fi

shfmt -f=0 . | xargs -0 -n1 sh -n
for arch in arm64 x86_64; do
	xcrun swiftc -typecheck -warnings-as-errors -swift-version 5 -target "$arch-apple-macosx13.0" \
		-module-cache-path "$HOME/Library/Caches/ca.aqsnow.alfred.spotify/build/modules" \
		-import-objc-header "$PWD/src/CacheCodec.h" src/*.swift
	xcrun clang -fsyntax-only -Wall -Wextra -Werror -arch "$arch" -mmacosx-version-min=13.0 src/*.c
	xcrun clang -fsyntax-only -arch "$arch" -mmacosx-version-min=13.0 src/vendor/zstddeclib.c
done
for source in src/*.c; do
	xcrun clang --analyze --analyzer-output text -Xanalyzer -analyzer-werror \
		-Wall -Wextra -Werror -o /dev/null "$source"
done
