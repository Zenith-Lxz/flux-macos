#!/usr/bin/env bash
# Read-only smoke test for the assembled dist/Flux.app (batch 001).
#
# Verifies bundle structure, Info.plist contract, executable, bundle id,
# codesign, and the recorded SHA-256/signing-method records. Never modifies
# system permissions and never registers login items.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Flux"
BUNDLE_ID="com.zenith.flux"
EXECUTABLE_NAME="FluxApp"
VERSION="1.0.0"
BUILD_NUMBER="1"
MIN_SYSTEM="13.0"

DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
SHA_FILE="$DIST_DIR/$APP_NAME.app.sha256"
INFO_FILE="$DIST_DIR/build-info.txt"

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
pass() { echo "SMOKE PASS: $*"; }

# 1. Bundle structure
[[ -d "$APP_DIR" ]] || fail "bundle missing: $APP_DIR"
[[ -d "$CONTENTS_DIR" ]] || fail "Contents directory missing"
[[ -d "$MACOS_DIR" ]] || fail "MacOS directory missing"
[[ -f "$CONTENTS_DIR/Info.plist" ]] || fail "Info.plist missing"
[[ -x "$MACOS_DIR/$EXECUTABLE_NAME" ]] || fail "executable missing or not executable"
pass "bundle structure (Contents, Info.plist, executable)"

# 2. Info.plist is a valid plist
/usr/libexec/PlistBuddy -c "Print" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 \
    || fail "Info.plist is not a valid plist"
pass "Info.plist is a valid plist"

read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$CONTENTS_DIR/Info.plist" 2>/dev/null; }

# 3. Info.plist contract
[[ "$(read_plist CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail "CFBundleIdentifier mismatch"
[[ "$(read_plist CFBundleExecutable)" == "$EXECUTABLE_NAME" ]] || fail "CFBundleExecutable mismatch"
[[ "$(read_plist CFBundleName)" == "$APP_NAME" ]] || fail "CFBundleName mismatch"
[[ "$(read_plist CFBundleShortVersionString)" == "$VERSION" ]] || fail "CFBundleShortVersionString mismatch"
[[ "$(read_plist CFBundleVersion)" == "$BUILD_NUMBER" ]] || fail "CFBundleVersion mismatch"
[[ "$(read_plist LSMinimumSystemVersion)" == "$MIN_SYSTEM" ]] || fail "LSMinimumSystemVersion mismatch"
[[ "$(read_plist LSUIElement)" == "true" ]] || fail "LSUIElement must be true (menu-bar-only app)"
pass "Info.plist contract (bundle id, executable, version, LSUIElement)"

# 4. Executable is a Mach-O binary for the host architecture
file "$MACOS_DIR/$EXECUTABLE_NAME" | grep -q "Mach-O" || fail "executable is not a Mach-O binary"
ARCHS="$(lipo -archs "$MACOS_DIR/$EXECUTABLE_NAME" 2>/dev/null || true)"
[[ "$ARCHS" == "arm64" ]] || fail "unexpected architecture: ${ARCHS:-unknown}"
pass "executable is Mach-O arm64"

# 5. Codesign verification. Never mutate the bound source artifact. Always
# verify a metadata-clean temporary copy: a file provider can re-tag the
# source bundle between a successful probe and a second verification, so a
# conditional fallback has an unavoidable time-of-check/time-of-use race.
SMOKE_TEMP_DIR="$(mktemp -d /tmp/flux-smoke.XXXXXX)"
trap 'rm -rf "$SMOKE_TEMP_DIR"' EXIT
VERIFY_APP="$SMOKE_TEMP_DIR/$APP_NAME.app"
ditto --noextattr --noqtn "$APP_DIR" "$VERIFY_APP"
xattr -cr "$VERIFY_APP" 2>/dev/null || true
codesign --verify --deep --strict "$VERIFY_APP" || fail "codesign --verify --deep --strict failed"
pass "codesign verify"

# 6. SHA-256 record matches the current bundle
[[ -f "$SHA_FILE" ]] || fail "SHA-256 manifest missing: $SHA_FILE"
recorded="$(cat "$SHA_FILE")"
recomputed="$(cd "$APP_DIR" && find . -type f -exec shasum -a 256 {} + | sort)"
[[ "$recorded" == "$recomputed" ]] \
    || fail "SHA-256 manifest does not match the bundle (rebuild and re-run build-app.sh)"
pass "SHA-256 manifest matches the bundle"

# 7. Build info record
[[ -f "$INFO_FILE" ]] || fail "build info record missing: $INFO_FILE"
grep -q "^bundle_identifier=$BUNDLE_ID$" "$INFO_FILE" || fail "build info bundle_identifier mismatch"
grep -q "^signing_method=" "$INFO_FILE" || fail "build info signing_method missing"
signing_method="$(sed -n 's/^signing_method=//p' "$INFO_FILE")"
case "$signing_method" in
    ad-hoc)
        pass "signing method record: ad-hoc"
        ;;
    identity:*)
        identity="${signing_method#identity:}"
        if ! { codesign -dv "$VERIFY_APP" 2>&1 | grep -q "Authority=" \
               && codesign -dv "$VERIFY_APP" 2>&1 | grep -qF "$identity"; }; then
            fail "recorded identity '$identity' not found in codesign output"
        fi
        pass "signing method record: identity '$identity'"
        ;;
    *)
        fail "unknown signing method in record: $signing_method"
        ;;
esac

echo
echo "SMOKE TEST PASSED"
