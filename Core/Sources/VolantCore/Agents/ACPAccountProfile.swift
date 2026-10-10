import Foundation

/// A provider login kept in a configuration folder of its own. Claude Code reads its folder from
/// `CLAUDE_CONFIG_DIR` and Codex from `CODEX_HOME`, so a conversation started under a profile gets
/// that one variable and nothing else. Volant never reads, copies or moves what the folder holds;
/// the owner signs in through the provider's own CLI with the same variable set.
public struct ACPAccountProfile: Codable, Equatable, Identifiable {
    public var id: String
    /// An `ACPProvider` raw value.
    public var provider: String
    /// Shown beside every conversation that runs under this profile.
    public var label: String
    /// The account folder, as an absolute path.
    public var directory: String

    public init(id: String = UUID().uuidString, provider: String, label: String, directory: String) {
        self.id = id
        self.provider = provider
        self.label = label
        self.directory = directory
    }

    /// The most characters a label may have, counted as the owner sees them.
    public static let labelLimit = 40

    /// Why a profile or its launch variables were refused.
    public struct Refusal: LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// The variable that points `provider` at an account folder; nil for a provider that has none.
    public static func environmentKey(for provider: ACPProvider) -> String? {
        switch provider {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        case .opencode, .cursor, .gemini, .qwen: return nil
        }
    }

    /// The launch variables that start `provider` under the account in `directory`. Throws a
    /// `Refusal` for a provider without an account variable, or a folder that is not an absolute
    /// path or holds NUL. Whether the folder exists is the helper's check, made after this one.
    public static func launchVariables(provider: ACPProvider, directory: String) throws -> [String: String] {
        guard let key = environmentKey(for: provider) else { throw Refusal("Only Claude Code and Codex can use an account folder.") }
        guard directory.hasPrefix("/"), !directory.contains("\0") else { throw Refusal("An account folder must be a full path.") }
        return [key: directory]
    }

    /// `label` without surrounding white space, or nil when that leaves 0 or more than
    /// `labelLimit` characters.
    public static func trimmedLabel(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...labelLimit).contains(trimmed.count) ? trimmed : nil
    }

    /// Throws a `Refusal` for an unknown provider or one without an account variable, an empty or
    /// overlong label, or a folder `launchVariables` refuses.
    public func validate() throws {
        guard let known = ACPProvider(rawValue: provider) else { throw Refusal("Only Claude Code and Codex can use an account folder.") }
        _ = try Self.launchVariables(provider: known, directory: directory)
        guard Self.trimmedLabel(label) != nil else { throw Refusal("Enter a label of 1 to \(Self.labelLimit) characters.") }
    }

    public var isValid: Bool { !id.isEmpty && (try? validate()) != nil }
}
