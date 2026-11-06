import CoreServices
import Foundation

/// Looks words up in the dictionaries enabled in Dictionary.app.
///
/// The public `DCSCopyTextDefinition` only returns the entry flattened into one line of
/// text. The full entry (parts of speech, every sense, examples with their translations,
/// cross-references) comes from the record API Dictionary.app itself uses. It is private,
/// so it is loaded at runtime; when anything is missing we fall back to the flat text.
enum DictionaryLookupService {
    /// Most records shown per word (homographs: "run" verb, "run" noun, …).
    private static let maxRecords = 4

    static func entry(for text: String) -> DictionaryEntry? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return nil }
        if let entry = htmlEntry(for: word) { return entry }
        return plainText(for: word).map(DictionaryEntry.text)
    }

    /// The word's entries in every enabled dictionary that has it, in the user's order —
    /// like the "All" tab in Dictionary.app. Falls back to the closest match (a lemma such
    /// as "confer" for "conferred") when no dictionary has the word itself.
    static func entries(for text: String) -> [DictionaryEntry] {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return [] }
        if let api = RecordAPI.shared {
            let exact = activeDictionaries(api).compactMap { dictionary -> DictionaryEntry? in
                guard let found = records(api, dictionary, word), !found.exact.isEmpty else { return nil }
                return htmlEntry(api, dictionary, records: found.exact)
            }
            if !exact.isEmpty { return exact }
        }
        return entry(for: word).map { [$0] } ?? []
    }

    /// Headwords starting with `text` in the enabled dictionaries, sorted like the
    /// Dictionary.app sidebar (the word itself first when a dictionary has it).
    static func suggestions(for text: String, limit: Int = 40) -> [String] {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, let api = RecordAPI.shared else { return [] }

        var seen = Set<String>()
        var headwords: [String] = []
        for dictionary in activeDictionaries(api) {
            let found = api.copyRecords(dictionary, word as CFString, RecordAPI.prefixMatch, 80)?
                .takeRetainedValue() as? [CFTypeRef] ?? []
            for record in found {
                guard let headword = api.headword(record)?.takeUnretainedValue() as String?,
                      seen.insert(headword).inserted
                else { continue }
                headwords.append(headword)
            }
        }

        // The search ignores accents ("conférer" for "confer"). Keep only real prefixes
        // when there are some, so "ban" isn't buried under "bàn …" and vice versa.
        let strict = headwords.filter { $0.range(of: word, options: [.caseInsensitive, .anchored]) != nil }
        let matches = strict.isEmpty ? headwords : strict
        return Array(matches.sorted { a, b in
            let order = a.compare(b, options: [.caseInsensitive, .diacriticInsensitive])
            return order == .orderedSame ? a < b : order == .orderedAscending
        }.prefix(limit))
    }

    // MARK: - Full entry (record API)

    /// First enabled dictionary (in the user's Dictionary.app order) that has the word —
    /// the same dictionary `DCSCopyTextDefinition` would pick.
    private static func htmlEntry(for word: String) -> DictionaryEntry? {
        guard let api = RecordAPI.shared else { return nil }
        for dictionary in activeDictionaries(api) {
            guard let found = records(api, dictionary, word) else { continue }
            // Exact headwords; else the best match.
            let chosen = found.exact.isEmpty ? Array(found.all.prefix(1)) : found.exact
            if let entry = htmlEntry(api, dictionary, records: chosen) { return entry }
        }
        return nil
    }

    /// The search also returns near matches ("rùn" for "run") and lemmas ("confer" for
    /// "conferred"): `exact` holds only the records whose headword is the word itself.
    private static func records(
        _ api: RecordAPI, _ dictionary: CFTypeRef, _ word: String
    ) -> (exact: [CFTypeRef], all: [CFTypeRef])? {
        guard let found = api.copyRecords(dictionary, word as CFString, RecordAPI.exactMatch, 0)?
            .takeRetainedValue() as? [CFTypeRef], !found.isEmpty
        else { return nil }
        let exact = found.filter { record in
            let headword = api.headword(record)?.takeUnretainedValue() as String?
            return headword?.caseInsensitiveCompare(word) == .orderedSame
        }
        return (exact, found)
    }

    private static func htmlEntry(_ api: RecordAPI, _ dictionary: CFTypeRef, records: [CFTypeRef]) -> DictionaryEntry? {
        let html = records
            .prefix(maxRecords)
            .compactMap { api.copyData($0, RecordAPI.applicationHTML)?.takeRetainedValue() as String? }
        guard !html.isEmpty else { return nil }
        let name = (api.shortName(dictionary) ?? api.name(dictionary))?.takeUnretainedValue() as String?
        return .html(dictionaryName: name ?? "Dictionary", records: html)
    }

    /// Dictionaries ticked in Dictionary.app settings, in the user's order.
    private static func activeDictionaries(_ api: RecordAPI) -> [CFTypeRef] {
        let ids = CFPreferencesCopyAppValue(
            "DCSActiveDictionaries" as CFString,
            "com.apple.DictionaryServices" as CFString
        ) as? [String] ?? []
        return ids.compactMap { api.dictionariesByID[$0] }
    }

    // MARK: - Flat text (public API)

    private static func plainText(for word: String) -> String? {
        let range = CFRange(location: 0, length: (word as NSString).length)
        guard let unmanaged = DCSCopyTextDefinition(nil, word as CFString, range) else { return nil }
        let raw = (unmanaged.takeRetainedValue() as String).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }
}

