#![allow(unsafe_code)]


mod answers_api;

mod clipboard_api;
mod lunar_api;
mod matching_api;

mod modes_api;
mod netspeed_api;

mod runtime_config;
mod search_api;
mod seed_api;

mod state;
mod tools_api;
mod translate_api;
mod url_history_api;
mod usage_api;

use look_engine::QueryEngine;
use search_api::FfiSearchResult;
use std::os::raw::c_char;

#[unsafe(no_mangle)]
pub extern "C" fn look_search_count(query_len: u32) -> FfiSearchResult {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        search_api::look_search_count_impl(query_len)
    }))
    .unwrap_or(FfiSearchResult { count: 0 })
}

#[unsafe(no_mangle)]
pub extern "C" fn look_search_json(query: *const c_char, limit: u32) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        search_api::look_search_json_impl(query, limit)
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "C" fn look_search_json_compact(query: *const c_char, limit: u32) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        search_api::look_search_json_compact_impl(query, limit)
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Natural-language file recall over Look's own index. Returns the same JSON as
/// `look_search_json`, or null when the query is not a file-recall query. Free
/// with `look_free_cstring`.

/// File recall from structured params JSON `{terms?, types?, when?, location?}`
/// (the model's `recall` step). Same payload shape as `look_search_files_json`;
/// null when the params are unusable. Free with `look_free_cstring`.

#[unsafe(no_mangle)]
pub extern "C" fn look_record_usage(candidate_id: *const c_char, action: *const c_char) -> bool {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        usage_api::look_record_usage_impl(candidate_id, action)
    }))
    .unwrap_or(false)
}

#[unsafe(no_mangle)]
pub extern "C" fn look_record_usage_json(
    candidate_id: *const c_char,
    action: *const c_char,
) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        usage_api::look_record_usage_json_impl(candidate_id, action)
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "C" fn look_reload_config() -> bool {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        // Drop the engine's cached `~/.look/config` before anything below reads
        // RuntimeConfig - otherwise the reload would see stale roots/limits.
        look_engine::config::RuntimeConfig::invalidate_cache();
        runtime_config::reload_runtime_config();
        state::restart_index_watchers();
        let path = state::default_db_path();
        if QueryEngine::bootstrap_sqlite(&path).is_err() {
            state::mark_index_dirty();
            return false;
        }
        state::refresh_engine_cache();
        state::clear_index_dirty();
        true
    }))
    .unwrap_or(false)
}

#[unsafe(no_mangle)]
pub extern "C" fn look_seed_uwp_apps_json(json: *const c_char) -> bool {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        seed_api::look_seed_uwp_apps_json_impl(json)
    }))
    .unwrap_or(false)
}

#[unsafe(no_mangle)]
pub extern "C" fn look_request_index_refresh() -> bool {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        state::request_background_index_refresh()
    }))
    .unwrap_or(false)
}

/// The launch-mode table as `--list-modes` prints it. Free with
/// `look_free_cstring`.
#[unsafe(no_mangle)]
pub extern "C" fn look_modes_list_text() -> *mut c_char {
    std::panic::catch_unwind(modes_api::look_modes_list_text_impl).unwrap_or(std::ptr::null_mut())
}

/// Parse argv (a JSON array of strings, program name already dropped) into
/// `{"kind":"normal"|"query"|"list_modes"|"unknown_mode", ...}`. Free with
/// `look_free_cstring`.
#[unsafe(no_mangle)]
pub extern "C" fn look_modes_parse_json(argv_json: *const c_char) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        modes_api::look_modes_parse_json_impl(argv_json)
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Lunar date JSON (`{day, month, year, leap}`) for a Gregorian `(year, month,
/// day)` at UTC offset `tz` hours. Free the result with `look_free_cstring`.
#[unsafe(no_mangle)]
pub extern "C" fn look_lunar_date_json(year: i64, month: i64, day: i64, tz: f64) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        lunar_api::look_lunar_date_json_impl(year, month, day, tz)
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// The call request in `query` (`{"name":"mom","modality":null}`), or the
/// literal `null` for an ordinary search. Tier-1 grammar, cheap enough to call
/// on every keystroke. Free the result with `look_free_cstring`.

/// The modality a bare "call" means (a `Modality` id). Free with
/// `look_free_cstring`.

