import Foundation
import Carbon.HIToolbox
import VolantCore

struct BindingFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Patch only this app's binding, preserving unknown fields and unrelated aliases.
/// Shortcuts are keyed by the application copy's path so two installed copies of one bundle identifier
/// keep separate bindings. Saving over a legacy entry without a path keeps its unknown fields and adds the path.
enum AppBindingStore {
    @discardableResult
    static func save(bundleID: String, path: String, originalAlias: String, alias: String, hotKey: String,
                     expected: Data, at url: URL, available: (KeyCombo) -> Bool) throws -> Data {
        let current = try Data(contentsOf: url)
        guard current == expected else { throw BindingFailure(message: "Configuration changed. Reload this editor before saving again.") }
        let config = try JSONDecoder().decode(Preferences.self, from: current)
        guard var object = try JSONSerialization.jsonObject(with: current) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try validateAlias(alias, originalAlias: originalAlias, config: config)
        if !hotKey.isEmpty {
            guard let combo = KeyCombo(parsing: hotKey), combo.carbonModifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else {
                throw BindingFailure(message: "Include Command, Control or Option in a global shortcut.")
            }
            let own = AppHotKey.bindingIndex(in: config.appHotKeys, bundleIdentifier: bundleID, path: path)
            let others = Array(GlobalShortcutStore.bindings(config).values) + config.appHotKeys.indices.filter { $0 != own }.map { config.appHotKeys[$0].hotKey }
            guard !others.contains(where: { KeyCombo(parsing: $0) == combo }) else { throw BindingFailure(message: "That shortcut is already assigned in Volant.") }
            guard available(combo) else { throw BindingFailure(message: "macOS or another app is using that shortcut. Choose another combination.") }
        }
        var aliases = object["aliases"] as? [String: String] ?? [:]
        if !originalAlias.isEmpty { aliases.removeValue(forKey: originalAlias) }
        if !alias.isEmpty { aliases[alias] = path }
        object["aliases"] = aliases
        var entries = object["appHotKeys"] as? [[String: Any]] ?? []
        let parsed = entries.map { AppHotKey(bundleIdentifier: $0["bundleIdentifier"] as? String ?? "", hotKey: $0["hotKey"] as? String ?? "", path: $0["path"] as? String) }
        var entry: [String: Any] = [:]
        if let index = AppHotKey.bindingIndex(in: parsed, bundleIdentifier: bundleID, path: path) { entry = entries.remove(at: index) }
        if !hotKey.isEmpty {
            entry["bundleIdentifier"] = bundleID
            entry["hotKey"] = hotKey
            entry["path"] = path
            entries.append(entry)
        }
        object["appHotKeys"] = entries
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        _ = try JSONDecoder().decode(Preferences.self, from: data)
        try data.write(to: url, options: .atomic)
        return data
    }
    private static func validateAlias(_ alias: String, originalAlias: String, config: Preferences) throws {
        if !alias.isEmpty {
            guard !LauncherRouting.isReserved(alias), !alias.contains(where: { $0.isWhitespace }),
                  !alias.hasPrefix("/"), !alias.hasPrefix("@"), !alias.hasPrefix(":"),
                  alias.rangeOfCharacter(from: .letters) != nil else {
                throw BindingFailure(message: "Choose a single word or letter that is not a built-in command.")
            }
            guard !config.aliases.keys.contains(where: { $0.lowercased() == alias && $0 != originalAlias }),
                  !config.quicklinks.contains(where: { $0.name.lowercased() == alias }),
                  !config.snippets.contains(where: { $0.keyword.lowercased() == alias }) else {
                throw BindingFailure(message: "That alias is already used by another alias, quicklink or snippet.")
            }
        }
    }

    static func updateAlias(path: String, name: String, originalAlias: String, value: String,
                            expectedAliases: [String: String], at url: URL) throws {
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(Preferences.self, from: data)
        let currentAliases = config.aliases.filter { $0.value == path || $0.value == name }
        guard currentAliases == expectedAliases else {
            throw BindingFailure(message: "This app's aliases changed. Reload the row before trying again.")
        }
        let alias = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        try validateAlias(alias, originalAlias: originalAlias, config: config)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        var aliases = config.aliases
        if !originalAlias.isEmpty { aliases.removeValue(forKey: originalAlias) }
        if !alias.isEmpty { aliases[alias] = path }
        object["aliases"] = aliases
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: url, options: .atomic)
    }

    static func updateHotKey(bundleID: String, path: String, value: String, expectedValue: String, at url: URL,
                             available: (KeyCombo) -> Bool) throws -> Data {
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(Preferences.self, from: data)
        let current = AppHotKey.binding(in: config.appHotKeys, bundleIdentifier: bundleID, path: path)
        guard current == expectedValue else { throw BindingFailure(message: "This app shortcut changed. Reload before trying again.") }
        return try save(bundleID: bundleID, path: path, originalAlias: "", alias: "", hotKey: value, expected: data, at: url) { combo in
            combo == KeyCombo(parsing: current) || available(combo)
        }
    }

}
