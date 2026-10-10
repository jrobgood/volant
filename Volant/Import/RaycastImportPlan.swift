import Foundation
import CryptoKit
import VolantCore

enum RaycastCategory: String, CaseIterable {
    case snippets = "Snippets", quicklinks = "Quicklinks", aliases = "App aliases", hotkeys = "App hotkeys", notes = "Notes"
}

struct RaycastImportPlan {
    var snippets: [Snippet] = []
    var quicklinks: [Quicklink] = []
    var aliases: [String: String] = [:]
    var hotkeys: [AppHotKey] = []
    var notes: [String: String] = [:]
    var report: [String] = []
    let originalConfig: Data
    let configURL: URL
    let notesURL: URL
    func count(_ category: RaycastCategory) -> Int {
        switch category {
        case .snippets: return snippets.count
        case .quicklinks: return quicklinks.count
        case .aliases: return aliases.count
        case .hotkeys: return hotkeys.count
        case .notes: return notes.count
        }
    }

    static func make(payload: Data, configURL: URL = Preferences.configURL,
                     notesURL: URL = Preferences.supportDirectory.appendingPathComponent("Notes"),
                     resolveApp: (String) -> (id: String, name: String)? = { path in
                         let url = URL(fileURLWithPath: path)
                         guard url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier else { return nil }
                         return (id, url.deletingPathExtension().lastPathComponent)
                     }) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw RaycastArchive.failure("The unlocked export is not a supported data object.") }
        let bytes = try Data(contentsOf: configURL)
        let existing = try JSONDecoder().decode(Preferences.self, from: bytes)
        var plan = Self(originalConfig: bytes, configURL: configURL, notesURL: notesURL)
        func rows(_ category: String, _ field: String) -> [[String: Any]] {
            guard let value = root[category] else { return [] }
            let entries = (value as? [String: Any])?[field] ?? value
            guard let list = entries as? [Any] else {
                plan.report.append("\(category): unrecognized data format; skipped."); return []
            }
            let dictionaries = list.compactMap { $0 as? [String: Any] }
            if dictionaries.count != list.count { plan.report.append("\(category): \(list.count - dictionaries.count) malformed entries skipped.") }
            return dictionaries
        }
        var snippetNames = Set(existing.snippets.map { $0.name.lowercased() })
        var keywords = Set(existing.snippets.map { $0.keyword.lowercased() }.filter { !$0.isEmpty })
        let supportedTokens: Set<String> = ["date", "time", "datetime", "isodate", "clipboard", "uuid"]
        for row in rows("snippets", "snippets") {
            guard let name = nonempty(row["title"]), let body = row["text"] as? String else { plan.report.append("Snippet with missing title or text skipped."); continue }
            var keyword = nonempty(row["keyword"]) ?? ""
            if LauncherRouting.isReserved(keyword) {
                plan.report.append("Snippet “\(name)”: reserved keyword “\(keyword)” removed; find it with snip instead.")
                keyword = ""
            }
            guard !snippetNames.contains(name.lowercased()), keyword.isEmpty || !keywords.contains(keyword.lowercased()) else {
                plan.report.append("Snippet “\(name)”: existing name or keyword; skipped."); continue
            }
            let tokens = matches(body, pattern: #"\{([^{}]+)\}"#)
            let unsupported = tokens.filter { !supportedTokens.contains($0) }
            if !unsupported.isEmpty {
                plan.report.append("Snippet “\(name)”: unsupported placeholders remain literal: \(unsupported.prefix(5).joined(separator: ", ")).")
            }
            if tokens.contains("date") || tokens.contains("time") || tokens.contains("datetime") {
                plan.report.append("Snippet “\(name)”: date/time placeholders use Volant’s local formatting.")
            }
            plan.snippets.append(Snippet(name: name, keyword: keyword, body: body))
            snippetNames.insert(name.lowercased()); if !keyword.isEmpty { keywords.insert(keyword.lowercased()) }
        }
        var linkNames = Set(existing.quicklinks.map { $0.name.lowercased() })
        var urls = Set(existing.quicklinks.map(\.url))
        for row in rows("quicklinks", "quicklinks") {
            guard let name = nonempty(row["name"]), let raw = nonempty(row["link"]) else { plan.report.append("Quicklink with missing name or URL skipped."); continue }
            guard !LauncherRouting.isReserved(name) else { plan.report.append("Quicklink “\(name)”: reserved launcher command; skipped."); continue }
            let url = raw.replacingOccurrences(of: "{Query}", with: "{query}")
            guard matches(url, pattern: #"\{([^{}]+)\}"#).allSatisfy({ $0 == "query" }) else {
                plan.report.append("Quicklink “\(name)”: unsupported dynamic parameters; skipped."); continue
            }
            let link = Quicklink(name: name, url: url)
            guard QuicklinkResolver.url(for: link, query: "preview") != nil else { plan.report.append("Quicklink “\(name)”: unsupported URL scheme; skipped."); continue }
            guard !linkNames.contains(name.lowercased()), !urls.contains(url) else { plan.report.append("Quicklink “\(name)”: duplicate name or URL; skipped."); continue }
            if nonempty(row["openWith"]) != nil || nonempty(row["applicationId"]) != nil {
                plan.report.append("Quicklink “\(name)”: opens in the default app; Raycast’s app override is not imported.")
            }
            plan.quicklinks.append(link); linkNames.insert(name.lowercased()); urls.insert(url)
        }
        let settings = root["settings"] as? [String: Any]
        var knownAliases = Set(existing.aliases.keys.map { $0.lowercased() })
        var appIDs = Set(existing.appHotKeys.map(\.bundleIdentifier))
        var combos = ([existing.summonHotKey, existing.notesHotKey, existing.emojiHotKey] + existing.appHotKeys.map(\.hotKey)).compactMap(KeyCombo.init(parsing:))
        for command in settings?["commands"] as? [[String: Any]] ?? [] {
            let alias = nonempty(command["alias"])
            let hasHotkey = command["macosHotkey"] is [String: Any]
            guard alias != nil || hasHotkey else { continue }
            guard command["extensionId"] as? String == "e:r:applications",
                  let id = command["id"] as? String, let split = id.range(of: "::=::"),
                  let app = resolveApp(String(id[split.upperBound...])) else {
                plan.report.append("A command alias/hotkey has no installed app equivalent; skipped."); continue
            }
            if let alias {
                if knownAliases.contains(alias.lowercased()) || alias.contains(where: \.isWhitespace) || LauncherRouting.isReserved(alias) {
                    plan.report.append("Alias “\(alias)”: conflict, reserved command, or unsupported multiword alias; skipped.")
                } else { plan.aliases[alias.lowercased()] = String(id[split.upperBound...]); knownAliases.insert(alias.lowercased()) }
            }
            if hasHotkey {
                guard let key = hotkey(command["macosHotkey"]), let combo = KeyCombo(parsing: key) else { plan.report.append("\(app.name): unsupported hotkey; skipped."); continue }
                guard !appIDs.contains(app.id), !combos.contains(combo) else { plan.report.append("\(app.name): existing app binding or key conflict; skipped."); continue }
                plan.hotkeys.append(AppHotKey(bundleIdentifier: app.id, hotKey: key, path: String(id[split.upperBound...]))); appIDs.insert(app.id); combos.append(combo)
            }
        }
        for row in rows("notes", "notes") {
            // Only explicit Markdown/plain-text fields are accepted. Never stringify rich document objects.
            let text = row["markdown"] as? String ?? row["text"] as? String
            guard let text else { plan.report.append("Note: unsupported rich-text representation; skipped."); continue }
            let title = nonempty(row["title"])
            let content = title.map { "# \($0)\n\n\(text)" } ?? text
            let hash = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
            let name = "raycast-\(hash).md"
            let target = notesURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: target.path) || plan.notes[name] != nil {
                plan.report.append("Note “\(title ?? "Untitled")”: already imported; skipped.")
            } else { plan.notes[name] = content }
        }
        let supported: Set<String> = ["snippets", "quicklinks", "settings", "notes"]
        let other = root.keys.filter { !supported.contains($0) }.sorted()
        if !other.isEmpty { plan.report.append("Not imported: \(other.joined(separator: ", ")).") }
        plan.report.append("Global shortcuts, extension commands, clipboard history, and AI sessions are not imported. Snippet keywords are searched in Volant; they do not enable automatic text expansion.")
        if !plan.hotkeys.isEmpty { plan.report.append("App hotkeys toggle activate/hide in Volant. Raycast may still own the same keys; disable those bindings there before enabling them here.") }
        return plan
    }
    private static func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private static func matches(_ text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
    private static func hotkey(_ value: Any?) -> String? {
        guard let hotkey = value as? [String: Any], let kind = hotkey["kind"] as? [String: Any],
              let shortcut = kind["shortcut"] as? [String: Any], let key = shortcut["key"] as? [String: Any],
              key["type"] as? String == "LayoutIndependent", let code = key["code"] as? Int,
              code >= 0, code <= Int(UInt32.max), let name = KeyCombo.keyCodes.keys.sorted().first(where: { KeyCombo.keyCodes[$0] == UInt32(code) }),
              let modifiers = shortcut["modifiers"] as? [[String: Any]], !modifiers.isEmpty else { return nil }
        let mapping = ["Meta": "cmd", "Ctrl": "ctrl", "Alt": "option", "Shift": "shift"]
        var parts: [String] = []
        for modifier in modifiers {
            guard let raw = modifier["modifier"] as? String, let mapped = mapping[raw] else { return nil }
            parts.append(mapped)
        }
        return (parts + [name]).joined(separator: "+")
    }

    /// Main-thread commit, with original-byte revalidation, additive notes, and a durable recovery folder.
    func apply(_ selected: Set<RaycastCategory>) throws -> URL {
        let fm = FileManager.default
        guard try Data(contentsOf: configURL) == originalConfig else { throw RaycastArchive.failure("Configuration changed after this preview. Unlock the export again to refresh conflicts.") }
        guard selected.contains(where: { count($0) > 0 }) else { throw RaycastArchive.failure("Select at least one category with new items.") }
        guard var object = try JSONSerialization.jsonObject(with: originalConfig) as? [String: Any] else { throw RaycastArchive.failure("Configuration is not a JSON object.") }
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: encoder.encode(value)) }
        let current = try JSONDecoder().decode(Preferences.self, from: originalConfig)
        if selected.contains(.snippets) { object["snippets"] = (object["snippets"] as? [Any] ?? []) + (try json(snippets) as? [Any] ?? []) }
        if selected.contains(.quicklinks) { object["quicklinks"] = (object["quicklinks"] as? [Any] ?? []) + (try json(quicklinks) as? [Any] ?? []) }
        if selected.contains(.hotkeys) { object["appHotKeys"] = (object["appHotKeys"] as? [Any] ?? []) + (try json(hotkeys) as? [Any] ?? []) }
        if selected.contains(.aliases) { object["aliases"] = current.aliases.merging(aliases) { old, _ in old } }
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        _ = try JSONDecoder().decode(Preferences.self, from: updated)
        let recovery = configURL.deletingLastPathComponent().appendingPathComponent("Raycast-Import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: recovery, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try originalConfig.write(to: recovery.appendingPathComponent("config.json"), options: .atomic)
        let planned = selected.contains(.notes) ? notes.keys.sorted() : []
        let instructions = "Original config.json is preserved here. Import adds only the following note files; existing notes are never changed. To undo, restore config.json and remove only these files from Notes after preserving any later edits.\n" + planned.joined(separator: "\n")
        try instructions.write(to: recovery.appendingPathComponent("Recovery.txt"), atomically: true, encoding: .utf8)
        var created: [URL] = []
        do {
            if !planned.isEmpty { try fm.createDirectory(at: notesURL, withIntermediateDirectories: true) }
            for name in planned {
                let target = notesURL.appendingPathComponent(name)
                guard let text = notes[name] else { throw RaycastArchive.failure("A previewed note is missing. Refresh the preview.") }
                try Data(text.utf8).write(to: target, options: .withoutOverwriting)
                created.append(target)
            }
            guard try Data(contentsOf: configURL) == originalConfig else { throw RaycastArchive.failure("Configuration changed during import. Nothing was replaced.") }
            try updated.write(to: configURL, options: .atomic)
        } catch {
            var rollbackFailed = false
            for url in created { do { try fm.removeItem(at: url) } catch { rollbackFailed = true } }
            if rollbackFailed { throw RaycastArchive.failure("Import failed and some added notes could not be removed. Recovery details: \(recovery.path)") }
            throw error
        }
        return recovery
    }
}
