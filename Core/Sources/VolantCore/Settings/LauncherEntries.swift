import Foundation

/// Adds a snippet or quicklink created in the launcher as a narrow configuration patch: one entry
/// is appended to the latest document, every other key and every existing entry keeps its unknown
/// fields, and the write is refused when the lists it was validated against changed meanwhile.
public enum LauncherEntries {
    /// Placeholders snippets expand when copied, in the order the form lists them.
    public static let snippetPlaceholders = ["{date}", "{isodate}", "{time}", "{datetime}", "{clipboard}", "{uuid}"]

    /// What a new entry is validated against: existing snippets, quicklinks and aliases.
    public struct Snapshot: Equatable {
        public var snippets: [Snippet]
        public var quicklinks: [Quicklink]
        public var aliases: [String: String]

        public init(_ config: Preferences) {
            snippets = config.snippets
            quicklinks = config.quicklinks
            aliases = config.aliases
        }
    }

    /// A validation or conflict problem, worded for the form.
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public let isConflict: Bool

        public init(_ message: String, isConflict: Bool = false) {
            self.message = message
            self.isConflict = isConflict
        }

        public var errorDescription: String? { message }
    }

    /// Trims the name and keyword and checks the snippet against reserved launcher words and the
    /// names already in use. The text is kept exactly as typed.
    public static func validated(_ snippet: Snippet, in config: Preferences) throws -> Snippet {
        let name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyword = snippet.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(where: \.isNewline) else { throw Failure("Enter a name for the snippet.") }
        guard !config.snippets.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw Failure("A snippet named “\(name)” already exists.")
        }
        if !keyword.isEmpty {
            guard !keyword.contains(where: \.isWhitespace), !LauncherRouting.isReserved(keyword) else {
                throw Failure("Choose a single-word keyword that is not a built-in command.")
            }
            try requireUnused(keyword, in: config)
        }
        guard !snippet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("Enter the snippet text.") }
        return Snippet(name: name, keyword: keyword, body: snippet.body)
    }

    /// Trims the name and URL, checks the name like an alias, and accepts only a URL that opens
    /// the way quicklinks open today: http, https, mailto or a Shortcuts run URL.
    public static func validated(_ link: Quicklink, in config: Preferences) throws -> Quicklink {
        let name = link.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains(where: \.isNewline) else { throw Failure("Enter a name for the quicklink.") }
        guard !LauncherRouting.isReserved(name) else { throw Failure("“\(name)” is a built-in command. Choose another name.") }
        try requireUnused(name, in: config)
        let candidate = Quicklink(name: name, url: url)
        guard !url.isEmpty else { throw Failure("Enter the quicklink URL.") }
        guard !url.contains(where: \.isWhitespace), let resolved = candidate.resolvedURL(query: "query"),
              let scheme = resolved.scheme?.lowercased() else {
            throw Failure("Enter a URL that starts with https://, http:// or mailto:, or a Shortcuts run link.")
        }
        if scheme == "http" || scheme == "https" {
            guard let host = resolved.host, !host.isEmpty else { throw Failure("Include the website’s address after \(scheme)://.") }
        }
        if scheme == "mailto" {
            guard url.count > "mailto:".count else { throw Failure("Include an email address after mailto:.") }
        }
        return candidate
    }

    /// Refuses a word already used as a quicklink name, snippet keyword or alias.
    private static func requireUnused(_ display: String, in config: Preferences) throws {
        let word = display.lowercased()
        guard !config.quicklinks.contains(where: { $0.name.lowercased() == word }),
              !config.snippets.contains(where: { $0.keyword.lowercased() == word }),
              !config.aliases.keys.contains(where: { $0.lowercased() == word }) else {
            throw Failure("“\(display)” is already used by a quicklink, snippet keyword or alias.")
        }
    }

    /// Validates the snippet against the latest document and appends it, returning the saved
    /// configuration.
    @discardableResult
    public static func appendSnippet(_ snippet: Snippet, expected: Snapshot, at url: URL) throws -> Preferences {
        try append(key: "snippets", expected: expected, at: url) { config in
            let entry = try validated(snippet, in: config)
            return (config.snippets, entry)
        }
    }

    /// Validates the quicklink against the latest document and appends it, returning the saved
    /// configuration.
    @discardableResult
    public static func appendQuicklink(_ link: Quicklink, expected: Snapshot, at url: URL) throws -> Preferences {
        try append(key: "quicklinks", expected: expected, at: url) { config in
            let entry = try validated(link, in: config)
            return (config.quicklinks, entry)
        }
    }

    /// Reads the latest document, rejects a stale snapshot, and appends one encoded entry to the
    /// raw list. A missing list starts from its decoded defaults, so a file without `quicklinks`
    /// keeps the default Google link rather than replacing it. Nothing is written unless the
    /// result still loads.
    private static func append<Entry: Encodable>(key: String, expected: Snapshot, at url: URL,
                                                 entry make: (Preferences) throws -> ([Entry], Entry)) throws -> Preferences {
        let data = try Data(contentsOf: url)
        let current = try JSONDecoder().decode(Preferences.self, from: data)
        guard Snapshot(current) == expected else {
            throw Failure("Snippets, quicklinks or aliases changed in the configuration file. Review the form and save again.", isConflict: true)
        }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        let (existing, entry) = try make(current)
        let encoder = JSONEncoder()
        var list: [Any]
        if let raw = object[key] as? [Any] { list = raw }
        else { list = try JSONSerialization.jsonObject(with: encoder.encode(existing)) as? [Any] ?? [] }
        list.append(try JSONSerialization.jsonObject(with: encoder.encode(entry)))
        object[key] = list
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let result = try JSONDecoder().decode(Preferences.self, from: updated)
        try updated.write(to: url, options: .atomic)
        return result
    }
}
