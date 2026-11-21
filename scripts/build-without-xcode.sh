#!/bin/bash
# Build Lumio.app with only the Xcode Command Line Tools (no Xcode.app).
#
# The normal build is `make app-build` (xcodebuild). This script is for a Mac that has
# `swiftc` and `cargo` but not the 15 GB Xcode: it compiles the Swift sources directly,
# links the Rust core, and assembles + ad-hoc signs the bundle by hand.
#
# Differences from the Xcode build:
#   - No Sparkle auto-update (the package is not fetched); a no-op UpdateChecker stands in.
#   - The app icon is built with iconutil instead of the asset catalog compiler.
#
# Usage: scripts/build-without-xcode.sh [output-dir]      (default: ./.build/manual)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.build/manual}"
APP_SRC="$ROOT/apps/macos/LauncherApp/lumio-app"
APP="$OUT/Lumio.app"
DEPLOY=15.0

# The newest SDK whose SwiftUI still ships @State as a plain property wrapper works with
# the Command Line Tools; newer SDKs need a macro plugin that only Xcode.app carries.
SDK="${LUMIO_SDK:-}"
if [ -z "$SDK" ]; then
  for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
                   /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
    [ -d "$candidate" ] && SDK="$candidate" && break
  done
fi
[ -n "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
echo "SDK: $SDK"

echo "==> Rust core"
CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
MACOSX_DEPLOYMENT_TARGET=$DEPLOY "$CARGO" build --release --manifest-path "$ROOT/bridge/ffi/Cargo.toml"
LIB="$ROOT/bridge/ffi/target/release/liblumio_ffi.a"

echo "==> Swift app"
mkdir -p "$OUT/obj"
cat > "$OUT/obj/UpdateCheckerStub.swift" <<'EOF'
import Combine
import Foundation

/// Stand-in for Support/UpdateChecker.swift (Sparkle) in builds made without Xcode.
final class UpdateChecker: NSObject, ObservableObject {
    static let shared = UpdateChecker()
    @Published private(set) var canCheckForUpdates = false
    var isEnabled: Bool { false }
    var automaticallyChecksForUpdates: Bool { get { false } set {} }
    func start() {}
    func checkForUpdates() {}
}
EOF
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done \
  < <(find "$APP_SRC" -name '*.swift' ! -name 'UpdateChecker.swift' | sort)

xcrun swiftc -O -wmo \
  -sdk "$SDK" -target "arm64-apple-macos$DEPLOY" -swift-version 6 \
  -default-isolation MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -module-name Lumio \
  "${SOURCES[@]}" "$OUT/obj/UpdateCheckerStub.swift" \
  -Xlinker -force_load -Xlinker "$LIB" \
  -o "$OUT/obj/Lumio"

echo "==> Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/obj/Lumio" "$APP/Contents/MacOS/Lumio"

ICONSET="$OUT/obj/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
cp "$APP_SRC"/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo dev)"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>Lumio</string>
	<key>CFBundleIdentifier</key><string>com.cavaldos.Lumio</string>
	<key>CFBundleName</key><string>Lumio</string>
	<key>CFBundleDisplayName</key><string>Lumio</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>$VERSION</string>
	<key>LSMinimumSystemVersion</key><string>$DEPLOY</string>
	<key>LSUIElement</key><true/>
	<key>LSMultipleInstancesProhibited</key><false/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>Lumio uses Finder to empty the Trash, and your browser to find open tabs and switch to them.</string>
</dict>
</plist>
EOF

# Ad-hoc signature with an identifier-based requirement instead of the default per-build hash:
# macOS privacy grants (Full Disk Access, Automation) then survive a rebuild instead of
# silently breaking every time the binary changes.
codesign --force --sign - \
  -r='designated => identifier "com.cavaldos.Lumio"' \
  --entitlements "$APP_SRC/Lumio.entitlements" "$APP" >/dev/null
echo "Built $APP"
