import XCTest

@testable import Volant

/// A manual clock for the indicator: scheduled work runs only when the test advances time.
private final class ManualScheduler {
    private var pending: [(id: Int, due: TimeInterval, work: () -> Void)] = []
    private var nextID = 0
    private(set) var now: TimeInterval = 0

    var count: Int { pending.count }

    /// Records work due after `delay` and returns a closure that removes it.
    func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        let id = nextID
        nextID += 1
        pending.append((id, now + delay, work))
        return { [weak self] in self?.pending.removeAll { $0.id == id } }
    }

    /// Moves the clock forward and runs everything that has come due.
    func advance(_ seconds: TimeInterval) {
        now += seconds
        let due = pending.filter { $0.due <= now }
        pending.removeAll { $0.due <= now }
        due.forEach { $0.work() }
    }
}

final class DictationIndicatorTests: XCTestCase {
    private var clock: ManualScheduler!
    private var model: DictationIndicatorModel!

    override func setUp() {
        clock = ManualScheduler()
        let clock = clock!
        model = DictationIndicatorModel(schedule: { clock.schedule($0, $1) })
    }

    func testListeningPartialTranscribingResultThenHidden() {
        model.listen(stopHint: "Release or press ⌥Space to stop")
        XCTAssertEqual(model.phase, .listening)
        XCTAssertEqual(model.stopHint, "Release or press ⌥Space to stop")
        model.heard("Hello")
        XCTAssertEqual(model.partial, "Hello")
        model.heard("Hello there")
        XCTAssertEqual(model.partial, "Hello there")
        model.transcribing()
        XCTAssertEqual(model.phase, .transcribing)
        model.heard("Hello there friend")
        XCTAssertEqual(model.partial, "Hello there friend", "Late recognition still updates while transcribing")
        XCTAssertEqual(clock.count, 0, "Nothing hides before a result")
        model.finish("Copied 18 characters — press ⌘V to paste.", outcome: .copied)
        XCTAssertEqual(model.phase, .result("Copied 18 characters — press ⌘V to paste.", .copied))
        XCTAssertTrue(model.partial.isEmpty, "Heard text is dropped once the result shows")
        clock.advance(1.9)
        XCTAssertTrue(model.isVisible, "The result stays up for about two seconds")
        clock.advance(0.2)
        XCTAssertEqual(model.phase, .hidden)
        XCTAssertFalse(model.isVisible)
    }

    func testCancelShowsCancelledThenHides() {
        model.listen(stopHint: "Press ⌥Space to stop")
        model.heard("discard me")
        model.finish("Dictation cancelled.", outcome: .cancelled)
        XCTAssertEqual(model.phase, .result("Dictation cancelled.", .cancelled))
        XCTAssertTrue(model.partial.isEmpty)
        clock.advance(DictationIndicatorModel.resultDuration)
        XCTAssertEqual(model.phase, .hidden)
    }

    func testFailureFromListeningShowsReason() {
        model.listen(stopHint: "Press ⌥Space to stop")
        model.finish("Dictation needs microphone access.", outcome: .failed)
        XCTAssertEqual(model.phase, .result("Dictation needs microphone access.", .failed))
        clock.advance(DictationIndicatorModel.resultDuration)
        XCTAssertEqual(model.phase, .hidden)
    }

    func testVolumeProblemShownWhileListeningAndAppendedToResult() {
        model.listen(stopHint: "Press ⌥Space to stop")
        model.note(volumeProblem: "Couldn’t restore Speakers.")
        XCTAssertEqual(model.volumeProblem, "Couldn’t restore Speakers.")
        XCTAssertEqual(model.phase, .listening, "A volume problem never interrupts dictation")
        model.transcribing()
        model.finish("Nothing was heard.", outcome: .nothing)
        XCTAssertEqual(model.phase, .result("Nothing was heard. Couldn’t restore Speakers.", .nothing))
        XCTAssertNil(model.volumeProblem)
        model.listen(stopHint: "Press ⌥Space to stop")
        model.finish("Dictation cancelled.", outcome: .cancelled)
        XCTAssertEqual(model.phase, .result("Dictation cancelled.", .cancelled), "A problem belongs to one dictation")
    }

