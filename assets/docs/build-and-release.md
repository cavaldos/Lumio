# Build and release

Run everything from the repo root. `Makefile` includes `scripts/Makefile.mac`; `make help` lists every target.

## Requirements

macOS 15+, Xcode 26, Rust stable and nightly, GNU Make.

## Common targets

| Command | Does |
| --- | --- |
| `make app-run` | Debug build, launched with `~/.lumio/config.dev` |
| `make app-run-dev` | Installs a side-by-side `/Applications/Lumio Dev.app` and runs it |
| `make app-logs` | Follow the app's logs |
| `make db-path`, `db-status`, `db-shell`, `db-reset` | Inspect or reset the SQLite index |
| `make icons` | Regenerate the app icon from `assets/icon-source.png` |

## Checks

```bash
cargo test --workspace --manifest-path core/Cargo.toml
cargo test --manifest-path bridge/ffi/Cargo.toml
```

## Local DMG

```bash
./scripts/build.sh            # release/Lumio.dmg (Release, Apple Silicon, ad-hoc signed)
./scripts/build.sh v1.2.3     # same, with the version shown in About
```

## Releasing (maintainers)

```bash
./scripts/release.sh v1.2.3
```

`release.sh` refuses a dirty tree or a commit that is not on `origin/main`, runs the cargo tests and `build.sh`, then pushes the `v*` tag. That tag starts `.github/workflows/release.yml`, which:

1. builds `Lumio.dmg` with `build.sh`,
2. publishes the GitHub release,
3. runs `notify-update.sh` (the `notify-users` job).

`notify-update.sh` reaches users two ways:

- **Sparkle**: adds the release to `appcast.xml` in [cavaldos/lumio-releases](https://github.com/cavaldos/lumio-releases), served at `https://cavaldos.github.io/lumio-releases/appcast.xml`.
- **Homebrew**: points the `lumio` cask in [cavaldos/homebrew-tap](https://github.com/cavaldos/homebrew-tap) at the new DMG.

Rules: the version comes from the tag (`vX.Y.Z`), is never reused, and must be newer than the last release. Updates are EdDSA-signed; never rotate the key, or installed apps will reject updates. The `notify-users` job needs the secrets `SPARKLE_PRIVATE_KEY`, `LUMIO_RELEASES_DEPLOY_KEY` and `HOMEBREW_TAP_DEPLOY_KEY`.

CI (`ci.yml`) is manual only (`workflow_dispatch`).
