#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 1.0.0" >&2
  exit 1
fi

"$ROOT_DIR/scripts/release-macos-app.sh" "$VERSION"

ZIP_PATH="$ROOT_DIR/dist/Look-${VERSION}-macOS.zip"
if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Expected artifact missing: $ZIP_PATH" >&2
  exit 1
fi

shasum -a 256 "$ZIP_PATH"
echo
echo "Release artifact ready: $ZIP_PATH"
echo "Publish it to the GitHub Release (CI does this automatically on tag push)."