    func testVolumeProblemAfterResultExtendsIt() {
        model.listen(stopHint: "Press ⌥Space to stop")
        model.finish("Copied 3 characters — press ⌘V to paste.", outcome: .copied)
        clock.advance(1.5)
        model.note(volumeProblem: "Couldn’t restore Speakers.")
        XCTAssertEqual(model.phase, .result("Copied 3 characters — press ⌘V to paste. Couldn’t restore Speakers.", .copied))
        model.note(volumeProblem: "Couldn’t restore Speakers.")
        XCTAssertEqual(clock.count, 1, "A repeated problem is not appended twice or scheduled twice")
        clock.advance(1.9)
        XCTAssertTrue(model.isVisible, "The extended result gets its own two seconds")
        clock.advance(0.2)
        XCTAssertEqual(model.phase, .hidden)
        model.note(volumeProblem: "Couldn’t restore Speakers.")
        XCTAssertEqual(model.phase, .result("Couldn’t restore Speakers.", .failed), "A late problem is still shown")
    }

    func testNewDictationCancelsPendingHide() {
        model.listen(stopHint: "Press ⌥Space to stop")
        model.finish("Nothing was heard.", outcome: .nothing)
        model.listen(stopHint: "Press ⌥Space to stop")
        XCTAssertEqual(clock.count, 0, "Starting again cancels the previous result's hide")
        clock.advance(5)
        XCTAssertEqual(model.phase, .listening, "A new dictation is never hidden by an old timer")
    }

    func testHeardIgnoredOutsideDictationAndTransitionsAreGuarded() {
        model.heard("stray")
        XCTAssertTrue(model.partial.isEmpty)
        model.transcribing()
        XCTAssertEqual(model.phase, .hidden, "Transcribing needs a listening indicator")
        model.listen(stopHint: "Press ⌥Space to stop")
        model.finish("Nothing was heard.", outcome: .nothing)
        model.heard("late")
        XCTAssertTrue(model.partial.isEmpty, "A result is not overwritten by late recognition")
        model.hide()
        XCTAssertEqual(model.phase, .hidden)
        XCTAssertEqual(clock.count, 0)
    }

    func testPartialIsBoundedToTheMostRecentText() {
        model.listen(stopHint: "Press ⌥Space to stop")
        let words = (1...60).map { "word\($0)" }.joined(separator: " ")
        model.heard(words)
        XCTAssertLessThanOrEqual(model.partial.count, DictationIndicatorModel.partialLimit)
        XCTAssertTrue(model.partial.hasPrefix("…"))
        XCTAssertTrue(model.partial.hasSuffix("word60"))
        XCTAssertFalse(model.partial.dropFirst().hasPrefix(" "))
        XCTAssertTrue(words.hasSuffix(model.partial.dropFirst()), "The tail starts on a word boundary")
        let unbroken = String(repeating: "a", count: 300)
        XCTAssertEqual(DictationIndicatorModel.tail(of: unbroken).count, DictationIndicatorModel.partialLimit)
        XCTAssertEqual(DictationIndicatorModel.tail(of: "  short  "), "short")
    }

    func testEscapeKeyRegisteredOnlyWhileListening() {
        var registered: [UInt32: () -> Void] = [:]
        var unregistered: [UInt32] = []
        var cancels = 0
        var next: UInt32 = 1
        let key = DictationEscapeKey(register: { combo, handler in
            XCTAssertEqual(combo, KeyCombo(keyCode: 53, carbonModifiers: 0), "Only unmodified Escape")
            defer { next += 1 }
            registered[next] = handler
            return next
        }, unregister: { id in
            unregistered.append(id)
            registered[id] = nil
        })
        XCTAssertTrue(key.update(listening: true) { cancels += 1 })
        XCTAssertTrue(key.update(listening: true) { cancels += 1 }, "Repeated listening keeps one registration")
        XCTAssertEqual(registered.count, 1)
        registered.values.first?()
        XCTAssertEqual(cancels, 1)
        XCTAssertFalse(key.update(listening: false) {})
        XCTAssertEqual(unregistered, [1])
        XCTAssertTrue(registered.isEmpty)
        XCTAssertFalse(key.update(listening: false) {})
        XCTAssertEqual(unregistered, [1], "Nothing to remove twice")
    }

    func testEscapeKeyUnavailableIsReported() {
        let key = DictationEscapeKey(register: { _, _ in nil }, unregister: { _ in XCTFail("Nothing was registered") })
        XCTAssertFalse(key.update(listening: true) {}, "A taken Escape is reported so the hint leaves it out")
        XCTAssertFalse(key.isRegistered)
        key.update(listening: false) {}
    }
}
