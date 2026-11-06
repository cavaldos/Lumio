import Foundation

// MARK: - Dictionary Lookup Data Models

/// One dictionary's entry for a word.
enum DictionaryEntry: Equatable {
    /// The full entry exactly as Dictionary.app shows it: one HTML document (with the
    /// dictionary's own CSS) per record, e.g. one per homograph.
    case html(dictionaryName: String, records: [String])
    /// Fallback when the full records can't be read: the flattened text of the entry.
    case text(String)
}
