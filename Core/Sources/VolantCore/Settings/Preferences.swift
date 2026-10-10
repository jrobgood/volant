import Foundation

/// User configuration, read from a JSON file in the app's sandbox container. General settings also have a native panel.
public struct Preferences: Codable {
    public var summonHotKey: String = "option+space"
    public var emojiHotKey: String = ""
    public var notesHotKey: String = "option+n"
    /// Dictation is the one hotkey that also acts on release, so holding it talks.
    public var talkHotKey: String = ""
    /// System actions that are useful as instant global shortcuts. Unset until the owner picks one.
    public var lockScreenHotKey: String = ""
    public var sleepDisplaysHotKey: String = ""
    public var appHotKeys: [AppHotKey] = []
    public var clipboardRetention: Int = 500
    public var showOnLaunch: Bool = true
    public var showInDock: Bool = true
    public var caffeinateKeepsDisplayAwake: Bool = true
    /// Per-Mac switch for mirroring the settings in SettingsSync.keys through iCloud.
    public var syncSettingsWithICloud: Bool = false
    public var statusBar = StatusBarConfiguration()
    // Compatibility for existing callers and older configuration files.
    public var promotedHarness: String? {
        get { statusBar.sources.contains("herdr") ? statusBar.herdrFilter : nil }
        set {
            statusBar.sources.removeAll { $0 == "herdr" }
            if let newValue { statusBar.sources.append("herdr"); statusBar.herdrFilter = newValue }
        }
    }
    public static let harnessOptions: [(id: String, title: String)] = [("all", "All Herdr agents"), ("opencode", "OpenCode"), ("cursor", "Cursor"), ("claude", "Claude Code"), ("codex", "Codex"), ("gemini", "Gemini CLI"), ("qwen", "Qwen Code")]
    public var snippets: [Snippet] = []
    public var quicklinks: [Quicklink] = [Quicklink(name: "Google", url: "https://www.google.com/search?q={query}")]
    public var favoriteApps: [String] = []
    public var aliases: [String: String] = [:]
    public var appearance: Appearance = Appearance()
    public var help: String = "Edit and choose Reload Configuration in Settings. Hotkeys: cmd|ctrl|option|shift|meh|hyper + key. App hotkeys use the bundle identifier. Snippets: {date} {isodate} {time} {datetime} {clipboard} {uuid}. Quicklinks: {query}. Aliases map a word to an app name or query. Appearance: theme system|light|dark, colorTheme system|volant|catppuccin-mocha|nord|…|custom-<name> (named themes set their own light or dark; customThemes holds imported Raycast themes), scale 0.8–1.4, opacity 0.5–1.0."

