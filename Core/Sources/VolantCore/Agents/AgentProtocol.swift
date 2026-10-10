import Foundation

@objc public protocol VolantAgentHostProtocol {
    func listAppleShortcuts(reply: @escaping (Data?, String?) -> Void)
    func runAppleShortcut(id: String, reply: @escaping (String?) -> Void)
    func acpStart(provider: String, project: String, reply: @escaping (String?) -> Void)
    /// Starts the provider and loads a conversation it created earlier, by its recorded native
    /// session ID. The reply reports only a refused ID or a failed launch; when the agent cannot
    /// load the conversation, it ends as failed in `acpRead` and no new conversation starts.
    func acpResume(provider: String, project: String, session: String, reply: @escaping (String?) -> Void)
    /// The conversation as JSON `ACPState` with its revision. When `after` is already the current
    /// revision the reply carries no data: nothing changed. A negative `after` always gets the state.
    func acpRead(after revision: Int, reply: @escaping (Data?, Int, String?) -> Void)
    func acpPrompt(text: String, reply: @escaping (String?) -> Void)
    /// A prompt with owner-chosen attachments, a JSON array of `ChatAttachment`.
    func acpPromptWithContext(text: String, attachments: Data, reply: @escaping (String?) -> Void)
    func acpCancel(reply: @escaping (String?) -> Void)
    func acpPermission(request: String, option: String, reply: @escaping (String?) -> Void)
    func acpStop(reply: @escaping () -> Void)
    func answerAgentQuestion(token: String, choice: Int, reply: @escaping (String?, String?) -> Void)
    func readAgentAttention(target: Data, reply: @escaping (Data?, String?) -> Void)
    func listHerdrMachines(reply: @escaping (Data?, String?) -> Void)
    /// Turns a saved machine on or off in Herdr, which owns that state, and replies with the
    /// refreshed catalog so the caller never renders the value it requested.
    func setHerdrMachine(machine: Data, enabled: Bool, reply: @escaping (Data?, String?) -> Void)
    func listAgents(machine: Data?, reply: @escaping (Data?, String?) -> Void)
    func focusAgent(target: Data, reply: @escaping (String?) -> Void)
    /// Every known ACP provider and whether its executable is present. Starts nothing.
    func detectACPAgents(reply: @escaping (Data?, String?) -> Void)
    /// Change counts for up to 32 local working folders, as a JSON map from path to state.
    func repositoryStates(paths: Data, reply: @escaping (Data?, String?) -> Void)
}

public struct AgentSession: Codable, Identifiable, Hashable {
    public let agent: String
    public let agentStatus: String
    public let paneID: String
    public let terminalID: String
    public let cwd: String?
    public let terminalTitle: String?
    public struct SessionReference: Codable, Hashable {
        public let value: String

        public init(value: String) { self.value = value }
    }
    public let agentSession: SessionReference?
    public var machine: HerdrMachine? = nil
    public var machineLabel: String { machine?.label ?? "Local" }
    public var stateChangeSequence: UInt64? = nil
    /// Whether Herdr reports this pane as the one in front, which counts as having looked at it.
    public var focused: Bool? = nil
    public var sessionIdentity: String { agent + ":" + (agentSession?.value ?? terminalID) }
    public var id: String { (machine.map { "remote:" + $0.routeIdentity + ":" } ?? "local:") + terminalID + ":" + paneID }
    /// The folder name, taken from the path string alone. `URL(fileURLWithPath:)` checks the file
    /// system, and on the main thread a sandboxed lookup of every pane's folder stalled typing.
    public var project: String { cwd.map { ($0 as NSString).lastPathComponent } ?? "Unknown project" }
    public var provider: String {
        switch agent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        case "cursor": return "Cursor"
        case "gemini": return "Gemini CLI"
        case "qwen": return "Qwen Code"
        default: return agent.capitalized
        }
    }
    public var status: String {
        switch agentStatus {
        case "blocked": return "Needs attention"
        case "working": return "Working"
        case "done": return "Done"
        case "idle": return "Idle"
        default: return "Unknown"
        }
    }
    public var priority: Int { ["blocked": 0, "working": 1, "done": 2, "idle": 3][agentStatus] ?? 4 }
    public enum CodingKeys: String, CodingKey {
        case agent, cwd, machine, focused
        case stateChangeSequence = "state_change_seq"
        case agentStatus = "agent_status"
        case paneID = "pane_id"
        case terminalID = "terminal_id"
        case terminalTitle = "terminal_title_stripped"
        case agentSession = "agent_session"
    }
    public static func decodeList(_ data: Data, machine: HerdrMachine? = nil) throws -> [AgentSession] {
        struct Envelope: Decodable { struct Result: Decodable { let agents: [AgentSession] }; let result: Result }
        return sorted(try JSONDecoder().decode(Envelope.self, from: data).result.agents.map { value in
            var value = value; value.machine = machine; return value
        })
    }
    /// Orders panes by attention priority, project name, then identity, computing each pane's keys
    /// once rather than on every comparison during each Herdr refresh.
    public static func sorted(_ agents: [AgentSession]) -> [AgentSession] {
        agents.map { (agent: $0, priority: $0.priority, project: $0.project, id: $0.id) }
            .sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                if $0.project != $1.project { return $0.project.localizedStandardCompare($1.project) == .orderedAscending }
                return $0.id < $1.id
            }
            .map(\.agent)
    }

    public init(agent: String, agentStatus: String, paneID: String, terminalID: String, cwd: String? = nil, terminalTitle: String? = nil, agentSession: SessionReference? = nil, machine: HerdrMachine? = nil, stateChangeSequence: UInt64? = nil) {
        self.agent = agent
        self.agentStatus = agentStatus
        self.paneID = paneID
        self.terminalID = terminalID
        self.cwd = cwd
        self.terminalTitle = terminalTitle
        self.agentSession = agentSession
        self.machine = machine
        self.stateChangeSequence = stateChangeSequence
    }
}
