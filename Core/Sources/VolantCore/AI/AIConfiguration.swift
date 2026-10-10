import Foundation

public struct AIConfiguration: Codable, Equatable {
    public var provider = ""
    public var connection: AIConnectionKind = .acp
    public var api = AIHTTPConfiguration()
    public var localAPI = AIHTTPConfiguration(provider: .compatible, endpoint: "http://127.0.0.1:11434/v1", local: true)
    public var http: AIHTTPConfiguration { connection == .local ? localAPI : api }
    /// Apple Intelligence carries no settings of its own; whether the model is actually usable is
    /// a runtime question the app answers, because this layer cannot import FoundationModels.
    public var isConfigured: Bool {
        switch connection {
        case .acp: return ACPProvider(rawValue: provider) != nil
        case .apple: return true
        case .byok, .local: return (try? http.validate()) != nil
        }
    }
    public var project = ""
    /// Account folders for Claude Code and Codex. Entries that are not `ACPAccountProfile.isValid`,
    /// and repeated IDs, are dropped when the settings are read. Saving keeps the fields a later
    /// version wrote inside a listed entry, and the entries this version cannot read.
    public var profiles: [ACPAccountProfile] = []
    /// The account each provider's new conversations run under, keyed by provider raw value: a
    /// profile ID, or "" for the provider's default login. Choices that name no profile of their
    /// provider are dropped when the settings are read. The default login is stored as "": saving
    /// merges into the file's earlier choices, so a removed key would keep its earlier value.
    public var accounts: [String: String] = [:]
    public enum CodingKeys: String, CodingKey { case provider, project, connection, api, localAPI, profiles, accounts }
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        connection = try c.decodeIfPresent(AIConnectionKind.self, forKey: .connection) ?? .acp
        api = try c.decodeIfPresent(AIHTTPConfiguration.self, forKey: .api) ?? AIHTTPConfiguration()
        localAPI = try c.decodeIfPresent(AIHTTPConfiguration.self, forKey: .localAPI) ?? AIHTTPConfiguration(provider: .compatible, endpoint: "http://127.0.0.1:11434/v1", local: true)
        guard !api.local, localAPI.local else { throw CocoaError(.fileReadCorruptFile) }