// MARK: - Private DictionaryServices symbols

private struct RecordAPI {
    typealias CopyAvailable = @convention(c) () -> Unmanaged<CFSet>?
    /// (dictionary, search string, search method, max results; 0 = no limit)
    typealias CopyRecords = @convention(c) (CFTypeRef, CFString, CFIndex, CFIndex) -> Unmanaged<CFArray>?
    typealias CopyData = @convention(c) (CFTypeRef, CFIndex) -> Unmanaged<CFString>?
    typealias GetString = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?

    /// `DCSRecordCopyData` version: full HTML document styled as in the Dictionary app
    /// (1 = app, 2 = look-up panel, 3 = plain text).
    static let applicationHTML: CFIndex = 1
    /// `DCSCopyRecordsForSearchString` search methods.
    static let exactMatch: CFIndex = 0
    static let prefixMatch: CFIndex = 1

    let copyRecords: CopyRecords
    let copyData: CopyData
    let headword: GetString
    let name: GetString
    let shortName: GetString
    let dictionariesByID: [String: CFTypeRef]

    /// nil when the framework or a symbol is missing (e.g. renamed in a future macOS).
    static let shared: RecordAPI? = {
        let path = "/System/Library/Frameworks/CoreServices.framework/Frameworks/DictionaryServices.framework/DictionaryServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copyAvailable = symbol("DCSCopyAvailableDictionaries", as: CopyAvailable.self),
              let copyRecords = symbol("DCSCopyRecordsForSearchString", as: CopyRecords.self),
              let copyData = symbol("DCSRecordCopyData", as: CopyData.self),
              let headword = symbol("DCSRecordGetHeadword", as: GetString.self),
              let identifier = symbol("DCSDictionaryGetIdentifier", as: GetString.self),
              let name = symbol("DCSDictionaryGetName", as: GetString.self),
              let shortName = symbol("DCSDictionaryGetShortName", as: GetString.self),
              let available = copyAvailable()?.takeRetainedValue()
        else { return nil }

        var byID: [String: CFTypeRef] = [:]
        for object in (available as NSSet).allObjects {
            let dictionary = object as CFTypeRef
            if let id = identifier(dictionary)?.takeUnretainedValue() as String? {
                byID[id] = dictionary
            }
        }
        return RecordAPI(
            copyRecords: copyRecords, copyData: copyData, headword: headword,
            name: name, shortName: shortName, dictionariesByID: byID
        )
    }()
}
