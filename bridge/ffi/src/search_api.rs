use crate::runtime_config::{is_debug_enabled, log_debug};
use crate::state::{cstr_to_string, store_json_allocation, with_engine};
use look_engine::LaunchResult;
use serde::Serialize;
use std::ffi::CString;
use std::os::raw::c_char;
use std::time::Instant;

const MAX_SEARCH_COUNT_QUERY_LEN: u32 = 1000;
const DEFAULT_SEARCH_LIMIT: u32 = 20;
const MAX_SEARCH_LIMIT: u32 = 100;

#[repr(C)]
pub struct FfiSearchResult {
    pub count: u32,
}

#[derive(serde::Serialize)]
struct FfiSearchPayload<'a> {
    query: &'a str,
    count: usize,
    results: Vec<look_engine::LaunchResult>,
    /// File recall only: which fallback produced the results when the strict
    /// query matched nothing ("window" | "terms" | "window_terms"), so the
    /// shell can label them instead of silently showing something broader.
    #[serde(skip_serializing_if = "Option::is_none")]
    relaxed: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<FfiErrorPayload>,
}

#[derive(Serialize)]
struct FfiCompactSearchPayload<'a> {
    count: usize,
    results: Vec<FfiCompactLaunchResult<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<FfiErrorPayload>,
}

#[derive(Serialize)]
struct FfiCompactLaunchResult<'a> {
    id: &'a str,
    kind: &'a str,
    title: &'a str,
    subtitle: Option<&'a str>,
    path: &'a str,
    score: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    icon: Option<&'a str>,
}

#[derive(serde::Serialize)]
struct FfiErrorPayload {
    code: &'static str,
    message: String,
}

#[derive(Clone, Copy)]
enum SearchError {
    SerializeFailed,
}

impl SearchError {
    fn code(self) -> &'static str {
        match self {
            Self::SerializeFailed => "serialize_failed",
        }
    }

    fn message(self) -> &'static str {
        match self {
            Self::SerializeFailed => "Failed to serialize search results",
        }
    }
}

pub(crate) fn look_search_count_impl(query_len: u32) -> FfiSearchResult {
    let len = query_len.min(MAX_SEARCH_COUNT_QUERY_LEN);
    let query = "x".repeat(len as usize);
    let results = with_engine(|engine| engine.search(&query, DEFAULT_SEARCH_LIMIT as usize));
    FfiSearchResult {
        count: results.len() as u32,
    }
}

pub(crate) fn look_search_json_impl(query: *const c_char, limit: u32) -> *mut c_char {
    let query = cstr_to_string(query);
    let max = normalized_limit(limit);
    let started_at = Instant::now();

    let results = with_engine(|engine| engine.search(&query, max as usize));
    let result_count = results.len();
    let cstring = serialize_full_payload(&query, results, None);
    if is_debug_enabled() {
        log_debug(&format!(
            "search query_len={} limit={} count={} elapsed_ms={}",
            query.len(),
            max,
            result_count,
            started_at.elapsed().as_millis()
        ));
    }
    store_json_allocation(cstring)
}

/// A parse with terms and nothing else was triggered by a bare "file" or
/// "download" word. Kept for the unit tests below.
fn is_weak_empty_recall(filter: &look_engine::FileFilter, results: &[LaunchResult]) -> bool {
    results.is_empty()
        && !filter.terms.trim().is_empty()
        && filter.categories.is_empty()
        && filter.locations.is_empty()
        && filter.start.is_none()
        && filter.end.is_none()
}

fn relaxed_code(relaxation: Option<look_engine::FileSearchRelaxation>) -> Option<&'static str> {
    relaxation.map(|r| match r {
        look_engine::FileSearchRelaxation::WidenedWindow => "window",
        look_engine::FileSearchRelaxation::DroppedTerms => "terms",
        look_engine::FileSearchRelaxation::DroppedTermsWidenedWindow => "window_terms",
    })
}

