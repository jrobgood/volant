import XCTest
@testable import VolantCore

/// The app's typing coordinator against a fake helper that answers when the test says so.
final class DictationTypingSessionTests: XCTestCase {
    final class FakeClient: InputHostClient {
        var begins: [(InputSessionStart?) -> Void] = []
        var inserts: [(phrase: String, token: Data, reply: (InputInsertion?) -> Void)] = []
        var ended: [Data] = []
        var disconnects = 0

        func status(prompt: Bool, completion: @escaping (InputHostStatus?) -> Void) {}
        func beginSession(completion: @escaping (InputSessionStart?) -> Void) { begins.append(completion) }
        func insert(phrase: String, token: Data, completion: @escaping (InputInsertion?) -> Void) {
            inserts.append((phrase, token, completion))
        }
        func endSession(token: Data) { ended.append(token) }
        func disconnect() { disconnects += 1 }

        /// Answers the oldest unanswered insertion.
        func answer(_ result: InputInsertion?) {
            let next = inserts.removeFirst()
            next.reply(result)
        }
    }

    private let token = Data([1, 2, 3])

    func testWhileSpeakingSendsFinalizedPhrasesInOrderOneAtATime() {
        let client = FakeClient()
        let session = DictationTypingSession(client: client, timing: .whileSpeaking)
        session.start()
        session.phraseFinalized("  Hello there.")
        XCTAssertTrue(client.inserts.isEmpty, "Nothing is sent before the session has a token")
        client.begins[0](InputSessionStart(token: token))
        XCTAssertEqual(client.inserts.map(\.phrase), ["Hello there."], "The first phrase starts at the cursor")
        session.phraseFinalized(" This is live.")
        XCTAssertEqual(client.inserts.count, 1, "One phrase in flight at a time")
        client.answer(.typed(12))
        XCTAssertEqual(client.inserts.map(\.phrase), [" This is live."])
        XCTAssertEqual(client.inserts.first?.token, token)
        var outcome: DictationTypingSession.Outcome?
        session.finish(transcript: "Hello there. This is live.") { outcome = $0 }
        XCTAssertNil(outcome, "Finishing waits for the phrase in flight")
        client.answer(.typed(14))
        XCTAssertEqual(outcome, .typed(26))
        XCTAssertEqual(outcome?.message, "Typed 26 characters.")
        XCTAssertEqual(client.ended, [token])
    }

    func testPasteFallbackIsReported() {
        let client = FakeClient()
        let session = DictationTypingSession(client: client, timing: .whileSpeaking)
        session.start()
        client.begins[0](InputSessionStart(token: token))
        session.phraseFinalized("One.")
        client.answer(.pasted(4))
        var outcome: DictationTypingSession.Outcome?
        session.finish(transcript: "One.") { outcome = $0 }
        XCTAssertEqual(outcome, .pasted(4))
        XCTAssertEqual(outcome?.message, "Pasted 4 characters.")
    }

    func testWhenFinishedSendsTheTranscriptOnce() {
        let client = FakeClient()
        let session = DictationTypingSession(client: client, timing: .whenFinished)
        session.start()
        client.begins[0](InputSessionStart(token: token))
        session.phraseFinalized("ignored while speaking")
        XCTAssertTrue(client.inserts.isEmpty)
        var outcome: DictationTypingSession.Outcome?
        session.finish(transcript: "  All of it at once. \n") { outcome = $0 }
        XCTAssertEqual(client.inserts.map(\.phrase), ["All of it at once."])
        client.answer(.typed(18))
        XCTAssertEqual(outcome, .typed(18))
    }

    func testRefusalStopsTypingAndAsksForACopy() {
        let client = FakeClient()
        let session = DictationTypingSession(client: client, timing: .whileSpeaking)
        session.start()
        client.begins[0](InputSessionStart(token: token))
        session.phraseFinalized("First.")
        session.phraseFinalized(" Second.")
        client.answer(.typed(6))
        client.answer(.refused(.secureField))
        XCTAssertEqual(client.ended, [token], "A refusal ends the helper session at once")
        session.phraseFinalized(" Third.")
        XCTAssertTrue(client.inserts.isEmpty, "Nothing more is typed after a refusal")
        var outcome: DictationTypingSession.Outcome?
        session.finish(transcript: "First. Second. Third.") { outcome = $0 }
        XCTAssertEqual(outcome, .copy(reason: .secureField, typedBefore: 6))
        XCTAssertEqual(outcome?.message, "Stopped after 6 characters and copied the transcript — typing isn’t allowed in password fields.")
        XCTAssertEqual(DictationTypingSession.Outcome.copy(reason: .secureField, typedBefore: 0).message,
                       "Copied — typing isn’t allowed in password fields.")
    }

