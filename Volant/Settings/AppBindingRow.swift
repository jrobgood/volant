import SwiftUI
import VolantCore

/// Inline editing keeps app identity, alias and hotkey visible together.
struct AppBindingRow: View {
    let app: AppEntry
    let config: Preferences
    let configURL: URL
    let onChange: () -> Void
    @State private var alias: String
    @State private var originalAlias: String
    @State private var expectedAliases: [String: String]
    @State private var error: String?
    @State private var saved = false
    @State private var icon: NSImage?
    @ObservedObject private var icons: IconCache
    @FocusState private var editingAlias: Bool
    private var bundleID: String? { Bundle(url: app.url)?.bundleIdentifier }
    private var storedAliases: [String: String] { config.aliases.filter { $0.value == app.url.path || $0.value == app.name } }
    private var hotKey: String { bundleID.map { AppHotKey.binding(in: config.appHotKeys, bundleIdentifier: $0, path: app.url.path) } ?? "" }

    /// Shows an icon already in the shared cache immediately; a missing one is fetched by the
    /// row's task rather than during body evaluation.
    init(app: AppEntry, config: Preferences, configURL: URL, icons: IconCache = .shared, onChange: @escaping () -> Void) {
        self.app = app; self.config = config; self.configURL = configURL; self.onChange = onChange
        self.icons = icons
        _icon = State(initialValue: icons.cachedIcon(forFile: app.url.path))
        let aliases = config.aliases.filter { $0.value == app.url.path || $0.value == app.name }
        let first = aliases.keys.sorted().first ?? ""
        _alias = State(initialValue: first); _originalAlias = State(initialValue: first)
        _expectedAliases = State(initialValue: aliases)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 10) {
                HStack(spacing: 8) {
                    Group {
                        if let icon { Image(nsImage: icon).resizable() } else { Color.clear }
                    }.frame(width: 20, height: 20)
                    Text(app.name).lineLimit(1).help(app.name)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Alias", text: $alias).textFieldStyle(.roundedBorder)
                        .frame(height: 26).focused($editingAlias)
                        .accessibilityLabel(app.name + " alias")
                        .help(storedAliases.keys.sorted().joined(separator: ", "))
                        .onSubmit { saveAlias() }
                        .onChange(of: editingAlias) { _, focused in if !focused { saveAlias() } }
                    if saved && alias == originalAlias {
                        Label("Saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(width: 90)
                ShortcutControl(title: app.name, value: hotKey) { replacement in
                    guard let bundleID else { throw BindingFailure(message: "This app has no bundle identifier.") }
                    _ = try AppBindingStore.updateHotKey(bundleID: bundleID, path: app.url.path, value: replacement, expectedValue: hotKey,
                        at: configURL, available: { HotKeyCenter.shared.isAvailable($0) })
                    onChange()
                }.frame(width: 160).disabled(bundleID == nil)
                    .help(bundleID == nil ? "This app has no bundle identifier for a global shortcut." : "Record a global shortcut")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Retry") { saveAlias() }
                    Button("Reload Alias") { reloadAlias() }
                }.font(.caption)
            }
        }
        .padding(.vertical, 2)
        .task(id: IconRequest(path: app.url.path, generation: icons.generation)) { icon = icons.icon(forFile: app.url.path) }
        .onChange(of: storedAliases) { _, latest in
            if alias == originalAlias { adopt(latest) }
        }
    }
    /// Identifies the icon a row shows, so a different app or a cleared cache fetches it again.
    private struct IconRequest: Equatable {
        let path: String
        let generation: Int
    }
    private func adopt(_ aliases: [String: String]) {
        expectedAliases = aliases
        originalAlias = aliases.keys.sorted().first ?? ""
        alias = originalAlias
    }
    private func reloadAlias() {
        do {
            let latest = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: configURL))
            adopt(latest.aliases.filter { $0.value == app.url.path || $0.value == app.name })
            error = nil; saved = false
            onChange()
        } catch { self.error = error.localizedDescription }
    }
    private func saveAlias() {
        guard alias != originalAlias else { return }
        do {
            try AppBindingStore.updateAlias(path: app.url.path, name: app.name, originalAlias: originalAlias,
                value: alias, expectedAliases: expectedAliases, at: configURL)
            if !originalAlias.isEmpty { expectedAliases.removeValue(forKey: originalAlias) }
            originalAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            alias = originalAlias
            if !alias.isEmpty { expectedAliases[alias] = app.url.path }
            error = nil; saved = true
            onChange()
        } catch { self.error = error.localizedDescription; saved = false }
    }
}
