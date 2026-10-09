import Combine
import XCTest
import VolantCore
@testable import Volant

/// Several conversations at once. Models read fresh defaults suites, removed after each test and
/// never the owner's, and starting one marks it ready instead of opening an XPC connection.
final class ACPConversationsTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
    }

    private func isolatedStore() -> UserDefaults {
        let suite = "volant.tests.acp-conversations." + UUID().uuidString
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    /// Models share `store` when one is given, as the app's models share the standard defaults.
    private func conversations(sharing store: UserDefaults? = nil) -> ACPConversations {
        ACPConversations(make: { ACPModel(resumeStore: store ?? self.isolatedStore()) },
                         start: { $0.state.phase = "ready" })
    }

    private var claude: AIConfiguration {
        var config = AIConfiguration(); config.provider = "claude"
        return config
    }

    private func record(_ session: String, in store: UserDefaults) throws {
        store.set(try JSONEncoder().encode(ACPResumeRecord(provider: "claude", project: "", sessionID: session)), forKey: ACPModel.resumeKey)
    }

    func testNewKeepsTheRunningConversationAndShowsTheNewOne() {
        let list = conversations()
        XCTAssertFalse(list.newConversation(configuration: nil))
        XCTAssertFalse(list.newConversation(configuration: AIConfiguration()), "an incomplete configuration starts nothing")
        XCTAssertTrue(list.newConversation(configuration: claude))
        let first = list.current
        XCTAssertTrue(list.newConversation(configuration: claude))
        let second = list.current
        XCTAssertFalse(first === second)
        XCTAssertTrue(first.active, "the first conversation keeps running")
        XCTAssertTrue(second.active)
        XCTAssertEqual(second.provider, "claude")
        XCTAssertEqual(list.live.map(\.id), [first.id, second.id])
        XCTAssertEqual(list.shown.map(\.id), [first.id, second.id])
    }

    func testNewReusesAnUnusedCurrentConversation() {
        var starts = 0
        let list = ACPConversations(make: { ACPModel(resumeStore: self.isolatedStore()) },
                                    start: { model in starts += 1; model.state.phase = "ready" })
        let first = list.current
        XCTAssertTrue(list.newConversation(configuration: claude))
        XCTAssertTrue(list.current === first)
        XCTAssertEqual(list.all.count, 1)
        XCTAssertEqual(starts, 1)
        first.state.phase = "disconnected"
        first.state.messages = [ACPMessage(role: "You", text: "Fictional question")]
        XCTAssertTrue(list.newConversation(configuration: claude))
        XCTAssertFalse(list.current === first, "an ended conversation that holds a transcript is not reused")
        XCTAssertEqual(list.all.map(\.id), [list.current.id])
        XCTAssertEqual(starts, 2)
    }

    func testTheConversationPastTheLimitIsRefused() {
        let list = conversations()
        for _ in 0..<ACPConversationLimit.live { XCTAssertTrue(list.newConversation(configuration: claude)) }
        XCTAssertEqual(list.live.count, ACPConversationLimit.live)
        XCTAssertFalse(list.canStartAnother)
        let current = list.current
        XCTAssertFalse(list.newConversation(configuration: claude))
        XCTAssertEqual(list.all.count, ACPConversationLimit.live, "no conversation is added")
        XCTAssertTrue(list.current === current)
        XCTAssertTrue(current.error?.contains("\(ACPConversationLimit.live) conversations") == true, current.error ?? "no error")
        list.all[0].state.phase = "disconnected"
        XCTAssertTrue(list.canStartAnother)
    }

    func testSelectDropsEndedConversationsAndKeepsLiveOnes() {
        let list = conversations()
        list.newConversation(configuration: claude)
        let first = list.current
        list.newConversation(configuration: claude)
        let second = list.current
        list.newConversation(configuration: claude)
        let third = list.current
        second.state.phase = "failed"
        XCTAssertEqual(list.shown.map(\.id), [first.id, third.id])
        list.select(first)
        XCTAssertTrue(list.current === first)
        XCTAssertEqual(list.all.map(\.id), [first.id, third.id])
        first.state.phase = "disconnected"
        XCTAssertEqual(list.shown.map(\.id), [first.id, third.id], "the current conversation stays listed after it ends")
        list.select(third)
        XCTAssertEqual(list.all.map(\.id), [third.id])
    }

    func testOnlyTheCurrentConversationPollsInTheForeground() {
        let list = conversations()
        list.newConversation(configuration: claude)
        list.newConversation(configuration: claude)
        list.newConversation(configuration: claude)
        XCTAssertEqual(list.all.filter { !$0.background }.map(\.id), [list.current.id])
        XCTAssertEqual(list.all.map(\.pollInterval), [1, 1, 0.25])
        let first = list.all[0]
        list.select(first)
        XCTAssertEqual(list.all.filter { !$0.background }.map(\.id), [first.id])
        XCTAssertEqual(list.all.map(\.pollInterval), [0.25, 1, 1])
    }

    func testObserversSeeTheCurrentConversationAndEveryStartOrEnd() {
        let list = conversations()
        list.newConversation(configuration: claude)
        let first = list.current
        list.newConversation(configuration: claude)
        var changes = 0
        let watching = list.objectWillChange.sink { _ in changes += 1 }
        list.current.state.messages = [ACPMessage(role: "Agent", text: "Fictional reply")]
        XCTAssertGreaterThan(changes, 0, "a change inside the current conversation reaches the list's observers")
        changes = 0
        var shownChanges = 0
        let watchingShown = list.current.objectWillChange.sink { _ in shownChanges += 1 }
        first.state.messages = [ACPMessage(role: "Agent", text: "Fictional background reply")]
        XCTAssertEqual(changes, 0, "a transcript update in the background does not")
        XCTAssertEqual(shownChanges, 0)
        first.state.phase = "disconnected"
        XCTAssertGreaterThan(changes, 0, "a background conversation ending does")
        XCTAssertGreaterThan(shownChanges, 0, "and reaches the shown conversation, whose Resume depends on the others")
        watching.cancel()
        watchingShown.cancel()
    }

    func testTheLauncherOpensAConversationAwaitingPermissionFirst() {
        let list = conversations()
        list.newConversation(configuration: claude)
        let first = list.current
        list.newConversation(configuration: claude)
        XCTAssertTrue(list.nextToOpen === list.current)
        first.state.permissions = [ACPPermission(id: "fictional", title: "Fictional tool", detail: "", options: [])]
        XCTAssertTrue(list.nextToOpen === first)
        first.state.permissions = []
        list.current.state.phase = "disconnected"
        XCTAssertTrue(list.nextToOpen === first, "an ended current conversation is never the one opened")
    }

    func testARejectedResumeKeepsARecordAnotherConversationSaved() throws {
        let store = isolatedStore()
        try record("fictional-old", in: store)
        let list = conversations(sharing: store)
        let resuming = list.current
        resuming.configure(claude)
        XCTAssertTrue(resuming.canResume)
        // What resume() records before it connects.
        resuming.resumedSession = "fictional-old"
        resuming.state.phase = "starting"
        list.newConversation(configuration: claude)
        let other = list.current
        other.remember(ACPState(phase: "ready", sessionID: "fictional-new", messages: [ACPMessage(role: "You", text: "Fictional question")]))
        XCTAssertEqual(ACPModel(resumeStore: store).resumable?.sessionID, "fictional-new")
        var rejected = ACPState(phase: "failed"); rejected.resumeRejected = true
        resuming.remember(rejected)
        XCTAssertNil(resuming.resumable)
        XCTAssertEqual(ACPModel(resumeStore: store).resumable?.sessionID, "fictional-new", "another conversation's record survives")
    }

    func testASessionAnAgentRefusedIsNotOfferedByAnotherConversation() throws {
        let store = isolatedStore()
        try record("fictional-session", in: store)
        let list = conversations(sharing: store)
        let resuming = list.current
        resuming.configure(claude)
        resuming.resumedSession = "fictional-session"
        resuming.state.phase = "starting"
        list.newConversation(configuration: claude)
        let other = list.current
        XCTAssertEqual(other.resumable?.sessionID, "fictional-session", "a conversation made during the load reads the record")
        var rejected = ACPState(phase: "failed"); rejected.resumeRejected = true
        resuming.state = rejected
        resuming.remember(rejected)
        other.state.phase = "disconnected"
        XCTAssertNil(other.resumable)
        XCTAssertFalse(other.canResume, "the refused session is not offered again")
        XCTAssertNil(ACPModel(resumeStore: store).resumable)
    }

    func testResumeIsNotOfferedForASessionAnotherConversationHolds() throws {
        let store = isolatedStore()
        try record("fictional-session", in: store)
        let list = conversations(sharing: store)
        let holder = list.current
        list.newConversation(configuration: claude)
        holder.state.sessionID = "fictional-session"
        list.newConversation(configuration: claude)
        let ended = list.current
        ended.state.phase = "disconnected"
        XCTAssertFalse(ended.canResume, "the session is live in another conversation")
        holder.state.sessionID = nil
        holder.resumedSession = "fictional-session"
        holder.state.phase = "starting"
        XCTAssertFalse(ended.canResume, "or is being loaded by one")
        holder.state.phase = "failed"
        XCTAssertTrue(ended.canResume)
    }

    func testConversationsWithTheSameProviderAreToldApartByTheFirstQuestion() {
        let model = ACPModel(resumeStore: isolatedStore())
        XCTAssertNil(model.topic)
        model.state.messages = [ACPMessage(role: "Agent", text: "Fictional greeting"), ACPMessage(role: "You", text: "  ")]
        XCTAssertNil(model.topic, "a blank question names nothing")
        model.state.messages = [ACPMessage(role: "You", text: "Fix the fictional build"), ACPMessage(role: "You", text: "Then the tests")]
        XCTAssertEqual(model.topic, "Fix the fictional build")
        model.state.messages = [ACPMessage(role: "You", text: "\nSummarize the fictional release notes\nand list risks")]
        XCTAssertEqual(model.topic, "Summarize the fictional…", "the first line, cut to 24 characters")
    }

    func testNewNeedsTheBYOKKeyThatOpeningTheChatNeeds() {
        let model = ACPModel(resumeStore: isolatedStore())
        var config = AIConfiguration(); config.connection = .byok
        var stored: String?
        model.credentials = AICredentials(read: { _ in stored }, write: { _, _ in })
        XCTAssertFalse(model.keyReady(for: config), "no key")
        stored = ""
        XCTAssertFalse(model.keyReady(for: config), "an empty key")
        stored = "fictional-key"
        XCTAssertTrue(model.keyReady(for: config))
        model.credentials = AICredentials(read: { _ in throw AICredentials.CredentialError.unavailable }, write: { _, _ in })
        XCTAssertFalse(model.keyReady(for: config))
        XCTAssertNotNil(model.error, "a key that can't be read is reported")
        config.connection = .acp
        XCTAssertTrue(model.keyReady(for: config), "an ACP connection needs no key")
    }
}