/// The URL that dials `handle` with `modality` (a `Modality` id such as
/// `face_time_audio`). Null when the modality is unknown. Free the result with
/// `look_free_cstring`.

/// The join request in `query` (`{}` for a bare "join", `{"name": "..."}` when
/// it names a meeting), or the literal `null` for an ordinary search. Tier-1
/// grammar, cheap enough to call on every keystroke. Free the result with
/// `look_free_cstring`.

/// What a `join` found in the events the shell fetched.
///
/// `events_json` is an array of `{title, startUnixS, endUnixS, url?, location?,
/// notes?, allDay?}`. `name` narrows to meetings whose title carries those
/// words; pass an empty string for "whatever is next". Returns
/// `{"meetings":[...],"withoutLink":[...]}`, the second list naming events that
/// matched but carry no join link. Free the result with `look_free_cstring`.

/// A full speed test as JSON (`{"ok":true,"reading":{...}}` or
/// `{"ok":false,"error":"..."}`). Blocks for 15 seconds and up, so call it off
/// the UI thread. Free the result with `look_free_cstring`.
#[unsafe(no_mangle)]
pub extern "C" fn look_netspeed_run_json() -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(
        netspeed_api::look_netspeed_run_json_impl,
    ))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "C" fn look_free_cstring(ptr: *mut c_char) {
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        state::free_json_allocation(ptr)
    }));
}

#[unsafe(no_mangle)]
pub extern "C" fn look_translate_json(
    text: *const c_char,
    target_lang: *const c_char,
) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        translate_api::look_translate_json_impl(text, target_lang)
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Resolves a shared instant answer (currency/weather/crypto) for `query`,
/// returning an owned JSON C string - an `Answer` object on a hit, or the JSON
/// literal `null` otherwise. Free the result with `look_free_cstring`.

/// `{id, name, steps}` for the user-declared block a candidate id belongs to,
/// so the panel can show what Enter will perform. `null` when the row is not a
/// block row.

/// The rows of `block_id` produced against the selected row, for descending
/// into a `then` target that lists rather than performs. Returns
/// `{rows, truncated, error}`; each row's `candidateId` encodes the levels it
/// came through, so two parents never share a row.
///
/// Runs the block live on every call. An error means do not descend.

/// Every declared block as `{id, name, icon}`, for the shell's row-icon cache.

/// What `action` ("edit", "terminal", "reveal") does to the row at `path`, as
/// `{kind, tool, command, path, reason, key}` where `kind` is "shell",
/// "application", "system_default", or "unavailable". Null for an unknown
/// action or empty path.
///
/// Reads the declared tools from the cached config, so Cmd+Shift+; is all a
/// user needs after editing them.
///
/// A block that declares `edit` / `terminal` / `reveal` wins for its own rows,
/// so pass the row's id, title and ancestors: its verb expands like every other
/// command it declares.
#[unsafe(no_mangle)]
pub extern "C" fn look_tool_action_json(
    action: *const c_char,
    candidate_id: *const c_char,
    row_title: *const c_char,
    path: *const c_char,
    is_dir: bool,
    ancestors_json: *const c_char,
) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        tools_api::look_tool_action_json_impl(
            action,
            candidate_id,
            row_title,
            path,
            is_dir,
            ancestors_json,
        )
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Runs `action` on the row at `path`. Shell actions are performed here,
/// detached, and come back as `{"kind":"performed"}` or `{"kind":"failed"}`; an
/// `application` result is handed back for the shell to launch itself.
#[unsafe(no_mangle)]
pub extern "C" fn look_perform_tool_action_json(
    action: *const c_char,
    candidate_id: *const c_char,
    row_title: *const c_char,
    path: *const c_char,
    is_dir: bool,
    ancestors_json: *const c_char,
) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        tools_api::look_perform_tool_action_json_impl(
            action,
            candidate_id,
            row_title,
            path,
            is_dir,
            ancestors_json,
        )
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Every action id `look_tool_action_json` accepts, as a JSON array.
#[unsafe(no_mangle)]
pub extern "C" fn look_tool_actions_json() -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(
        tools_api::look_tool_actions_json_impl,
    ))
    .unwrap_or(std::ptr::null_mut())
}