    func testBeginRefusalOrUnavailableHelperCopies() {
        for (reply, reason) in [(InputSessionStart(refusal: .notTrusted), InputRefusal.notTrusted),
                                (InputSessionStart(refusal: .noTarget), .noTarget)] {
            let client = FakeClient()
            let session = DictationTypingSession(client: client, timing: .whenFinished)
            session.start()
            client.begins[0](reply)
            var outcome: DictationTypingSession.Outcome?
            session.finish(transcript: "Words.") { outcome = $0 }
            XCTAssertEqual(outcome, .copy(reason: reason, typedBefore: 0))
            XCTAssertTrue(client.inserts.isEmpty)
        }
        let client = FakeClient()
        let session = DictationTypingSession(client: client, timing: .whileSpeaking)
        session.start()
        session.phraseFinalized("Queued.")
        var outcome: DictationTypingSession.Outcome?
        session.finish(transcript: "Queued.") { outcome = $0 }
        XCTAssertNil(outcome, "Finishing waits for the helper to answer")
        client.begins[0](nil)
        XCTAssertEqual(outcome, .copy(reason: nil, typedBefore: 0))
        XCTAssertEqual(outcome?.message, "Copied — the input helper didn’t respond.")
    }

    func testFailedOrMissingReplyStopsTyping() {
        let client = FakeClient()
        let session = DictationTypingSession(client: client, timing: .whileSpeaking)
        session.start()
        client.begins[0](InputSessionStart(token: token))
        session.phraseFinalized("One.")
        client.answer(nil)
        var outcome: DictationTypingSession.Outcome?
        session.finish(transcript: "One.") { outcome = $0 }
        XCTAssertEqual(outcome, .copy(reason: nil, typedBefore: 0))
    }

    func testNothingHeard() {
        let client = FakeClient()
        let session = DictationTypingSession(client: client, timing: .whileSpeaking)
        session.start()
        client.begins[0](InputSessionStart(token: token))
        var outcome: DictationTypingSession.Outcome?
        session.finish(transcript: nil) { outcome = $0 }
        XCTAssertEqual(outcome, .nothing)
        XCTAssertEqual(client.ended, [token])
        let refused = FakeClient()
        let other = DictationTypingSession(client: refused, timing: .whenFinished)
        other.start()
        refused.begins[0](InputSessionStart(refusal: .notTrusted))
        var second: DictationTypingSession.Outcome?
        other.finish(transcript: "   ") { second = $0 }
        XCTAssertEqual(second, .nothing, "Nothing heard needs no copy, even when typing was refused")
    }

    func testCancelStopsWithoutCompletion() {
        let client = FakeClient()
        let session = DictationTypingSession(client: client, timing: .whileSpeaking)
        session.start()
        client.begins[0](InputSessionStart(token: token))
        session.phraseFinalized("One.")
        session.phraseFinalized(" Two.")
        session.cancel()
        XCTAssertEqual(client.ended, [token])
        client.answer(.typed(4))
        XCTAssertTrue(client.inserts.isEmpty, "Queued phrases are dropped and a late reply sends nothing")
        var called = false
        session.finish(transcript: "One. Two.") { _ in called = true }
        XCTAssertFalse(called)
        let early = FakeClient()
        let pending = DictationTypingSession(client: early, timing: .whileSpeaking)
        pending.start()
        pending.cancel()
        early.begins[0](InputSessionStart(token: token))
        XCTAssertEqual(early.ended, [token], "A late begin after Escape is ended at once")
        XCTAssertTrue(early.inserts.isEmpty, "and types nothing")
    }

    /// The launcher drops its reference when dictation finishes; answers still in flight must
    /// complete the dictation. Found by the VM run, where When finished never reported.
    func testCompletesAfterTheCallerLetsGo() {
        let client = FakeClient()
        var outcome: DictationTypingSession.Outcome?
        weak var released: DictationTypingSession?
        do {
            let session = DictationTypingSession(client: client, timing: .whenFinished)
            released = session
            session.start()
            session.finish(transcript: "Typed once at the end.") { outcome = $0 }
        }
        XCTAssertNotNil(released, "Pending replies keep the session alive")
        client.begins[0](InputSessionStart(token: token))
        client.answer(.typed(22))
        XCTAssertEqual(outcome, .typed(22))
        client.begins.removeAll()
        XCTAssertNil(released, "and release it once answered")
    }

    func testEveryRefusalHasWording() {
        for reason in InputRefusal.allCases {
            XCTAssertFalse(DictationTypingSession.Outcome.copy(reason: reason, typedBefore: 0).message.isEmpty)
        }
    }
}
