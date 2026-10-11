import XCTest
@testable import VolantCore

final class LauncherEntriesTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("volant-entries-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes a fictional configuration with unknown fields at the top level and inside entries.
    private func writeFixture(_ json: String? = nil) throws -> Preferences {
        let text = json ?? """
        {"futureSetting": {"keep": true},
         "snippets": [{"name": "Greeting", "keyword": "hi", "body": "Hello", "futureField": 7}],
         "quicklinks": [{"name": "Docs", "url": "https://docs.example.com/?q={query}", "openWith": "Fixture Browser"}],
         "aliases": {"term": "/Applications/Fixture.app"}}
        """
        try Data(text.utf8).write(to: url)
        return try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
    }

    private func object() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testAppendSnippetKeepsUnknownFields() throws {
        let config = try writeFixture()
        let saved = try LauncherEntries.appendSnippet(Snippet(name: "  Signature ", keyword: " sig ", body: "Thanks,\n{date}\n"),
                                                      expected: .init(config), at: url)
        XCTAssertEqual(saved.snippets.last, Snippet(name: "Signature", keyword: "sig", body: "Thanks,\n{date}\n"))
        let raw = try object()
        XCTAssertEqual((raw["futureSetting"] as? [String: Bool])?["keep"], true)
        let snippets = try XCTUnwrap(raw["snippets"] as? [[String: Any]])
        XCTAssertEqual(snippets.count, 2)
        XCTAssertEqual(snippets[0]["futureField"] as? Int, 7)
        let links = try XCTUnwrap(raw["quicklinks"] as? [[String: Any]])
        XCTAssertEqual(links[0]["openWith"] as? String, "Fixture Browser")
    }

    func testAppendQuicklinkKeepsUnknownFields() throws {
        let config = try writeFixture()
        let saved = try LauncherEntries.appendQuicklink(Quicklink(name: "Maps", url: " https://maps.example.com/?q={query} "),
                                                        expected: .init(config), at: url)
        XCTAssertEqual(saved.quicklinks.map(\.name), ["Docs", "Maps"])
        XCTAssertEqual(saved.quicklinks.last?.url, "https://maps.example.com/?q={query}")
        let links = try XCTUnwrap(try object()["quicklinks"] as? [[String: Any]])
        XCTAssertEqual(links[0]["openWith"] as? String, "Fixture Browser")
        XCTAssertEqual((try object()["futureSetting"] as? [String: Bool])?["keep"], true)
    }

    func testMissingQuicklinksKeepTheDefaultLink() throws {
        let config = try writeFixture(#"{"futureSetting": 1}"#)
        let saved = try LauncherEntries.appendQuicklink(Quicklink(name: "Maps", url: "https://maps.example.com"), expected: .init(config), at: url)
        XCTAssertEqual(saved.quicklinks.map(\.name), ["Google", "Maps"])
        XCTAssertEqual(try object()["futureSetting"] as? Int, 1)
    }

    func testStaleSnapshotIsRejectedWithoutWriting() throws {
        let config = try writeFixture()
        var newer = try object()
        newer["aliases"] = ["term": "/Applications/Fixture.app", "edit": "/Applications/Other.app"]
        let changed = try JSONSerialization.data(withJSONObject: newer, options: [.sortedKeys])
        try changed.write(to: url)
        XCTAssertThrowsError(try LauncherEntries.appendSnippet(Snippet(name: "New", keyword: "", body: "Text"), expected: .init(config), at: url)) { error in
            XCTAssertEqual((error as? LauncherEntries.Failure)?.isConflict, true)
        }
        XCTAssertEqual(try Data(contentsOf: url), changed)
    }

    func testUnrelatedChangesDoNotMakeTheSnapshotStale() throws {
        let config = try writeFixture()
        var newer = try object()
        newer["clipboardRetention"] = 42
        try JSONSerialization.data(withJSONObject: newer).write(to: url)
        let saved = try LauncherEntries.appendSnippet(Snippet(name: "New", keyword: "", body: "Text"), expected: .init(config), at: url)
        XCTAssertEqual(saved.clipboardRetention, 42)
        XCTAssertEqual(saved.snippets.count, 2)
    }

    func testSnippetUniquenessAndReservedWords() throws {
        let config = try writeFixture()
        let cases: [(Snippet, String)] = [
            (Snippet(name: "greeting", keyword: "", body: "x"), "already exists"),
            (Snippet(name: "A", keyword: "HI", body: "x"), "already used"),
            (Snippet(name: "B", keyword: "docs", body: "x"), "already used"),
            (Snippet(name: "C", keyword: "term", body: "x"), "already used"),
            (Snippet(name: "D", keyword: "clip", body: "x"), "built-in"),
            (Snippet(name: "E", keyword: "/files", body: "x"), "built-in"),
            (Snippet(name: "F", keyword: "two words", body: "x"), "single-word"),
            (Snippet(name: " ", keyword: "", body: "x"), "name"),
            (Snippet(name: "G", keyword: "", body: " \n"), "text"),
        ]
        for (snippet, expected) in cases {
            XCTAssertThrowsError(try LauncherEntries.appendSnippet(snippet, expected: .init(config), at: url), snippet.name) { error in
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(snippet): \(error.localizedDescription)")
            }
        }
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url)).snippets.count, 1)
    }

    func testQuicklinkNamesAndURLs() throws {
        let config = try writeFixture()
        let invalid: [(Quicklink, String)] = [
            (Quicklink(name: "docs", url: "https://example.com"), "already used"),
            (Quicklink(name: "hi", url: "https://example.com"), "already used"),
            (Quicklink(name: "Term", url: "https://example.com"), "already used"),
            (Quicklink(name: "new snippet", url: "https://example.com"), "built-in"),
            (Quicklink(name: "notes", url: "https://example.com"), "built-in"),
            (Quicklink(name: "Files", url: "file:///etc/passwd"), "https://"),
            (Quicklink(name: "Script", url: "javascript:alert(1)"), "https://"),
            (Quicklink(name: "Spaces", url: "https://example.com/a b"), "https://"),
            (Quicklink(name: "Hostless", url: "https:///path"), "address"),
            (Quicklink(name: "Mail", url: "mailto:"), "email"),
            (Quicklink(name: "Run", url: "shortcuts://run-shortcut?input=text"), "https://"),
            (Quicklink(name: "Empty", url: ""), "URL"),
        ]
        for (link, expected) in invalid {
            XCTAssertThrowsError(try LauncherEntries.validated(link, in: config), link.name) { error in
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(link): \(error.localizedDescription)")
            }
        }
        for valid in ["https://example.com/search?q={query}", "http://localhost:8080", "mailto:team@example.com?subject={query}",
                      "shortcuts://run-shortcut?name=Fixture&input=text&text={query}"] {
            XCTAssertNoThrow(try LauncherEntries.validated(Quicklink(name: "Valid", url: valid), in: config), valid)
        }
    }

    func testCreateCommandsAreReservedAndSearchable() {
        for phrase in ["new snippet", "Create Snippet", "add quicklink", "new quicklink"] {
            XCTAssertTrue(LauncherRouting.isReserved(phrase), phrase)
        }
        XCTAssertFalse(LauncherRouting.isReserved("new snippets for work"))
        XCTAssertEqual(CoreCommand.search("new snippet"), [.newSnippet])
        XCTAssertEqual(CoreCommand.search("create quicklink"), [.newQuicklink])
        XCTAssertEqual(CoreCommand.newSnippet.title, "Create Snippet")
    }

    func testMalformedDocumentIsNotReplaced() throws {
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try LauncherEntries.appendSnippet(Snippet(name: "A", keyword: "", body: "x"), expected: .init(Preferences()), at: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
    }
}