        guard provider.isEmpty || ACPProvider(rawValue: provider) != nil else { throw CocoaError(.fileReadCorruptFile) }
        // A damaged profile or choice falls back to the default login instead of failing the whole
        // AI configuration.
        let kept = Self.readable((try? c.decodeIfPresent([Lossy<ACPAccountProfile>].self, forKey: .profiles)) ?? []).compactMap { $0 }
        let choices = (try? c.decodeIfPresent([String: String].self, forKey: .accounts)) ?? [:]
        profiles = kept
        accounts = choices.filter { Self.isChoice($0.value, for: $0.key, among: kept) }
    }

    /// The profile `provider`'s new conversations run under; nil for the default login.
    public func account(for provider: String) -> ACPAccountProfile? {
        guard let id = accounts[provider], !id.isEmpty else { return nil }
        return profiles.first { $0.id == id && $0.provider == provider }
    }

    public func profiles(for provider: String) -> [ACPAccountProfile] {
        profiles.filter { $0.provider == provider }
    }

    /// Chooses the account for `provider`'s new conversations. nil, an unknown ID or another
    /// provider's profile chooses the default login; a provider without an account variable is left
    /// unchanged. A conversation already running keeps the account it started with.
    public mutating func chooseAccount(_ id: String?, for provider: String) {
        guard let known = ACPProvider(rawValue: provider), ACPAccountProfile.environmentKey(for: known) != nil else { return }
        let chosen = id.flatMap { id in profiles.first { $0.id == id && $0.provider == provider }?.id }
        accounts[provider] = chosen ?? ""
    }

    /// Adds a profile with its label trimmed. Throws an `ACPAccountProfile.Refusal` for a profile
    /// that fails `validate()`, a repeated ID, a folder any account already uses, since two
    /// providers would keep their files side by side in it, or a label already used for that provider.
    public mutating func addProfile(_ profile: ACPAccountProfile) throws {
        try profile.validate()
        var added = profile
        added.label = ACPAccountProfile.trimmedLabel(profile.label) ?? profile.label
        let title = ACPProvider(rawValue: profile.provider)?.title ?? profile.provider
        guard !added.id.isEmpty, !profiles.contains(where: { $0.id == added.id }) else { throw ACPAccountProfile.Refusal("This account is already listed.") }
        if let owner = profiles.first(where: { $0.directory == added.directory }) {
            throw ACPAccountProfile.Refusal("This folder is already a \(ACPProvider(rawValue: owner.provider)?.title ?? owner.provider) account.")
        }
        guard !profiles(for: added.provider).contains(where: { $0.label == added.label }) else { throw ACPAccountProfile.Refusal("Another \(title) account uses this label.") }
        profiles.append(added)
    }

    /// Removes a profile. A provider whose choice named it goes back to the default login; a
    /// conversation already running under it keeps it until it ends.
    public mutating func removeProfile(id: String) {
        guard let removed = profiles.first(where: { $0.id == id }) else { return }
        profiles.removeAll { $0.id == id }
        if accounts[removed.provider] == id { accounts[removed.provider] = "" }
    }

    private static func isChoice(_ id: String, for provider: String, among profiles: [ACPAccountProfile]) -> Bool {
        guard let known = ACPProvider(rawValue: provider), ACPAccountProfile.environmentKey(for: known) != nil else { return false }
        return id.isEmpty || profiles.contains { $0.id == id && $0.provider == provider }
    }

    /// One array element that decodes to nil instead of failing the array.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    /// The profiles this version reads from a `profiles` value, by position: nil for an entry that
    /// failed to decode, is not `ACPAccountProfile.isValid`, or repeats an earlier ID.
    private static func readable(_ entries: [Lossy<ACPAccountProfile>]) -> [ACPAccountProfile?] {
        var ids = Set<String>()
        return entries.map { entry in entry.value.flatMap { $0.isValid && ids.insert($0.id).inserted ? $0 : nil } }
    }

    /// The encoded `listed` profiles, each with the fields a later version wrote inside its entry in
    /// the file's `previous` value, followed by the file's entries that fail decoding or validation:
    /// this version never lists those, so the owner cannot have removed them. A readable entry that
    /// is no longer listed was removed, and a repeated ID is dropped, as when the file is read.
    private static func mergedProfiles(_ listed: [[String: Any]], into previous: Any?) -> [Any] {
        let earlier = previous as? [Any] ?? []
        let entries = (try? JSONSerialization.data(withJSONObject: earlier)).flatMap { try? JSONDecoder().decode([Lossy<ACPAccountProfile>].self, from: $0) } ?? []
        guard entries.count == earlier.count else { return listed }
        let read = readable(entries)
        var fields: [String: [String: Any]] = [:]
        var unread: [Any] = []
        for (index, entry) in earlier.enumerated() {
            if let profile = read[index] { fields[profile.id] = entry as? [String: Any] }
            else if entries[index].value?.isValid != true { unread.append(entry) }
        }
        let merged: [Any] = listed.map { profile -> [String: Any] in
            guard let id = profile["id"] as? String, var entry = fields[id] else { return profile }
            profile.forEach { entry[$0.key] = $0.value }
            return entry
        }
        return merged + unread
    }
    public static func load(at url: URL = Preferences.configURL) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        guard let value = object["ai"] else { return Self() }
        return try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value))
    }
    public func save(at url: URL = Preferences.configURL, expected: AIConfiguration? = nil) throws {
        if let expected, try Self.load(at: url) != expected { throw CocoaError(.fileWriteFileExists) }
        guard provider.isEmpty || ACPProvider(rawValue: provider) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        // Patch the latest file; preserve unknown settings inside and outside AI.
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        var ai = object["ai"] as? [String: Any] ?? [:]
        guard let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] else { throw CocoaError(.fileWriteUnknown) }
        for (key, value) in values {
            if key == CodingKeys.profiles.rawValue, let listed = value as? [[String: Any]] {
                ai[key] = Self.mergedProfiles(listed, into: ai[key])
            } else if let fields = value as? [String: Any], var previous = ai[key] as? [String: Any] {
                fields.forEach { previous[$0.key] = $0.value }; ai[key] = previous
            } else { ai[key] = value }
        }
        object["ai"] = ai
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
