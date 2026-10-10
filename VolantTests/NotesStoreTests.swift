import XCTest
import VolantCore
@testable import Volant

final class NotesStoreTests: XCTestCase {
    func testCreateUpdateSearchDelete() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("volant-notes-\(UUID().uuidString)")
        let store = NotesStore(directory: dir)
        let note = store.create(initialText: "# Groceries\nmilk")
        XCTAssertEqual(store.notes.first?.title, "Groceries")
        store.update(note.id, text: "# Groceries\nmilk\neggs")
        store.flush()
        XCTAssertEqual(try String(contentsOf: note.url, encoding: .utf8), "# Groceries\nmilk\neggs")
        XCTAssertEqual(fullSearch(store, "eggs").count, 1)
        XCTAssertEqual(fullSearch(store, "bread").count, 0)
        store.delete(note.id)
        XCTAssertTrue(store.notes.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    func testFailedCreationSurvivesReloadAndRetries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("volant-recovery-\(UUID().uuidString)")
        let store = NotesStore(directory: dir)
        try FileManager.default.removeItem(at: dir)
        let note = store.create(initialText: "Fictional draft")
        XCTAssertNotNil(store.saveErrors[note.id])
        store.reload()
        XCTAssertEqual(store.notes.first?.text, "Fictional draft")
        store.flush()
        XCTAssertEqual(store.dirtyText[note.id], "Fictional draft")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store.flush()
        XCTAssertTrue(store.dirtyText.isEmpty)
        XCTAssertTrue(store.saveErrors.isEmpty)
        XCTAssertEqual(try String(contentsOf: note.url, encoding: .utf8), "Fictional draft")
        try FileManager.default.removeItem(at: dir)
    }

    func testFailedUpdatePreservesLatestTextAndSelection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("volant-retry-\(UUID().uuidString)")
        let store = NotesStore(directory: dir)
        let note = store.create(initialText: "First")
        try FileManager.default.removeItem(at: dir)
        store.update(note.id, text: "Latest")
        store.flush()
        XCTAssertNotNil(store.saveErrors[note.id])
        store.delete(note.id)
        XCTAssertEqual(store.notes.first?.text, "Latest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store.flush()
        XCTAssertTrue(store.dirtyText.isEmpty)
        XCTAssertEqual(try String(contentsOf: note.url, encoding: .utf8), "Latest")
        try FileManager.default.removeItem(at: dir)
    }

