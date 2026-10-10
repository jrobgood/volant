import AppKit
import XCTest
@testable import Volant

final class NotesShortcutTests: XCTestCase {
    /// Builds a key-down event without a window, as the panel would receive it.
    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)!
    }

    func testMatchesEachShortcutWithExactModifiers() {
        XCTAssertEqual(NotesShortcut.matching(key("e", .command)), .togglePreview)
        XCTAssertEqual(NotesShortcut.matching(key("C", [.command, .shift])), .copyMarkdown)
        XCTAssertEqual(NotesShortcut.matching(key("d", .command)), .duplicate)
        XCTAssertEqual(NotesShortcut.matching(key("P", [.command, .shift])), .pin)
        XCTAssertEqual(NotesShortcut.matching(key("\u{7F}", .command, keyCode: 51)), .trash)
        XCTAssertEqual(NotesShortcut.matching(key("k", .command)), .actions)
        XCTAssertEqual(NotesShortcut.matching(key("p", .command)), .browse)
        XCTAssertEqual(NotesShortcut.matching(key("n", .command)), .newNote)
    }

    func testIgnoresOtherCombinations() {
        XCTAssertNil(NotesShortcut.matching(key("e", [.command, .option])))
        XCTAssertNil(NotesShortcut.matching(key("E", [.command, .shift])))
        XCTAssertNil(NotesShortcut.matching(key("c", .command)))
        XCTAssertNil(NotesShortcut.matching(key("j", .command)))
        XCTAssertNil(NotesShortcut.matching(key("e", [])))
        XCTAssertNil(NotesShortcut.matching(key("\u{7F}", [], keyCode: 51)))
        XCTAssertNil(NotesShortcut.matching(key("\u{7F}", [.command, .shift], keyCode: 51)))
    }

    func testOnlyCommandDeleteKeepsItsTextEditingMeaning() {
        XCTAssertEqual(NotesShortcut.allCases.filter(\.hasTextEditingMeaning), [.trash])
    }

    func testNoteCommandsAreUnavailableWithoutSelectionOrUnderOverlay() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("volant-shortcuts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesStore(directory: dir)
        let model = NotesModel(store: store)
        XCTAssertNil(model.selected)
        XCTAssertFalse(model.noteCommandsAvailable)
        for shortcut in NotesShortcut.allCases {
            XCTAssertEqual(model.isAvailable(shortcut), !shortcut.actsOnSelectedNote, "\(shortcut)")
        }
        model.newNote(text: "Fictional note")
        XCTAssertTrue(model.noteCommandsAvailable)
        XCTAssertTrue(NotesShortcut.allCases.allSatisfy(model.isAvailable))
        model.show(.actions)
        XCTAssertFalse(model.noteCommandsAvailable)
        XCTAssertFalse(model.isAvailable(.togglePreview))
        XCTAssertTrue(model.isAvailable(.browse))
        model.overlay = nil
        XCTAssertTrue(model.noteCommandsAvailable)
    }
}
