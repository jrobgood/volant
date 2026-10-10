import XCTest
@testable import Volant

/// A shortcut confirmation describes only the value it saved, and never lingers.
final class ShortcutFeedbackTests: XCTestCase {
    func testSaveAndRemoveShowTheirConfirmation() {
        var feedback = ShortcutFeedback()
        feedback.saved("option+r")
        XCTAssertEqual(feedback.message, "Saved")
        feedback.saved("")
        XCTAssertEqual(feedback.message, "Removed")
    }

    func testTheSavedValueArrivingKeepsTheConfirmation() {
        var feedback = ShortcutFeedback()
        feedback.saved("option+r")
        feedback.valueChanged(to: "option+r")
        XCTAssertEqual(feedback.message, "Saved")
    }

    func testAChangeMadeElsewhereClearsAStaleConfirmation() {
        var feedback = ShortcutFeedback()
        feedback.saved("")
        feedback.valueChanged(to: "option+u")
        XCTAssertNil(feedback.message)
    }

    func testExpiryClearsAndEachChangeRestartsTheTimer() {
        var feedback = ShortcutFeedback()
        let start = feedback.generation
        feedback.saved("option+r")
        XCTAssertNotEqual(feedback.generation, start)
        let saved = feedback.generation
        feedback.expire()
        XCTAssertNil(feedback.message)
        XCTAssertNotEqual(feedback.generation, saved)
    }
}
