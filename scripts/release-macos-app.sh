#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/apps/macos/LauncherApp"
SCHEME="Lumio"
CONFIGURATION="Release"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(date +%Y.%m.%d)"
fi

BUILD_DIR="$ROOT_DIR/.build/release-macos"
OUT_DIR="$ROOT_DIR/dist"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/Lumio.app"
ZIP_NAME="Lumio-${VERSION}-macOS.zip"
ZIP_PATH="$OUT_DIR/$ZIP_NAME"

echo "[1/4] Cleaning previous release artifacts"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUT_DIR"

echo "[2/4] Building macOS app ($CONFIGURATION)"
xcodebuild \
  -project "$APP_DIR/lumio-app.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  build >/dev/null

if [[ ! -d "$APP_PATH" ]]; then
  echo "Build succeeded but app bundle not found at: $APP_PATH" >&2
  exit 1
fi

echo "[3/4] Packaging app bundle"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "[4/4] Calculating sha256"
SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

echo
echo "Release artifact ready:"
echo "  File: $ZIP_PATH"
echo "  SHA256: $SHA256"
echo
echo "Use this zip for the GitHub Release."
