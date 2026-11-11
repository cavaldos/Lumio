#!/bin/bash
# Tell users about a release (Lumio's version of Ice's update-appcast.sh).
# CI runs this after every release (job notify-users in release.yml); run it
# by hand only if that job failed.
#   1. Sparkle: adds the release to lumio/appcast.xml in cavaldos/macos-app-releases
#      (GitHub Pages, shared with other apps). Installed apps check it daily or via Check for Updates,
#      then download, verify and install the update.
#   2. Homebrew: points Casks/lumio.rb in cavaldos/homebrew-tap at the new
#      Lumio.dmg, so `brew upgrade` installs it.
#
# Usage: ./scripts/notify-update.sh vX.Y.Z [--key <private-key-file>]
#   --key  Sparkle EdDSA private key. Default: $SPARKLE_PRIVATE_KEY, then
#          ~/.sparkle/sparkle-priv.pem, then the key in your Keychain. It must
#          match SUPublicEDKey in apps/macos/LauncherApp/lumio-app/Info.plist.
# Needs: gh logged in, generate_appcast (bin/ of the Sparkle release download),
#        git push access to the repos below. CI pushes with deploy keys: set
#        RELEASES_SSH / LEGACY_RELEASES_SSH / HOMEBREW_TAP_SSH to an ssh
#        command using the key.
set -eo pipefail
cd "$(dirname "$0")/.."

REPO="cavaldos/Lumio"
RELEASES_REPO="cavaldos/macos-app-releases"
APPCAST="lumio/appcast.xml"
# Old feed of Lumio v0.0.5 and older. cavaldos/lumio-releases has been deleted,
# so there is nothing left to mirror to.
LEGACY_REPO=""
TAP_REPO="cavaldos/homebrew-tap"
ASSET="Lumio.dmg"
FEED_URL="https://cavaldos.github.io/macos-app-releases/$APPCAST"

TAG=""
KEY="${SPARKLE_PRIVATE_KEY:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --key) KEY="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) TAG="$1"; shift ;;
    esac
done
if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: $0 vX.Y.Z [--key <private-key-file>]" >&2
    exit 1
fi
VERSION="${TAG#v}"
command -v gh >/dev/null || { echo "missing gh: brew install gh" >&2; exit 1; }
command -v generate_appcast >/dev/null || {
    echo "missing generate_appcast: get it from bin/ of https://github.com/sparkle-project/Sparkle/releases" >&2
    exit 1
}
if [ -z "$KEY" ] && [ -f "$HOME/.sparkle/sparkle-priv.pem" ]; then
    KEY="$HOME/.sparkle/sparkle-priv.pem"
fi
KEY_ARGS=()
if [ -n "$KEY" ]; then
    [ -f "$KEY" ] || { echo "private key not found: $KEY" >&2; exit 1; }
    # --ed-key-file, not -f: -f is for legacy DSA keys.
    KEY_ARGS=(--ed-key-file "$KEY")
fi

GIT_NAME="$(git config --global user.name || echo 'github-actions[bot]')"
GIT_EMAIL="$(git config --global user.email || echo 'github-actions[bot]@users.noreply.github.com')"

# Clones <owner/name> into <dir>: over SSH with <ssh command> (CI deploy key),
# otherwise over HTTPS with your own git credentials.
clone() {
    if [ -n "$3" ]; then
        GIT_SSH_COMMAND="$3" git clone --quiet --depth 1 "git@github.com:$1.git" "$2"
        git -C "$2" config core.sshCommand "$3"
    else
        git clone --quiet --depth 1 "https://github.com/$1.git" "$2"
    fi
    git -C "$2" config user.name "$GIT_NAME"
    git -C "$2" config user.email "$GIT_EMAIL"
}

# Commits what is staged in <dir> and pushes, retrying transient GitHub errors.
# A failed push fails the script, so CI never goes green without publishing.
publish() {
    if git -C "$1" diff --cached --quiet; then
        echo "    already up to date"
        return 0
    fi
    git -C "$1" commit --quiet -m "$2"
    for attempt in 1 2 3 4 5; do
        if git -C "$1" push --quiet origin HEAD; then
            return 0
        fi
        if [ "$attempt" -eq 5 ]; then
            echo "push from $1 failed" >&2
            exit 1
        fi
        echo "push failed (attempt $attempt), retrying in $((attempt * 10))s..."
        sleep $((attempt * 10))
        git -C "$1" pull --quiet --rebase
    done
}

