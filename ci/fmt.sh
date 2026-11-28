#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

case "${1-}" in
-h | --help)
	printf 'Usage: %s [--help | --fish-completions]\n\nFormat source files concurrently.\n' "$0"
	exit 0
	;;
--fish-completions)
	printf "complete -c fmt.sh -s h -l help -d 'Show usage'\n"
	printf "complete -c fmt.sh -l fish-completions -d 'Print Fish completions'\n"
	exit 0
	;;
esac

if [ "${GITHUB_ACTIONS-}" ]; then
	brew install parallel shfmt clang-format
fi

printf '%s\0' \
	prettier 'npx prettier --log-level warn -w --print-width=110 --no-semi --bracket-same-line --ignore-path .gitignore --ignore-path .prettierignore .' \
	shfmt 'shfmt -s -w .' \
	swift-format 'xcrun swift format --in-place --parallel src/*.swift' \
	clang-format 'clang-format -i src/*.c src/*.h' |
	PARALLEL_SHELL=/bin/sh parallel --plain --null -N 2 --jobs 4 --line-buffer --tagstring '[{1}]' 'sh -ec {2} 2>&1'

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
