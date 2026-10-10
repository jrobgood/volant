import AppKit
import Combine
import VolantCore

struct AppEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let lastUsed: Date?
}

/// Application index built from Spotlight metadata, which works inside the sandbox without folder access.
/// Only bundles in real application folders are indexed, so helper and system-internal apps stay out.
final class AppIndex: NSObject {
    @Published private(set) var unavailable = false
    private let startQuery: (NSMetadataQuery) -> Bool
    private var observing = false
    private var started = false
    @Published private(set) var apps: [AppEntry] = []
    private let query = NSMetadataQuery()
    private let launchOverride: ((AppEntry) -> Void)?
    private let bundleExists: (String) -> Bool
    init(entries: [AppEntry] = [], launch: ((AppEntry) -> Void)? = nil, startQuery: @escaping (NSMetadataQuery) -> Bool = { $0.start() },
         bundleExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.startQuery = startQuery
        self.apps = entries
        self.launchOverride = launch
        self.bundleExists = bundleExists
        super.init()
    }

    /// Imported aliases contain a path and must never fuzzy-match a different app. A saved path deeper in an
    /// application folder than the search index reaches still resolves to exactly that bundle while it exists.
    func resolveAlias(_ target: String) -> AppEntry? {
        if target.hasPrefix("/") {
            if let indexed = apps.first(where: { $0.url.path == target }) { return indexed }
            guard Self.isApplicationBundle(target, maxDepth: nil), bundleExists(target) else { return nil }
            let url = URL(fileURLWithPath: target)
            return AppEntry(id: target, name: url.deletingPathExtension().lastPathComponent, url: url, lastUsed: nil)
        }
        return search(target, limit: 1).first
    }

    static let applicationRoots: [String] = {
        var roots = ["/Applications/", "/System/Applications/", "/System/Applications/Utilities/", "/Applications/Utilities/",
                     "/System/Library/CoreServices/Applications/"]
        roots.append(NSHomeDirectory() + "/Applications/")
        if let real = try? FileManager.default.destinationOfSymbolicLink(atPath: NSHomeDirectory()) { roots.append(real + "/Applications/") }
        return roots
    }()

    /// Folders the Spotlight query searches: the application folders plus CoreServices for Finder.
    /// A whole-computer scope also waits on every mounted volume, and one slow mount (a network
    /// share, Xcode's device file system) kept gathering from ever finishing, leaving no apps at all.
    static var searchScopes: [String] {
        (applicationRoots + ["/System/Library/CoreServices/"]).filter { FileManager.default.fileExists(atPath: $0) }
    }

    func start() {
        guard !started else { return }
        query.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")
        query.searchScopes = Self.searchScopes
        if !observing {
            NotificationCenter.default.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidFinishGathering, object: query)
            NotificationCenter.default.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryGatheringProgress, object: query)
            NotificationCenter.default.addObserver(self, selector: #selector(gathered), name: .NSMetadataQueryDidUpdate, object: query)
            observing = true
        }
        started = startQuery(query)
        unavailable = !started
    }

    deinit { query.stop(); NotificationCenter.default.removeObserver(self) }

    /// Spotlight sends updates for unrelated metadata changes; the list is republished only when
    /// it differs, because each publish re-runs the open launcher query. Results are also read while
    /// gathering is in progress, so a query that is slow to finish still fills the list as it goes.
    @objc private func gathered() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var seen = Set<String>()
        var result: [AppEntry] = []
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  AppIndex.isUserFacingApp(path) else { continue }
            let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let clean = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
            guard seen.insert(path).inserted else { continue }
            let lastUsed = item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
            result.append(AppEntry(id: path, name: clean, url: URL(fileURLWithPath: path), lastUsed: lastUsed))
        }
        let sorted = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if sorted != apps { apps = sorted }
    }

    /// User-facing apps in CoreServices outside its Applications folder. The rest of CoreServices is
    /// background agents and UI services, so it is never indexed as a whole.
    static let systemApps: Set<String> = ["/System/Library/CoreServices/Finder.app"]

    /// An app the user would launch: directly inside one of the application folders (one level of subfolder allowed), not nested in another bundle.
    /// Vendor suites nest uninstallers and helpers deeper, so fuzzy search stays at this depth.
    static func isUserFacingApp(_ path: String) -> Bool {
        isApplicationBundle(path, maxDepth: 2)
    }

    /// An application bundle inside an application folder, at most `maxDepth` components below it when given,
    /// and never inside another bundle.
    static func isApplicationBundle(_ path: String, maxDepth: Int?) -> Bool {
        guard path.hasSuffix(".app"), !path.contains("/Contents/") else { return false }
        if systemApps.contains(path) { return true }
        for root in applicationRoots where path.hasPrefix(root) {
            let components = path.dropFirst(root.count).split(separator: "/")
            guard !components.dropLast().contains(where: { $0.hasSuffix(".app") }) else { return false }
            return maxDepth.map { components.count <= $0 } ?? true
        }
        return false
    }

    /// Fuzzy match, then learned ranking: each past use adds a decayed bonus, and the app last chosen
    /// for this exact query is pinned to the top.
    func search(_ text: String, limit: Int = 8, usage: UsageStore? = nil) -> [AppEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let pinned = usage?.choice(forQuery: trimmed)
        return apps
            .compactMap { app -> (AppEntry, Double)? in
                guard let base = FuzzyMatcher.score(query: trimmed, candidate: app.name) else { return nil }
                var score = Double(base)
                if let usage { score += 25 * min(usage.score("app:" + app.id), 4) }
                if pinned == "app:" + app.id { score += 1000 }
                return (app, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    func launch(_ app: AppEntry) {
        if let launchOverride { launchOverride(app); return }
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Most recently used apps by Spotlight's last-used date, which LaunchServices updates however the app was opened.
    /// Volant's own launches count immediately, before Spotlight catches up.
    /// Learned first: apps by frecency of being chosen here, then the system's last-used dates to fill.
    func suggestions(limit: Int = 6, usage: UsageStore? = nil) -> [AppEntry] {
        let byPath = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        var out: [AppEntry] = []
        if let usage {
            for key in usage.top(prefix: "app:", limit: limit) {
                if let app = byPath[String(key.dropFirst(4))], !out.contains(app) { out.append(app) }
            }
        }
        let bySystem = apps.filter { $0.lastUsed != nil }.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        for app in bySystem where out.count < limit && !out.contains(app) { out.append(app) }
        return Array(out.prefix(limit))
    }
}
