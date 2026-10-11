import AppKit
import VolantCore


/// Opens web/mail links and Apple's documented Shortcuts run URL; validation lives on `Quicklink`
/// so the launcher, Raycast import and configuration patches agree on what may open.
enum QuicklinkResolver {
    static func url(for link: Quicklink, query: String) -> URL? { link.resolvedURL(query: query) }

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
