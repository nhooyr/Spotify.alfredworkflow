#!/bin/sh
set -eu

xcode_version=$(xcodebuild -version)
sdk_build=$(xcrun --show-sdk-build-version)
architecture=$(uname -m)
printf '%s\n' "$xcode_version" "$sdk_build" "$architecture" | shasum -a 256 | awk '{print "key=" $1}'
