import XCTest

@testable import VolantCore

final class PreferencesTests: XCTestCase {
    func testDockSettingPreservesOtherFields() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"aliases":{"s":"Safari"},"future":{"keep":1}}"#.utf8).write(to: url)
        try Preferences.updateBoolean("showInDock", value: false, at: url)
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertFalse(config.showInDock)
        XCTAssertEqual(config.aliases["s"], "Safari")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["future"])
    }

    /// Caffeinate keeps the display awake unless the owner turns it off; older configs get the default.
    func testCaffeinateDisplaySettingDefaultsOnAndPatchesNarrowly() throws {
        XCTAssertTrue(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).caffeinateKeepsDisplayAwake)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"showInDock":false,"future":{"keep":1}}"#.utf8).write(to: url)
        try Preferences.updateBoolean("caffeinateKeepsDisplayAwake", value: false, at: url)
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertFalse(config.caffeinateKeepsDisplayAwake)
        XCTAssertFalse(config.showInDock)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["future"])
    }
    func testPinnedHarnessRoundTripPreservesOtherSettings() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"aliases":{"s":"Safari"},"future":true}"#.utf8).write(to: url)
        try Preferences.updatePromotedHarness("codex", at: url)
        var data = try Data(contentsOf: url)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data).promotedHarness, "codex")
        XCTAssertThrowsError(try Preferences.updatePromotedHarness("unsupported", at: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
        try Preferences.updatePromotedHarness(nil, at: url)
        data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertNil(config.promotedHarness)
        XCTAssertEqual(config.aliases["s"], "Safari")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["future"] as? Bool, true)
    }

    func testStatusBarMigratesLegacyAndPreservesFutureSources() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"promotedHarness":"claude","future":true}"#.utf8).write(to: url)
        var config = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
        XCTAssertEqual(config.statusBar.sources, ["herdr"])
        XCTAssertEqual(config.statusBar.herdrFilter, "claude")
        try Preferences.updateStatusBar(enabled: false, at: url)
        config = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
        XCTAssertNil(config.promotedHarness)
        XCTAssertEqual(config.statusBar.herdrFilter, "claude")
        try Preferences.updateStatusBar(enabled: true, at: url)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url)).promotedHarness, "claude")
        try Data(#"{"promotedHarness":"codex","statusBar":{"sources":["herdr","future"],"herdrFilter":"all","unknown":42}}"#.utf8).write(to: url)
        try Preferences.updateStatusBar(enabled: false, at: url)
        config = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
        XCTAssertEqual(config.statusBar.sources, ["future"])
        XCTAssertNil(config.promotedHarness)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(object["promotedHarness"])
        XCTAssertEqual((object["statusBar"] as? [String: Any])?["unknown"] as? Int, 42)
    }

    func testMalformedConfigIsNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data("broken json".utf8)
        try data.write(to: url)
        XCTAssertThrowsError(try Preferences.updateBoolean("showInDock", value: true, at: url))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testAppHotKeyBindingPrefersExactCopyAndKeepsLegacyEntriesReadable() throws {
        let json = #"{"appHotKeys":[{"bundleIdentifier":"fixture.app","hotKey":"ctrl+option+l"},{"bundleIdentifier":"fixture.app","hotKey":"ctrl+option+b","path":"/Applications/Beta/Fixture.app"}]}"#
        let entries = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8)).appHotKeys
        XCTAssertNil(entries[0].path, "entries saved before paths existed still decode")
        XCTAssertEqual(AppHotKey.binding(in: entries, bundleIdentifier: "fixture.app", path: "/Applications/Beta/Fixture.app"), "ctrl+option+b")
        XCTAssertEqual(AppHotKey.binding(in: entries, bundleIdentifier: "fixture.app", path: "/Applications/Fixture.app"), "ctrl+option+l")
        let pathOnly = [AppHotKey(bundleIdentifier: "fixture.app", hotKey: "ctrl+option+b", path: "/Applications/Beta/Fixture.app")]
        XCTAssertEqual(AppHotKey.binding(in: pathOnly, bundleIdentifier: "fixture.app", path: "/Applications/Fixture.app"), "",
                       "a shortcut saved for one copy never belongs to another copy")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppHotKey(bundleIdentifier: "fixture.app", hotKey: "ctrl+k"))) as? [String: Any])
        XCTAssertNil(encoded["path"], "a legacy entry is not given an empty path")
    }
}
