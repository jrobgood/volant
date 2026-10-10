import VolantCore
import XCTest
import AppKit
import CryptoKit
@testable import Volant

/// Delivers file results on demand so tests control when a search answers.
private final class ManualFileSearch: FileSearch {
    private(set) var searches: [String] = []
    private var completions: [(String, (SearchResult) -> Void)] = []

    init() { super.init(startQuery: { _ in false }) }

    override func search(_ term: String, completion: @escaping (SearchResult) -> Void) {
        searches.append(term)
        completions.append((term, completion))
    }

    override func cancel() {}

    func complete(_ term: String, names: [String]) {
        guard let index = completions.lastIndex(where: { $0.0 == term }) else { return XCTFail("No search for \(term)") }
        let entries = names.map { FileEntry(id: "/Users/fixture/" + $0, name: $0, url: URL(fileURLWithPath: "/Users/fixture/" + $0), kind: "Document") }
        completions[index].1(.success(entries))
    }
}

final class LauncherTypingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeModel(files: FileSearch = FileSearch(startQuery: { _ in false }), notes: NotesStore? = nil) -> LauncherModel {
        let model = LauncherModel(index: AppIndex(entries: []),
            clipboard: ClipboardStore(retention: 10, storageURL: root.appendingPathComponent("clips.sqlite"), encryptionKey: SymmetricKey(size: .bits256)),
            notes: notes ?? NotesStore(directory: root.appendingPathComponent("Notes")), config: Preferences(),
            usage: UsageStore(url: root.appendingPathComponent("usage.sqlite")), files: files) { _ in }
        model.appleShortcuts.loadOverride = { $0([], nil) }
        model.isPresented = true
        return model
    }

    private func fileNames(_ model: LauncherModel) -> [String] {
        model.rows.compactMap { if case .file(let file) = $0 { return file.name }; return nil }
    }

    /// Digits-only queries keep the real Contacts search out of the test while files still run.
    @MainActor
    func testFilesStayNarrowedUntilTheirReplacementArrives() {
        let files = ManualFileSearch()
        let model = makeModel(files: files)
        model.query = "202"
        files.complete("202", names: ["2026-plan.md", "2025-notes.md"])
        XCTAssertEqual(fileNames(model), ["2026-plan.md", "2025-notes.md"])
        model.query = "2026"
        XCTAssertEqual(fileNames(model), ["2026-plan.md"], "Rows that still match stay while the new search runs")
        XCTAssertEqual(model.selection, 0, "A new query still selects its first result")
        files.complete("202", names: ["2025-old.md"])
        XCTAssertEqual(fileNames(model), ["2026-plan.md"], "A reply for the previous query is ignored")
        files.complete("2026", names: ["2026-plan.md", "2026-budget.xlsx"])
        XCTAssertEqual(fileNames(model), ["2026-plan.md", "2026-budget.xlsx"])
        model.query = "20"
        XCTAssertEqual(fileNames(model), [], "A query too short for file search shows none")
    }

    @MainActor
    func testRatesRefreshKeepsFilesSelectionAndRunningSearches() {
        let files = ManualFileSearch()
        let model = makeModel(files: files)
        model.query = "2026"
        files.complete("2026", names: ["2026-plan.md"])
        guard let fileIndex = model.rows.firstIndex(where: { $0.id == "file:/Users/fixture/2026-plan.md" }) else { return XCTFail("Missing file row") }
        model.selection = fileIndex
        let searches = files.searches.count
        model.refreshForCurrencyRates()
        XCTAssertEqual(files.searches.count, searches, "New rates do not restart the file search")
        XCTAssertEqual(fileNames(model), ["2026-plan.md"])
        XCTAssertEqual(model.selectedRow?.id, "file:/Users/fixture/2026-plan.md")
        XCTAssertEqual(model.rowState.selectedID, "file:/Users/fixture/2026-plan.md")
    }

    @MainActor
    func testCalculatorCardKeepsIdentityAndNeverActivatesAHeldAnswer() async throws {
        let model = makeModel()
        model.searchesSecondarySources = false
        model.calculationHoldDuration = 0.1
        var copied: [String] = []
        model.copyText = { copied.append($0) }
        model.query = "5"
        XCTAssertEqual(model.selectedRow?.id, "calc:0")
        model.query = "5+"
        XCTAssertNotNil(model.heldCalculation, "An incomplete edit keeps the last answer in place")
        XCTAssertFalse(model.rows.contains { $0.id.hasPrefix("calc:") }, "A held answer is not a selectable row")
        model.activateSelection()
        XCTAssertTrue(copied.isEmpty, "Return never copies the held answer")
        model.query = "5+3"
        XCTAssertNil(model.heldCalculation)
        XCTAssertEqual(model.selectedRow?.id, "calc:0", "The card keeps its identity while the query is edited")
        guard case .calculation(let answer, _)? = model.selectedRow else { return XCTFail("Missing answer") }
        XCTAssertEqual(answer.result, "8")
        XCTAssertEqual(model.rowState.selectedID, "calc:0")
        if case .calculation(let current, _)? = model.rowState.rowsByID["calc:0"] { XCTAssertEqual(current.result, "8") }
        else { XCTFail("Row state lacks the current answer") }
        model.activateSelection()
        XCTAssertEqual(copied, ["8"])
        model.query = "5+3+"
        XCTAssertNotNil(model.heldCalculation)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(model.heldCalculation, "The hold ends after its duration even without another keystroke")
        model.query = "5+3+1"
        model.query = "safari"
        XCTAssertNil(model.heldCalculation, "A query that is not an edit of the answered one drops the card at once")
    }

    @MainActor
    func testNotesAreReadWhenEnteredNotOnEveryKeystroke() throws {
        let directory = root.appendingPathComponent("Notes")
        let store = NotesStore(directory: directory)
        let model = makeModel(notes: store)
        model.searchesSecondarySources = false
        try "# Fictional first".write(to: directory.appendingPathComponent("first.md"), atomically: true, encoding: .utf8)
        model.query = "note f"
        XCTAssertTrue(model.rows.contains { $0.id == "note:first.md" }, "Entering notes reads the folder")
        try "# Fictional fresh".write(to: directory.appendingPathComponent("fresh.md"), atomically: true, encoding: .utf8)
        model.query = "note fr"
        XCTAssertFalse(model.rows.contains { $0.id == "note:fresh.md" }, "Typing inside notes does not reread the folder")
        model.query = "x"
        model.query = "note fr"
        XCTAssertTrue(model.rows.contains { $0.id == "note:fresh.md" }, "Entering notes again rereads the folder")
    }

    @MainActor
    func testNoteBodyMatchesArriveForTheCurrentQueryAndKeepTheSelection() async throws {
        let directory = root.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = [("title.md", "# Fictional plan\nfirst line", 1_000.0), ("body.md", "# Errands\nfirst line\nthe plan for later", 2_000.0),
                     ("other.md", "# Errands two\nfirst line\na zebra crossing", 3_000.0)]
        for (name, text, date) in files {
            let url = directory.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: date)], ofItemAtPath: url.path)
        }
        let store = NotesStore(directory: directory, searchReader: { url in
            Thread.sleep(forTimeInterval: 0.05)
            return try? String(contentsOf: url, encoding: .utf8)
        })
        let model = makeModel(notes: store)
        model.searchesSecondarySources = false
        model.query = "note zebra"
        model.query = "note plan"
        XCTAssertEqual(model.rows.map(\.id), ["note:title.md", "newnote:plan"], "Title matches show before any file is read")
        model.selection = 1
        for _ in 0..<100 where model.rows.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.rows.map(\.id), ["note:body.md", "note:title.md", "newnote:plan"])
        XCTAssertEqual(model.selectedRow?.id, "newnote:plan", "A same-query update keeps the selected row")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(model.rows.contains { $0.id == "note:other.md" }, "The abandoned query's matches never arrive")
    }

    @MainActor
    func testTypingEmojiSwitchesToTheGridAfterTheEdit() async throws {
        let model = makeModel()
        model.searchesSecondarySources = false
        model.query = "emoji"
        XCTAssertEqual(model.query, "emoji", "The field is not rewritten inside its own edit")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.query, ":")
        XCTAssertTrue(model.showingEmoji)
    }

    func testClipboardSearchSeesNewAndDeletedEntries() {
        let store = ClipboardStore(retention: 10, storageURL: root.appendingPathComponent("search.sqlite"), encryptionKey: SymmetricKey(size: .bits256))
        store.record("fictional alpha")
        store.record("unrelated")
        _ = store.recent(limit: 1)
        XCTAssertEqual(store.recent(limit: 12, matching: "fict").map(\.text), ["fictional alpha"])
        store.record("fictional beta")
        _ = store.recent(limit: 1)
        XCTAssertEqual(store.recent(limit: 12, matching: "fict").map(\.text), ["fictional beta", "fictional alpha"], "A new copy is searchable at once")
        guard let beta = store.recent(limit: 12, matching: "beta").first else { return XCTFail("Missing entry") }
        store.delete(id: beta.id)
        _ = store.recent(limit: 1)
        XCTAssertEqual(store.recent(limit: 12, matching: "fict").map(\.text), ["fictional alpha"], "A deleted copy leaves search results")
        store.endSearchSession()
        XCTAssertEqual(store.recent(limit: 12, matching: "ALPHA").map(\.text), ["fictional alpha"])
    }

    /// Search lists images by size without decrypting them up front; a matched image row still
    /// carries its exact bytes and the size its title reports.
    func testClipboardSearchListsImagesWithoutChangingThem() throws {
        let store = ClipboardStore(retention: 10, storageURL: root.appendingPathComponent("images.sqlite"), encryptionKey: SymmetricKey(size: .bits256))
        let png = try XCTUnwrap(Self.fictionalPNG(width: 300, height: 200))
        store.recordImage(png)
        store.record("fictional caption")
        _ = store.recent(limit: 1)
        XCTAssertEqual(store.recent(limit: 12, matching: "caption").map(\.text), ["fictional caption"])
        let image = try XCTUnwrap(store.recent(limit: 12, matching: "image").first)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(image.imageData, png)
        XCTAssertEqual(image.text, "Image (\(ByteCountFormatter.string(fromByteCount: Int64(png.count), countStyle: .file)))")
    }

    /// Row thumbnails are downsampled to the row's size instead of keeping a full-size decode.
    func testClipboardThumbnailsAreSmall() throws {
        let png = try XCTUnwrap(Self.fictionalPNG(width: 1600, height: 900))
        let thumbnail = try XCTUnwrap(LauncherRowState.thumbnail(png))
        let pixels = try XCTUnwrap(thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertLessThanOrEqual(max(pixels.width, pixels.height), LauncherRowState.thumbnailPixels)
        XCTAssertEqual(Double(pixels.width) / Double(pixels.height), 16.0 / 9.0, accuracy: 0.1)
        XCTAssertNil(LauncherRowState.thumbnail(Data("not an image".utf8)))
    }

    private static func fictionalPNG(width: Int, height: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    func testRetainedRowsMatchTheirSourcesQueries() {
        let contact = ContactEntry(id: "fixture", name: "Fictional Person", organization: "", fields: [])
        XCTAssertTrue(LauncherModel.contact(contact, matches: "pers"))
        XCTAssertTrue(LauncherModel.contact(contact, matches: "fictional p"))
        XCTAssertFalse(LauncherModel.contact(contact, matches: "erson"))
        let file = FileEntry(id: "/f/Résumé.pdf", name: "Résumé", url: URL(fileURLWithPath: "/f/Résumé.pdf"), kind: "PDF")
        XCTAssertTrue(LauncherModel.file(file, matches: "resume"))
        XCTAssertFalse(LauncherModel.file(file, matches: "cv"))
    }
}
