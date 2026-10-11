import Foundation

public struct Quicklink: Codable, Hashable {
    public var name: String
    public var url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    /// Schemes a quicklink may open, besides Apple's documented Shortcuts run URL.
    public static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// The URL this link opens for a typed query, or nil when the scheme is not allowed.
    /// `{query}` is encoded as a single value, so typed text cannot add URL parameters.
    public func resolvedURL(query: String) -> URL? {
        let valueCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: valueCharacters) ?? ""
        let text = url.replacingOccurrences(of: "{query}", with: encoded)
        guard let resolved = URL(string: text), let scheme = resolved.scheme?.lowercased() else { return nil }
        if scheme == "shortcuts" { return Self.isShortcutRun(resolved) ? resolved : nil }
        guard Self.allowedSchemes.contains(scheme) else { return nil }
        return resolved
    }

    /// Accepts only `shortcuts://run-shortcut` with a name and Apple's documented input parameters.
    public static func isShortcutRun(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "shortcuts", parts.host == "run-shortcut",
              parts.path.isEmpty, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil else { return false }
        let items = parts.queryItems ?? []
        let names = items.map(\.name)
        guard Set(names).count == names.count,
              Set(names).isSubset(of: ["name", "input", "text"]),
              let name = items.first(where: { $0.name == "name" })?.value,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let input = items.first { $0.name == "input" }
        let text = items.first { $0.name == "text" }
        if input == nil { return text == nil }
        switch input?.value {
        case "text": return text?.value != nil
        case "clipboard": return text == nil
        default: return false
        }
    }
}
