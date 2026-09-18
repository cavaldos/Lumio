//! C-ABI wrapper over `lumio_answers::classify_url` (URL detection is core
//! search, not AI). AI web answers removed.

use crate::state::{cstr_to_string, json_cstring_or_null};
use std::os::raw::c_char;

/// Serialized `UrlMatch` object for `query`, or the JSON literal `null` when the
/// query is not a URL.
pub(crate) fn lumio_classify_url_json_impl(query: *const c_char) -> *mut c_char {
    let query = cstr_to_string(query);
    json_cstring_or_null(
        lumio_answers::classify_url(&query).and_then(|m| serde_json::to_string(&m).ok()),
    )
}
