#!/bin/zsh
# Runs the tests. With only Command Line Tools installed, Swift Testing lives outside the default
# search paths, so they are passed explicitly; with Xcode plain `swift test` works too.
set -euo pipefail
cd "$(dirname "$0")"

CLT=/Library/Developer/CommandLineTools/Library/Developer
FLAGS=()
if [[ -d "$CLT/Frameworks/Testing.framework" ]]; then
    FLAGS=(-Xswiftc -F"$CLT/Frameworks" -Xlinker -F"$CLT/Frameworks"
           -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib")
fi
swift test "${FLAGS[@]}" "$@"
