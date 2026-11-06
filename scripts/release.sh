#!/bin/bash
# Release Lumio: run the checks, then tag + push. The tag starts
# .github/workflows/release.yml, which builds Lumio.dmg on GitHub
# (scripts/build.sh), publishes the GitHub Release and runs
# scripts/notify-update.sh so users get the update (in-app + Homebrew).
#
# Usage: ./scripts/release.sh vX.Y.Z [--skip-checks]
#   --skip-checks  skip the local cargo tests + Release build (CI builds anyway)
set -eo pipefail
cd "$(dirname "$0")/.."

TAG=""
CHECKS=1
for arg in "$@"; do
    case "$arg" in
        --skip-checks) CHECKS=0 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) TAG="$arg" ;;
    esac
done

if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 vX.Y.Z [--skip-checks]   (e.g. $0 v1.2.0)" >&2
    exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "working tree dirty: commit or stash first" >&2
    exit 1
fi

git fetch --quiet --tags origin main
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "tag $TAG already exists (never reuse a version)" >&2
    exit 1
fi
if ! git merge-base --is-ancestor HEAD origin/main; then
    echo "HEAD is not on origin/main: push your commits to main first" >&2
    exit 1
fi
# The in-app update check only offers versions newer than the installed one.
LATEST="$(git for-each-ref --count=1 --sort=-v:refname --format='%(refname:short)' 'refs/tags/v[0-9]*')"
if [ -n "$LATEST" ] && [ "$(printf '%s\n%s\n' "$LATEST" "$TAG" | sort -V | tail -1)" != "$TAG" ]; then
    echo "$TAG must be newer than the latest release $LATEST" >&2
    exit 1
fi

if [ "$CHECKS" -eq 1 ]; then
    # The Rust workspace needs nightly, like the Xcode "Build Rust FFI" phase.
    if ! cargo +nightly --version >/dev/null 2>&1; then
        echo "nightly toolchain not found: rustup toolchain install nightly" >&2
        exit 1
    fi
    LOG="${TMPDIR:-/tmp}/lumio-release-check.log"
    : > "$LOG"
    check() {
        echo "==> $1"
        shift
        if ! "$@" >>"$LOG" 2>&1; then
            tail -30 "$LOG" >&2
            echo "check failed, nothing was tagged. Full log: $LOG" >&2
            exit 1
        fi
    }
    check "cargo test (core)" cargo +nightly test --workspace --manifest-path core/Cargo.toml
    check "cargo test (ffi)" cargo +nightly test --manifest-path bridge/ffi/Cargo.toml
    check "Release build (scripts/build.sh, same as CI)" ./scripts/build.sh "$TAG"
fi

git tag "$TAG"
if ! git push origin "$TAG"; then
    git tag -d "$TAG" >/dev/null
    echo "push failed, local tag removed" >&2
    exit 1
fi

echo
echo "Pushed $TAG. GitHub Actions now builds Lumio.dmg, publishes the release"
echo "and updates the Homebrew cask:"
echo "  https://github.com/cavaldos/Lumio/actions/workflows/release.yml"
