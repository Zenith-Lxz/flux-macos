#!/usr/bin/env bash
# Execute Flux tests and ensure Swift Testing is visible to SwiftPM's generated
# runner when only Apple's Command Line Tools are installed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CLT_TESTING_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

if [[ -d "$CLT_TESTING_FRAMEWORKS/Testing.framework" ]] \
    && ! xcodebuild -version >/dev/null 2>&1; then
    exec swift test \
        -Xswiftc -F \
        -Xswiftc "$CLT_TESTING_FRAMEWORKS" \
        "$@"
fi

exec swift test "$@"
