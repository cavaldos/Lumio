use crate::normalize::normalize_for_search;
use lumio_indexing::CandidateKind;

// Query prefixes: leading letter matched case-insensitively, trailing `"`
// exactly (see `strip_query_prefix`).
const PREFIX_APPS: &[u8] = b"a\"";
const PREFIX_FILES: &[u8] = b"f\"";
const PREFIX_FOLDERS: &[u8] = b"d\"";

#[derive(Clone, Debug)]
pub(crate) struct ParsedQuery {
    pub(crate) normalized_query: String,
    pub(crate) kind_filter: Option<CandidateKind>,
}

impl ParsedQuery {
    pub(crate) fn from_input(input: &str) -> Self {
        let trimmed = input.trim();

        if let Some(rest) = strip_query_prefix(trimmed, PREFIX_FOLDERS) {
            return Self {
                normalized_query: normalize_for_search(rest),
                kind_filter: Some(CandidateKind::Folder),
            };
        }

        if let Some(rest) = strip_query_prefix(trimmed, PREFIX_FILES) {
            return Self {
                normalized_query: normalize_for_search(rest),
                kind_filter: Some(CandidateKind::File),
            };
        }

        if let Some(rest) = strip_query_prefix(trimmed, PREFIX_APPS) {
            return Self {
                normalized_query: normalize_for_search(rest),
                kind_filter: Some(CandidateKind::App),
            };
        }

        Self {
            normalized_query: normalize_for_search(trimmed),
            kind_filter: None,
        }
    }
}

/// Strips a `…"` query prefix, returning the trimmed text after it (or `None`
/// when `input` doesn't start with `prefix`). The prefix is matched ASCII
/// case-insensitively - the trailing `"` has no case, so it matches exactly.
/// `prefix` is all-ASCII, so its length is always a UTF-8 char boundary in a
/// matched input.
fn strip_query_prefix<'a>(input: &'a str, prefix: &[u8]) -> Option<&'a str> {
    let bytes = input.as_bytes();
    if bytes.len() < prefix.len() || !bytes[..prefix.len()].eq_ignore_ascii_case(prefix) {
        return None;
    }
    Some(input[prefix.len()..].trim())
}

#[cfg(test)]
mod tests {
    use super::ParsedQuery;
    use lumio_indexing::CandidateKind;

    #[test]
    fn folder_prefix_sets_filter() {
        let parsed = ParsedQuery::from_input("D\"report");
        assert_eq!(parsed.kind_filter, Some(CandidateKind::Folder));
        assert_eq!(parsed.normalized_query, "report");
    }

    #[test]
    fn old_recent_and_regex_prefixes_are_plain_text() {
        assert!(ParsedQuery::from_input("rc\"report").kind_filter.is_none());
        assert!(ParsedQuery::from_input("r\"foo").kind_filter.is_none());
    }
}