# --- The GitHub Release must be public: the appcast and cask download from it.
STATE="$(gh release view "$TAG" -R "$REPO" --json isDraft,isPrerelease,assets \
    --jq "[.isDraft, .isPrerelease, ([.assets[].name] | index(\"$ASSET\") != null)] | map(tostring) | join(\" \")")" || {
    echo "no GitHub release for $TAG yet: wait for the Release workflow to finish" >&2
    exit 1
}
read -r IS_DRAFT IS_PRERELEASE HAS_ASSET <<< "$STATE"
if [ "$HAS_ASSET" != true ]; then
    echo "release $TAG has no $ASSET yet: wait for the Release workflow to finish" >&2
    exit 1
fi
if [ "$IS_DRAFT" = true ] || [ "$IS_PRERELEASE" = true ]; then
    echo "==> Publishing release $TAG (it was a draft or pre-release)"
    gh release edit "$TAG" -R "$REPO" --draft=false --prerelease=false >/dev/null
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/archives"
gh release download "$TAG" -R "$REPO" -p "$ASSET" -D "$WORK/archives"
SHA256="$(shasum -a 256 "$WORK/archives/$ASSET" | cut -d' ' -f1)"

# --- 1. Sparkle appcast ---------------------------------------------------------
echo "==> Sparkle: adding $TAG to $APPCAST in $RELEASES_REPO"
clone "$RELEASES_REPO" "$WORK/releases" "${RELEASES_SSH:-}"
# Keep history: generate_appcast keeps the entries of an appcast.xml it finds
# next to the archives.
if [ -f "$WORK/releases/$APPCAST" ]; then
    cp "$WORK/releases/$APPCAST" "$WORK/archives/appcast.xml"
fi
generate_appcast ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    "$WORK/archives"
if ! grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$WORK/archives/appcast.xml"; then
    echo "appcast has no $VERSION entry: is $ASSET on $TAG really version $VERSION?" >&2
    exit 1
fi
mkdir -p "$(dirname "$WORK/releases/$APPCAST")"
cp "$WORK/archives/appcast.xml" "$WORK/releases/$APPCAST"
git -C "$WORK/releases" add "$APPCAST"
publish "$WORK/releases" "appcast: Lumio $TAG"

if [ -n "$LEGACY_REPO" ]; then
    echo "==> Sparkle: mirroring appcast.xml to $LEGACY_REPO (old feed)"
    clone "$LEGACY_REPO" "$WORK/legacy" "${LEGACY_RELEASES_SSH:-}"
    cp "$WORK/archives/appcast.xml" "$WORK/legacy/appcast.xml"
    git -C "$WORK/legacy" add appcast.xml
    publish "$WORK/legacy" "appcast: $TAG"
fi

# --- 2. Homebrew cask -----------------------------------------------------------
echo "==> Homebrew: pointing Casks/lumio.rb in $TAP_REPO at $VERSION"
clone "$TAP_REPO" "$WORK/tap" "${HOMEBREW_TAP_SSH:-}"
mkdir -p "$WORK/tap/Casks"
cat > "$WORK/tap/Casks/lumio.rb" <<EOF
cask "lumio" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/cavaldos/Lumio/releases/download/v#{version}/Lumio.dmg"
  name "Lumio"
  desc "Local-first keyboard launcher and Spotlight alternative"
  homepage "https://github.com/cavaldos/Lumio"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Lumio.app"
  binary "#{appdir}/Lumio.app/Contents/MacOS/Lumio", target: "lumio"

  # Releases are ad-hoc signed and not notarized; without this Gatekeeper blocks the first launch.
  postflight_steps do
    run "/usr/bin/xattr",
        args:         ["-dr", "com.apple.quarantine", "{{appdir}}/Lumio.app"],
        must_succeed: false
  end

  uninstall quit: "com.cavaldos.Lumio"

  zap trash: [
    "~/.lumio",
    "~/Library/Application Support/lumio",
    "~/Library/Preferences/com.cavaldos.Lumio.plist",
    "~/Library/Caches/com.cavaldos.Lumio",
    "~/Library/HTTPStorages/com.cavaldos.Lumio",
    "~/Library/Preferences/noah-code.Lumio.plist",
    "~/Library/Caches/noah-code.Lumio",
    "~/Library/HTTPStorages/noah-code.Lumio",
  ]

  caveats <<~EOS
    Lumio is ad-hoc signed. If macOS still blocks it, run:
      xattr -dr com.apple.quarantine #{appdir}/Lumio.app
    Then open Lumio and press Option+Space.
  EOS
end
EOF
git -C "$WORK/tap" add Casks/lumio.rb
publish "$WORK/tap" "lumio $VERSION"

echo
echo "Done. Users get Lumio $VERSION via:"
echo "  - the app: Sparkle checks $FEED_URL daily (or Settings > About > Check for Updates)"
echo "  - Homebrew: brew upgrade --cask lumio"
