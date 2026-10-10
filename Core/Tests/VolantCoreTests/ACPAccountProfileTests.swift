import Foundation
import XCTest

@testable import VolantCore

/// Account folders: the one launch variable each provider reads, profile validation, the
/// per-provider choice, and how both are read from and saved to the settings file.
final class ACPAccountProfileTests: XCTestCase {
    private let work = ACPAccountProfile(id: "fictional-work", provider: "claude", label: "Work", directory: "/tmp/fictional-claude-work")
    private let personal = ACPAccountProfile(id: "fictional-personal", provider: "codex", label: "Personal", directory: "/tmp/fictional-codex-personal")

    private func refusal(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return (error as? ACPAccountProfile.Refusal)?.message ?? "\(error)" }
    }

    private func decoded(_ json: String) throws -> AIConfiguration {
        try JSONDecoder().decode(AIConfiguration.self, from: Data(json.utf8))
    }

    func testOnlyClaudeCodeAndCodexHaveAnAccountVariable() {
        XCTAssertEqual(ACPAccountProfile.environmentKey(for: .claude), "CLAUDE_CONFIG_DIR")
        XCTAssertEqual(ACPAccountProfile.environmentKey(for: .codex), "CODEX_HOME")
        for provider in [ACPProvider.opencode, .cursor, .gemini, .qwen] {
            XCTAssertNil(ACPAccountProfile.environmentKey(for: provider), provider.rawValue)
        }
    }

    func testLaunchVariablesSetOneFolderBesideTheProviderLaunch() throws {
        XCTAssertEqual(try ACPAccountProfile.launchVariables(provider: .claude, directory: "/tmp/fictional-claude-work"),
                       ["CLAUDE_CONFIG_DIR": "/tmp/fictional-claude-work"])
        XCTAssertEqual(try ACPAccountProfile.launchVariables(provider: .codex, directory: "/tmp/fictional-codex-personal"),
                       ["CODEX_HOME": "/tmp/fictional-codex-personal"])
        let launch = ["CLAUDE_CODE_EXECUTABLE": "/opt/fictional/bin/claude"]
            .merging(try ACPAccountProfile.launchVariables(provider: .claude, directory: "/tmp/fictional-claude-work")) { $1 }
        let environment = ChildProcessEnvironment.acpProvider(home: "/Users/fictional", user: "fictional", executable: "/opt/fictional/bin/node", launch: launch)
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/fictional-claude-work")
        XCTAssertEqual(environment["CLAUDE_CODE_EXECUTABLE"], "/opt/fictional/bin/claude")
        XCTAssertEqual(Set(environment.keys), ["HOME", "USER", "PATH", "LANG", "CLAUDE_CODE_EXECUTABLE", "CLAUDE_CONFIG_DIR"])
    }

    func testLaunchVariablesRefuseOtherProvidersAndPartialPaths() {
        for provider in [ACPProvider.opencode, .cursor, .gemini, .qwen] {
            XCTAssertEqual(refusal { _ = try ACPAccountProfile.launchVariables(provider: provider, directory: "/tmp/fictional-claude-work") },
                           "Only Claude Code and Codex can use an account folder.", provider.rawValue)
        }
        for bad in ["", "fictional-claude-work", "~/fictional-claude-work", "/tmp/fictional\u{0}work"] {
            XCTAssertEqual(refusal { _ = try ACPAccountProfile.launchVariables(provider: .claude, directory: bad) },
                           "An account folder must be a full path.", bad)
        }
    }

    func testLabelsAreTrimmedAndCountedAsCharacters() {
        XCTAssertEqual(ACPAccountProfile.trimmedLabel("  Work \n"), "Work")
        XCTAssertNil(ACPAccountProfile.trimmedLabel(""))
        XCTAssertNil(ACPAccountProfile.trimmedLabel(" \t "))
        XCTAssertNotNil(ACPAccountProfile.trimmedLabel(String(repeating: "a", count: 40)))
        XCTAssertNil(ACPAccountProfile.trimmedLabel(String(repeating: "a", count: 41)))
        let decomposed = String(repeating: "e\u{301}", count: 40)
        XCTAssertEqual(decomposed.unicodeScalars.count, 80)
        XCTAssertEqual(ACPAccountProfile.trimmedLabel(decomposed), decomposed, "a decomposed accent counts as one character")
        XCTAssertEqual(refusal { try ACPAccountProfile(provider: "claude", label: " ", directory: "/tmp/fictional-claude-work").validate() },
                       "Enter a label of 1 to 40 characters.")
        XCTAssertEqual(refusal { try ACPAccountProfile(provider: "unknown", label: "Work", directory: "/tmp/fictional-claude-work").validate() },
                       "Only Claude Code and Codex can use an account folder.")
        XCTAssertTrue(work.isValid)
        XCTAssertFalse(ACPAccountProfile(id: "", provider: "claude", label: "Work", directory: "/tmp/fictional-claude-work").isValid)
    }

    func testAnOlderFileReadsAsTheDefaultLogin() throws {
        let config = try decoded(#"{"provider":"claude"}"#)
        XCTAssertEqual(config.profiles, [])
        XCTAssertEqual(config.accounts, [:])
        XCTAssertNil(config.account(for: "claude"))
    }

    func testReadingDropsInvalidProfilesAndStaleChoices() throws {
        let json = #"""
        {"provider":"claude",
         "profiles":[
          {"id":"fictional-work","provider":"claude","label":"Work","directory":"/tmp/fictional-claude-work"},
          {"id":"fictional-personal","provider":"codex","label":"Personal","directory":"/tmp/fictional-codex-personal"},
          {"id":"fictional-qwen","provider":"qwen","label":"Other","directory":"/tmp/fictional-qwen"},
          {"id":"fictional-relative","provider":"claude","label":"Relative","directory":"fictional-relative"},
          {"id":"fictional-blank","provider":"claude","label":"  ","directory":"/tmp/fictional-blank"},
          {"id":"fictional-partial","provider":"claude","label":"Partial"},
          {"id":"fictional-work","provider":"claude","label":"Again","directory":"/tmp/fictional-again"},
          42],
         "accounts":{"claude":"fictional-work","codex":"fictional-work","gemini":"","qwen":"fictional-qwen","future":"","cursor":"fictional-personal"}}
        """#
        let config = try decoded(json)
        XCTAssertEqual(config.profiles, [work, personal])
        XCTAssertEqual(config.accounts, ["claude": "fictional-work"], "choices for other providers, providers without a folder and gone profiles are dropped")
        XCTAssertEqual(config.account(for: "claude"), work)
        XCTAssertNil(config.account(for: "codex"))
        XCTAssertEqual(try decoded(#"{"provider":"codex","profiles":"damaged","accounts":["damaged"]}"#).profiles, [],
                       "a damaged value falls back to the default login instead of failing the settings")
    }

    func testChoosingAnAccountForOneProvider() {
        var config = AIConfiguration()
        config.profiles = [work, personal]
        XCTAssertNil(config.account(for: "claude"))
        config.chooseAccount("fictional-work", for: "claude")
        XCTAssertEqual(config.account(for: "claude"), work)
        XCTAssertNil(config.account(for: "codex"), "a choice belongs to one provider")
        config.chooseAccount("fictional-personal", for: "claude")
        XCTAssertEqual(config.accounts["claude"], "", "another provider's profile is the default login")
        config.chooseAccount("fictional-work", for: "claude")
        config.chooseAccount("fictional-gone", for: "claude")
        XCTAssertEqual(config.accounts["claude"], "")
        config.chooseAccount("fictional-work", for: "claude")
        config.chooseAccount(nil, for: "claude")
        XCTAssertEqual(config.accounts["claude"], "")
        config.chooseAccount("fictional-work", for: "qwen")
        XCTAssertNil(config.accounts["qwen"], "a provider without an account variable stores no choice")
        XCTAssertEqual(config.profiles(for: "codex"), [personal])
    }

    func testAddingAProfileTrimsItsLabelAndRefusesRepeats() {
        var config = AIConfiguration()
        XCTAssertNil(refusal { try config.addProfile(ACPAccountProfile(id: "fictional-work", provider: "claude", label: " Work ", directory: "/tmp/fictional-claude-work")) })
        XCTAssertEqual(config.profiles, [work])
        XCTAssertEqual(refusal { try config.addProfile(ACPAccountProfile(id: "fictional-work", provider: "codex", label: "Work", directory: "/tmp/fictional-codex-work")) },
                       "This account is already listed.")
        XCTAssertEqual(refusal { try config.addProfile(ACPAccountProfile(provider: "claude", label: "Other", directory: "/tmp/fictional-claude-work")) },
                       "This folder is already a Claude Code account.")
        XCTAssertEqual(refusal { try config.addProfile(ACPAccountProfile(provider: "claude", label: "Work", directory: "/tmp/fictional-claude-other")) },
                       "Another Claude Code account uses this label.")
        XCTAssertEqual(refusal { try config.addProfile(ACPAccountProfile(provider: "qwen", label: "Other", directory: "/tmp/fictional-qwen")) },
                       "Only Claude Code and Codex can use an account folder.")
        XCTAssertEqual(refusal { try config.addProfile(ACPAccountProfile(provider: "codex", label: "Work", directory: "fictional-codex-work")) },
                       "An account folder must be a full path.")
        XCTAssertEqual(refusal { try config.addProfile(ACPAccountProfile(provider: "codex", label: "Other", directory: "/tmp/fictional-claude-work")) },
                       "This folder is already a Claude Code account.", "two providers never share one folder")
        XCTAssertNil(refusal { try config.addProfile(ACPAccountProfile(provider: "codex", label: "Work", directory: "/tmp/fictional-codex-work")) },
                     "another provider may use the same label")
        XCTAssertEqual(config.profiles.count, 2)
    }

    func testRemovingAChosenProfileReturnsItsProviderToTheDefaultLogin() {
        var config = AIConfiguration()
        config.profiles = [work, personal]
        config.chooseAccount("fictional-work", for: "claude")
        config.chooseAccount("fictional-personal", for: "codex")
        config.removeProfile(id: "fictional-work")
        XCTAssertEqual(config.profiles, [personal])
        XCTAssertEqual(config.accounts["claude"], "")
        XCTAssertNil(config.account(for: "claude"))
        XCTAssertEqual(config.account(for: "codex"), personal, "another provider's choice is kept")
    }

    func testAccountsAreSavedBesideUnknownFieldsAndTheDefaultLoginIsKept() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("volant-accounts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"ai":{"provider":"claude","future":42,"accounts":{"future":"kept"}}}"#.utf8).write(to: url)
        let original = try AIConfiguration.load(at: url)
        var chosen = original
        try chosen.addProfile(work)
        chosen.chooseAccount("fictional-work", for: "claude")
        try chosen.save(at: url, expected: original)
        XCTAssertEqual(try AIConfiguration.load(at: url), chosen)
        XCTAssertEqual(try AIConfiguration.load(at: url).account(for: "claude"), work)

        var reset = chosen
        reset.chooseAccount(nil, for: "claude")
        try reset.save(at: url, expected: chosen)
        XCTAssertEqual(try AIConfiguration.load(at: url), reset)
        XCTAssertNil(try AIConfiguration.load(at: url).account(for: "claude"), "the default login survives the merge into the earlier choice")

        var removed = reset
        removed.removeProfile(id: "fictional-work")
        try removed.save(at: url, expected: reset)
        XCTAssertEqual(try AIConfiguration.load(at: url).profiles, [])
        let ai = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["ai"] as? [String: Any])
        XCTAssertEqual(ai["future"] as? Int, 42)
        XCTAssertEqual(ai["accounts"] as? [String: String], ["claude": "", "future": "kept"])
    }

    func testSavingKeepsFieldsInsideProfilesAndEntriesThisVersionCannotRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("volant-accounts-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let json = #"""
        {"ai":{"provider":"claude","accounts":{"claude":"fictional-work"},"profiles":[
         {"id":"fictional-work","provider":"claude","label":"Work","directory":"/tmp/fictional-claude-work","note":"kept"},
         {"id":"fictional-tilde","provider":"claude","label":"Tilde","directory":"~/fictional-claude-tilde"},
         {"id":"fictional-later","provider":"later","label":"Later","directory":"/tmp/fictional-later"},
         {"id":"fictional-work","provider":"claude","label":"Again","directory":"/tmp/fictional-again"}]}}
        """#
        try Data(json.utf8).write(to: url)
        func savedProfiles() throws -> [[String: String]] {
            let ai = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["ai"] as? [String: Any]
            return try XCTUnwrap(ai?["profiles"] as? [[String: String]])
        }
        let original = try AIConfiguration.load(at: url)
        XCTAssertEqual(original.profiles, [work])

        var added = original; added.project = "/tmp/fictional-project"
        try added.addProfile(personal)
        try added.save(at: url, expected: original)
        XCTAssertEqual(try AIConfiguration.load(at: url), added)
        XCTAssertEqual(try savedProfiles().map { $0["id"] }, ["fictional-work", "fictional-personal", "fictional-tilde", "fictional-later"],
                       "entries this version cannot read stay, and the repeated ID is dropped as it is when read")
        XCTAssertEqual(try savedProfiles().first?["note"], "kept", "a field a later version wrote inside a profile stays")

        var removed = added
        removed.removeProfile(id: "fictional-work")
        try removed.save(at: url, expected: added)
        XCTAssertEqual(try AIConfiguration.load(at: url), removed)
        XCTAssertEqual(try savedProfiles().map { $0["id"] }, ["fictional-personal", "fictional-tilde", "fictional-later"], "a removed profile leaves the file")
    }
}