    func testNewNoteClearsFilterAndPinsPersist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("volant-model-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults.standard.removeObject(forKey: "notes." + dir.path + ".selected")
            UserDefaults.standard.removeObject(forKey: "notes." + dir.path + ".pinned")
        }
        let store = NotesStore(directory: dir)
        let model = NotesModel(store: store)
        model.newNote(text: "Pinned reference")
        let pinnedID = try XCTUnwrap(model.selectedID)
        model.togglePin()
        model.show(.browse)
        model.filter = "does not match"
        model.newNote(text: "New thought")
        XCTAssertEqual(model.filter, "")
        XCTAssertNil(model.overlay)
        XCTAssertTrue(model.editing)
        XCTAssertEqual(model.filtered.first?.id, pinnedID)
        let restored = NotesModel(store: store)
        XCTAssertEqual(restored.selectedID, model.selectedID)
        XCTAssertTrue(restored.pinned.contains(pinnedID))
    }

    /// Creates an isolated folder of fictional notes and removes it and its preferences afterward.
    private func fixture(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("volant-lazy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent(name).path)
            }
            try? FileManager.default.removeItem(at: dir)
            UserDefaults.standard.removeObject(forKey: "notes." + dir.path + ".selected")
            UserDefaults.standard.removeObject(forKey: "notes." + dir.path + ".pinned")
        }
        return dir
    }

    /// The full-text definition search had before lazy loading: every note's current text, in list order.
    private func reference(_ store: NotesStore, _ term: String) -> [String] {
        let t = term.trimmingCharacters(in: .whitespaces)
        return store.notes.filter { note in
            if note.readError != nil { return note.id.localizedCaseInsensitiveContains(t) }
            let text = store.dirtyText[note.id] ?? (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
            return text.localizedCaseInsensitiveContains(t)
        }.map(\.id)
    }

    /// Runs the complete search: the immediate matches, then the background file scan when one is needed.
    private func fullSearch(_ store: NotesStore, _ term: String, limit: Int = 8) -> [String] {
        var result = store.search(term, limit: limit).map(\.id)
        let done = expectation(description: "Search \(term)")
        if store.searchFiles(term, limit: limit, completion: { result = $0.map(\.id); done.fulfill() }) == nil { done.fulfill() }
        wait(for: [done], timeout: 5)
        return result
    }

    /// Writes fictional notes with a body-only phrase in every third note and a known order.
    private func bodyFixture(count: Int) throws -> URL {
        var files: [String: String] = [:]
        for index in 0..<count {
            files["n\(index).md"] = "# Note \(index)\nfirst line\n" + (index % 3 == 0 ? "hidden phrase \(index)\n" : "nothing here\n")
        }
        let dir = try fixture(files)
        for index in 0..<count { try touch(dir.appendingPathComponent("n\(index).md"), Double(10_000 - index)) }
        return dir
    }

    func testImmediateSearchNeverReadsFilesAndTheScanRunsOffTheMainThread() throws {
        let dir = try bodyFixture(count: 12)
        let reads = NSLock()
        var readThreads: [Bool] = []
        let store = NotesStore(directory: dir, searchReader: { url in
            reads.withLock { readThreads.append(Thread.isMainThread) }
            Thread.sleep(forTimeInterval: 0.05)
            return try? String(contentsOf: url, encoding: .utf8)
        })
        let started = Date()
        XCTAssertEqual(store.search("hidden phrase", limit: Int.max).map(\.id), [])
        XCTAssertEqual(store.search("note 1", limit: Int.max).map(\.id), ["n1.md", "n10.md", "n11.md"], "Titles match at once")
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.3, "The immediate search does not wait for a reader")
        XCTAssertTrue(reads.withLock { readThreads.isEmpty })
        XCTAssertEqual(fullSearch(store, "hidden phrase", limit: Int.max), reference(store, "hidden phrase"))
        XCTAssertEqual(fullSearch(store, "hidden phrase"), ["n0.md", "n3.md", "n6.md", "n9.md"])
        XCTAssertFalse(reads.withLock { readThreads.contains(true) }, "Files are read only on the background queue")
    }

    func testCancelledOrStaleScansDeliverNothingAndListChangesRedoTheScan() throws {
        let dir = try bodyFixture(count: 6)
        let gate = DispatchSemaphore(value: 0)
        let store = NotesStore(directory: dir, searchReader: { url in
            gate.wait()
            gate.signal()
            return try? String(contentsOf: url, encoding: .utf8)
        })
        let stale = expectation(description: "Cancelled scan")
        stale.isInverted = true
        let first = try XCTUnwrap(store.searchFiles("hidden phrase", limit: Int.max) { _ in stale.fulfill() })
        first.cancel()
        var latest: [String] = []
        let answered = expectation(description: "Current scan")
        XCTAssertNotNil(store.searchFiles("nothing here", limit: Int.max) { latest = $0.map(\.id); answered.fulfill() })
        try "# Arrived later\nfirst line\nnothing here".write(to: dir.appendingPathComponent("z.md"), atomically: true, encoding: .utf8)
        try touch(dir.appendingPathComponent("z.md"), 20_000)
        store.reload()
        gate.signal()
        wait(for: [answered, stale], timeout: 2)
        XCTAssertEqual(latest, reference(store, "nothing here"))
        XCTAssertEqual(latest.first, "z.md", "A scan planned on the old list is redone for the new one")
    }

    /// Sets a file's modification date so ordering and change detection are deterministic.
    private func touch(_ url: URL, _ seconds: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
    }

    func testListedNotesKeepMetadataAndOnlyTheOpenNoteIsResident() throws {
        let dir = try fixture(["a.md": "# Trip plan\nPack the blue bag\nferry at noon",
                               "b.md": "\n\n  ## Recipes  \n\n  Lemon cake  \nflour",
                               "c.md": ""])
        try touch(dir.appendingPathComponent("a.md"), 3_000)
        try touch(dir.appendingPathComponent("b.md"), 2_000)
        try touch(dir.appendingPathComponent("c.md"), 1_000)
        let store = NotesStore(directory: dir)
        XCTAssertEqual(store.notes.map(\.id), ["a.md", "b.md", "c.md"])
        XCTAssertEqual(store.notes.map(\.title), ["Trip plan", "Recipes", "Untitled"])
        XCTAssertEqual(store.notes.map(\.preview), ["Pack the blue bag", "Lemon cake", ""])
        XCTAssertTrue(store.notes.allSatisfy { $0.text == nil })
        XCTAssertEqual(store.search("FERRY").map(\.id), [], "Body text is not read on the calling thread")
        XCTAssertEqual(fullSearch(store, "FERRY"), ["a.md"])
        XCTAssertTrue(store.notes.allSatisfy { $0.text == nil })
        XCTAssertEqual(store.text(of: "b.md"), "\n\n  ## Recipes  \n\n  Lemon cake  \nflour")

        let model = NotesModel(store: store)
        model.select("b.md")
        XCTAssertEqual(model.selected?.text, "\n\n  ## Recipes  \n\n  Lemon cake  \nflour")
        model.select("a.md")
        XCTAssertEqual(store.notes.filter { $0.text != nil }.map(\.id), ["a.md"])
        store.reload()
        XCTAssertEqual(model.selected?.text, "# Trip plan\nPack the blue bag\nferry at noon")
        XCTAssertEqual(store.notes.filter { $0.text != nil }.map(\.id), ["a.md"])
    }

    func testReloadReusesUnchangedFilesAndRereadsChangedOnes() throws {
        let dir = try fixture(["a.md": "# Alpha\nfirst", "b.md": "# Beta\nsecond"])
        let a = dir.appendingPathComponent("a.md"), b = dir.appendingPathComponent("b.md")
        try touch(a, 2_000)
        try touch(b, 1_000)
        let store = NotesStore(directory: dir)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: a.path)
        store.reload()
        XCTAssertNil(store.loadMessage, "An unchanged file must be reused without reading it again")
        XCTAssertEqual(store.notes.first?.title, "Alpha")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: a.path)

        try "# Gamma\nthird".write(to: b, atomically: true, encoding: .utf8)
        try touch(b, 3_000)
        store.reload()
        XCTAssertEqual(store.notes.map(\.title), ["Gamma", "Alpha"])
        XCTAssertEqual(store.search("third").map(\.id), ["b.md"])

        try "# Delta\nthird".write(to: b, atomically: true, encoding: .utf8)
        try touch(b, 3_001)
        store.reload()
        XCTAssertEqual(store.notes.first?.title, "Delta", "A same-size edit with a new date is read again")
    }

    func testSearchMatchesFullTextScanAcrossResidentDirtyAndUnreadableNotes() throws {
        let body = String(repeating: "filler line\n", count: 400)
        var files: [String: String] = [:]
        for index in 0..<40 { files["n\(index).md"] = "# Note \(index)\n" + body + (index % 3 == 0 ? "Résumé marker \(index)\n" : "plain\n") }
        let dir = try fixture(files)
        for index in 0..<40 { try touch(dir.appendingPathComponent("n\(index).md"), Double(1_000 + index)) }
        try Data([0xFF, 0xFE]).write(to: dir.appendingPathComponent("broken.md"))
        let store = NotesStore(directory: dir)
        let model = NotesModel(store: store)
        model.select("n5.md")
        store.update("n7.md", text: "# Note 7\nnow mentions résumé")
        for term in ["résumé", "RESUME", "marker 3", "note", "filler", "broken", "absent", " plain "] {
            let expected = reference(store, term)
            XCTAssertEqual(fullSearch(store, term, limit: Int.max), expected, term)
            XCTAssertEqual(fullSearch(store, term), Array(expected.prefix(8)), term)
            XCTAssertEqual(store.search(term, limit: Int.max).map(\.id), expected, "Remembered \(term)")
        }
        XCTAssertEqual(Set(store.notes.filter { $0.text != nil }.map(\.id)), ["n5.md", "n7.md"])
        store.flush()
        XCTAssertEqual(store.notes.filter { $0.text != nil }.map(\.id), ["n5.md"], "A saved note that is not open releases its text")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("n7.md"), encoding: .utf8), "# Note 7\nnow mentions résumé")
        XCTAssertEqual(store.search("now mentions").map(\.id), ["n7.md"])
    }

    func testOpeningAFileThatBecameUnreadableShowsThePlaceholderAndKeepsBytes() throws {
        let dir = try fixture(["a.md": "# Alpha\nfirst", "b.md": "# Beta\nsecond"])
        let store = NotesStore(directory: dir)
        let model = NotesModel(store: store)
        let invalid = Data([0xFF, 0xFE, 0xFA])
        let target = model.selectedID == "a.md" ? "b.md" : "a.md"
        try invalid.write(to: dir.appendingPathComponent(target))
        model.select(target)
        XCTAssertNotNil(model.selected?.readError)
        XCTAssertNil(model.selected?.text)
        XCTAssertEqual(model.selected?.title, target)
        store.update(target, text: "Must not overwrite unreadable bytes")
        store.flush()
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(target)), invalid)
        try "# Repaired\nok".write(to: dir.appendingPathComponent(target), atomically: true, encoding: .utf8)
        store.reload()
        XCTAssertNil(model.selected?.readError)
        XCTAssertEqual(model.selected?.text, "# Repaired\nok")
    }

    func testSummaryMatchesTheFullTextDefinition() {
        let samples = ["", "\n\n", "# Title", "###   \nsecond", "  Hello  \r\nworld\nthird", "\t# Tabbed\n\n\tPreview line\t",
                       "one\n" + String(repeating: "x", count: 500), String(repeating: "y", count: 120)]
        for text in samples {
            let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let cleaned = (lines.first ?? "").drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            var note = Note(id: "sample.md", url: URL(fileURLWithPath: "/fixture/sample.md"), text: text, modified: .distantPast)
            XCTAssertEqual(note.title, cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80)), text)
            XCTAssertEqual(note.preview, lines.dropFirst().first.map { String($0.prefix(Note.previewLimit)) } ?? "", text)
            note.unload()
            XCTAssertEqual(note.title, cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80)), "Kept after unloading \(text)")
            XCTAssertEqual(note.summaryContains("Untitled"), false, "The placeholder title is not note text")
        }
    }
}

