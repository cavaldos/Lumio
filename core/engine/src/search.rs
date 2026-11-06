use crate::QueryEngine;
use crate::query::ParsedQuery;
use crate::scoring::{
    ScoredMatch, contains_match_score, default_browse_score, finalize_top_k,
    is_system_settings_candidate, kind_bias, looks_like_settings_query, path_depth_penalty,
    path_match_score, push_top_k, query_kind_penalty_with_settings_flag,
};
use lumio_indexing::{Candidate, CandidateKind};
use lumio_matching::{fuzzy_quality_bonus_prepared, fuzzy_score_prepared, prepare_query};
use lumio_ranking::rank_score;
use std::collections::BinaryHeap;
use std::time::{SystemTime, UNIX_EPOCH};

const RERANK_POOL_MULTIPLIER: usize = 4;
const RERANK_TOP_N: usize = 80;
const RERANK_MIN_QUERY_CHARS: usize = 3;
const SCORE_ALIAS_TITLE_MATCH: i64 = 1_520;
const SCORE_ALIAS_SUBTITLE_MATCH: i64 = 1_260;

fn top_limit(mut ranked: Vec<(u32, i64)>, limit: usize) -> Vec<(u32, i64)> {
    ranked.truncate(limit);
    ranked
}

impl QueryEngine {
    fn has_term_boundary_match(haystack: &str, term: &str) -> bool {
        if term.is_empty() {
            return false;
        }

        for (start, _) in haystack.match_indices(term) {
            let end = start + term.len();
            let left_ok = haystack[..start]
                .chars()
                .next_back()
                .is_none_or(|ch| !ch.is_alphanumeric());
            let right_ok = haystack[end..]
                .chars()
                .next()
                .is_none_or(|ch| !ch.is_alphanumeric());
            if left_ok && right_ok {
                return true;
            }
        }

        false
    }
    fn alias_terms_for_query<'a>(
        &'a self,
        normalized_query: &str,
        kind_filter: Option<&CandidateKind>,
    ) -> Option<&'a Vec<String>> {
        if normalized_query.is_empty() {
            return None;
        }

        if let Some(kind) = kind_filter
            && *kind != CandidateKind::App
        {
            return None;
        }

        self.search_aliases.get(normalized_query)
    }

    fn alias_match_score(
        alias_terms: &[String],
        title_search: &str,
        subtitle_search: Option<&str>,
    ) -> Option<i64> {
        let mut best = None;
        for term in alias_terms {
            if Self::has_term_boundary_match(title_search, term) {
                best = Some(best.unwrap_or(0).max(SCORE_ALIAS_TITLE_MATCH));
            }

            if subtitle_search.is_some_and(|subtitle| Self::has_term_boundary_match(subtitle, term))
            {
                best = Some(best.unwrap_or(0).max(SCORE_ALIAS_SUBTITLE_MATCH));
            }
        }
        best
    }

    fn kind_matches(
        candidate: &crate::IndexedCandidate,
        kind_filter: Option<&CandidateKind>,
    ) -> bool {
        kind_filter.is_none_or(|kind| &candidate.candidate.kind == kind)
    }

    fn search_empty_query(
        &self,
        kind_filter: Option<&CandidateKind>,
        limit: usize,
    ) -> Vec<(u32, i64)> {
        // Empty-query mode is a browse ranking pass: usage + recency, no text matching.
        let now_unix_s = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);

        let mut top = BinaryHeap::new();
        for (idx, candidate) in self.candidates.iter().enumerate() {
            if !Self::kind_matches(candidate, kind_filter) {
                continue;
            }
            let score = default_browse_score(&candidate.candidate, now_unix_s);
            push_top_k(
                &mut top,
                ScoredMatch::new(idx as u32, score, &candidate.candidate.title),
                limit,
            );
        }

        finalize_top_k(top)
    }

    pub(crate) fn search_files_indices(
        &self,
        filter: &crate::FileFilter,
        limit: usize,
    ) -> Vec<(u32, i64)> {
        if limit == 0 {
            return vec![];
        }
        let exts = extensions_for(&filter.categories);
        let want_folder = filter.categories.iter().any(|c| c == "folder");
        let only_folder = want_folder && filter.categories.iter().all(|c| c == "folder");
        let want_screenshot = filter.categories.iter().any(|c| c == "screenshot");
        // Extensions of every OTHER requested category, so a candidate that
        // satisfies one of them is not also forced through the screenshot gate.
        let other_exts: Vec<&'static str> = if want_screenshot {
            let others: Vec<String> = filter
                .categories
                .iter()
                .filter(|c| *c != "screenshot")
                .cloned()
                .collect();
            extensions_for(&others)
        } else {
            Vec::new()
        };
        let type_gated = !filter.categories.is_empty();
        let terms = filter.terms.trim().to_lowercase();

        let mut matches: Vec<(u32, i64)> = Vec::new();
        for (idx, c) in self.candidates.iter().enumerate() {
            let cand = &c.candidate;
            let is_file = cand.kind == CandidateKind::File;
            let is_folder = cand.kind == CandidateKind::Folder;
            if !is_file && !is_folder {
                continue; // apps and processes are never file-recall results
            }
            if only_folder && !is_folder {
                continue;
            }
            // A type-named query ("pdfs", "screenshots") means files, not folders.
            if type_gated && !want_folder && is_folder {
                continue;
            }
            if is_file && !exts.is_empty() && !exts.contains(&ext_of(&cand.path).as_str()) {
                continue;
            }
            // "screenshots" is a PATH heuristic, not an extension, so it must
            // gate only its own category: asking for "screenshots and pdfs"
            // must not drop every pdf whose path lacks the word.
            if want_screenshot && is_file {
                let p = cand.path.to_lowercase();
                let looks_like_screenshot = p.contains("screenshot") || p.contains("screen shot");
                let matches_other_category =
                    !other_exts.is_empty() && other_exts.contains(&ext_of(&cand.path).as_str());
                if !looks_like_screenshot && !matches_other_category {
                    continue;
                }
            }
            let recency = cand.fs_modified_at_unix_s.unwrap_or(0);
            if let (Some(start), Some(end)) = (filter.start, filter.end)
                && (recency < start || recency > end)
            {
                continue;
            }
            if !filter.locations.is_empty() {
                let path = cand.path.to_lowercase();
                let in_location = filter
                    .locations
                    .iter()
                    .any(|loc| location_folder(loc).is_some_and(|f| path.contains(f)));
                if !in_location {
                    continue;
                }
            }
            if !terms.is_empty()
                && !c.title_search.contains(&terms)
                && !cand.path.to_lowercase().contains(&terms)
            {
                continue;
            }
            matches.push((idx as u32, recency));
        }

        // Most-recent first; stable tie-break by title.
        matches.sort_by(|a, b| {
            b.1.cmp(&a.1).then_with(|| {
                self.candidates[a.0 as usize]
                    .candidate
                    .title
                    .cmp(&self.candidates[b.0 as usize].candidate.title)
            })
        });
        matches.truncate(limit);
        matches
    }

    fn search_text_query(
        &self,
        normalized_query: &str,
        kind_filter: Option<&CandidateKind>,
        limit: usize,
    ) -> Vec<(u32, i64)> {
        // Stage 1: fast retrieval over all candidates into a bounded top-K pool.
        let prepared_query = prepare_query(normalized_query);
        let mut top = BinaryHeap::new();
        let has_path_hint = normalized_query.contains('/');
        // Query-level flag reused across all candidates in this search pass.
        let settings_query = looks_like_settings_query(normalized_query);
        let pool_limit = (limit.saturating_mul(RERANK_POOL_MULTIPLIER)).max(RERANK_TOP_N);
        let alias_terms = self.alias_terms_for_query(normalized_query, kind_filter);

        for (idx, candidate) in self.candidates.iter().enumerate() {
            if !Self::kind_matches(candidate, kind_filter) {
                continue;
            }
            // Use precomputed normalized strings from IndexedCandidate.
            // This avoids normalize_for_search allocations in the hot loop.
            let title_score = fuzzy_score_prepared(&prepared_query, &candidate.title_search);
            let subtitle_search =
                if !settings_query && is_system_settings_candidate(&candidate.candidate) {
                    None
                } else {
                    candidate.subtitle_search.as_deref()
                };
            let subtitle_score = subtitle_search
                .as_ref()
                .and_then(|subtitle| fuzzy_score_prepared(&prepared_query, subtitle))
                .map(|value| value / 2);
            let contains_score =
                contains_match_score(normalized_query, &candidate.title_search, subtitle_search);
            let path_score = if has_path_hint {
                path_match_score(normalized_query, &candidate.path_search)
            } else {
                None
            };
            let alias_subtitle_search = if is_system_settings_candidate(&candidate.candidate) {
                candidate.subtitle_search.as_deref()
            } else {
                subtitle_search
            };
            let alias_score = alias_terms.and_then(|terms| {
                if candidate.candidate.kind == CandidateKind::App {
                    // Alias boosts are app-only to avoid distorting file/folder
                    // ranking.
                    return Self::alias_match_score(
                        terms,
                        &candidate.title_search,
                        alias_subtitle_search,
                    );
                }
                None
            });

            let base = [
                title_score,
                subtitle_score,
                contains_score,
                path_score,
                alias_score,
            ]
            .into_iter()
            .flatten()
            .max();

            let Some(base) = base else {
                continue;
            };

            let final_score = rank_score(
                base,
                normalized_query,
                &candidate.candidate,
                &candidate.title_search,
            ) + kind_bias(&candidate.candidate)
                // Reuse precomputed query kind to keep this hot loop allocation-free.
                + query_kind_penalty_with_settings_flag(settings_query, &candidate.candidate)
                + path_depth_penalty(&candidate.candidate);
            push_top_k(
                &mut top,
                ScoredMatch::new(idx as u32, final_score, &candidate.candidate.title),
                pool_limit,
            );
        }

        let mut ranked = finalize_top_k(top);

        if normalized_query.chars().count() < RERANK_MIN_QUERY_CHARS {
            return top_limit(ranked, limit);
        }

        // Stage 2: quality rerank only the leading window to keep latency bounded.
        // Two-stage retrieval:
        // 1) fast scorer over full candidate set
        // 2) quality rerank only on top-N candidates to keep latency predictable
        let rerank_count = ranked.len().min(RERANK_TOP_N);
        for entry in ranked.iter_mut().take(rerank_count) {
            // Reuse the precomputed normalized title from IndexedCandidate rather
            // than re-normalizing here on every rerank.
            let title_search = &self.candidates[entry.0 as usize].title_search;
            entry.1 += fuzzy_quality_bonus_prepared(&prepared_query, title_search);
        }

        ranked.sort_by(|a, b| {
            b.1.cmp(&a.1).then_with(|| {
                let title_a = &self.candidates[a.0 as usize].candidate.title;
                let title_b = &self.candidates[b.0 as usize].candidate.title;
                title_a.cmp(title_b)
            })
        });
        top_limit(ranked, limit)
    }

    pub fn search_scored(&self, query: &str, limit: usize) -> Vec<(Candidate, i64)> {
        if limit == 0 {
            return vec![];
        }

        let parsed_query = ParsedQuery::from_input(query);
        let kind_filter = parsed_query.kind_filter.as_ref();

        let indices = if parsed_query.normalized_query.is_empty() {
            self.search_empty_query(kind_filter, limit)
        } else {
            self.search_text_query(&parsed_query.normalized_query, kind_filter, limit)
        };

        // Materialize Candidates only for the final top-K - the hot scoring loop
        // kept everything as (index, score) pairs to avoid per-push clones.
        top_limit(indices, limit)
            .into_iter()
            .map(|(idx, score)| (self.candidates[idx as usize].candidate.clone(), score))
            .collect()
    }
}

