import XCTest

@testable import VolantCore

final class PasteboardCaptureTests: XCTestCase {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01])

    func testTextOnlyRecordsText() {
        XCTAssertEqual(PasteboardCapture.entries(text: "Fictional note", image: { nil }), [.text("Fictional note")])
    }

    func testImageOnlyRecordsImage() {
        XCTAssertEqual(PasteboardCapture.entries(text: nil, image: { self.png }), [.image(png)])
    }

    func testTextAndImageRecordsBothWithImageNewest() {
        XCTAssertEqual(PasteboardCapture.entries(text: "Frame 12", image: { self.png }), [.text("Frame 12"), .image(png)])
    }

    func testOversizedTextStillRecordsImage() {
        let text = String(repeating: "x", count: PasteboardCapture.maxTextBytes + 1)
        XCTAssertEqual(PasteboardCapture.entries(text: text, image: { self.png }), [.image(png)])
    }

    func testOversizedTextWithoutImageRecordsNothing() {
        let text = String(repeating: "x", count: PasteboardCapture.maxTextBytes + 1)
        XCTAssertEqual(PasteboardCapture.entries(text: text, image: { nil }), [])
    }

    func testTextAtCapIsRecorded() {
        let text = String(repeating: "x", count: PasteboardCapture.maxTextBytes)
        XCTAssertEqual(PasteboardCapture.entries(text: text, image: { nil }), [.text(text)])
    }

    func testWhitespaceTextIsIgnoredButImageKept() {
        XCTAssertEqual(PasteboardCapture.entries(text: " \n\t", image: { self.png }), [.image(png)])
    }

    func testOversizedImageIsDroppedButTextKept() {
        let large = Data(count: PasteboardCapture.maxImageBytes + 1)
        XCTAssertEqual(PasteboardCapture.entries(text: "Frame 12", image: { large }), [.text("Frame 12")])
    }

    func testEmptyImageIsIgnored() {
        XCTAssertEqual(PasteboardCapture.entries(text: nil, image: { Data() }), [])
    }
}
