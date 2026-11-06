# FFI bridge

`bridge/ffi` is the `lumio-ffi` crate. It builds as `staticlib`, `cdylib` and `rlib`; the app links the static library `liblumio_ffi.a`.

## Contract

- Every export is `extern "C"`, named `lumio_*`, and takes and returns C strings (UTF-8). Structured data crosses the boundary as JSON.
- Every export wraps its body in `catch_unwind`, so a Rust panic returns a null pointer instead of crashing the app. The release profile keeps `panic = "unwind"` for this reason.
- Strings returned to Swift are heap-allocated by Rust; Swift gives them back with `lumio_free_cstring`.

## Modules

| File | Exposes |
| --- | --- |
| `search_api.rs` | `lumio_search_json`, `lumio_search_json_compact` |
| `usage_api.rs` | recording and reading usage events |
| `clipboard_api.rs` | clipboard history |
| `modes_api.rs` | launch modes |
| `tools_api.rs` | preferred tools (editor, terminal) |
| `translate_api.rs`, `answers_api.rs` | translation and URL helpers |
| `url_history_api.rs` | web search history |
| `matching_api.rs` | text matching helpers |
| `runtime_config.rs` | loading and reloading `~/.lumio/config` |
| `state.rs` | the process-wide `QueryEngine` and filesystem watchers (`notify`) that keep the index fresh |

## Swift side

`EngineBridge.swift` declares each export with `@_silgen_name`, converts Swift strings to C strings, and decodes the JSON that comes back.

## Adding an export

1. Write `fn lumio_x_impl(...)` in the right `*_api.rs`.
2. Add the `#[unsafe(no_mangle)] pub extern "C" fn lumio_x(...)` wrapper in `lib.rs` with `catch_unwind`.
3. Declare it in `EngineBridge.swift` and call it from Swift.

## Tests

```bash
cargo test --manifest-path bridge/ffi/Cargo.toml
```