import SwiftUI
import AppKit

final class NotesRenderTests: XCTestCase {
    @MainActor
    func testRenderNotesStates() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("volant-render-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults.standard.removeObject(forKey: "notes." + dir.path + ".selected")
            UserDefaults.standard.removeObject(forKey: "notes." + dir.path + ".pinned")
        }
        let store = NotesStore(directory: dir)
        let model = NotesModel(store: store)
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let scheme: ColorScheme = dark ? .dark : .light
            model.selectedID = nil
            // Empty state uses a separate empty store to keep the fixture independent of prior iteration.
            let emptyDir = dir.appendingPathComponent(mode)
            let emptyStore = NotesStore(directory: emptyDir)
            render(NotesView(model: NotesModel(store: emptyStore)).environment(\.colorScheme, scheme), name: "\(mode)-empty", size: NSSize(width: 380, height: 300), dark: dark)
            model.newNote(text: "# Weekend ideas\n\nA small place for thoughts worth keeping.\n\n- Walk by the lake\n- Try a new recipe\n\n```swift\nlet greeting = \"Hello, world!\"\nprint(greeting)\n```\n\nhttps://example.com/notes")
            for size in [NSSize(width: 380, height: 300), NSSize(width: 560, height: 620)] {
                render(NotesView(model: model).environment(\.colorScheme, scheme), name: "\(mode)-edit-\(Int(size.width))", size: size, dark: dark)
            }
            render(NotesView(model: model).environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, .accessibility3), name: "\(mode)-large-text", size: NSSize(width: 800, height: 700), dark: dark)
            let liveState = LiveEditorState()
            model.newNote(text: "# A little space to think\n\nKeep **useful things** close.\n\n```\ndef greet(name):\n    return 'Hello, ' + name\n```\n\nBack to the note.")
            render(NotesView(model: model, liveState: liveState).environment(\.colorScheme, scheme), name: "\(mode)-live-code", size: NSSize(width: 560, height: 620), dark: dark, prepare: {
                if let view = liveState.textView { view.setSelectedRange((view.string as NSString).range(of: "name):")) }
            })
            let compactState = LiveEditorState()
            render(NotesView(model: model, liveState: compactState).environment(\.colorScheme, scheme), name: "\(mode)-live-code-compact", size: NSSize(width: 380, height: 300), dark: dark, prepare: {
                if let view = compactState.textView { view.setSelectedRange((view.string as NSString).range(of: "name):")) }
            })
            model.show(.actions)
            render(NotesView(model: model).environment(\.colorScheme, scheme), name: "\(mode)-actions-overlay", size: NSSize(width: 560, height: 620), dark: dark)
            model.overlay = nil
            model.editing = false
            render(NotesView(model: model).environment(\.colorScheme, scheme), name: "\(mode)-preview", size: NSSize(width: 560, height: 620), dark: dark)
            model.show(.browse)
            render(NotesPicker(model: model, store: store).environment(\.colorScheme, scheme), name: "\(mode)-browse", size: NSSize(width: 340, height: 350), dark: dark)
            model.filter = "nothing matches"
            render(NotesPicker(model: model, store: store).environment(\.colorScheme, scheme), name: "\(mode)-no-matches", size: NSSize(width: 340, height: 350), dark: dark)
            model.show(.actions)
            render(NotesPicker(model: model, store: store).environment(\.colorScheme, scheme), name: "\(mode)-actions", size: NSSize(width: 340, height: 350), dark: dark)
            model.overlay = nil
            store.lastError = "Could not move note to Trash. Your note has been kept."
            render(NotesView(model: model).environment(\.colorScheme, scheme), name: "\(mode)-error", size: NSSize(width: 380, height: 300), dark: dark)
            store.lastError = nil
        }
        model.newNote(text: "# Packing list\n\n## Before Friday\n\n- Pack the **blue** bag\n- Check the [route](https://example.com/route)\n- Bring `charger` and cards\n\n> Leave by 7:30.\n\n```swift\nlet bags = 2\nlet note = \"Window seat\"\n```\n")
        model.editing = true
        for id in ["catppuccin-latte", "catppuccin-mocha", "solarized-light", "nord"] {
            let theme = ColorTheme.named(id)
            let dark = theme.mode == .dark
            render(NotesView(model: model).environment(\.volantTheme, ResolvedTheme(theme)).environment(\.colorScheme, dark ? .dark : .light),
                   name: "theme-\(id)-editor", size: NSSize(width: 560, height: 620), dark: dark)
        }
    }

    @MainActor
    private func render<V: View>(_ view: V, name: String, size: NSSize, dark: Bool, prepare: (() -> Void)? = nil) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        prepare?()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { XCTFail("No bitmap for \(name)"); return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
