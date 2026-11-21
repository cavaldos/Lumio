//! The one long-lived `SqliteStore` connection behind the clipboard, URL
//! history and usage endpoints. `SqliteStore::open` re-runs the whole
//! migration, and these endpoints run on every copy made in the OS and on every
//! search keystroke, so they borrow this connection instead of opening one.

use crate::state::default_db_path;
use lumio_storage::SqliteStore;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, OnceLock};

/// Keyed on the path: `set_db_path_for_test` can repoint the database, and an
/// unkeyed cache would keep writing to the old file.
type Cached = Option<(PathBuf, SqliteStore)>;

static SHARED_STORE: OnceLock<Mutex<Cached>> = OnceLock::new();

/// The cached connection for the current database path, opened on first use
/// (and again whenever the path changes). The guard is the lock: hold it only
/// for the store call, and never while calling anything that takes it again.
/// `None` inside means the open failed; the next call retries.
pub(crate) fn store() -> MutexGuard<'static, Cached> {
    lock_for(SHARED_STORE.get_or_init(|| Mutex::new(None)), default_db_path())
}

fn lock_for(cell: &'static Mutex<Cached>, path: PathBuf) -> MutexGuard<'static, Cached> {
    let mut guard = cell.lock().unwrap_or_else(|e| e.into_inner());
    let matches_path = guard.as_ref().is_some_and(|(cached, _)| *cached == path);
    if !matches_path {
        // A failed open is retried on the next call rather than cached.
        *guard = open_at(&path).map(|store| (path, store));
    }
    guard
}

fn open_at(path: &Path) -> Option<SqliteStore> {
    SqliteStore::open(path).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_db(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "lumio-shared-store-{}-{}",
            name,
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).expect("temp dir");
        dir.join("lumio.db")
    }

    #[test]
    fn reuses_the_connection_for_the_same_path_and_reopens_for_a_new_one() {
        static CELL: OnceLock<Mutex<Cached>> = OnceLock::new();
        let cell = CELL.get_or_init(|| Mutex::new(None));
        let first = temp_db("a");
        let second = temp_db("b");

        {
            let guard = lock_for(cell, first.clone());
            let (path, store) = guard.as_ref().expect("opened");
            assert_eq!(path, &first);
            store.record_url_hit("https://example.com/").expect("hit");
        }
        {
            // Same path: the data written above is visible and nothing reopened.
            let guard = lock_for(cell, first.clone());
            let (_, store) = guard.as_ref().expect("still open");
            assert_eq!(store.recent_urls("example", 5).expect("urls").len(), 1);
        }
        {
            let guard = lock_for(cell, second.clone());
            let (path, store) = guard.as_ref().expect("reopened");
            assert_eq!(path, &second);
            assert!(store.recent_urls("example", 5).expect("urls").is_empty());
        }
        let _ = std::fs::remove_dir_all(first.parent().unwrap());
        let _ = std::fs::remove_dir_all(second.parent().unwrap());
    }
}
