# Development

Guide for building Lumio locally and contributing to the project.

## Repository layout

```text
.
├── apps/
│   └── macos/
│       └── LauncherApp/          # Swift macOS app (Xcode project)
├── core/                         # Shared Rust, consumed by the app shell
│   ├── answers/                  # URL classification + translation helpers
│   ├── engine/                   # Query engine, search pipeline, config
│   ├── indexing/                 # Candidate model
│   ├── lunar/                    # Solar-to-lunar date conversion
│   ├── matching/                 # Fuzzy matching
│   ├── netspeed/                 # Bandwidth measurement
│   ├── ranking/                  # Ranking heuristics
│   ├── storage/                  # SQLite-backed storage
│   └── tools/                    # Preferred tools: catalog + command composition
├── bridge/
│   └── ffi/                      # Rust FFI bridge (consumed by the macOS app)
├── tools/
│   └── perf/                     # Watcher / refresh benchmarks (separate crate, never bundled)
├── docs/                         # User guide, architecture, design decisions
├── scripts/                      # Build, release, install scripts
└── assets/                       # Icons, screenshots, demo GIF
```

## Prerequisites

- Rust stable toolchain (for the core engine and FFI bridge)
- GNU Make
- macOS 15.0+
- Xcode (for the app shell)

## Building and running

Rust workspace checks:

```bash
cd core
cargo check --workspace
cargo test --workspace
```

FFI bridge checks:

```bash
cd bridge/ffi
cargo check
cargo test
```

Run the local dev app (from repo root):

```bash
make app-run
```

`make app-run` behavior:

- builds a local Debug app bundle with Xcode
- stops any running `Lumio` process (including a release-installed instance)
- launches with `LUMIO_CONFIG_PATH=$HOME/.lumio/config.dev`
- shows a red `TEST APP` badge so the dev run is visually distinct

Install a side-by-side test build (`Lumio Dev`) without replacing the normal install:

```bash
make app-run-dev
```

`make app-run-dev` builds a local Debug bundle, installs `/Applications/Lumio Dev.app` with bundle id `noah-code.Lumio.Dev`, leaves the release `/Applications/Lumio.app` untouched, then launches `Lumio Dev` with `LUMIO_CONFIG_PATH=$HOME/.lumio/config.dev`.

`lumio` is a symlink to the **installed** app (`scripts/install-lumio.sh`), so it always runs the release binary no matter what you just built. `make app-install-dev` installs `lumiodev` beside it as the same handle for the dev build:

```bash
lumiodev                 # launch it with the dev config
lumiodev clipboard       # open it in a mode
lumiodev --list-modes
```

Install it on its own with `make dev-cli`. It reads `LUMIO_DEV_APP` and `LUMIO_DEV_CONFIG` if you keep them elsewhere.

Override the macOS dev config path:

```bash
make app-run-dev DEV_CONFIG_PATH="$HOME/.lumio.qa.config"
```

`make help` lists every target.

## Benchmarks

All benches live in a separate `tools/perf` crate. Nothing in `apps/` or
`bridge/` depends on it, so they never end up in a shipped binary.

```bash
cd tools/perf
cargo run --release --bin query_engine_bench     # query throughput + fuzzy scoring micro-bench
cargo run --release --bin scoped_refresh_bench   # per-call latency: ALL / APPS_ONLY / FILES_ONLY
cargo run --release --bin watcher_stress         # simulated event streams, BEFORE vs AFTER
cargo run --release --bin real_fs_stress         # real notify watcher + worker doing real disk I/O
```

Watcher / index-refresh methodology, scenarios, and a side-by-side report
live at [tools/perf/WATCHER_PERF.md](tools/perf/WATCHER_PERF.md).

Benchmark snapshots land under [docs/bench-notes/](docs/bench-notes/). Add a new snapshot when scoring, matching, or indexing changes.

## Releasing (maintainers)

Every release is 1 command — version comes from the tag name, CI builds
`Lumio-<version>-macOS.zip` on the GitHub Release:

```bash
./scripts/release.sh v1.0.0
```

Tag rules: format `vX.Y.Z`, never re-tag an old number. No need to touch the
version in Xcode — CI injects `MARKETING_VERSION` from the tag name.
`release.sh` refuses a dirty tree — commit first.

Local preflight (same checks `release.sh` runs):

```bash
./scripts/test-ci-local.sh v1.0.0   # cargo tests + Release xcodebuild
./scripts/build-release.sh 1.0.0   # local zip into dist/ (no publish)
```

Signing and notarization (optional, for Gatekeeper-clean public builds):

- a paid Apple Developer membership is required for Developer ID signing and notarization
- ad-hoc CI builds install fine via the curl installer (quarantine is cleared)

Signing/notarization walkthrough: [docs/apple-developer-release-guide.md](docs/apple-developer-release-guide.md).

## Contribution flow

- every PR targets `main`, maintainer and external alike; there is no long-lived staging branch
- external contributions: branch from `main` in your fork and open the PR into `main`
- run local checks before opening a PR:
  ```bash
  cargo test --workspace --manifest-path core/Cargo.toml
  cargo test --manifest-path bridge/ffi/Cargo.toml
  ```
- update docs when user-visible behavior changes
- see [CONTRIBUTING.md](CONTRIBUTING.md) and the issue templates under [.github/ISSUE_TEMPLATE/](.github/ISSUE_TEMPLATE/)

## Further reading

- [docs/architecture.md](docs/architecture.md) - canonical architecture reference
- [docs/backend-guide.md](docs/backend-guide.md) - backend edit targets and verification
- [docs/user-guide.md](docs/user-guide.md) - user guide
- [docs/features.md](docs/features.md) - feature status
