#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

if [ "${GITHUB_ACTIONS-}" ]; then
	brew install parallel shfmt
fi

arch_checks='
	xcrun swiftc -typecheck -warnings-as-errors -swift-version 5 -target "$1-apple-macosx13.0" \
		-module-cache-path "$HOME/Library/Caches/ca.aqsnow.alfred.spotify/build/modules" \
		-import-objc-header "$PWD/src/Bridge.h" src/*.swift
	xcrun clang -fsyntax-only -Wall -Wextra -Werror -arch "$1" -mmacosx-version-min=13.0 src/*.c
	xcrun clang -fsyntax-only -arch "$1" -mmacosx-version-min=13.0 src/vendor/zstddeclib.c
'
printf '%s\0' \
	sh 'shfmt -f=0 . | xargs -0 -n1 sh -n' \
	arm64 "$arch_checks" \
	x86_64 "$arch_checks" \
	clang-analyze 'for source in src/*.c; do
		xcrun clang --analyze --analyzer-output text -Xanalyzer -analyzer-werror \
			-Wall -Wextra -Werror -o /dev/null "$source"
	done' |
	PARALLEL_SHELL=/bin/sh parallel --plain --null -N 2 --jobs 4 --line-buffer --tagstring '[{1}]' 'sh -ec {2} sh {1} 2>&1'
