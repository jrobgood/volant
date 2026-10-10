import AppKit
import Combine
import VolantCore

/// UI-owned ACP conversation. Transcript stays in memory; the provider owns its own session storage.
final class ACPModel: ObservableObject {
    @Published var provider = "opencode"
    @Published var project = ""
    @Published var draft = ""
    /// Owner-chosen context for the next prompt. Kept in memory with the draft, cleared once sent.
    @Published private(set) var attachments: [ChatAttachment] = []
    /// Any change made here, rather than by a helper snapshot, forgets the helper's revision so
    /// the next read replaces it with the helper's full state.
    @Published var state = ACPState() { didSet { helperRevision = -1 } }
    /// The ACP helper revision `state` was last decoded from; -1 when none is current.
    private(set) var helperRevision = -1
    @Published var error: String?
    @Published var submitting = false
    /// The last ACP conversation, kept on this Mac only so it can be resumed by its own ID.
    @Published private(set) var resumable: ACPResumeRecord?
    private let resumeStore: UserDefaults
    static let resumeKey = "acp.lastConversation"

    init(resumeStore: UserDefaults = .standard) {
        self.resumeStore = resumeStore
        if let data = resumeStore.data(forKey: Self.resumeKey),
           let record = try? JSONDecoder().decode(ACPResumeRecord.self, from: data), record.isValid { resumable = record }
    }
    private var configuration = AIConfiguration()
    var credentials = AICredentials.keychain
    /// Apple's model runs in this process, so it uses neither helper.
    var usesApple: Bool { configuration.connection == .apple }
    var usesAPI: Bool { configuration.connection.usesHTTP }
    private var apple: AppleFoundationModel.Conversation?
    var providerTitle: String {
        if usesApple { return AIConnectionKind.apple.title }
        return usesAPI ? configuration.http.model : (ACPProvider(rawValue: provider)?.title ?? provider)
    }
    var configured: Bool {
        if usesApple { return AppleFoundationModel.availability.isReady }
        return usesAPI ? configuration.isConfigured : ACPProvider(rawValue: provider) != nil
    }

