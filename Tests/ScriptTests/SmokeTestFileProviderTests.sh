#!/usr/bin/env bash
# Regression test for metadata reattached between smoke-test verifications.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIXTURE_BIN="$ROOT_DIR/Tests/ScriptTests/fixtures/bin"
TEST_DIR="$(mktemp -d /tmp/flux-smoke-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/scripts" "$TEST_DIR/fake-bin"
cp "$ROOT_DIR/scripts/build-app.sh" "$TEST_DIR/scripts/build-app.sh"
cp "$ROOT_DIR/scripts/smoke-test.sh" "$TEST_DIR/scripts/smoke-test.sh"
cp "$FIXTURE_BIN/swift" "$TEST_DIR/fake-bin/swift"
cp "$FIXTURE_BIN/codesign" "$TEST_DIR/fake-bin/codesign"
cp "$FIXTURE_BIN/xattr" "$TEST_DIR/fake-bin/xattr"
cp "$FIXTURE_BIN/file" "$TEST_DIR/fake-bin/file"
cp "$FIXTURE_BIN/lipo" "$TEST_DIR/fake-bin/lipo"
chmod +x "$TEST_DIR/scripts/"* "$TEST_DIR/fake-bin/"*

export FLUX_TEST_BIN_DIR="$TEST_DIR/swift-bin"
mkdir -p "$FLUX_TEST_BIN_DIR"
cp /usr/bin/true "$FLUX_TEST_BIN_DIR/FluxApp"

PATH="$TEST_DIR/fake-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$TEST_DIR/scripts/build-app.sh" >/dev/null

FLUX_TEST_CODESIGN_MODE=smoke-race \
PATH="$TEST_DIR/fake-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$TEST_DIR/scripts/smoke-test.sh"

echo "SCRIPT TEST PASS: smoke verification is immune to source-bundle retagging"