/// The config file to read and write. Pass `dev` for a development build, which
/// keeps its own pair so it never edits the installed copy's settings. Plain
/// path string, not JSON.
#[unsafe(no_mangle)]
pub extern "C" fn look_config_path(dev: bool) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .ok()
            .filter(|v| !v.trim().is_empty())
            .map(std::path::PathBuf::from);
        let Some(home) = home else {
            return crate::state::json_cstring_or_null(None);
        };
        let resolved = look_engine::config_path::resolve_home_variant(&home, dev);
        crate::state::json_cstring_or_null(Some(
            resolved.path.to_string_lossy().into_owned(),
        ))
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Shared `core/matching` fuzzy score for `query` vs `title` (both pre-lowercased
/// by the caller). Returns `matching_api::NO_MATCH` (`i64::MIN`) on no match, so
/// callers reproduce the linows ranking without porting the algorithm.
#[unsafe(no_mangle)]
pub extern "C" fn look_fuzzy_score(query: *const c_char, title: *const c_char) -> i64 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        matching_api::look_fuzzy_score_impl(query, title)
    }))
    .unwrap_or(matching_api::NO_MATCH)
}

/// URL classification JSON for `query` (a `UrlMatch` object or `null`).
#[unsafe(no_mangle)]
pub extern "C" fn look_classify_url_json(query: *const c_char) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        answers_api::look_classify_url_json_impl(query)
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Records that `url` was opened through the launcher. Returns false on failure.
#[unsafe(no_mangle)]
pub extern "C" fn look_record_url_hit(url: *const c_char) -> bool {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        url_history_api::look_record_url_hit_impl(url)
    }))
    .unwrap_or(false)
}

/// JSON array of up to `limit` remembered URLs matching `query` (or `[]`).
#[unsafe(no_mangle)]
pub extern "C" fn look_recent_urls_json(query: *const c_char, limit: u32) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        url_history_api::look_recent_urls_json_impl(query, limit)
    }))
    .unwrap_or(std::ptr::null_mut())
}

/// Remembers a clipboard entry, returning its row id (0 on failure). The SHELL
/// must not call this for concealed or transient clips (password managers,
/// one-time secrets): only it can see the pasteboard markers that say so.
#[unsafe(no_mangle)]
pub extern "C" fn look_clipboard_record(
    content: *const c_char,
    app_bundle_id: *const c_char,
) -> i64 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        clipboard_api::look_clipboard_record_impl(content, app_bundle_id)
    }))
    .unwrap_or(0)
}

/// Remembers a copied image, returning its row id (0 on failure). The bytes are
/// the shell's to write, under `image_hash`. Same concealed-clip rule as above.
#[unsafe(no_mangle)]
pub extern "C" fn look_clipboard_record_image(
    label: *const c_char,
    image_hash: *const c_char,
    app_bundle_id: *const c_char,
) -> i64 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        clipboard_api::look_clipboard_record_image_impl(label, image_hash, app_bundle_id)
    }))
    .unwrap_or(0)
}

/// Where image clips keep their bytes. Each file's name starts with the hash of
/// the row that owns it; anything not backed by a row is swept.
#[unsafe(no_mangle)]
pub extern "C" fn look_clipboard_images_dir() -> *mut c_char {
    std::panic::catch_unwind(clipboard_api::look_clipboard_images_dir_impl)
        .unwrap_or(std::ptr::null_mut())
}

/// JSON array of up to `limit` remembered clips of `kind` matching `query`
/// (or `[]`).
#[unsafe(no_mangle)]
pub extern "C" fn look_clipboard_list_json(
    kind: *const c_char,
    query: *const c_char,
    limit: u32,
) -> *mut c_char {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        clipboard_api::look_clipboard_list_json_impl(kind, query, limit)
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[unsafe(no_mangle)]
pub extern "C" fn look_clipboard_delete(id: i64) -> bool {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        clipboard_api::look_clipboard_delete_impl(id)
    }))
    .unwrap_or(false)
}

/// Forgets every remembered clip, returning how many were removed.
#[unsafe(no_mangle)]
pub extern "C" fn look_clipboard_clear() -> u32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(
        clipboard_api::look_clipboard_clear_impl,
    ))
    .unwrap_or(0)
}