    public enum CodingKeys: String, CodingKey {
        case favoriteApps, summonHotKey, notesHotKey, emojiHotKey, talkHotKey, lockScreenHotKey, sleepDisplaysHotKey, appHotKeys, clipboardRetention, showOnLaunch, showInDock, caffeinateKeepsDisplayAwake, syncSettingsWithICloud, statusBar, snippets, quicklinks, aliases, appearance
        case help = "_help"
    }

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Preserve the original storage location across the Volant rebrand.
        let dir = base.appendingPathComponent("Vey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static var configURL: URL { supportDirectory.appendingPathComponent("config.json") }

    /// Missing keys fall back to defaults, so a config written by an older version keeps working.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        summonHotKey = try c.decodeIfPresent(String.self, forKey: .summonHotKey) ?? d.summonHotKey
        notesHotKey = try c.decodeIfPresent(String.self, forKey: .notesHotKey) ?? d.notesHotKey
        talkHotKey = try c.decodeIfPresent(String.self, forKey: .talkHotKey) ?? d.talkHotKey
        lockScreenHotKey = try c.decodeIfPresent(String.self, forKey: .lockScreenHotKey) ?? d.lockScreenHotKey
        sleepDisplaysHotKey = try c.decodeIfPresent(String.self, forKey: .sleepDisplaysHotKey) ?? d.sleepDisplaysHotKey
        emojiHotKey = try c.decodeIfPresent(String.self, forKey: .emojiHotKey) ?? d.emojiHotKey
        appHotKeys = try c.decodeIfPresent([AppHotKey].self, forKey: .appHotKeys) ?? d.appHotKeys
        clipboardRetention = try c.decodeIfPresent(Int.self, forKey: .clipboardRetention) ?? d.clipboardRetention
        showOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .showOnLaunch) ?? d.showOnLaunch
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? d.showInDock
        caffeinateKeepsDisplayAwake = try c.decodeIfPresent(Bool.self, forKey: .caffeinateKeepsDisplayAwake) ?? d.caffeinateKeepsDisplayAwake
        syncSettingsWithICloud = try c.decodeIfPresent(Bool.self, forKey: .syncSettingsWithICloud) ?? d.syncSettingsWithICloud
        statusBar = try c.decodeIfPresent(StatusBarConfiguration.self, forKey: .statusBar) ?? StatusBarConfiguration()
        if !c.contains(.statusBar) {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            if let id = try legacy.decodeIfPresent(String.self, forKey: .promotedHarness), Self.harnessOptions.contains(where: { $0.id == id }) { promotedHarness = id }
        }
        if !Self.harnessOptions.contains(where: { $0.id == statusBar.herdrFilter }) { statusBar.herdrFilter = "all" }
        snippets = try c.decodeIfPresent([Snippet].self, forKey: .snippets) ?? d.snippets
        quicklinks = try c.decodeIfPresent([Quicklink].self, forKey: .quicklinks) ?? d.quicklinks
        favoriteApps = try c.decodeIfPresent([String].self, forKey: .favoriteApps) ?? []
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? d.aliases
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? d.appearance
        help = try c.decodeIfPresent(String.self, forKey: .help) ?? d.help
    }

    public init() {}

    /// Patch a single setting, preserving externally edited and unknown configuration fields.
    public static func updateBoolean(_ key: String, value: Bool, at url: URL = configURL) throws {
        precondition(["showInDock", "showOnLaunch", "caffeinateKeepsDisplayAwake", "syncSettingsWithICloud"].contains(key))
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        object[key] = value
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        // Reject invalid known settings before changing the file.
        _ = try JSONDecoder().decode(Preferences.self, from: updated)
        try updated.write(to: url, options: .atomic)
    }

    /// Patch the appearance block against an expected snapshot, keeping unknown keys inside it and
    /// elsewhere. Values are clamped to their supported ranges before they are written.
    public static func updateAppearance(_ appearance: Appearance, expected: Appearance, at url: URL = configURL) throws {
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let current = try JSONDecoder().decode(Preferences.self, from: data).appearance
        guard current == expected else { throw AppearanceConflict() }
        var block = object["appearance"] as? [String: Any] ?? [:]
        block["theme"] = appearance.theme.rawValue
        block["colorTheme"] = appearance.colorTheme
        block["scale"] = (appearance.clampedScale * 100).rounded() / 100
        block["opacity"] = (appearance.clampedOpacity * 100).rounded() / 100
        object["appearance"] = block
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        _ = try JSONDecoder().decode(Preferences.self, from: updated)
        try updated.write(to: url, options: .atomic)
    }

    /// Adds an imported theme, or replaces the one with the same identifier while keeping fields
    /// this version does not know, and optionally selects it. Rejects stale snapshots and more than
    /// `CustomColorTheme.maximumCount` themes.
    public static func saveCustomTheme(_ theme: CustomColorTheme, select: Bool, expected: Appearance, at url: URL = configURL) throws {
        try patchAppearance(expected: expected, at: url) { block in
            var entries = block["customThemes"] as? [Any] ?? []
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(theme)) as? [String: Any] ?? [:]
            if let index = entries.firstIndex(where: { ($0 as? [String: Any])?["id"] as? String == theme.id }) {
                var merged = entries[index] as? [String: Any] ?? [:]
                merged.merge(encoded) { _, new in new }
                if theme.author == nil { merged["author"] = nil }
                entries[index] = merged
            } else {
                guard entries.count < CustomColorTheme.maximumCount else { throw CustomThemeLimit() }
                entries.append(encoded)
            }
            block["customThemes"] = entries
            if select { block["colorTheme"] = theme.id }
        }
    }

    /// Removes an imported theme; when it was selected, Volant returns to the System theme.
    public static func removeCustomTheme(_ id: String, expected: Appearance, at url: URL = configURL) throws {
        try patchAppearance(expected: expected, at: url) { block in
            let entries = block["customThemes"] as? [Any] ?? []
            block["customThemes"] = entries.filter { ($0 as? [String: Any])?["id"] as? String != id }
            if block["colorTheme"] as? String == id { block["colorTheme"] = ColorTheme.systemID }
        }
    }

    /// Applies a change to the raw appearance block of the latest document after checking it still
    /// matches the snapshot the edit started from, and refuses to write a result that fails to load.
    private static func patchAppearance(expected: Appearance, at url: URL, _ change: (inout [String: Any]) throws -> Void) throws {
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let current = try JSONDecoder().decode(Preferences.self, from: data).appearance
        guard current == expected else { throw AppearanceConflict() }
        var block = object["appearance"] as? [String: Any] ?? [:]
        try change(&block)
        object["appearance"] = block
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        _ = try JSONDecoder().decode(Preferences.self, from: updated)
        try updated.write(to: url, options: .atomic)
    }

    public struct CustomThemeLimit: LocalizedError {
        public var errorDescription: String? { "Volant keeps up to \(CustomColorTheme.maximumCount) imported themes. Remove one before importing another." }
    }

    public struct AppearanceConflict: LocalizedError {
        public var errorDescription: String? { "Appearance changed in the configuration file. Reload Configuration before changing it again." }
    }

    /// Patch only this app's membership against the latest document.
    public static func updateFavorite(_ id: String, expected: Bool, at url: URL = configURL) throws -> Preferences {
        let data = try Data(contentsOf: url)
        let current = try JSONDecoder().decode(Preferences.self, from: data)
        guard current.favoriteApps.contains(id) == expected else { throw CocoaError(.fileWriteFileExists) }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        var favorites = current.favoriteApps.filter { $0 != id }
        if !expected { favorites.append(id) }
        object["favoriteApps"] = favorites
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let result = try JSONDecoder().decode(Preferences.self, from: updated)
        try updated.write(to: url, options: .atomic)
        return result
    }

    private enum LegacyKeys: String, CodingKey { case promotedHarness }

    public static func updatePromotedHarness(_ harness: String?, at url: URL = configURL) throws {
        guard harness == nil || harnessOptions.contains(where: { $0.id == harness }) else { throw CocoaError(.fileReadCorruptFile) }
        try updateStatusBar(enabled: harness != nil, filter: harness, at: url)
    }

    public static func updateStatusBar(source: String = "herdr", enabled: Bool? = nil, filter: String? = nil, at url: URL = configURL) throws {
        guard ["herdr", "ai-chat"].contains(source) else { throw CocoaError(.fileReadCorruptFile) }
        if let filter, !harnessOptions.contains(where: { $0.id == filter }) { throw CocoaError(.fileReadCorruptFile) }
        let data = try Data(contentsOf: url)
        let current = try JSONDecoder().decode(Preferences.self, from: data)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        var bar = object["statusBar"] as? [String: Any] ?? [:]
        var sources = current.statusBar.sources
        if let enabled {
            sources.removeAll { $0 == source }
            if enabled { sources.append(source) }
        }
        bar["sources"] = sources
        bar["herdrFilter"] = filter ?? current.statusBar.herdrFilter
        object["statusBar"] = bar
        object.removeValue(forKey: "promotedHarness")
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        _ = try JSONDecoder().decode(Preferences.self, from: updated)
        try updated.write(to: url, options: .atomic)
    }

    /// Last load problem, shown in the menu bar. A malformed file is left in place, never replaced.
    public static var loadError: String? = nil

    /// Loads the config. Writes the defaults only when no file exists at all.
    public static func load() -> Preferences {
        loadError = nil
        if let data = try? Data(contentsOf: configURL) {
            do {
                return try JSONDecoder().decode(Preferences.self, from: data)
            } catch {
                loadError = "config.json could not be read (\(error.localizedDescription)); using defaults without overwriting it."
                return Preferences()
            }
        }
        let defaults = Preferences()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(defaults) {
            try? data.write(to: configURL, options: .atomic)
        }
        return defaults
    }
}