pub(crate) fn look_search_json_compact_impl(query: *const c_char, limit: u32) -> *mut c_char {
    let query = cstr_to_string(query);
    let max = normalized_limit(limit);
    let started_at = Instant::now();

    let scored = with_engine(|engine| engine.search_scored(&query, max as usize));
    let result_count = scored.len();
    let compact_results: Vec<FfiCompactLaunchResult<'_>> = scored
        .iter()
        .map(|(candidate, score)| FfiCompactLaunchResult {
            id: &candidate.id,
            kind: candidate.kind.as_str(),
            title: &candidate.title,
            subtitle: candidate.subtitle.as_deref(),
            path: &candidate.path,
            score: *score,
            icon: candidate.icon.as_deref(),
        })
        .collect();
    let payload = FfiCompactSearchPayload {
        count: result_count,
        results: compact_results,
        error: None,
    };

    let json = serde_json::to_string(&payload)
        .unwrap_or_else(|_| search_error_json_compact(SearchError::SerializeFailed));
    let cstring = CString::new(json).unwrap_or_else(|_| {
        CString::new(
            "{\"count\":0,\"results\":[],\"error\":{\"code\":\"serialize_failed\",\"message\":\"Failed to serialize search results\"}}",
        )
            .expect("valid static json")
    });
    if is_debug_enabled() {
        log_debug(&format!(
            "search_compact query_len={} limit={} count={} elapsed_ms={}",
            query.len(),
            max,
            result_count,
            started_at.elapsed().as_millis()
        ));
    }
    store_json_allocation(cstring)
}

impl<'a> From<&'a LaunchResult> for FfiCompactLaunchResult<'a> {
    fn from(value: &'a LaunchResult) -> Self {
        Self {
            id: &value.id,
            kind: &value.kind,
            title: &value.title,
            subtitle: value.subtitle.as_deref(),
            path: &value.path,
            score: value.score,
            icon: value.icon.as_deref(),
        }
    }
}

fn normalized_limit(limit: u32) -> u32 {
    if limit == 0 {
        DEFAULT_SEARCH_LIMIT
    } else {
        limit.min(MAX_SEARCH_LIMIT)
    }
}

fn serialize_full_payload(
    query: &str,
    results: Vec<look_engine::LaunchResult>,
    relaxed: Option<&'static str>,
) -> CString {
    let result_count = results.len();
    let payload = FfiSearchPayload {
        query,
        count: result_count,
        results,
        relaxed,
        error: None,
    };

    let json = serde_json::to_string(&payload)
        .unwrap_or_else(|_| search_error_json_full(query, SearchError::SerializeFailed));

    CString::new(json).unwrap_or_else(|_| {
        CString::new("{\"query\":\"\",\"count\":0,\"results\":[]}").expect("valid static json")
    })
}

fn search_error_json_full(query: &str, err: SearchError) -> String {
    serde_json::json!({
        "query": query,
        "count": 0,
        "results": [],
        "error": {
            "code": err.code(),
            "message": err.message()
        }
    })
    .to_string()
}

fn search_error_json_compact(err: SearchError) -> String {
    serde_json::json!({
        "count": 0,
        "results": [],
        "error": {
            "code": err.code(),
            "message": err.message()
        }
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::is_weak_empty_recall;
    use look_engine::{FileFilter, LaunchResult};
    use look_indexing::{Candidate, CandidateKind};

    fn result() -> LaunchResult {
        LaunchResult::from((
            &Candidate::new("file:a", CandidateKind::File, "a.pdf", "/tmp/a.pdf"),
            1,
        ))
    }

    #[test]
    fn terms_only_recall_with_no_match_falls_back_to_normal_search() {
        let filter = FileFilter {
            terms: "bitcoin price".into(),
            ..Default::default()
        };
        assert!(is_weak_empty_recall(&filter, &[]));
        assert!(!is_weak_empty_recall(&filter, &[result()]));
    }

    #[test]
    fn typed_or_dated_recall_keeps_its_empty_panel() {
        let typed = FileFilter {
            terms: "invoice".into(),
            categories: vec!["pdf".into()],
            ..Default::default()
        };
        let dated = FileFilter {
            terms: "invoice".into(),
            start: Some(0),
            end: Some(1),
            ..Default::default()
        };
        assert!(!is_weak_empty_recall(&typed, &[]));
        assert!(!is_weak_empty_recall(&dated, &[]));
    }

    #[test]
    fn a_bare_files_request_is_not_weak() {
        // "show me my files": every word is glue, so an empty index is the only
        // way it comes back empty. That still asked for files.
        assert!(!is_weak_empty_recall(&FileFilter::default(), &[]));
    }
}
