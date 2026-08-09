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
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

echo "==> Building FluxApp (release)"
swift build -c release --product FluxApp

BIN_PATH="$(swift build -c release --show-bin-path)/$EXECUTABLE_NAME"

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$EXECUTABLE_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
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

# The repository may live under an iCloud/file-provider path whose extended
# attributes (FinderInfo, fileprovider fpfs) make codesign reject the bundle.
# Clean only after every bundle file has been written.
xattr -cr "$APP_DIR" 2>/dev/null || true

echo "==> Signing"
if [[ -n "${FLUX_CODESIGN_IDENTITY:-}" ]]; then
    echo "==> Signing with identity: $FLUX_CODESIGN_IDENTITY"
    codesign --force --sign "$FLUX_CODESIGN_IDENTITY" "$APP_DIR"
    SIGNING_METHOD="identity:$FLUX_CODESIGN_IDENTITY"
else
    echo "WARNING: FLUX_CODESIGN_IDENTITY is not set; using ad-hoc signing."
    echo "         ad-hoc binaries may require re-granting Accessibility /"
    echo "         Input Monitoring permissions after a rebuild."
    codesign --force --sign - "$APP_DIR"
    SIGNING_METHOD="ad-hoc"
fi

# The file provider can re-tag the bundle after signing. Remove those
# attributes before the first strict verification; otherwise the verifier
# rejects FinderInfo/fpfs metadata before the later cleanup can run.
xattr -cr "$APP_DIR" 2>/dev/null || true

echo "==> Verifying signature"
codesign --verify --deep --strict "$APP_DIR"
codesign -d -r - "$APP_DIR" 2>/dev/null | sed 's/^/designated requirement: /'

# The file provider re-tags bundle files with FinderInfo/fpfs xattrs after the
# initial cleanup; remove them again so the recorded artifact is clean and the
# smoke test's strict verification is stable.
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --verify --deep --strict "$APP_DIR"

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
