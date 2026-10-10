import AppKit
import VolantCore


/// Opens web/mail links and Apple's documented Shortcuts run URL.
/// `{query}` is encoded as a single value, so typed text cannot add URL parameters.
enum QuicklinkResolver {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func url(for link: Quicklink, query: String) -> URL? {
        let valueCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: valueCharacters) ?? ""
        let text = link.url.replacingOccurrences(of: "{query}", with: encoded)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "shortcuts" { return isShortcutRun(url) ? url : nil }
        guard allowedSchemes.contains(scheme) else { return nil }
        return url
    }

    static func isShortcutRun(_ url: URL) -> Bool {
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

    static func needsQuery(_ link: Quicklink) -> Bool { link.url.contains("{query}") }

    static func search(_ links: [Quicklink], _ term: String, limit: Int = 5) -> [Quicklink] {
        let t = term.lowercased()
        guard !t.isEmpty else { return [] }
        return Array(links.filter { $0.name.lowercased().hasPrefix(t) || $0.name.lowercased().contains(" " + t) }.prefix(limit))
    }

    /// Opens the link in the application Launch Services picks for it, so a site-specific handler wins over the scheme default.
    /// Returns false when no handler is registered.
    @discardableResult
    static func open(_ url: URL, workspace: HandlerWorkspace = NSWorkspace.shared) -> Bool {
        guard let application = DefaultHandler.application(for: url, workspace: workspace) else { return false }
        Task { @MainActor in try? await workspace.open(url, withApplication: application) }
        return true
    }
}
