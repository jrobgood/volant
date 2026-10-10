import XCTest
import VolantCore
@testable import Volant

final class AppBindingTests: XCTestCase {
    func testGlyphFormattingPreservesCanonicalInput() {
        XCTAssertEqual(KeyCombo.display("hyper+c"), "✦ C")
        XCTAssertEqual(KeyCombo.display("cmd+ctrl+option+shift+c"), "✦ C")
        XCTAssertEqual(KeyCombo.display("cmd+ctrl+space"), "⌃⌘ ␣")
        XCTAssertEqual(KeyCombo.display("option+n"), "⌥ N")
        XCTAssertEqual(KeyCombo.display("shift+return"), "⇧ ↩")
        XCTAssertEqual(KeyCombo.display("meh+left"), "⌃⌥⇧ ←")
        XCTAssertEqual(KeyCombo.display(""), "")
        XCTAssertEqual(KeyCombo(parsing: "hyper+c"), KeyCombo(parsing: "cmd+ctrl+option+shift+c"))
    }
    func testInlineAliasPreservesOtherFieldsAndRejectsStaleEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let original = #"{"aliases":{"old":"/Fixture.app","another":"/Fixture.app","keep":"/Other.app"},"unknown":{"preserve":true},"appHotKeys":[{"bundleIdentifier":"test.fixture","hotKey":"hyper+c","future":7}]}"#
        try Data(original.utf8).write(to: url)
        let expected = ["old": "/Fixture.app", "another": "/Fixture.app"]
        try AppBindingStore.updateAlias(path: "/Fixture.app", name: "Fixture", originalAlias: "old", value: "new", expectedAliases: expected, at: url)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(object["aliases"] as? [String: String], ["new": "/Fixture.app", "another": "/Fixture.app", "keep": "/Other.app"])
        XCTAssertEqual((object["unknown"] as? [String: Bool])?["preserve"], true)
        XCTAssertEqual((object["appHotKeys"] as? [[String: Any]])?.first?["future"] as? Int, 7)
        let saved = try Data(contentsOf: url)
        XCTAssertThrowsError(try AppBindingStore.updateAlias(path: "/Fixture.app", name: "Fixture", originalAlias: "old", value: "stale", expectedAliases: expected, at: url))
        XCTAssertEqual(try Data(contentsOf: url), saved)
        for invalid in ["emoji", "caffeinate", "two words", "keep"] {
            XCTAssertThrowsError(try AppBindingStore.updateAlias(path: "/Fixture.app", name: "Fixture", originalAlias: "new", value: invalid, expectedAliases: ["new": "/Fixture.app", "another": "/Fixture.app"], at: url))
            XCTAssertEqual(try Data(contentsOf: url), saved)
        }
        try AppBindingStore.updateAlias(path: "/Fixture.app", name: "Fixture", originalAlias: "new", value: "", expectedAliases: ["new": "/Fixture.app", "another": "/Fixture.app"], at: url)
        let latest = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
        XCTAssertNil(latest.aliases["new"])
        XCTAssertEqual(latest.aliases["another"], "/Fixture.app")
    }

    func testAppShortcutsAreKeyedByCopyAndMigrateLegacyEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let release = "/Applications/Fixture.app", beta = "/Applications/Beta/Fixture.app"
        try Data(#"{"unknown":{"preserve":true},"appHotKeys":[{"bundleIdentifier":"test.fixture","hotKey":"ctrl+option+f","future":7}]}"#.utf8).write(to: url)
        var config = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
        XCTAssertEqual(AppHotKey.binding(in: config.appHotKeys, bundleIdentifier: "test.fixture", path: beta), "ctrl+option+f",
                       "an unedited legacy entry still shows for every copy")
        _ = try AppBindingStore.updateHotKey(bundleID: "test.fixture", path: beta, value: "ctrl+option+b", expectedValue: "ctrl+option+f",
                                             at: url, available: { _ in true })
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var entries = try XCTUnwrap(object["appHotKeys"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["path"] as? String, beta, "editing a legacy entry records the selected copy")
        XCTAssertEqual(entries[0]["future"] as? Int, 7, "unknown entry fields survive migration")
        XCTAssertEqual((object["unknown"] as? [String: Bool])?["preserve"], true)
        config = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
        XCTAssertEqual(AppHotKey.binding(in: config.appHotKeys, bundleIdentifier: "test.fixture", path: release), "")
        XCTAssertThrowsError(try AppBindingStore.updateHotKey(bundleID: "test.fixture", path: release, value: "ctrl+option+b", expectedValue: "",
                                                              at: url, available: { _ in true }), "two copies cannot share one shortcut")
        _ = try AppBindingStore.updateHotKey(bundleID: "test.fixture", path: release, value: "ctrl+option+r", expectedValue: "",
                                             at: url, available: { _ in true })
        config = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
        XCTAssertEqual(AppHotKey.binding(in: config.appHotKeys, bundleIdentifier: "test.fixture", path: release), "ctrl+option+r")
        XCTAssertEqual(AppHotKey.binding(in: config.appHotKeys, bundleIdentifier: "test.fixture", path: beta), "ctrl+option+b")
        let saved = try Data(contentsOf: url)
        XCTAssertThrowsError(try AppBindingStore.updateHotKey(bundleID: "test.fixture", path: beta, value: "ctrl+option+x", expectedValue: "ctrl+option+f",
                                                              at: url, available: { _ in true }), "a stale editor is rejected")
        XCTAssertEqual(try Data(contentsOf: url), saved)
        _ = try AppBindingStore.updateHotKey(bundleID: "test.fixture", path: beta, value: "", expectedValue: "ctrl+option+b",
                                             at: url, available: { _ in true })
        object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        entries = try XCTUnwrap(object["appHotKeys"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["path"] as? String }, [release], "clearing one copy leaves the other copy's shortcut")
    }

    func testDictationShortcutSavesFromSettingsAndJoinsDuplicateChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        try Data(#"{"summonHotKey":"option+space","unknown":{"preserve":true}}"#.utf8).write(to: url)
        try GlobalShortcutStore.save(key: "talkHotKey", value: "option+d", expectedValue: "", at: url, available: { _ in true })
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(object["talkHotKey"] as? String, "option+d")
        XCTAssertEqual((object["unknown"] as? [String: Bool])?["preserve"], true)
        let saved = try Data(contentsOf: url)
        XCTAssertThrowsError(try GlobalShortcutStore.save(key: "notesHotKey", value: "option+d", expectedValue: "", at: url, available: { _ in true }),
                             "another global binding cannot reuse the dictation shortcut")
        XCTAssertThrowsError(try AppBindingStore.save(bundleID: "test.fixture", path: "/Fixture.app", originalAlias: "", alias: "", hotKey: "option+d",
                                                      expected: saved, at: url, available: { _ in true }),
                             "an app shortcut cannot reuse the dictation shortcut")
        XCTAssertThrowsError(try GlobalShortcutStore.save(key: "talkHotKey", value: "option+e", expectedValue: "", at: url, available: { _ in true }),
                             "a stale snapshot is rejected")
        XCTAssertEqual(try Data(contentsOf: url), saved)
    }

    func testSystemActionShortcutsSaveAndJoinDuplicateChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        try Data(#"{"talkHotKey":"option+d"}"#.utf8).write(to: url)
        try GlobalShortcutStore.save(key: "lockScreenHotKey", value: "control+option+l", expectedValue: "", at: url, available: { _ in true })
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url)).lockScreenHotKey, "control+option+l")
        XCTAssertThrowsError(try GlobalShortcutStore.save(key: "sleepDisplaysHotKey", value: "option+d", expectedValue: "", at: url, available: { _ in true }),
                             "cannot reuse the dictation shortcut")
        XCTAssertThrowsError(try GlobalShortcutStore.save(key: "sleepDisplaysHotKey", value: "control+option+l", expectedValue: "", at: url, available: { _ in true }),
                             "cannot reuse the Lock Screen shortcut")
    }
}
