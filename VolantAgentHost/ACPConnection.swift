import Foundation
import Darwin
import VolantCore

/// One Volant-owned ACP v1 session. All state and protocol IO are serialized on queue.
/// Only fixed provider executables are launched. No shell, terminal-input or generic RPC surface.
final class ACPConnection {
    let queue = DispatchQueue(label: "com.mysticcoders.volant.acp")
    /// Every change to state, including in-place edits of a message, advances the revision.
    private(set) var state = ACPState() { didSet { revision &+= 1 } }
    private(set) var revision = 0
    private let writer = DispatchQueue(label: "com.mysticcoders.volant.acp-writer")
    private var task: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var pending: [Int: String] = [:]
    private var nextID = 0
    private var permissionIDs: [String: Any] = [:]
    private var project = ""
    /// Set only for a resume: the recorded native session ID, sent with session/load in place of session/new.
    private var resumeID: String?
    private var epoch = UUID()
    private var turn = UUID()
    private var textBytes = 0
    private var toolDetails: [String: [String: Any]] = [:]
    private var detailBytes = 0
    private var replayTrimmed = false
    static let replayTextLimit = 400_000
    static let replayEventLimit = 800
    /// Shared by every connection in this helper process, so the limit counts conversations across
    /// all of the app's connections.
    private let slots: ACPConversationSlots
    private var holdsSlot = false
    // Fixture injection is only available to Swift tests, never over XPC.
    var testSend: (([String: Any]) -> Void)?

    init(slots: ACPConversationSlots = .shared) {
        self.slots = slots
    }

