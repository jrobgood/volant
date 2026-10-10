import Foundation

public struct ACPMessage: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString
    public var role: String
    public var text: String
    /// Titles of what was attached to a prompt. The transcript shows these rather than the
    /// attached text, which went to the agent but would bury the conversation.
    public var attachments: [String]?

    public init(id: String = UUID().uuidString, role: String, text: String, attachments: [String]? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
    }
}
public struct ACPPermission: Codable, Identifiable, Equatable {
    public struct Option: Codable, Identifiable, Equatable {
        public var optionId: String
        public var name: String
        public var kind: String
        public var id: String { optionId }

        public init(optionId: String, name: String, kind: String) {
            self.optionId = optionId
            self.name = name
            self.kind = kind
        }
    }
    public var id: String
    public var title: String
    public var detail: String
    public var options: [Option]

    public init(id: String, title: String, detail: String, options: [Option]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.options = options
    }
}
public struct ACPState: Codable, Equatable {
    public var phase = "disconnected"
    public var status = "Connect to your AI provider to start chatting."
    public var sessionID: String?
    public var agentName = ""
    public var messages: [ACPMessage] = []
    public var permissions: [ACPPermission] = []
    public var capabilities = ""
    /// Set when the agent refused to load a recorded conversation, so the app stops offering it.
    public var resumeRejected: Bool?
    public var busy: Bool { ["starting", "working", "cancelling"].contains(phase) }

    public init(phase: String = "disconnected", status: String = "Connect to your AI provider to start chatting.", sessionID: String? = nil, agentName: String = "", messages: [ACPMessage] = [], permissions: [ACPPermission] = [], capabilities: String = "") {
        self.phase = phase
        self.status = status
        self.sessionID = sessionID
        self.agentName = agentName
        self.messages = messages
        self.permissions = permissions
        self.capabilities = capabilities
    }
}


/// The last ACP conversation Volant started, kept so it can be resumed by its own ID.
/// Resuming by "the latest conversation in this folder" could reopen one the owner started in
/// the provider's own CLI or another client, so only the recorded native session ID is ever
/// sent back to the agent.
public struct ACPResumeRecord: Codable, Equatable {
    public var provider: String
    /// The project exactly as the owner chose it; empty for general chat.
    public var project: String
    public var sessionID: String
    public var savedAt: Date
    /// The account folder the conversation ran under; nil or "" for the provider's default login.
    /// A record saved before accounts existed reads as the default login.
    public var profile: String?

    public init(provider: String, project: String, sessionID: String, savedAt: Date = Date(), profile: String? = nil) {
        self.provider = provider
        self.project = project
        self.sessionID = sessionID
        self.savedAt = savedAt
        self.profile = profile
    }

    /// Whether a new conversation with this provider, folder and account may continue this one.
    /// `profile` is the account folder, or "" for the default login: a session another login
    /// started is not offered.
    public func matches(provider: String, project: String, profile: String) -> Bool {
        self.provider == provider && self.project == project && (self.profile ?? "") == profile
    }

    /// Session IDs come from the agent, so a stored one is checked again before it is sent back:
    /// 1 to 256 printable ASCII characters, with no spaces, slashes or control characters.
    public static func isValidSessionID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && scalar.value > 0x20 && scalar.value < 0x7F && scalar != "/" && scalar != "\\"
        }
    }

    /// A recorded account folder is sent back to the helper as a launch variable, so it must be an
    /// absolute path without NUL.
    public var isValid: Bool {
        ACPProvider(rawValue: provider) != nil && Self.isValidSessionID(sessionID)
            && profile.map { $0.isEmpty || ($0.hasPrefix("/") && !$0.contains("\0")) } ?? true
    }
}

public enum ACPCapabilities {
    /// Whether the agent advertised `loadSession` at initialization. Without it `session/load`
    /// must not be sent.
    public static func supportsLoadSession(_ capabilities: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(capabilities.utf8)) as? [String: Any] else { return false }
        return object["loadSession"] as? Bool ?? false
    }
}

public enum ACPProvider: String, CaseIterable, Identifiable {
    case opencode, cursor, claude, codex, gemini, qwen
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .qwen: return "Qwen Code"
        }
    }
}

/// ACP requires an absolute cwd; general chat does not require a user-selected project.
public enum ACPWorkingDirectory {
    public static func resolve(project: String, generalChat: URL) throws -> String {
        let url: URL
        if project.isEmpty {
            try FileManager.default.createDirectory(at: generalChat, withIntermediateDirectories: true)
            url = generalChat
        } else {
            guard project.hasPrefix("/"), !project.contains("\0") else { throw CocoaError(.fileReadInvalidFileName) }
            url = URL(fileURLWithPath: project)
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw CocoaError(.fileReadNoSuchFile) }
        return url.resolvingSymlinksInPath().path
    }
}
