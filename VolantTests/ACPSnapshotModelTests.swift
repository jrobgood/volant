import XCTest
import VolantCore
@testable import Volant

/// The app decodes a helper snapshot only when its revision is new, and any change it makes to
/// the conversation itself forces the next read to fetch the helper's full state.
final class ACPSnapshotModelTests: XCTestCase {
    private var suite: String!
    private var store: UserDefaults!

    override func setUp() {
        suite = "volant.tests.acp-snapshot." + UUID().uuidString
        store = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
    }

    private func encoded(_ state: ACPState) throws -> Data { try JSONEncoder().encode(state) }

    func testANewRevisionIsAppliedAndAnUnchangedOneIsSkipped() throws {
        let model = ACPModel(resumeStore: store)
        let snapshot = ACPState(phase: "ready", status: "Ready", sessionID: "fictional-session", messages: [ACPMessage(role: "Agent", text: "Hello")])
        XCTAssertEqual(model.receive(try encoded(snapshot), revision: 5, after: -1), .applied)
        XCTAssertEqual(model.state, snapshot)
        XCTAssertEqual(model.helperRevision, 5)
        XCTAssertEqual(model.receive(nil, revision: 5, after: 5), .unchanged)
        XCTAssertEqual(model.state, snapshot)
        var next = snapshot; next.messages[0].text += " world"
        XCTAssertEqual(model.receive(try encoded(next), revision: 6, after: 5), .applied)
        XCTAssertEqual(model.state.messages.last?.text, "Hello world")
        XCTAssertEqual(model.helperRevision, 6)
    }

    func testALocalChangeForgetsTheHelperRevision() throws {
        let model = ACPModel(resumeStore: store)
        XCTAssertEqual(model.receive(try encoded(ACPState(phase: "ready", sessionID: "fictional-session")), revision: 3, after: -1), .applied)
        model.state.phase = "working"
        XCTAssertEqual(model.helperRevision, -1)
        XCTAssertEqual(model.receive(try encoded(ACPState(phase: "ready", sessionID: "fictional-session")), revision: 3, after: -1), .applied)
        XCTAssertEqual(model.state.phase, "ready")
        model.disconnect()
        XCTAssertEqual(model.helperRevision, -1)
    }

    func testAnUnchangedReplyToAReadStartedBeforeALocalChangeIsStale() throws {
        let model = ACPModel(resumeStore: store)
        XCTAssertEqual(model.receive(try encoded(ACPState(phase: "ready", sessionID: "fictional-session")), revision: 3, after: -1), .applied)
        model.state.phase = "working"
        XCTAssertEqual(model.receive(nil, revision: 3, after: 3), .stale, "the app's own change must not be confirmed by an old revision")
        XCTAssertEqual(model.state.phase, "working")
    }

    func testRepliesWithoutAUsableSnapshotAreInvalid() throws {
        let model = ACPModel(resumeStore: store)
        XCTAssertEqual(model.receive(nil, revision: -1, after: -1), .invalid)
        XCTAssertEqual(model.receive(nil, revision: 4, after: 2), .invalid)
        XCTAssertEqual(model.receive(Data("not json".utf8), revision: 2, after: -1), .invalid)
        XCTAssertEqual(model.state, ACPState())
    }

    func testAppliedSnapshotsAreStillRememberedForResume() throws {
        let model = ACPModel(resumeStore: store)
        var config = AIConfiguration(); config.provider = "claude"
        model.configure(config)
        let used = ACPState(phase: "ready", sessionID: "used-session", messages: [ACPMessage(role: "You", text: "Fictional question")])
        XCTAssertEqual(model.receive(try encoded(used), revision: 9, after: -1), .applied)
        XCTAssertEqual(model.resumable?.sessionID, "used-session")
    }
}
