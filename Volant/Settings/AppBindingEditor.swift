import AppKit
import SwiftUI
import Carbon.HIToolbox
import VolantCore

struct AppBindingEditor: View {
    let app: AppEntry
    let configURL: URL
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var originalAlias = ""
    @State private var hotKey = ""
    @State private var originalHotKey = ""
    @State private var expected: Data?
    @State private var error: String?
    private var bundleID: String? { Bundle(url: app.url)?.bundleIdentifier }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(app.name).font(.title2.bold())
            Text("Global shortcut").font(.headline)
            ShortcutControl(title: app.name, value: hotKey, onSave: saveShortcut)
                .disabled(expected == nil || bundleID == nil)
            Text("Press to launch or focus this app. Press again when it is frontmost to hide it. Use Command, Control or Option with a key.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("Launcher alias").font(.headline)
            HStack {
                TextField("For example: c", text: $alias).textFieldStyle(.roundedBorder).onSubmit { saveAlias() }
                if alias != originalAlias { Button("Apply Alias") { saveAlias() } }
            }
            Text("Type this alias in Volant, then press Return. Clearing it removes this alias; other aliases are preserved.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Reload") { load() }
                Spacer()
                Button("Done") { if alias == originalAlias || saveAlias() { dismiss() } }
            }
        }.padding(24).frame(width: 450).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { load() }
    }
    private func load() {
        do {
            let bytes = try Data(contentsOf: configURL)
            let config = try JSONDecoder().decode(Preferences.self, from: bytes)
            expected = bytes
            originalAlias = config.aliases.filter { $0.value == app.url.path || $0.value == app.name }.keys.sorted().first ?? ""
            alias = originalAlias
            originalHotKey = bundleID.map { AppHotKey.binding(in: config.appHotKeys, bundleIdentifier: $0, path: app.url.path) } ?? ""
            hotKey = originalHotKey
            error = bundleID == nil ? "This application has no bundle identifier and cannot receive a global shortcut." : nil
        } catch { self.error = error.localizedDescription; expected = nil }
    }
    private func saveShortcut(_ replacement: String) throws {
        guard let bundleID else { throw BindingFailure(message: "This application has no bundle identifier.") }
        let updated = try AppBindingStore.updateHotKey(bundleID: bundleID, path: app.url.path, value: replacement, expectedValue: originalHotKey,
                                                       at: configURL, available: { HotKeyCenter.shared.isAvailable($0) })
        // A concurrent alias edit must still invalidate the alias draft after saving a shortcut.
        if let expected,
           let previous = try? JSONDecoder().decode(Preferences.self, from: expected),
           let current = try? JSONDecoder().decode(Preferences.self, from: updated),
           previous.aliases == current.aliases { self.expected = updated }
        hotKey = replacement
        originalHotKey = replacement
        onChange()
    }
    @discardableResult
    private func saveAlias() -> Bool {
        guard let expected, let bundleID else { return false }
        do {
            let updated = try AppBindingStore.save(bundleID: bundleID, path: app.url.path, originalAlias: originalAlias, alias: alias,
                                                   hotKey: hotKey, expected: expected, at: configURL) { combo in
                combo == KeyCombo(parsing: originalHotKey) || HotKeyCenter.shared.isAvailable(combo)
            }
            self.expected = updated
            originalAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            alias = originalAlias
            error = nil
            onChange()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