/// Quick Action descriptors JSON for the result `(result_id, kind)` (or `[]`).

/// The empty-state launchpad layout as `{columns, rows, tiles}` (or `[]`).
/// The layout is fixed and input-free, so this takes no arguments. Free the
/// result with `look_free_cstring`.

/// JSON array of strings describing anything wrong with `~/.look/super-actions.toml`
/// (or `[]`). Free the result with `look_free_cstring`.

/// Free with `look_free_cstring`.

/// Spawns and blocks: call off the UI thread. Free with `look_free_cstring`.

/// Returns `{"error": ...}`. Free with `look_free_cstring`.

/// Definitional entity JSON for `query` (a JSON string or `null`).

#[cfg(test)]
mod tests {
    use super::*;
    use look_indexing::{Candidate, CandidateKind};
    use look_storage::SqliteStore;
    use std::env;
    use std::ffi::{CStr, CString};
    use std::fs;
    use std::path::PathBuf;
    use std::sync::{Mutex, OnceLock};
    use std::thread;
    use std::time::Duration;
    use std::time::{SystemTime, UNIX_EPOCH};

    static TEST_MUTEX: OnceLock<Mutex<()>> = OnceLock::new();

    /// Config the whole binary runs against, so no test reads the developer's
    /// real `~/.look/config`.
    const TEST_CONFIG: &str =
        "lazy_indexing_enabled=true\nfile_scan_roots=\nfile_scan_extra_roots=\napp_scan_roots=\n";

