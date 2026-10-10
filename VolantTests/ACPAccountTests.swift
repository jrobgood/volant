import XCTest
import VolantCore
@testable import Volant

/// Conversations under an account folder, without a helper: what the model asks the helper for,
/// that a conversation keeps its account after it ends while its next start follows the setting,
/// that the provider shown and its account belong together, and that Resume is offered only under the
/// same account. Helper snapshots reach a conversation through
/// `handleRead`, each under a new revision. Records live in per-test defaults suites, never the
/// owner's.
final class ACPAccountTests: XCTestCase {
    private var suites: [String] = []
    private let work = ACPAccountProfile(id: "fictional-work", provider: "claude", label: "Work", directory: "/tmp/fictional-claude-work")
    private let personal = ACPAccountProfile(id: "fictional-personal", provider: "codex", label: "Personal", directory: "/tmp/fictional-codex-personal")

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
    }

    private func isolatedStore() -> UserDefaults {
        let suite = "volant.tests.acp-account." + UUID().uuidString
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    /// Claude Code under Work and Codex under Personal unless a test chooses otherwise.
    private func settings(provider: String = "claude", project: String = "", claude: String? = "fictional-work",
                          codex: String? = "fictional-personal") -> AIConfiguration {
        var config = AIConfiguration(); config.provider = provider; config.project = project
        config.profiles = [work, personal]
        config.chooseAccount(claude, for: "claude")
        config.chooseAccount(codex, for: "codex")
        return config
    }

    private func record(profile: String?, session: String = "fictional-session") -> ACPResumeRecord {
        ACPResumeRecord(provider: "claude", project: "", sessionID: session, profile: profile)
    }

    private func store(with record: ACPResumeRecord) throws -> UserDefaults {
        let store = isolatedStore()
        store.set(try JSONEncoder().encode(record), forKey: ACPModel.resumeKey)
        return store
    }

    /// Stands in for the helper's revision, which every change to its state advances.
    private var snapshotRevision = 0

    /// Hands `model` a snapshot as the helper's reply to a read does: encoded, with a new revision,
    /// through `handleRead`, the path every poll's reply takes, so the revision rules and the rules
    /// that follow a change of phase both run.
    private func deliver(_ state: ACPState, to model: ACPModel) {
        snapshotRevision += 1
        XCTAssertEqual(model.handleRead(try? JSONEncoder().encode(state), revision: snapshotRevision, after: model.helperRevision), .applied)
    }

    func testANewConversationAsksForTheChosenAccount() {
        let model = ACPModel(resumeStore: isolatedStore())
        var requests: [ACPModel.HelperStart] = []
        model.connector = { requests.append($0) }
        model.configure(settings())
        XCTAssertEqual(model.account, work)
        model.start()
        XCTAssertEqual(requests, [.start(project: "", profile: "/tmp/fictional-claude-work")])

        model.state.phase = "disconnected"
        model.configure(settings(project: "/tmp/fictional-project"))
        XCTAssertEqual(model.helperStart(resume: nil), .start(project: "/tmp/fictional-project", profile: "/tmp/fictional-claude-work"))

        model.configure(settings(provider: "codex"))
        XCTAssertEqual(model.helperStart(resume: nil), .start(project: "", profile: "/tmp/fictional-codex-personal"))
        model.configure(settings(claude: nil))
        XCTAssertEqual(model.helperStart(resume: nil), .start(project: "", profile: ""), "the default login sends no folder")

        let unstarted = ACPModel(resumeStore: isolatedStore())
        unstarted.configure(settings())
        XCTAssertEqual(unstarted.account, work, "before its first start a conversation shows the account it will use")
        unstarted.configure(settings(claude: nil))
        XCTAssertNil(unstarted.account)
        unstarted.configure(settings(provider: "gemini"))
        XCTAssertNil(unstarted.account, "a provider without an account variable runs under its default login")
        var api = settings(); api.connection = .byok
        unstarted.configure(api)
        XCTAssertNil(unstarted.account)
    }

    /// Conversations that ask a recording connector, so `apply`, which settings changes go through,
    /// and the header's New, Connect and Resume reach no helper.
    private func recordingList(store: @escaping () -> UserDefaults, into requests: @escaping (ACPModel.HelperStart) -> Void) -> ACPConversations {
        ACPConversations(make: {
            let model = ACPModel(resumeStore: store())
            model.connector = requests
            return model
        })
    }

    func testAConversationKeepsItsAccountForItsWholeLife() {
        var requests: [ACPModel.HelperStart] = []
        let list = recordingList(store: { [unowned self] in self.isolatedStore() }, into: { requests.append($0) })
        XCTAssertTrue(list.newConversation(configuration: settings()))
        let model = list.current
        list.apply(settings(claude: nil))
        XCTAssertEqual(model.account, work, "a changed choice leaves a running conversation its account")
        var removed = settings(); removed.removeProfile(id: "fictional-work")
        list.apply(removed)
        XCTAssertEqual(model.account?.label, "Work", "so does a removed account")

        deliver(ACPState(phase: "failed", status: "Fictional failure."), to: model)
        XCTAssertEqual(model.account, work, "an ended conversation keeps the account it ran under")
        model.start()
        XCTAssertEqual(requests, [.start(project: "", profile: "/tmp/fictional-claude-work"), .start(project: "", profile: "")],
                       "the next start uses the choice made while it ran, with no settings applied after it ended")
        XCTAssertNil(model.account, "the new conversation shows its own account")
    }

    func testEveryConversationsNextStartFollowsTheChoice() throws {
        var requests: [ACPModel.HelperStart] = []
        let underWork = try store(with: record(profile: "/tmp/fictional-claude-work"))
        let list = recordingList(store: { underWork }, into: { requests.append($0) })
        XCTAssertTrue(list.newConversation(configuration: settings()))
        let ended = list.current
        XCTAssertTrue(list.newConversation(configuration: settings()))
        let running = list.current
        ended.disconnect()
        XCTAssertTrue(ended.canResume)

        var removed = settings(provider: "codex"); removed.removeProfile(id: "fictional-work")
        list.apply(removed)
        XCTAssertEqual([running.provider, ended.provider], ["claude", "claude"], "a running conversation and one not shown keep their provider")
        XCTAssertEqual([running.account, ended.account], [work, work], "each shows the account it ran under")
        XCTAssertFalse(ended.canResume, "a removed account's session is not resumed")
        ended.start()
        running.disconnect()
        XCTAssertFalse(running.canResume)
        running.start()
        XCTAssertEqual(Array(requests.suffix(2)), [.start(project: "", profile: ""), .start(project: "", profile: "")],
                       "each next start uses the choice for its own provider, here the default login")
    }

    func testAnEndedConversationShowsItsProviderWithThatProvidersAccount() {
        let list = recordingList(store: { [unowned self] in self.isolatedStore() }, into: { _ in })
        XCTAssertTrue(list.newConversation(configuration: settings()))
        let model = list.current
        deliver(ACPState(phase: "failed", status: "Fictional failure."), to: model)
        list.apply(settings(claude: nil))
        XCTAssertEqual(model.account, work, "the same provider keeps the account it ran under")
        list.apply(settings(provider: "codex"))
        XCTAssertEqual(model.providerTitle, "Codex")
        XCTAssertEqual(model.account, personal, "another provider brings its own account")
        list.apply(settings(provider: "codex", codex: nil))
        XCTAssertNil(model.account, "and follows the choice for it")
        list.apply(settings(claude: nil))
        XCTAssertEqual(model.account, work, "back on the provider it ran under, it shows the account that produced its transcript")
        var api = settings(); api.connection = .byok
        list.apply(api)
        XCTAssertNil(model.account, "an API connection runs under no account")
        list.apply(settings())
        XCTAssertEqual(model.account, work)
    }

    func testAConversationNotShownFollowsTheChoiceForItsProvider() {
        let list = recordingList(store: { [unowned self] in self.isolatedStore() }, into: { _ in })
        XCTAssertTrue(list.newConversation(configuration: settings()))
        let model = list.current
        let turn = [ACPMessage(role: "You", text: "Fictional question")]
        deliver(ACPState(phase: "working", messages: turn), to: model)
        deliver(ACPState(phase: "ready", messages: turn), to: model)
        deliver(ACPState(phase: "failed", status: "Fictional failure.", messages: turn), to: model)
        list.apply(settings(provider: "codex"))
        XCTAssertEqual(model.account, personal)
        XCTAssertTrue(list.newConversation(configuration: settings()))
        let running = list.current
        XCTAssertFalse(model === running)
        XCTAssertTrue(list.newConversation(configuration: settings(provider: "codex")))
        XCTAssertFalse(running === list.current)
        XCTAssertTrue(list.all.contains { $0 === running }, "a running conversation not shown stays listed, so settings reach it")
        list.apply(settings(claude: nil))
        XCTAssertEqual(running.account, work, "it keeps the account it runs under")
        XCTAssertEqual(running.profile, "", "and its next start uses the choice now made")
    }

    func testEachConversationShowsTheAccountItStartedWith() {
        let list = ACPConversations(make: { [unowned self] in ACPModel(resumeStore: self.isolatedStore()) },
                                    start: { [unowned self] in self.deliver(ACPState(phase: "starting", status: "Connecting…"), to: $0) })
        XCTAssertTrue(list.newConversation(configuration: settings()))
        let first = list.current
        XCTAssertTrue(list.newConversation(configuration: settings(claude: nil)))
        XCTAssertFalse(first === list.current)
        XCTAssertEqual(first.account, work)
        XCTAssertNil(list.current.account)
    }

    func testResumeIsOfferedOnlyUnderTheAccountTheConversationRanUnder() throws {
        let underWork = try store(with: record(profile: "/tmp/fictional-claude-work"))
        let model = ACPModel(resumeStore: underWork)
        model.configure(settings())
        XCTAssertTrue(model.canResume)
        var requests: [ACPModel.HelperStart] = []
        model.connector = { requests.append($0) }
        model.resume()
        XCTAssertEqual(requests, [.resume(folder: "", profile: "/tmp/fictional-claude-work", session: "fictional-session")])

        let other = ACPModel(resumeStore: underWork)
        other.configure(settings(claude: nil))
        XCTAssertFalse(other.canResume, "the default login is not offered a session another login started")
        var elsewhere = settings()
        let third = ACPAccountProfile(id: "fictional-third", provider: "claude", label: "Other", directory: "/tmp/fictional-claude-other")
        try elsewhere.addProfile(third)
        elsewhere.chooseAccount("fictional-third", for: "claude")
        other.configure(elsewhere)
        XCTAssertFalse(other.canResume)

        let older = ACPModel(resumeStore: try store(with: record(profile: nil)))
        older.configure(settings(claude: nil))
        XCTAssertTrue(older.canResume, "a record saved before accounts existed belongs to the default login")
        older.configure(settings())
        XCTAssertFalse(older.canResume)
    }

    func testResumeKeepsTheOtherRulesUnderAnAccount() throws {
        let model = ACPModel(resumeStore: try store(with: record(profile: "/tmp/fictional-claude-work")))
        model.configure(settings())
        model.sessionsElsewhere = { ["fictional-session"] }
        XCTAssertFalse(model.canResume, "a session another live conversation holds is never loaded twice")
        model.sessionsElsewhere = { [] }
        XCTAssertEqual(model.helperStart(resume: model.resumable),
                       .resume(folder: "", profile: "/tmp/fictional-claude-work", session: "fictional-session"))
    }

    func testRememberRecordsTheAccount() {
        let store = isolatedStore()
        let model = ACPModel(resumeStore: store)
        model.configure(settings())
        model.remember(ACPState(phase: "ready", sessionID: "used-session", messages: [ACPMessage(role: "You", text: "Fictional question")]))
        XCTAssertEqual(ACPModel(resumeStore: store).resumable?.profile, "/tmp/fictional-claude-work")
        let later = ACPModel(resumeStore: store)
        later.configure(settings())
        XCTAssertTrue(later.canResume)

        let plain = ACPModel(resumeStore: store)
        plain.configure(settings(claude: nil))
        plain.remember(ACPState(phase: "ready", sessionID: "plain-session", messages: [ACPMessage(role: "You", text: "Fictional question")]))
        XCTAssertNil(ACPModel(resumeStore: store).resumable?.profile, "the default login records no folder")
    }

    func testARecordKeepsTheAccountItsSessionRanUnder() {
        let store = isolatedStore()
        let list = recordingList(store: { store }, into: { _ in })
        XCTAssertTrue(list.newConversation(configuration: settings()))
        let model = list.current
        list.apply(settings(claude: nil))
        deliver(ACPState(phase: "ready", sessionID: "fictional-session", messages: [ACPMessage(role: "You", text: "Fictional question")]), to: model)
        XCTAssertEqual(ACPModel(resumeStore: store).resumable?.profile, "/tmp/fictional-claude-work",
                       "a session that started under Work is recorded under Work after the choice changed")
        let later = ACPModel(resumeStore: store)
        later.configure(settings(claude: nil))
        XCTAssertFalse(later.canResume, "the default login is not offered it")
        later.configure(settings())
        XCTAssertTrue(later.canResume)
    }

    func testAnAPIConversationTakesNoAccountFromTheSettings() {
        let api = ACPModel(resumeStore: isolatedStore())
        var byok = settings(); byok.connection = .byok
        api.configure(byok)
        api.credentials = AICredentials(read: { _ in nil }, write: { _, _ in })
        let turn = [ACPMessage(role: "You", text: "Fictional question")]
        deliver(ACPState(phase: "working", messages: turn), to: api)
        deliver(ACPState(phase: "ready", messages: turn), to: api)
        deliver(ACPState(phase: "failed", status: "Fictional API failure.", messages: turn), to: api)
        api.followAccountChoice(settings())
        XCTAssertEqual(api.profile, "", "an API conversation's next start asks for no account folder")
        api.start()
        XCTAssertTrue(api.usesAPI)
        XCTAssertNil(api.account, "and runs under no account")
    }
}
