import XCTest
import VolantCore
@testable import Volant

/// Several conversations at once. Every model reads its own cleared defaults suite, never the
/// owner's, and starting one marks it ready instead of opening an XPC connection.
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
        let first = list.all[0]
        list.select(first)
        XCTAssertEqual(list.all.filter { !$0.background }.map(\.id), [first.id])
    }

    func testTheLauncherOpensAConversationAwaitingPermissionFirst() {
        let list = conversations()
        list.newConversation(configuration: claude)
        let first = list.current
        list.newConversation(configuration: claude)
        XCTAssertTrue(list.nextToOpen === list.current)
        first.state.permissions = [ACPPermission(id: "fictional", title: "Fictional tool", detail: "", options: [])]
        XCTAssertTrue(list.nextToOpen === first)
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
}
