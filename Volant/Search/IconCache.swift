import AppKit
import Combine

/// Finder icons keyed by path, shared by launcher rows and the Settings application list so each
/// path is fetched from LaunchServices once per app index generation rather than on every redraw.
/// `generation` advances when the cache is cleared, letting views that hold an icon refetch it
/// after an app update may have changed it.
final class IconCache: ObservableObject {
    static let shared = IconCache()

    @Published private(set) var generation = 0
    private let icons = NSCache<NSString, NSImage>()
    private let fetch: (String) -> NSImage

    /// Creates a cache holding at most `countLimit` icons. Tests inject `fetch` to count lookups
    /// without depending on which applications are installed.
    init(countLimit: Int = 256, fetch: @escaping (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }) {
        icons.countLimit = countLimit
        self.fetch = fetch
    }

    /// The icon for a path, fetched once and reused until the cache is cleared or evicts it.
    func icon(forFile path: String) -> NSImage {
        if let cached = icons.object(forKey: path as NSString) { return cached }
        let image = fetch(path)
        icons.setObject(image, forKey: path as NSString)
        return image
    }

    /// The icon already cached for a path, without fetching one. Safe to call while a SwiftUI
    /// body is being evaluated.
    func cachedIcon(forFile path: String) -> NSImage? {
        icons.object(forKey: path as NSString)
    }

    /// Drops every cached icon after the app index changes, since an update can change an app's
    /// icon, and advances `generation` so views holding an icon fetch it again.
    func clear() {
        icons.removeAllObjects()
        generation += 1
    }
}