public struct Appearance: Codable, Equatable {
    /// Follows macOS unless the owner pins Volant to one appearance.
    public enum Theme: String, Codable, CaseIterable, Identifiable {
        case system, light, dark
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }
    public static let scaleRange = 0.8...1.4
    public static let opacityRange = 0.5...1.0

    public var theme: Theme = .system
    /// The color theme's identifier; a theme with its own mode overrides `theme` for light and dark.
    public var colorTheme: String = ColorTheme.systemID
    /// Imported themes, offered after the built-in ones; entries that fail to decode are skipped.
    public var customThemes: [CustomColorTheme] = []
    /// 1.0 is the default 750×480 panel; 0.8 to 1.4 are sensible.
    public var scale: Double = 1.0
    /// 1.0 is the system material; lower values let the desktop show through more.
    public var opacity: Double = 1.0

    public init(theme: Theme = .system, colorTheme: String = ColorTheme.systemID, customThemes: [CustomColorTheme] = [],
                scale: Double = 1.0, opacity: Double = 1.0) {
        self.theme = theme
        self.colorTheme = colorTheme
        self.customThemes = customThemes
        self.scale = scale
        self.opacity = opacity
    }

    /// Each field falls back on its own, so a hand-edited block with only one key still loads and an
    /// unknown theme name follows the system rather than rejecting the whole configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? .system
        colorTheme = (try? c.decodeIfPresent(String.self, forKey: .colorTheme)) ?? ColorTheme.systemID
        let entries = (try? c.decodeIfPresent([LossyCustomTheme].self, forKey: .customThemes)) ?? []
        customThemes = entries.compactMap(\.theme)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1.0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
    }

    public var clampedScale: Double { min(Self.scaleRange.upperBound, max(Self.scaleRange.lowerBound, scale)) }
    public var clampedOpacity: Double { min(Self.opacityRange.upperBound, max(Self.opacityRange.lowerBound, opacity)) }

    /// The chosen color theme, built-in or imported; an unknown identifier resolves to System.
    public var resolvedColorTheme: ColorTheme {
        customThemes.first { $0.id == colorTheme }?.colorTheme ?? ColorTheme.named(colorTheme)
    }

    /// Built-in themes followed by imported ones, in picker order.
    public var availableColorThemes: [ColorTheme] { ColorTheme.catalog + customThemes.map(\.colorTheme) }

    /// Decodes one imported theme without failing the list when an entry is malformed.
    private struct LossyCustomTheme: Decodable {
        let theme: CustomColorTheme?
        init(from decoder: Decoder) throws {
            let decoded = try? CustomColorTheme(from: decoder)
            theme = decoded?.isValid == true ? decoded : nil
        }
    }

    /// Light, dark or nil to follow macOS: a theme with its own mode wins over the appearance setting.
    public var effectiveMode: ColorTheme.Mode? {
        if let mode = resolvedColorTheme.mode { return mode }
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// A per-app shortcut. `path` names the exact application copy; entries saved before it existed omit it
/// and still resolve by bundle identifier until they are edited.
public struct AppHotKey: Codable, Equatable {
    public var bundleIdentifier: String
    public var hotKey: String
    public var path: String?

    public init(bundleIdentifier: String, hotKey: String, path: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.hotKey = hotKey
        self.path = path
    }

    /// The entry that belongs to one application copy: an exact path match first, otherwise a legacy
    /// entry without a path for the same bundle identifier. An entry saved for another copy never matches.
    public static func bindingIndex(in entries: [AppHotKey], bundleIdentifier: String, path: String) -> Int? {
        if let exact = entries.firstIndex(where: { $0.path == path }) { return exact }
        return entries.firstIndex { $0.path == nil && $0.bundleIdentifier == bundleIdentifier }
    }

    /// The shortcut configured for one application copy, or an empty string.
    public static func binding(in entries: [AppHotKey], bundleIdentifier: String, path: String) -> String {
        bindingIndex(in: entries, bundleIdentifier: bundleIdentifier, path: path).map { entries[$0].hotKey } ?? ""
    }
}

/// Sources are independent so future status providers need not reuse Herdr settings.
public struct StatusBarConfiguration: Codable {
    public var sources: [String] = []
    public var herdrFilter = "all"
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        herdrFilter = try c.decodeIfPresent(String.self, forKey: .herdrFilter) ?? "all"
    }
}
