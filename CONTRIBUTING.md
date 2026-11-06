# Contributing to Lumio

Thanks for contributing! Bug reports, ideas and pull requests are all welcome.

## Issues

Search existing issues first. A good bug report has:

- what you expected and what happened
- numbered steps to reproduce, and how often it happens (`always`, `sometimes`, `once`)
- macOS version, Lumio version (or commit), Apple Silicon or Intel
- logs, screenshots or the crash text if you have them

For a feature request, describe the problem first, then the behavior you'd like.

## Development setup

**Requirements:** macOS 15+, Xcode 26 (its SDK is needed for Liquid Glass), Rust stable and nightly (the Xcode build phase builds the Rust bridge with `cargo +nightly`), GNU Make.

```text
apps/macos/LauncherApp/   Swift app (Xcode project: lumio-app.xcodeproj)
core/                     Rust: query engine, indexing, matching, ranking, storage, tools
bridge/ffi/               Rust FFI bridge linked into the app
scripts/                  build.sh (local DMG), release.sh, notify-update.sh, lumiodev, Makefile.mac
assets/                   app icon (icon-source.png is the original)
tools/perf/               benchmarks (separate crate, never bundled)
```

Build and run (from the repo root):

```bash
make app-run       # Debug build, launched with ~/.lumio/config.dev
make app-run-dev   # installs a side-by-side "/Applications/Lumio Dev.app" and runs it
make help          # every target
```

Run the checks before opening a PR:

```bash
cargo test --workspace --manifest-path core/Cargo.toml
cargo test --manifest-path bridge/ffi/Cargo.toml
```

## App icon

Replace `assets/icon-source.png` with the new artwork (1024 px or larger), then run:

```bash
make icons
```

`assets/generate-icons.py` removes a solid background (the edge turns transparent, with no leftover fringe), trims the empty margin, centers the shape on Apple's macOS icon grid and writes `assets/icon.png` plus every size in `AppIcon.appiconset`. Run `pipx run assets/generate-icons.py --help` for the options (`--padding 0` fills the whole canvas).

## Pull requests

- branch from `main` and target `main`; it is the only long-lived branch and must stay releasable
- keep the change focused; no unrelated formatting
- rebase onto the latest `main` (or merge `origin/main` whole) before asking for review
- update the README when user-visible behavior changes
- explain *why* in the PR description, and add before/after screenshots for UI changes

Commit prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`.

## Building a DMG locally

```bash
./scripts/build.sh            # release/Lumio.dmg (Release, Apple Silicon, ad-hoc signed)
./scripts/build.sh v1.2.3     # same, with the version shown in About
```

CI builds the release with this same script.

## Releasing (maintainers)

```bash
# 1. Commit and push to main, then tag (runs cargo tests + build.sh first):
./scripts/release.sh v1.2.3

# 2. Nothing else. CI (release.yml) builds Lumio.dmg, publishes the GitHub release
#    and runs notify-update.sh. Only if its `notify-users` job fails, run by hand:
./scripts/notify-update.sh v1.2.3
```

- The version comes from the tag: `vX.Y.Z`, never reused, and newer than the last release (Sparkle only offers newer versions). `release.sh` refuses a dirty tree or a commit that isn't on `origin/main`. `--skip-checks` skips the local tests and build.
- `notify-update.sh` tells users two ways, like Ice:
  - **Sparkle** (in-app): adds the release to `lumio/appcast.xml` in [cavaldos/macos-app-releases](https://github.com/cavaldos/macos-app-releases) (shared with other apps), served at `https://cavaldos.github.io/macos-app-releases/lumio/appcast.xml` (`SUFeedURL`). Installed apps check it daily, then download, verify and install the update.
  - **Homebrew**: points the `lumio` cask in [cavaldos/homebrew-tap](https://github.com/cavaldos/homebrew-tap) at the new `Lumio.dmg`.
- Updates are signed with the same EdDSA key as Ice (`~/.sparkle/sparkle-priv.pem`; its public half is `SUPublicEDKey` in `lumio-app/Info.plist`). Never lose or rotate it: installed apps reject updates signed with another key.
- The `notify-users` job needs four repo secrets: `SPARKLE_PRIVATE_KEY` (that key file), `MACOS_APP_RELEASES_DEPLOY_KEY`, `LUMIO_RELEASES_DEPLOY_KEY` and `HOMEBREW_TAP_DEPLOY_KEY` (private halves of write deploy keys on `macos-app-releases`, `lumio-releases` and `homebrew-tap`). Lumio v0.0.5 and older still read `cavaldos/lumio-releases`, so the appcast is mirrored there too; once most users have updated, set `LEGACY_REPO=""` in `scripts/notify-update.sh`, drop `LUMIO_RELEASES_DEPLOY_KEY`, and delete that repo. Running `notify-update.sh` by hand needs `gh auth login`, Sparkle's `generate_appcast` and your own push access instead.
- Sparkle is off in Debug builds and in Lumio Dev (`make app-run-dev`, `lumiodev`), so it never replaces a dev build with a release.
