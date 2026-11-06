# Rust core

A Cargo workspace in `core/` (edition 2024, Rust 1.88+). Each crate has one job.

| Crate | Role |
| --- | --- |
| `lumio-indexing` | The `Candidate` type (app, file, folder, setting, …) and its id scheme. Shared by every other crate. |
| `lumio-matching` | Query normalization (case and accent folding) and fuzzy scoring. |
| `lumio-ranking` | `rank_score`: adjusts a base match score using exact/prefix matches and usage history. |
| `lumio-storage` | SQLite persistence: candidates, usage events, index state, URL history, clipboard entries. |
| `lumio-engine` | The query engine: config, discovery, search, scoring, modes. Depends on the crates above. |
| `lumio-tools` | Preferred tools (editor, terminal): turns an action plus an object into something the platform can launch. |
| `lumio-answers` | URL helpers and text translation over HTTP. |

## Engine (`core/engine`)

- `config.rs`, `config_path.rs`: parse `~/.lumio/config` into `RuntimeConfig`.
- `index/`: discovery of candidates. `apps.rs`, `files.rs`, `settings.rs` each run on their own thread and stream `Candidate`s over a bounded channel.
- `platform/`: per-OS discovery (`macos`, plus `linux` and `windows` code paths).
- `query.rs`, `search.rs`, `scoring.rs`: parse a query, score candidates, keep the top-K in a heap, then re-rank a bounded pool.
- `modes.rs`: the launch modes the app can open straight into (also used by the `lumio` shell command).
- `action.rs`, `result.rs`: what a result is and what can be done with it.

## Search pipeline

```text
query ─▶ normalize ─▶ fuzzy score every candidate ─▶ top-K heap
      ─▶ re-rank the pool with ranking::rank_score (usage, exact/prefix bonus)
      ─▶ kind/path penalties and bonuses ─▶ limit ─▶ results
```

Search aliases from the config (`alias_code=Visual Studio Code|Cursor|Zed`) are applied to app queries before scoring.

## Tests and benchmarks

```bash
cargo test --workspace --manifest-path core/Cargo.toml
```

Benchmarks and stress tests live in `tools/perf`, a separate crate that is never bundled.
