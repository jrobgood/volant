import XCTest

@testable import VolantCore

final class PasteboardFilterTests: XCTestCase {
    func testPlainTextIsRecorded() {
        XCTAssertTrue(PasteboardFilter.shouldRecord(types: ["public.utf8-plain-text"]))
    }

    func testConcealedIsNeverRecorded() {
        XCTAssertFalse(PasteboardFilter.shouldRecord(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertFalse(PasteboardFilter.shouldRecord(types: ["com.apple.is-sensitive", "public.utf8-plain-text"]))
        XCTAssertFalse(PasteboardFilter.shouldRecord(types: ["org.nspasteboard.TransientType"]))
    }

    /// The input helper's dictation pastes and clipboard restores carry their own marker too.
    func testDictationSessionMarkerIsNeverRecorded() {
        XCTAssertEqual(PasteboardFilter.dictationSessionType, "com.mysticcoders.volant.dictation-session")
        XCTAssertFalse(PasteboardFilter.shouldRecord(types: ["public.utf8-plain-text", PasteboardFilter.dictationSessionType]))
    }
}
