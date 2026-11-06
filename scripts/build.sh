#!/bin/bash
# Build Lumio (Release, Apple Silicon, ad-hoc signed) and package release/Lumio.dmg.
# The Release workflow runs this same script, so a local DMG matches the one
# attached to the GitHub Release.
#
# Usage: ./scripts/build.sh [vX.Y.Z]
#   vX.Y.Z  version shown in About (default: MARKETING_VERSION from the Xcode project)
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Lumio"
PROJECT="apps/macos/LauncherApp/lumio-app.xcodeproj"
DERIVED_DATA="$ROOT_DIR/.build/release"
APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
RELEASE_DIR="$ROOT_DIR/release"
DMG_PATH="$RELEASE_DIR/$APP_NAME.dmg"

VERSION=""
VERSION_ARGS=()
if [ $# -ge 1 ]; then
    VERSION="${1#v}"
    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "version '$1' must look like vX.Y.Z (e.g. $0 v1.2.0)" >&2
        exit 1
    fi
    VERSION_ARGS=(MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION")
fi

echo "==> [1/3] Building $APP_NAME ${VERSION:+$VERSION }(Release, arm64)"
# Debug and Release share RustBuild/liblumio_ffi.a and Xcode skips the Rust
# phase when it exists: drop it unless it was built for Release from this source.
make --no-print-directory ffi-unstale XCODE_CONFIG=Release
# ARCHS=arm64: the Rust phase only builds the host architecture.
# Ad-hoc signing: there is no Developer ID certificate (local or CI).
xcodebuild -quiet \
    -project "$PROJECT" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS=arm64 \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} \
    clean build

if [ ! -d "$APP_PATH" ]; then
    echo "build succeeded but $APP_PATH is missing" >&2
    exit 1
fi
codesign --verify --deep --strict "$APP_PATH"

echo "==> [2/3] Creating $DMG_PATH"
mkdir -p "$RELEASE_DIR"
rm -f "$DMG_PATH"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
# ditto (not cp -R) keeps symlinks, signatures and extended attributes.
ditto "$APP_PATH" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
# hdiutil sometimes fails with "Resource busy" (common on CI runners): retry.
for attempt in 1 2 3; do
    if hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null; then
        break
    fi
    if [ "$attempt" -eq 3 ]; then
        echo "hdiutil create failed" >&2
        exit 1
    fi
    echo "hdiutil create failed (attempt $attempt), retrying..."
    sleep $((attempt * 5))
done

echo "==> [3/3] Done"
echo "  DMG:    $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1 | tr -d ' '))"
echo "  SHA256: $(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"

# Show the DMG in Finder for interactive local runs only.
if [ -z "${CI:-}" ] && [ -t 1 ]; then
    open -R "$DMG_PATH"
fi