    func configure(_ value: AIConfiguration) {
        guard !active else { return }
        configuration = value
        provider = value.provider; project = value.connection == .acp ? value.project : ""
    }
    /// Reopening an active chat must never replace its session or draft. A conversation that can be
    /// resumed is offered instead of connecting, so opening the chat never replaces its record.
    @discardableResult func openChat(configuration: AIConfiguration?, connect: () -> Void) -> Bool {
        if active { return true }
        guard let configuration, configuration.isConfigured else { return false }
        if configuration.connection == .byok {
            do { guard let key = try credentials.read(configuration.http.credentialID), !key.isEmpty else { return false } }
            catch { self.error = "Couldn’t read your API key. Open AI Settings to check it."; return false }
        }
        configure(configuration)
        if !canResume { connect() }
        return true
    }
    private var connection: NSXPCConnection?
    private var timer: Timer?
    private var generation = UUID()
    private var reading = false
    private var revision = 0
    var active: Bool { !["failed", "disconnected"].contains(state.phase) }
    /// Resume is offered only for the provider and project currently chosen, so it can never
    /// reopen a conversation in a folder the owner has since moved away from.
    var canResume: Bool {
        !active && !usesAPI && !usesApple && resumable?.matches(provider: provider, project: project) == true
    }
    var canSend: Bool { state.phase == "ready" && !submitting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func start() { connect(resume: nil) }

    func resume() {
        guard canResume, let record = resumable else { return }
        connect(resume: record.sessionID)
    }

    private func connect(resume session: String?) {
        disconnect()
        if usesApple { startApple(); return }
        if usesAPI { startAPI(); return }
        let current = generation
        state = ACPState(); state.phase = "starting"; state.status = session == nil ? "Connecting…" : "Restoring conversation…"; error = nil
        let connection = NSXPCConnection(serviceName: "com.mysticcoders.volant.AgentHost")
        connection.remoteObjectInterface = NSXPCInterface(with: VolantAgentHostProtocol.self)
        connection.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.failed("Agent helper disconnected. Start a new conversation to reconnect.", current: current) } }
        connection.interruptionHandler = connection.invalidationHandler
        self.connection = connection; connection.resume()
        let started: (String?) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                if let error { self.failed(error, current: current); return }
                self.read()
                self.timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.read() }
            }
        }
        if let session { proxy()?.acpResume(provider: provider, project: project, session: session, reply: started) }
        else { proxy()?.acpStart(provider: provider, project: project, reply: started) }
    }
    /// Records a conversation once it is ready and holds an owner turn, so a session opened and left
    /// unused never replaces the record. A launch failure keeps the record, since the cause may be an
    /// expired provider login with the conversation still intact; an agent that refuses to load it
    /// clears it.
    func remember(_ snapshot: ACPState) {
        if snapshot.resumeRejected == true {
            resumeStore.removeObject(forKey: Self.resumeKey); resumable = nil; return
        }
        guard !usesAPI, !usesApple, snapshot.phase == "ready", let session = snapshot.sessionID,
              snapshot.messages.contains(where: { $0.role == "You" }) else { return }
        let record = ACPResumeRecord(provider: provider, project: project, sessionID: session)
        guard record.isValid, resumable?.sessionID != session || resumable?.matches(provider: provider, project: project) != true,
              let data = try? JSONEncoder().encode(record) else { return }
        resumeStore.set(data, forKey: Self.resumeKey)
        resumable = record
    }
    /// Adds a snapshot unless it is already attached; refuses one that would break the limits
    /// for this connection, leaving the draft and existing attachments unchanged.
    @discardableResult func attach(_ attachment: ChatAttachment) -> Bool {
        guard !attachments.contains(where: { $0.id == attachment.id }) else { return true }
        if let problem = ChatAttachmentLimits.problem(attachments + [attachment], apple: usesApple) {
            error = problem
            return false
        }
        attachments.append(attachment)
        error = nil
        return true
    }

    func detach(_ id: String) { attachments.removeAll { $0.id == id } }

    func send() {
        guard canSend else { return }
        let text = draft, sent = attachments, current = generation
        revision += 1
        submitting = true; error = nil
        let reply: (String?) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                self.submitting = false
                if let error { self.error = error }
                else {
                    if self.draft == text { self.draft = "" }
                    if self.attachments == sent { self.attachments = [] }
                    // Keep Send disabled until a subsequent snapshot shows the completed turn.
                    self.state.phase = "working"
                }
                if self.usesAPI { self.startAPIPolling() }
                self.read()
            }
        }
        if let problem = ChatAttachmentLimits.problem(sent, apple: usesApple) { submitting = false; error = problem; return }
        // Without attachments the original text-only path is used unchanged.
        guard !sent.isEmpty, let data = try? JSONEncoder().encode(sent) else {
            if usesApple { promptApple(text, reply: reply) }
            else if usesAPI { apiProxy()?.prompt(text: text, reply: reply) }
            else { proxy()?.acpPrompt(text: text, reply: reply) }
            return
        }
        if usesApple { promptApple(text, attachments: sent, reply: reply) }
        else if usesAPI { apiProxy()?.promptWithContext(text: text, attachments: data, reply: reply) }
        else { proxy()?.acpPromptWithContext(text: text, attachments: data, reply: reply) }
    }
    func cancel() {
        let current = generation
        revision += 1
        state.phase = "cancelling"
        let reply: (String?) -> Void = { [weak self] error in DispatchQueue.main.async {
            guard let self, self.generation == current else { return }
            self.error = error; self.read()
        } }
        if usesApple { apple?.cancel(); state.phase = "ready"; state.status = "Ready."; submitting = false }
        else if usesAPI { apiProxy()?.cancel { reply(nil) } }
        else { proxy()?.acpCancel(reply: reply) }
    }
    func choose(_ permission: ACPPermission, _ option: ACPPermission.Option) {
        let current = generation
        revision += 1
        proxy()?.acpPermission(request: permission.id, option: option.optionId) { [weak self] error in DispatchQueue.main.async {
            guard let self, self.generation == current else { return }
            self.error = error; self.read()
        } }
    }
    func disconnect() {
        generation = UUID(); timer?.invalidate(); timer = nil; reading = false; submitting = false
        apple?.cancel(); apple = nil
        // Invalidation stops the provider even if it is waiting on a permission request.
        connection?.invalidate(); connection = nil
        state.phase = "disconnected"; state.status = "Conversation ended."; state.permissions = []; state.sessionID = nil
    }
    deinit { timer?.invalidate(); connection?.invalidate() }
    private func proxy() -> VolantAgentHostProtocol? {
        let current = generation
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            DispatchQueue.main.async { self?.failed(error.localizedDescription, current: current) }
        } as? VolantAgentHostProtocol
    }
    private func read() {
        guard !reading, connection != nil else { return }
        reading = true
        let current = generation, currentRevision = revision, known = usesAPI ? -1 : helperRevision
        let reply: (Data?, Int, String?) -> Void = { [weak self] data, snapshotRevision, error in DispatchQueue.main.async {
            guard let self, self.generation == current else { return }
            self.reading = false
            guard self.revision == currentRevision else { self.read(); return }
            switch self.receive(data, revision: snapshotRevision, after: known) {
            case .unchanged: return
            case .stale: self.read(); return
            case .invalid: self.failed(error ?? "Invalid conversation state from helper.", current: current); return
            case .applied: break
            }
            if self.state.phase == "failed" || (self.usesAPI && self.state.phase == "ready") { self.timer?.invalidate(); self.timer = nil }
        } }
        if usesAPI { apiProxy()?.read { reply($0, -1, $1) } }
        else { proxy()?.acpRead(after: known, reply: reply) }
    }
    enum SnapshotResult { case applied, unchanged, stale, invalid }
    /// Applies one helper reply to a read that asked for changes after `known`. A reply without
    /// data confirms `known` is current, so nothing is decoded; if the app changed `state` while
    /// that read was in flight, the reply is stale and the next read fetches the full state.
    /// Otherwise the snapshot replaces `state` only when it differs, and its revision is kept.
    func receive(_ data: Data?, revision: Int, after known: Int) -> SnapshotResult {
        if data == nil, revision >= 0, revision == known { return helperRevision == known ? .unchanged : .stale }
        guard let data, let snapshot = try? JSONDecoder().decode(ACPState.self, from: data) else { return .invalid }
        if snapshot != state { state = snapshot }
        helperRevision = revision
        remember(snapshot)
        return .applied
    }
    private func startAPI() {
        let current = generation
        do {
            let config = configuration.http
            try config.validate()
            let key = try credentials.read(config.credentialID) ?? ""
            if !config.local && key.isEmpty { throw AIHTTPError.key }
            state = ACPState(); state.phase = "starting"; state.status = "Connecting…"; error = nil
            let connection = NSXPCConnection(serviceName: "com.mysticcoders.volant.AIHost")
            connection.remoteObjectInterface = NSXPCInterface(with: VolantAIHostProtocol.self)
            connection.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.failed("AI connection ended. Connect again to start a new conversation.", current: current) } }
            connection.interruptionHandler = connection.invalidationHandler
            self.connection = connection; connection.resume()
            apiProxy()?.start(configuration: try JSONEncoder().encode(config), key: key) { [weak self] error in DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                if let error { self.failed(error, current: current); return }
                self.read()
                self.startAPIPolling()
            } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.generation == current, self.state.phase == "starting" else { return }
                self.failed("AI helper did not become ready. Try connecting again.", current: current)
            }
        } catch { failed((error as? LocalizedError)?.errorDescription ?? "Couldn’t open AI connection.", current: current) }
    }
    /// Apple Intelligence runs in this process: no helper, no polling, no network. Availability is
    /// rechecked at connect time because the owner can switch it off in System Settings.
    private func startApple() {
        let availability = AppleFoundationModel.availability
        guard availability.isReady else {
            failed(availability.reason ?? "Apple Intelligence is unavailable.", current: generation)
            return
        }
        apple = AppleFoundationModel.Conversation()
        state = ACPState()
        state.phase = "ready"
        state.status = "Ready."
        state.agentName = AIConnectionKind.apple.title
        error = nil
    }

    private func promptApple(_ text: String, attachments: [ChatAttachment] = [], reply: @escaping (String?) -> Void) {
        let current = generation
        state.messages.append(ACPMessage(role: "You", text: text, attachments: attachments.isEmpty ? nil : attachments.map(\.title)))
        // The reply slot is created now and replaced as snapshots arrive, because FoundationModels
        // streams the whole text so far rather than deltas.
        let index = state.messages.count
        state.messages.append(ACPMessage(role: "Assistant", text: ""))
        reply(nil)
        apple?.send(ChatPromptComposer.inline(prompt: text, attachments: attachments), snapshot: { [weak self] snapshot in
            guard let self, self.generation == current, self.state.messages.indices.contains(index) else { return }
            self.state.messages[index] = ACPMessage(id: self.state.messages[index].id, role: "Assistant", text: snapshot)
        }, finished: { [weak self] failure in
            guard let self, self.generation == current else { return }
            self.submitting = false
            self.state.phase = "ready"
            self.state.status = failure ?? "Ready."
            if let failure { self.error = failure }
        })
    }

    private func startAPIPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.read() }
    }
    private func apiProxy() -> VolantAIHostProtocol? {
        let current = generation
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in DispatchQueue.main.async {
            self?.failed("AI helper disconnected. Connect again to start a new conversation.", current: current)
        } } as? VolantAIHostProtocol
    }
    private func failed(_ message: String, current: UUID) {
        guard generation == current else { return }
        disconnect(); state.phase = "failed"; error = message; state.status = message
    }
}