    func start(provider: String, project: String, resume: String? = nil) throws {
        guard task == nil, state.phase == "disconnected" else { throw failure("End this conversation before starting another.") }
        if let resume, !ACPResumeRecord.isValidSessionID(resume) { throw failure("This conversation can’t be resumed. Start a new conversation.") }
        try takeSlot()
        // Every exit below that launches no agent returns the slot.
        var launched = false
        defer { if !launched { releaseSlot() } }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let selected = ACPProvider(rawValue: provider) else { throw failure("Unknown ACP provider.") }
        let launch: ACPLaunch
        do { launch = try ACPAgentResolver.system.launch(selected) }
        catch { throw failure(error.localizedDescription) }
        let executable = launch.executable, arguments = launch.arguments, providerEnvironment = launch.environment
        let chatDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Volant/Chat", isDirectory: true)
        do { self.project = try ACPWorkingDirectory.resolve(project: project, generalChat: chatDirectory) }
        catch { throw failure("Could not open the working folder. Choose another folder or use General Chat in AI Settings.") }
        state.phase = "starting"; state.status = "Connecting to " + provider + "…"
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: self.project)
        process.environment = ChildProcessEnvironment.acpProvider(home: home, user: NSUserName(), executable: executable, launch: providerEnvironment)
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        let generation = epoch
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.epoch == generation else { return }
                self.stop("Agent process exited. Check the provider’s terminal login and reconnect.", failed: true)
            }
        }
        try process.run()
        launched = true
        task = process; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { [weak self] in
                guard let self, self.epoch == generation else { return }
                if data.isEmpty { self.stop("Agent connection closed.", failed: true) }
                else { self.receive(data) }
            }
        }
        beginHandshake(project: self.project, resume: resume)
        queue.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.epoch == generation, self.state.phase == "starting" else { return }
            self.stop("Agent startup timed out. Check its terminal login and reconnect.", failed: true)
        }
    }
    /// The encoded state and its revision. A reader that already holds the current revision gets
    /// no data, so an unchanged conversation is neither encoded nor sent again.
    func snapshot(after known: Int) throws -> (Data?, Int) {
        known == revision ? (nil, revision) : (try JSONEncoder().encode(state), revision)
    }
    /// Takes one of the helper's conversation slots before anything is resolved or launched. Internal
    /// so `tools/acp/check.swift` can hold a slot without an installed agent; never exposed over XPC.
    func takeSlot() throws {
        guard !holdsSlot else { return }
        guard slots.acquire() else {
            throw failure("Volant runs up to \(slots.limit) conversations at once. End one to start another.")
        }
        holdsSlot = true
    }
    private func releaseSlot() {
        guard holdsSlot else { return }
        holdsSlot = false
        slots.release()
    }
    func beginHandshake(project: String, resume: String? = nil) {
        self.project = project
        resumeID = resume; replayTrimmed = false; state.resumeRejected = nil
        state.phase = "starting"
        request("initialize", ["protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false], "clientInfo": ["name": "volant", "title": "Volant", "version": "0.1.0"]])
    }
    /// Attachments are re-checked here rather than trusted from the app, and shaped by what this
    /// agent advertised at initialization.
    func prompt(_ text: String, attachments: [ChatAttachment] = []) throws {
        guard state.phase == "ready", let id = state.sessionID else { throw failure("The conversation is not ready for another prompt.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 64_000 else { throw failure("Enter a prompt of at most 64 KB.") }
        if let problem = ChatAttachmentLimits.problem(attachments) { throw failure(problem) }
        let size = text.utf8.count + attachments.reduce(0) { $0 + $1.size }
        guard textBytes + size < 1_000_000 else { throw failure("This conversation reached its display limit. Start a new conversation.") }
        textBytes += size
        state.messages.append(ACPMessage(role: "You", text: text, attachments: attachments.isEmpty ? nil : attachments.map(\.title)))
        state.phase = "working"; state.status = "Working…"; turn = UUID()
        let blocks = ChatPromptComposer.acpBlocks(prompt: text, attachments: attachments,
                                                  embeddedContext: ChatPromptComposer.supportsEmbeddedContext(capabilities: state.capabilities))
        request("session/prompt", ["sessionId": id, "prompt": blocks])
    }
    func cancel() {
        guard ["working", "cancelling"].contains(state.phase), let id = state.sessionID else { return }
        state.phase = "cancelling"; state.status = "Cancelling…"
        cancelPermissions()
        send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": id]])
        let generation = epoch, currentTurn = turn
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.epoch == generation, self.turn == currentTurn, self.state.phase == "cancelling" else { return }
            self.stop("Agent did not finish cancellation; connection ended.", failed: true)
        }
    }
    func choose(request key: String, option: String) throws {
        guard state.phase == "working", let id = permissionIDs[key],
              let permission = state.permissions.first(where: { $0.id == key }),
              permission.options.contains(where: { $0.optionId == option }) else { throw failure("This permission request has expired.") }
        permissionIDs.removeValue(forKey: key); state.permissions.removeAll { $0.id == key }
        send(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "selected", "optionId": option]]])
        state.status = state.permissions.isEmpty ? "Working…" : "Needs your permission"
    }
    func stop(_ message: String = "Conversation ended.", failed: Bool = false) {
        cancelPermissions()
        epoch = UUID()
        output?.readabilityHandler = nil
        if let process = task, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        // Terminate before closing handles: a blocked writer may hold a FileHandle lock.
        try? input?.close(); input = nil
        try? output?.close(); output = nil
        task = nil; pending = [:]; buffer = Data(); resumeID = nil
        // Stop runs on process exit, every failure, acpStop and XPC invalidation, so the slot
        // returns on each of those paths.
        releaseSlot()
        state.phase = failed ? "failed" : "disconnected"; state.status = message; state.sessionID = nil
    }
    private func cancelPermissions() {
        let ids = Array(permissionIDs.values)
        permissionIDs = [:]; state.permissions = []
        for id in ids { send(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]]) }
    }
    private func request(_ method: String, _ params: [String: Any]) {
        nextID += 1; pending[nextID] = method
        send(["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
    }
    private func send(_ object: [String: Any]) {
        if let testSend { testSend(object); return }
        guard let input else { return }
        let generation = epoch
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(10)
        // A provider that stops reading stdin must never block cancellation or XPC snapshots.
        writer.async { [weak self] in
            do { try input.write(contentsOf: data) }
            catch { self?.queue.async { [weak self] in
                guard let self, self.epoch == generation else { return }
                self.stop("Couldn’t send to the agent. Reconnect to continue.", failed: true)
            } }
        }
    }

    func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
            if line.isEmpty { continue }
            guard line.count <= 2_000_000, let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
                stop("Agent returned invalid ACP data.", failed: true); return
            }
            handle(message)
            if state.phase == "failed" { return }
        }
        if buffer.count > 2_000_000 { stop("Agent response exceeded the ACP frame limit.", failed: true) }
    }
    private func handle(_ object: [String: Any]) {
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            if let id = object["id"] {
                if method == "session/request_permission", let sessionID = state.sessionID, params["sessionId"] as? String == sessionID, state.phase == "working" {
                    guard permissionIDs.count < 16, let options = params["options"], let bytes = try? JSONSerialization.data(withJSONObject: options),
                          bytes.count <= 8_000, let choices = try? JSONDecoder().decode([ACPPermission.Option].self, from: bytes), !choices.isEmpty,
                          choices.count <= 8, Set(choices.map(\.optionId)).count == choices.count else {
                        send(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]]); return
                    }
                    let incoming = params["toolCall"] as? [String: Any] ?? [:]
                    var tool = toolDetails[incoming["toolCallId"] as? String ?? ""] ?? [:]
                    tool.merge(incoming) { _, new in new }
                    let detail = (try? JSONSerialization.data(withJSONObject: tool, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    // Never approve an operation whose details were dropped by a display limit.
                    guard detail.utf8.count <= 64_000 else { send(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]]); return }
                    let key = UUID().uuidString
                    permissionIDs[key] = id
                    state.permissions.append(ACPPermission(id: key, title: tool["title"] as? String ?? "Agent requests permission", detail: detail, options: choices))
                    state.status = "Needs your permission"
                } else if method == "session/request_permission" {
                    send(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]])
                } else {
                    send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Volant does not support this client method."]])
                    state.status = "Unsupported agent request: " + method
                }
            } else if method == "session/update", let sessionID = state.sessionID, params["sessionId"] as? String == sessionID,
                      let update = params["update"] as? [String: Any] { updateSession(update) }
            return
        }
        guard let id = object["id"] as? Int, let method = pending.removeValue(forKey: id) else { return }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Agent request failed."
            if method == "session/prompt" { cancelPermissions(); state.phase = "ready"; state.status = message }
            else if method == "session/load" {
                stop("Couldn’t resume this conversation: " + message + " Start a new conversation.", failed: true)
                state.resumeRejected = true
            }
            else { stop(message + " Check the provider’s terminal login and retry.", failed: true) }
            return
        }
        let result = object["result"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            guard result["protocolVersion"] as? Int == 1 else { stop("Agent requires an unsupported ACP version.", failed: true); return }
            state.agentName = (result["agentInfo"] as? [String: Any])?["name"] as? String ?? "ACP agent"
            state.capabilities = ((try? JSONSerialization.data(withJSONObject: result["agentCapabilities"] ?? [:], options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }) ?? "{}"
            if let resumeID {
                // Never fall back to a new session: the owner asked for this one.
                guard ACPCapabilities.supportsLoadSession(state.capabilities) else {
                    stop("This agent can’t resume conversations. Start a new conversation.", failed: true)
                    state.resumeRejected = true; return
                }
                // The ID is set first so the replayed history routes to this conversation.
                state.sessionID = resumeID; state.status = "Restoring conversation…"
                request("session/load", ["sessionId": resumeID, "cwd": project, "mcpServers": []])
            } else {
                request("session/new", ["cwd": project, "mcpServers": []])
            }
        case "session/load":
            resumeID = nil
            state.phase = "ready"; state.status = replayTrimmed ? "Ready. Earlier history isn’t shown." : "Ready"
        case "session/new":
            guard let session = result["sessionId"] as? String, !session.isEmpty else { stop("Agent returned no conversation ID.", failed: true); return }
            state.sessionID = session; state.phase = "ready"; state.status = "Ready"
        case "session/prompt":
            cancelPermissions()
            let cancelled = state.phase == "cancelling"
            state.phase = "ready"; state.status = cancelled ? "Cancelled" : (result["stopReason"] as? String == "end_turn" ? "Ready" : "Stopped: " + (result["stopReason"] as? String ?? "unknown reason"))
        default: break
        }
    }
    private func updateSession(_ update: [String: Any]) {
        let kind = update["sessionUpdate"] as? String ?? ""
        // Volant shows the owner's own turns only from history replayed by session/load. During a
        // live turn the transcript already holds the prompt Volant sent, so user chunks are ignored.
        let replaying = resumeID != nil && state.phase == "starting"
        if kind == "agent_message_chunk" || (kind == "user_message_chunk" && replaying), let content = update["content"] as? [String: Any] {
            let role = kind == "agent_message_chunk" ? "Agent" : "You"
            let text = content["type"] as? String == "text" ? (content["text"] as? String ?? "") : "\n[Non-text " + (role == "Agent" ? "response" : "content") + " is not displayed in this version.]\n"
            textBytes += text.utf8.count
            guard textBytes < 1_000_000 else { stop("Conversation reached its display limit; connection ended.", failed: true); return }
            if state.messages.last?.role == role { state.messages[state.messages.count - 1].text += text }
            else { state.messages.append(ACPMessage(role: role, text: text)) }
        } else if kind == "tool_call" || kind == "tool_call_update" {
            if !replaying, let toolID = update["toolCallId"] as? String {
                let size = (try? JSONSerialization.data(withJSONObject: update).count) ?? 0
                detailBytes += size
                guard detailBytes < 2_000_000 else { stop("Conversation reached its tool-detail limit.", failed: true); return }
                var details = toolDetails[toolID] ?? [:]
                details.merge(update) { _, new in new }
                toolDetails[toolID] = details
            }
            if let title = update["title"] as? String {
                textBytes += title.utf8.count
                guard textBytes < 1_000_000 else { stop("Conversation reached its display limit.", failed: true); return }
            }
            let key = "tool:" + (update["toolCallId"] as? String ?? UUID().uuidString)
            let status = update["status"] as? String ?? "pending"
            if let index = state.messages.firstIndex(where: { $0.id == key }) {
                if let title = update["title"] as? String { state.messages[index].text = title }
                state.messages[index].role = "Tool · " + status
            } else {
                state.messages.append(ACPMessage(id: key, role: "Tool · " + status, text: update["title"] as? String ?? "Agent tool"))
            }
            if state.messages.count > 2_000 { stop("Conversation reached its event limit.", failed: true) }
        }
        if replaying { trimReplay() }
    }
    /// Keeps replayed history within its share of the conversation limits by dropping the oldest
    /// entries, so a long conversation can still resume and leave room for new turns. Replayed tool
    /// details are never stored: no approval is offered for them.
    private func trimReplay() {
        while state.messages.count > 1, textBytes > Self.replayTextLimit || state.messages.count > Self.replayEventLimit {
            textBytes = max(0, textBytes - state.messages.removeFirst().text.utf8.count)
            replayTrimmed = true
        }
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "VolantACP", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
