//! Shared URL + translation helpers. AI web answers removed.

pub mod http;
mod translate;
mod url;

pub use translate::{TranslateError, Translation, translate};
pub use url::{UrlMatch, UrlTier, classify_url};