    /// Serializes the tests that share process-global state, and publishes the
    /// scratch config path exactly once, inside the `OnceLock` initializer: every
    /// test waits here before its body runs, so the one `set_var` in the suite
    /// lands before any engine thread exists to read it concurrently. The
    /// database path needs to differ per test and goes through
    /// `state::set_db_path_for_test` instead, which touches no environment.
    /// Callers take this with `unwrap_or_else(|p| p.into_inner())`, never
    /// `expect`: a panicking test poisons the mutex, and panicking again on
    /// the poison turns one real failure into a cascade of "test lock
    /// poisoned" reports that bury the actual cause.
    fn test_lock() -> &'static Mutex<()> {
        TEST_MUTEX.get_or_init(|| {
            let path = test_config_path();
            fs::write(&path, TEST_CONFIG).expect("write test config");
            unsafe {
                env::set_var("LOOK_CONFIG_PATH", path.as_os_str());
            }
            Mutex::new(())
        })
    }

    /// Fixed, unlike the database path: it is published to the environment once
    /// and so cannot change between tests.
    fn test_config_path() -> PathBuf {
        env::temp_dir().join("look-ffi-config-smoke.config")
    }

    #[test]
    fn ffi_search_and_record_usage_smoke() {
        let _guard = test_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        // Both sides of the guard: an index refresh spawned by an earlier test
        // runs detached and reads the database path late, so it would rebuild
        // `candidates` in this test's scratch database and delete the row below.
        state::wait_for_index_refresh_for_test();

        let db_path = unique_test_db_path();
        let _ = fs::remove_file(&db_path);

        let mut store = SqliteStore::open(&db_path).expect("open sqlite store");
        store
            .upsert_candidates(&[smoke_candidate()])
            .expect("insert smoke candidate");

        state::set_db_path_for_test(&db_path);
        assert!(look_reload_config());

        // `look_reload_config` starts filesystem watchers on the real scan
        // roots. Any event under them marks the index dirty, which lets a
        // background refresh fire - and that refresh runs DETACHED, reads the
        // database path late, and rebuilds `candidates` in this test's scratch
        // database, deleting the row inserted above. The neighbouring refresh
        // test stops them for the same reason.
        state::stop_index_watchers_for_test();
        state::wait_for_index_refresh_for_test();

        let query = CString::new("smoke").expect("query cstring");
        let ptr = look_search_json(query.as_ptr(), 10);
        assert!(!ptr.is_null());

        let raw = unsafe { CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned();
        look_free_cstring(ptr);

        let payload: serde_json::Value = serde_json::from_str(&raw).expect("valid search payload");

        let mut has_smoke = payload
            .get("results")
            .and_then(|value| value.as_array())
            .is_some_and(|results| {
                results.iter().any(|item| {
                    item.get("id")
                        .and_then(|value| value.as_str())
                        .is_some_and(|id| id == "app:smoke.test")
                })
            });

        if !has_smoke {
            // Background bootstrap refresh can replace the in-memory cache during tests
            // (including racing the cache to empty before the first search). Re-seed the
            // sqlite fixture and refresh the cache before asserting.
            let mut store = SqliteStore::open(&db_path).expect("re-open sqlite store");
            store
                .upsert_candidates(&[smoke_candidate()])
                .expect("reinsert smoke candidate");
            state::refresh_engine_cache();

            let retry_ptr = look_search_json(query.as_ptr(), 10);
            assert!(!retry_ptr.is_null());
            let retry_raw = unsafe { CStr::from_ptr(retry_ptr) }
                .to_string_lossy()
                .into_owned();
            look_free_cstring(retry_ptr);
            let retry_payload: serde_json::Value =
                serde_json::from_str(&retry_raw).expect("valid retry payload");
            has_smoke = retry_payload
                .get("results")
                .and_then(|value| value.as_array())
                .is_some_and(|results| {
                    results.iter().any(|item| {
                        item.get("id")
                            .and_then(|value| value.as_str())
                            .is_some_and(|id| id == "app:smoke.test")
                    })
                });
        }
        assert!(has_smoke);

        let compact_ptr = look_search_json_compact(query.as_ptr(), 10);
        assert!(!compact_ptr.is_null());
        let compact_raw = unsafe { CStr::from_ptr(compact_ptr) }
            .to_string_lossy()
            .into_owned();
        look_free_cstring(compact_ptr);
        let compact_payload: serde_json::Value =
            serde_json::from_str(&compact_raw).expect("valid compact payload");
        assert!(compact_payload.get("query").is_none());
        assert!(compact_payload.get("results").is_some());

        // The subject below is `look_record_usage`; that the candidate exists is
        // its PRECONDITION, so it is re-established here rather than assumed to
        // have survived. `usage_events` has a foreign key onto `candidates`, and
        // an index refresh - which runs detached and reads the database path
        // late - rebuilds that table. Those refreshes are triggered from state
        // this binary shares across test modules that hold DIFFERENT locks
        // (state.rs has its own), so no amount of waiting here makes the row's
        // survival something this test can rely on.
        store
            .upsert_candidates(&[smoke_candidate()])
            .expect("re-establish the smoke candidate");

        let id = CString::new("app:smoke.test").expect("id cstring");
        let action = CString::new("open").expect("action cstring");
        assert!(look_record_usage(id.as_ptr(), action.as_ptr()));

        let usage_ptr = look_record_usage_json(id.as_ptr(), action.as_ptr());
        assert!(!usage_ptr.is_null());
        let usage_raw = unsafe { CStr::from_ptr(usage_ptr) }
            .to_string_lossy()
            .into_owned();
        look_free_cstring(usage_ptr);
        let usage_payload: serde_json::Value =
            serde_json::from_str(&usage_raw).expect("valid usage payload");
        assert_eq!(
            usage_payload.get("ok").and_then(|v| v.as_bool()),
            Some(true)
        );

        let empty = CString::new("").expect("empty cstring");
        assert!(!look_record_usage(empty.as_ptr(), action.as_ptr()));
        let invalid_ptr = look_record_usage_json(empty.as_ptr(), action.as_ptr());
        assert!(!invalid_ptr.is_null());
        let invalid_raw = unsafe { CStr::from_ptr(invalid_ptr) }
            .to_string_lossy()
            .into_owned();
        look_free_cstring(invalid_ptr);
        let invalid_payload: serde_json::Value =
            serde_json::from_str(&invalid_raw).expect("valid invalid-usage payload");
        assert_eq!(
            invalid_payload.get("ok").and_then(|v| v.as_bool()),
            Some(false)
        );
        assert!(
            invalid_payload
                .get("error")
                .and_then(|e| e.get("code"))
                .and_then(|v| v.as_str())
                .is_some()
        );

        let bad_action = CString::new("not_a_usage_action").expect("bad action");
        let bad_action_ptr = look_record_usage_json(id.as_ptr(), bad_action.as_ptr());
        assert!(!bad_action_ptr.is_null());
        let bad_action_raw = unsafe { CStr::from_ptr(bad_action_ptr) }
            .to_string_lossy()
            .into_owned();
        look_free_cstring(bad_action_ptr);
        let bad_action_payload: serde_json::Value =
            serde_json::from_str(&bad_action_raw).expect("valid bad-action payload");
        assert_eq!(
            bad_action_payload
                .get("error")
                .and_then(|e| e.get("code"))
                .and_then(|v| v.as_str()),
            Some("invalid_usage_action")
        );

        let loaded = SqliteStore::open(&db_path)
            .expect("reopen sqlite")
            .load_candidates(None)
            .expect("load candidates after usage");
        let updated = loaded
            .iter()
            .find(|candidate| candidate.id.as_ref() == "app:smoke.test")
            .expect("smoke candidate exists");
        assert_eq!(updated.use_count, 2);
        assert!(updated.last_used_at_unix_s.is_some());

        let _ = fs::remove_file(&db_path);
    }

    fn smoke_candidate() -> Candidate {
        Candidate {
            id: "app:smoke.test".into(),
            kind: CandidateKind::App,
            title: "Smoke Test App".into(),
            subtitle: Some("smoke app".into()),
            path: "/Applications/Smoke Test App.app".into(),
            ..Default::default()
        }
    }

    #[test]
    fn ffi_reload_refresh_and_translate_error_smoke() {
        let _guard = test_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        let db_path = unique_test_db_path();
        let _ = fs::remove_file(&db_path);
        state::set_db_path_for_test(&db_path);

        assert!(look_reload_config());

        crate::state::stop_index_watchers_for_test();
        thread::sleep(Duration::from_millis(50));

        crate::state::mark_index_dirty();
        let mut refresh_triggered = false;
        for _ in 0..20 {
            if look_request_index_refresh() {
                refresh_triggered = true;
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
        assert!(
            refresh_triggered,
            "expected refresh request to acquire slot at least once"
        );

        // The refresh runs on a DETACHED thread. Leaving this test without
        // waiting for it releases the lock while it is still going, and it then
        // rebuilds `candidates` in whatever database the NEXT test points the
        // process-global path at - deleting the row that test just inserted.
        crate::state::wait_for_index_refresh_for_test();

        thread::sleep(Duration::from_millis(100));

        let text = CString::new("hello").expect("text cstring");
        let bad_lang = CString::new("invalid_lang!").expect("bad lang cstring");
        let bad_lang_ptr = look_translate_json(text.as_ptr(), bad_lang.as_ptr());
        let bad_lang_payload = json_from_ptr(bad_lang_ptr);
        assert_eq!(
            bad_lang_payload
                .get("error")
                .and_then(|e| e.get("code"))
                .and_then(|v| v.as_str()),
            Some("invalid_target_lang")
        );

        let empty = CString::new("").expect("empty cstring");
        let lang = CString::new("en").expect("lang cstring");
        let empty_ptr = look_translate_json(empty.as_ptr(), lang.as_ptr());
        let empty_payload = json_from_ptr(empty_ptr);
        assert_eq!(
            empty_payload
                .get("error")
                .and_then(|e| e.get("code"))
                .and_then(|v| v.as_str()),
            Some("empty_text")
        );

        crate::state::stop_index_watchers_for_test();
        let _ = fs::remove_file(&db_path);
    }

    fn json_from_ptr(ptr: *mut std::os::raw::c_char) -> serde_json::Value {
        assert!(!ptr.is_null());
        let raw = unsafe { CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned();
        look_free_cstring(ptr);
        serde_json::from_str(&raw).expect("valid json payload")
    }

    fn unique_test_db_path() -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        env::temp_dir().join(format!("look-ffi-smoke-{nanos}.db"))
    }

    #[test]
    fn ffi_seed_uwp_apps_json_inserts_and_search_finds() {
        let _guard = test_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());

        // Both sides of the guard, for the reason the smoke test above gives.
        state::wait_for_index_refresh_for_test();

        let db_path = unique_test_db_path();
        let _ = fs::remove_file(&db_path);

        state::set_db_path_for_test(&db_path);
        assert!(look_reload_config());
        // The reload restarts the watchers and can spawn a refresh of its own,
        // neither wanted while this seeds and prunes the same database.
        state::stop_index_watchers_for_test();
        state::wait_for_index_refresh_for_test();

        // The JSON shape the seeding API accepts.
        let json = CString::new(
            r#"[
                {"aumid": "Microsoft.WindowsTerminal_8wekyb3d8bbwe!App", "title": "Terminal"},
                {"aumid": "Microsoft.WindowsNotepad_8wekyb3d8bbwe!App", "title": "Notepad"}
            ]"#,
        )
        .expect("seed json");
        assert!(look_seed_uwp_apps_json(json.as_ptr()));

        // Round-trip via sqlite - make sure the rows actually persisted with the right shape.
        let stored = SqliteStore::open(&db_path)
            .expect("reopen sqlite")
            .load_candidates(None)
            .expect("load candidates");
        let terminal = stored
            .iter()
            .find(|c| c.id.as_ref() == "app:uwp:Microsoft.WindowsTerminal_8wekyb3d8bbwe!App")
            .expect("seeded terminal candidate");
        assert_eq!(terminal.title.as_ref(), "Terminal");
        assert_eq!(
            terminal.path.as_ref(),
            "shell:AppsFolder\\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"
        );
        assert_eq!(terminal.use_count, 0);
        assert_eq!(terminal.last_used_at_unix_s, None);

        // Search has to surface the seeded entry - without this, the user can't find Terminal
        // via the launcher even though it sits in the DB.
        let query = CString::new("terminal").expect("query");
        let ptr = look_search_json(query.as_ptr(), 10);
        assert!(!ptr.is_null());
        let raw = unsafe { CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned();
        look_free_cstring(ptr);
        let payload: serde_json::Value = serde_json::from_str(&raw).expect("valid search payload");
        let has_terminal = payload
            .get("results")
            .and_then(|value| value.as_array())
            .is_some_and(|results| {
                results.iter().any(|item| {
                    item.get("id")
                        .and_then(|value| value.as_str())
                        .is_some_and(|id| {
                            id == "app:uwp:Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"
                        })
                })
            });
        assert!(
            has_terminal,
            "expected seeded UWP Terminal in search results, got: {raw}"
        );

        // Re-seeding must be idempotent and preserve use_count after a launch.
        let id = CString::new("app:uwp:Microsoft.WindowsTerminal_8wekyb3d8bbwe!App").expect("id");
        let action = CString::new("open_app").expect("action");
        assert!(look_record_usage(id.as_ptr(), action.as_ptr()));
        assert!(look_seed_uwp_apps_json(json.as_ptr())); // second seed
        let after = SqliteStore::open(&db_path)
            .expect("reopen")
            .load_candidates(None)
            .expect("load");
        let after_terminal = after
            .iter()
            .find(|c| c.id.as_ref() == "app:uwp:Microsoft.WindowsTerminal_8wekyb3d8bbwe!App")
            .expect("still here");
        assert_eq!(
            after_terminal.use_count, 1,
            "re-seeding must preserve use_count via ON CONFLICT"
        );

        // Re-seed with Notepad omitted - simulates the user uninstalling that UWP app
        // between runs. The vanished row must be pruned so it doesn't keep showing up
        // in search forever (delete_stale_candidates can't reach rows written with
        // indexed_at_unix_s = i64::MAX).
        let json_terminal_only = CString::new(
            r#"[{"aumid": "Microsoft.WindowsTerminal_8wekyb3d8bbwe!App", "title": "Terminal"}]"#,
        )
        .expect("seed json terminal only");
        assert!(look_seed_uwp_apps_json(json_terminal_only.as_ptr()));

        let after_prune = SqliteStore::open(&db_path)
            .expect("reopen for prune check")
            .load_candidates(None)
            .expect("load after prune");
        let ids_after_prune: Vec<&str> = after_prune.iter().map(|c| c.id.as_ref()).collect();
        assert!(ids_after_prune.contains(&"app:uwp:Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"));
        assert!(
            !ids_after_prune.contains(&"app:uwp:Microsoft.WindowsNotepad_8wekyb3d8bbwe!App"),
            "Notepad should have been pruned after disappearing from the seed"
        );

        state::wait_for_index_refresh_for_test();
        let _ = fs::remove_file(&db_path);
    }
}
