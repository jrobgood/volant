import XCTest
import CryptoKit
import VolantCore
@testable import Volant

final class LauncherEntryFormTests: XCTestCase {
    private var root: URL!
    private var model: LauncherModel!
    private var actions: [LauncherAction] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.json")
        try Data(#"{"future":1,"snippets":[{"name":"Existing","keyword":"exist","body":"Fixture"}],"quicklinks":[]}"#.utf8).write(to: config)
        model = LauncherModel(index: AppIndex(entries: []),
                              clipboard: ClipboardStore(retention: 2, storageURL: root.appendingPathComponent("clipboard.sqlite"), encryptionKey: SymmetricKey(size: .bits256)),
                              notes: NotesStore(directory: root.appendingPathComponent("Notes")),
                              config: try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: config)),
                              usage: UsageStore(url: root.appendingPathComponent("usage.sqlite"))) { [weak self] action in self?.actions.append(action) }
        model.searchesSecondarySources = false
        model.actionConfigURL = config
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Opens the form the way Return on the command row does.
    private func open(_ phrase: String) throws -> LauncherEntryDraft {
        model.query = phrase
        XCTAssertEqual(model.selectedRow?.id, phrase.contains("snippet") ? "core:newSnippet" : "core:newQuicklink")
        model.activateSelection()
        return try XCTUnwrap(model.entryForm)
    }

    func testSavingASnippetMakesItSearchableAndReloadsConfiguration() throws {
        let draft = try open("create snippet")
        draft.name = "Signature"
        draft.keyword = "fsig"
        draft.text = "Regards,\n{date}"
        XCTAssertTrue(model.saveEntry(draft))
        XCTAssertNil(model.entryForm)
        XCTAssertEqual(model.query, "fsig")
        XCTAssertEqual(model.selectedRow, .snippet(Snippet(name: "Signature", keyword: "fsig", body: "Regards,\n{date}")))
        XCTAssertEqual(model.actionFeedback, "Snippet saved.")
        XCTAssertTrue(actions.contains { if case .reloadConfig = $0 { return true }; return false })
    }

    func testSnippetWithoutKeywordIsFoundBySnip() throws {
        let draft = try open("new snippet")
        draft.name = "Address"
        draft.text = "1 Fixture Way"
        XCTAssertTrue(model.saveEntry(draft))
        XCTAssertEqual(model.query, "snip Address")
        XCTAssertEqual(model.selectedRow, .snippet(Snippet(name: "Address", keyword: "", body: "1 Fixture Way")))
    }

    func testStaleSnapshotKeepsTheDraftAndTheSecondSaveRevalidates() throws {
        let draft = try open("new quicklink")
        draft.name = "Docs"
        draft.text = "https://docs.example.com/?q={query}"
        try Data(#"{"future":1,"snippets":[],"quicklinks":[{"name":"Wiki","url":"https://wiki.example.com"}]}"#.utf8).write(to: model.actionConfigURL)
        XCTAssertFalse(model.saveEntry(draft))
        XCTAssertTrue(model.entryForm === draft)
        XCTAssertEqual(draft.name, "Docs")
        XCTAssertNotNil(draft.error)
        XCTAssertEqual(model.config.quicklinks.map(\.name), ["Wiki"])
        XCTAssertTrue(model.saveEntry(draft))
        XCTAssertEqual(model.config.quicklinks.map(\.name), ["Wiki", "Docs"])
        XCTAssertEqual(model.query, "Docs")
        XCTAssertEqual(model.selectedRow?.id, "ql:Docs:")
    }

    func testCancelAndQueryChangesCloseTheFormButUnchangedTextDoesNot() throws {
        let draft = try open("new snippet")
        model.searchText = "new snippet"
        XCTAssertTrue(model.entryForm === draft, "Unchanged search text must not reset an open form")
        model.cancelEntryForm()
        XCTAssertNil(model.entryForm)
        XCTAssertEqual(model.query, "new snippet")
        _ = try open("new snippet")
        model.query = "safari"
        XCTAssertNil(model.entryForm)
    }

    func testSnipListOffersCreateAndInvalidSaveWritesNothing() throws {
        model.query = "snip"
        XCTAssertEqual(model.rows.last, .core(.newSnippet))
        let before = try Data(contentsOf: model.actionConfigURL)
        let draft = try open("new snippet")
        draft.name = "Other"
        draft.keyword = "exist"
        draft.text = "x"
        XCTAssertFalse(model.saveEntry(draft))
        XCTAssertEqual(try Data(contentsOf: model.actionConfigURL), before)
    }
}
