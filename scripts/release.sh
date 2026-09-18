#!/bin/bash
# Step 1: tag + push to trigger CI (CI builds Look-<version>-macOS.zip on the GitHub Release).
# Usage: ./scripts/release.sh vX.Y.Z   (e.g. ./scripts/release.sh v1.0.0)
set -e
cd "$(dirname "$0")/.."

TAG="${1:-}"
if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 vX.Y.Z   (e.g. $0 v1.0.0)"
  exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "tag '$TAG' already exists"
  exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "working tree dirty — commit or stash first"
  exit 1
fi

./scripts/ci-local.sh "$TAG"

git tag "$TAG"
git push origin "$TAG"
echo "pushed $TAG — watch CI, the zip lands on the GitHub Release"
