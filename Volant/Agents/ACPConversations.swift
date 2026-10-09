import Combine
import Foundation
import VolantCore

/// Conversations are told apart by object, so a button always acts on the conversation it was
/// drawn for, never on a position in a list.
extension ACPModel: Identifiable {}

/// The launcher's AI conversations. One is current and shown; the others keep running in
/// their own helper connections until the owner ends them.
final class ACPConversations: ObservableObject {
    /// Every conversation in creation order, including ended ones not yet dropped.
    @Published private(set) var all: [ACPModel] {
        didSet { watchPhases(); updateBackground() }
    }
    @Published private(set) var current: ACPModel {
        didSet { followCurrent(); updateBackground() }
    }
    private let make: () -> ACPModel
    private let start: (ACPModel) -> Void
    private var currentChanges: AnyCancellable?
    private var phaseChanges: AnyCancellable?

    /// `start` is injected so tests never open an XPC connection.
    init(make: @escaping () -> ACPModel = { ACPModel() }, start: @escaping (ACPModel) -> Void = { $0.start() }) {
        let first = make()
        self.make = make
        self.start = start
        all = [first]
        current = first
        adopt(first)
        followCurrent()
        watchPhases()
        updateBackground()
    }

    /// Conversations with a running session.
    var live: [ACPModel] { all.filter(\.active) }
    /// What the conversation buttons list: the live conversations, plus the current one after it
    /// ends, in the order they were started.
    var shown: [ACPModel] { all.filter { $0.active || $0 === current } }
    /// The app counts a conversation as ended as soon as End runs. The helper frees its slot when that
    /// connection's invalidation reaches it, unordered with a start on another connection, so a start
    /// sent within that delivery delay can still be refused at the limit.
    var canStartAnother: Bool { live.count < ACPConversationLimit.live }
    /// The conversation the launcher opens: the first that waits for a permission, else the current
    /// one while it runs, else the first that runs. Opening AI Chat on an ended conversation can start
    /// a new one in its place, so the row always opens a running one.
    var nextToOpen: ACPModel {
        live.first { !$0.state.permissions.isEmpty } ?? (current.active ? current : live.first ?? current)
    }

    /// Starts a conversation with `configuration` and shows it, leaving the others running. An unused
    /// current conversation is started in place. Returns false and starts nothing when the
    /// configuration is missing or incomplete, or when the live limit is reached; the limit is
    /// reported in the current conversation.
    @discardableResult func newConversation(configuration: AIConfiguration?) -> Bool {
        guard let configuration, configuration.isConfigured else { return false }
        guard canStartAnother else {
            current.error = "Volant runs up to \(ACPConversationLimit.live) conversations at once. End one to start another."
            return false
        }
        if !current.active, current.state.messages.isEmpty {
            current.configure(configuration)
            start(current)
            return true
        }
        let model = make()
        adopt(model)
        model.configure(configuration)
        all.append(model)
        current = model
        dropEnded()
        start(model)
        return true
    }

    func select(_ model: ACPModel) {
        guard all.contains(where: { $0 === model }) else { return }
        current = model
        dropEnded()
    }

    /// Drops every conversation that is neither live nor current; its transcript was in memory only.
    private func dropEnded() {
        let current = self.current
        all.removeAll { !$0.active && $0 !== current }
    }

    private func adopt(_ model: ACPModel) {
        model.sessionsElsewhere = { [weak self, weak model] in
            guard let self else { return [] }
            return self.live.filter { $0 !== model }.flatMap { other in [other.state.sessionID, other.resumedSession].compactMap { $0 } }
        }
        model.resumeRefused = { [weak self] session in
            self?.all.forEach { $0.forgetResume(of: session) }
        }
    }

    /// Views that observe this list redraw on every change inside the current conversation.
    private func followCurrent() {
        currentChanges = current.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// `live` and `shown` change when any conversation starts or ends, and so does whether the current
    /// one may resume, since Resume skips sessions the others hold. Phase changes of every
    /// conversation therefore reach the current conversation's observers, and through `followCurrent`
    /// this list's; transcript updates in the background do not.
    private func watchPhases() {
        let phases = all.map { $0.$state.map(\.phase).removeDuplicates().dropFirst() }
        phaseChanges = Publishers.MergeMany(phases).sink { [weak self] _ in self?.current.objectWillChange.send() }
    }

    /// Only the current conversation polls at the foreground interval.
    private func updateBackground() {
        for model in all { model.background = model !== current }
    }
}
