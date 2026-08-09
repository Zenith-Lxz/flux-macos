#!/usr/bin/env bash
# Regression test for file-provider metadata being reattached after signing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_BIN="$ROOT_DIR/Tests/ScriptTests/fixtures/bin"
TEST_DIR="$(mktemp -d /tmp/flux-build-app-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/scripts" "$TEST_DIR/fake-bin"
cp "$ROOT_DIR/scripts/build-app.sh" "$TEST_DIR/scripts/build-app.sh"
cp "$FIXTURE_BIN/swift" "$TEST_DIR/fake-bin/swift"
cp "$FIXTURE_BIN/codesign" "$TEST_DIR/fake-bin/codesign"
cp "$FIXTURE_BIN/xattr" "$TEST_DIR/fake-bin/xattr"
chmod +x "$TEST_DIR/scripts/build-app.sh" "$TEST_DIR/fake-bin/"*

export FLUX_TEST_BIN_DIR="$TEST_DIR/swift-bin"
mkdir -p "$FLUX_TEST_BIN_DIR"
cp /usr/bin/true "$FLUX_TEST_BIN_DIR/FluxApp"

FLUX_TEST_CODESIGN_FORBID_VERIFY_PREFIX="$TEST_DIR/dist" \
PATH="$TEST_DIR/fake-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$TEST_DIR/scripts/build-app.sh"

[[ ! -e "$TEST_DIR/dist/Flux.app/.provider-metadata" ]]
[[ -f "$TEST_DIR/dist/Flux.app.sha256" ]]
[[ -f "$TEST_DIR/dist/build-info.txt" ]]

echo "SCRIPT TEST PASS: build-app removes metadata reattached after signing"
