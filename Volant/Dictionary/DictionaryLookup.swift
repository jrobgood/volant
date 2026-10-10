import AppKit
import CoreServices

struct DictionaryEntry: Equatable, Sendable {
    let term: String
    let definition: String
}

enum DictionaryQuery {
    static let limit = 256
    static func term(_ query: String) -> String? {
        let parts = query.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.first?.lowercased() == "define" else { return nil }
        return parts.count == 2 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
    static func string(in text: String, range: CFRange) -> String? {
        let count = text.utf16.count
        guard range.location >= 0, range.location <= count, range.length > 0,
              range.length <= count - range.location,
              let valid = Range(NSRange(location: range.location, length: range.length), in: text),
              NSRange(valid, in: text) == NSRange(location: range.location, length: range.length) else { return nil }
        let units = Array(text.utf16)
        let end = range.location + range.length
        guard !(0xDC00...0xDFFF).contains(units[range.location]),
              end == units.count || !(0xDC00...0xDFFF).contains(units[end]) else { return nil }
        return String(text[valid])
    }
    private static let ignorable = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)

    /// The UTF-16 offset of the first letter or digit, so detection skips an opening quote or bracket.
    static func termStart(_ text: String) -> CFIndex {
        guard let index = text.unicodeScalars.firstIndex(where: { !ignorable.contains($0) }) else { return 0 }
        return index.utf16Offset(in: text)
    }

    /// Whether a detected range leaves out only punctuation, symbols or whitespace. Surrounding quotes or a trailing
    /// period are dropped, but a phrase is never reduced to its first word.
    static func covers(_ text: String, range: CFRange) -> Bool {
        guard string(in: text, range: range) != nil else { return false }
        let source = text as NSString
        let outside = source.substring(to: range.location) + source.substring(from: range.location + range.length)
        return outside.unicodeScalars.allSatisfy(ignorable.contains)
    }

    /// Ranges to pass to `DCSCopyTextDefinition`, in order. The whole explicit input comes first, so phrases are
    /// defined as written and Dictionary Services can normalize plurals and inflections itself. The range
    /// `DCSGetTermRangeInString` reports follows only when it is valid and covers every letter of the input.
    static func candidateRanges(in text: String, detect: (CFIndex) -> CFRange) -> [CFRange] {
        let full = CFRange(location: 0, length: text.utf16.count)
        guard full.length > 0 else { return [] }
        let detected = detect(termStart(text))
        guard covers(text, range: detected), detected.location != 0 || detected.length != full.length else { return [full] }
        return [full, detected]
    }

    static func url(for term: String) -> URL? {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= limit,
              let encoded = term.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) else { return nil }
        return URL(string: "dict://" + encoded)
    }
}

/// Dictionary Services is synchronous. An actor serializes calls away from the UI executor.
actor NativeDictionaryLookup {
    static let shared = NativeDictionaryLookup()

    /// Defines the explicit input, retrying with the detected term only when Dictionary Services rejects the whole input.
    /// Every range is validated first: an unvalidated `kCFNotFound` range raises inside `DCSCopyTextDefinition`.
    func lookup(_ text: String) throws -> DictionaryEntry? {
        try Task.checkCancellation()
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= DictionaryQuery.limit else { return nil }
        return autoreleasepool {
            let ranges = DictionaryQuery.candidateRanges(in: term) { DCSGetTermRangeInString(nil, term as CFString, $0) }
            for range in ranges {
                guard let owned = DCSCopyTextDefinition(nil, term as CFString, range) else { continue }
                let definition = (owned.takeRetainedValue() as String).trimmingCharacters(in: .whitespacesAndNewlines)
                if !definition.isEmpty { return DictionaryEntry(term: term, definition: definition) }
            }
            return nil
        }
    }
}

enum DictionaryApplication {
    /// Opens the term in the user's `dict` handler, falling back to Apple's Dictionary only when none is registered.
    @MainActor static func open(_ term: String, workspace: HandlerWorkspace = NSWorkspace.shared) async throws {
        guard let url = DictionaryQuery.url(for: term) else { throw CocoaError(.fileNoSuchFile) }
        try await DefaultHandler.open(url, fallback: DefaultHandler.dictionaryBundleIdentifier, workspace: workspace)
    }
}
