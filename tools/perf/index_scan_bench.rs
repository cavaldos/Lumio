//! Full-bootstrap cost of the file/folder scan on a synthetic tree.
//!
//! Two shapes:
//!   • `folders` — a folder-heavy tree (40 × 40 × 40 = 64,000 dirs, one file
//!     per leaf dir up to the file limit). Folders are not counted against
//!     `file_scan_limit`, so this is where an uncapped walk indexes everything.
//!   • `files`   — an ordinary tree (50 dirs × 200 files) where the file limit
//!     is what stops the walk. Guards against a regression on the common case.
//!
//! Each run bootstraps into a fresh throwaway DB via `LUMIO_DB_PATH` /
//! `LUMIO_CONFIG_PATH`, so the live index is never touched. Reports the median
//! wall time, the candidate count, and the WAL size left on disk.
//!
//! Run with (peak RSS comes from `time -l`):
//!   cargo build --release --bin index_scan_bench --manifest-path tools/perf/Cargo.toml
//!   /usr/bin/time -l tools/perf/target/release/index_scan_bench folders
use lumio_engine::QueryEngine;
use std::env;
use std::fs;
use std::path::Path;
use std::time::Instant;

const RUNS: usize = 5;
const FILE_SCAN_LIMIT: usize = 5_000;

fn main() {
    let shape = env::args().nth(1).unwrap_or_else(|| "folders".into());
    let tempdir = env::temp_dir().join(format!("lumio-index-scan-{shape}-{}", std::process::id()));
    let apps_root = tempdir.join("apps");
    let files_root = tempdir.join("files");
    let config_path = tempdir.join("lumio.config");
    fs::create_dir_all(&apps_root).expect("mkdir apps");
    fs::create_dir_all(&files_root).expect("mkdir files");

    let (dirs, files) = match shape.as_str() {
        "folders" => build_folder_heavy(&files_root),
        "files" => build_file_heavy(&files_root),
        other => panic!("unknown shape {other:?}; use `folders` or `files`"),
    };
    write_config(&config_path, &apps_root, &files_root);
    unsafe { env::set_var("LUMIO_CONFIG_PATH", &config_path) };

    let mut times_ms = Vec::with_capacity(RUNS);
    let mut candidates = 0;
    let mut wal_bytes = 0;
    for run in 0..RUNS {
        let db_path = tempdir.join(format!("run{run}.db"));
        unsafe { env::set_var("LUMIO_DB_PATH", &db_path) };
        let started = Instant::now();
        QueryEngine::bootstrap_sqlite(&db_path).expect("bootstrap");
        times_ms.push(started.elapsed().as_secs_f64() * 1000.0);
        wal_bytes = fs::metadata(db_path.with_extension("db-wal"))
            .map(|m| m.len())
            .unwrap_or(0);
        candidates = lumio_storage::SqliteStore::open(&db_path)
            .and_then(|s| s.load_candidates(None))
            .map(|v| v.len())
            .unwrap_or(0);
    }
    times_ms.sort_by(|a, b| a.partial_cmp(b).unwrap());

    println!("shape                 {shape}");
    println!("tree                  {dirs} dirs, {files} files");
    println!("bootstrap median      {:.1} ms", times_ms[RUNS / 2]);
    println!(
        "bootstrap min..max    {:.1} .. {:.1} ms",
        times_ms[0],
        times_ms[RUNS - 1]
    );
    println!("candidates in DB      {candidates}");
    println!("wal on disk           {:.1} KiB", wal_bytes as f64 / 1024.0);

    let _ = fs::remove_dir_all(&tempdir);
}

fn build_folder_heavy(root: &Path) -> (usize, usize) {
    let (mut dirs, mut files) = (0, 0);
    for a in 0..40 {
        for b in 0..40 {
            for c in 0..40 {
                let dir = root.join(format!("a{a}/b{b}/c{c}"));
                fs::create_dir_all(&dir).expect("mkdir");
                dirs += 1;
                if files < 2_000 {
                    fs::write(dir.join("note.txt"), b"x").expect("write");
                    files += 1;
                }
            }
        }
    }
    (dirs, files)
}

fn build_file_heavy(root: &Path) -> (usize, usize) {
    let (mut dirs, mut files) = (0, 0);
    for d in 0..50 {
        let dir = root.join(format!("dir{d}"));
        fs::create_dir_all(&dir).expect("mkdir");
        dirs += 1;
        for f in 0..200 {
            fs::write(dir.join(format!("file{f}.txt")), b"x").expect("write");
            files += 1;
        }
    }
    (dirs, files)
}

fn write_config(path: &Path, apps_root: &Path, files_root: &Path) {
    let contents = format!(
        "app_scan_roots={}\n\
         app_scan_depth=2\n\
         file_scan_roots={}\n\
         file_scan_extra_roots=\n\
         file_scan_depth=4\n\
         file_scan_limit={FILE_SCAN_LIMIT}\n\
         lazy_indexing_enabled=true\n",
        apps_root.display(),
        files_root.display(),
    );
    fs::write(path, contents).expect("write config");
}