/// File extensions for each file-recall category (empty for `folder`).
fn extensions_for(categories: &[String]) -> Vec<&'static str> {
    let mut out = Vec::new();
    for c in categories {
        let exts: &[&str] = match c.as_str() {
            "pdf" => &["pdf"],
            "image" | "screenshot" => &["png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp", "webp"],
            "movie" => &["mp4", "mov", "m4v", "avi", "mkv", "webm"],
            "audio" => &["mp3", "m4a", "wav", "aac", "flac", "aiff"],
            "document" => &["doc", "docx", "pages", "txt", "rtf", "md", "odt"],
            "spreadsheet" => &["xls", "xlsx", "numbers", "csv", "ods"],
            "presentation" => &["ppt", "pptx", "key", "odp"],
            "archive" => &["zip", "tar", "gz", "rar", "7z", "dmg"],
            _ => &[],
        };
        out.extend_from_slice(exts);
    }
    out
}

/// Lowercased extension of the filename in `path` (empty when none).
fn ext_of(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    match name.rsplit_once('.') {
        Some((_, ext)) => ext.to_lowercase(),
        None => String::new(),
    }
}

/// Path fragment a location hint scopes to.
fn location_folder(loc: &str) -> Option<&'static str> {
    match loc {
        "downloads" => Some("/downloads/"),
        "desktop" => Some("/desktop/"),
        "documents" => Some("/documents/"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::QueryEngine;

    #[test]
    fn term_boundary_match_rejects_inner_substring() {
        assert!(!QueryEngine::has_term_boundary_match(
            "archive utility",
            "arc"
        ));
    }

    #[test]
    fn term_boundary_match_accepts_full_token() {
        assert!(QueryEngine::has_term_boundary_match("arc browser", "arc"));
        assert!(QueryEngine::has_term_boundary_match("arc-browser", "arc"));
    }
}
