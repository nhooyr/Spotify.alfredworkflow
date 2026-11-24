#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

if [ "${GITHUB_ACTIONS-}" ]; then
	brew install shfmt clang-format
fi

npx prettier --log-level warn -w --print-width=110 --no-semi --bracket-same-line \
	--ignore-path .gitignore --ignore-path .prettierignore .
shfmt -s -w .
xcrun swift format --in-place --parallel src/*.swift
clang-format -i src/*.c src/*.h

if [ "${CI-}" ]; then
	git add --intent-to-add --ignore-removal .

	tput() { command tput -Txterm-256color "$@"; }

	if ! git --no-pager diff --color=always --stat --patch --exit-code; then
		tput bold
		printf '%s %s: unexpected diff\n' "$(printf '%40s' '' | tr ' ' '^')" "${0##*/}"
		tput sgr0
		exit 1
	fi
fi
