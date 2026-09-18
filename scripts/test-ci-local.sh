#!/bin/bash
# Mirror of CI (ci.yml rust checks + release.yml build) — run before tagging.
# Usage: ./scripts/test-ci-local.sh [vX.Y.Z]  (pass tag to also validate tag format)
set -e
cd "$(dirname "$0")/.."

# The workspace needs nightly (libsqlite3-sys build script uses cfg_select);
# stable fails with E0658. The Xcode "Build Rust FFI" phase needs nightly too.
if cargo +nightly --version >/dev/null 2>&1; then
  CARGO="cargo +nightly"
else
  echo "nightly toolchain not found — run: rustup toolchain install nightly"
  exit 1
fi

echo "==> cargo test (core workspace)"
$CARGO test --workspace --manifest-path core/Cargo.toml

echo "==> cargo test (ffi crate)"
$CARGO test --manifest-path bridge/ffi/Cargo.toml

echo "==> xcodebuild -version (CI builds with Xcode 26 on macos-26)"
xcodebuild -version

echo "==> xcodebuild Release (same project/scheme as release.yml)"
xcodebuild -project apps/macos/LauncherApp/lumio-app.xcodeproj -scheme Lumio \
  -configuration Release -destination 'platform=macOS' \
  clean build >/dev/null
echo "build OK"

if [ -n "$1" ]; then
  if ! [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "tag '$1' must look like vX.Y.Z (e.g. v1.0.0)"
    exit 1
  fi
  echo "tag OK: $1"
fi

echo "test-ci-local PASS"
