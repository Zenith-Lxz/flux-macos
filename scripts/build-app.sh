#!/usr/bin/env bash
# Build the Flux.app bundle for local verification (batch 001).
#
# - Compiles FluxApp in release mode with SwiftPM.
# - Assembles dist/Flux.app with a generated Info.plist (LSUIElement menu bar
#   app; no Dock icon).
# - Signs with FLUX_CODESIGN_IDENTITY when set; otherwise ad-hoc signing.
# - Verifies the signature and writes SHA-256 + signing-method records into
#   dist/.
#
# Never creates certificates and never touches the keychain.
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
BUILD_TEMP_DIR="$(mktemp -d /tmp/flux-build.XXXXXX)"
trap 'rm -rf "$BUILD_TEMP_DIR"' EXIT
STAGED_APP_DIR="$BUILD_TEMP_DIR/$APP_NAME.app"
STAGED_CONTENTS_DIR="$STAGED_APP_DIR/Contents"
STAGED_MACOS_DIR="$STAGED_CONTENTS_DIR/MacOS"
VERIFY_APP_DIR="$BUILD_TEMP_DIR/verify/$APP_NAME.app"

echo "==> Building FluxApp (release)"
swift build -c release --product FluxApp

BIN_PATH="$(swift build -c release --show-bin-path)/$EXECUTABLE_NAME"

echo "==> Assembling staged app"
mkdir -p "$STAGED_MACOS_DIR"
cp "$BIN_PATH" "$STAGED_MACOS_DIR/$EXECUTABLE_NAME"

cat > "$STAGED_CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$EXECUTABLE_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_SYSTEM</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# Assemble and sign outside the repository's file-provider path. FinderInfo
# and fpfs metadata can be reattached between cleanup and verification when
# signing directly in dist, creating an unavoidable race.
xattr -cr "$STAGED_APP_DIR" 2>/dev/null || true

echo "==> Signing"
if [[ -n "${FLUX_CODESIGN_IDENTITY:-}" ]]; then
    echo "==> Signing with identity: $FLUX_CODESIGN_IDENTITY"
    codesign --force --sign "$FLUX_CODESIGN_IDENTITY" "$STAGED_APP_DIR"
    SIGNING_METHOD="identity:$FLUX_CODESIGN_IDENTITY"
else
    echo "WARNING: FLUX_CODESIGN_IDENTITY is not set; using ad-hoc signing."
    echo "         ad-hoc binaries may require re-granting Accessibility /"
    echo "         Input Monitoring permissions after a rebuild."
    codesign --force --sign - "$STAGED_APP_DIR"
    SIGNING_METHOD="ad-hoc"
fi

# A signing tool or local filesystem may attach metadata even in staging;
# clean it before verification. /tmp is not managed by the repository's file
# provider, so it cannot be re-tagged by that provider between these steps.
xattr -cr "$STAGED_APP_DIR" 2>/dev/null || true

echo "==> Verifying signature"
codesign --verify --deep --strict "$STAGED_APP_DIR"
codesign -d -r - "$STAGED_APP_DIR" 2>/dev/null | sed 's/^/designated requirement: /'

echo "==> Publishing $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$DIST_DIR"
ditto --noextattr --noqtn "$STAGED_APP_DIR" "$APP_DIR"
xattr -cr "$APP_DIR" 2>/dev/null || true

# Prove the published file contents still carry the valid signature without
# verifying inside the file-provider path: copy the bound artifact back to a
# clean temporary location and verify that copy exactly once.
mkdir -p "$(dirname "$VERIFY_APP_DIR")"
ditto --noextattr --noqtn "$APP_DIR" "$VERIFY_APP_DIR"
xattr -cr "$VERIFY_APP_DIR" 2>/dev/null || true
codesign --verify --deep --strict "$VERIFY_APP_DIR"

echo "==> Recording checksums"
(cd "$APP_DIR" && find . -type f -exec shasum -a 256 {} + | sort) > "$DIST_DIR/$APP_NAME.app.sha256"
{
    echo "bundle=$APP_DIR"
    echo "bundle_identifier=$BUNDLE_ID"
    echo "version=$VERSION"
    echo "build=$BUILD_NUMBER"
    echo "signing_method=$SIGNING_METHOD"
    echo "sha256_manifest=$APP_NAME.app.sha256"
    echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$DIST_DIR/build-info.txt"

echo "==> Done"
echo "Bundle:       $APP_DIR"
echo "Signing:      $SIGNING_METHOD"
echo "SHA-256:      $DIST_DIR/$APP_NAME.app.sha256"
echo "Build info:   $DIST_DIR/build-info.txt"
