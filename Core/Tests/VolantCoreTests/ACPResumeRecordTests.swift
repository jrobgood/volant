import XCTest

@testable import VolantCore

/// A stored session ID came from an agent, so it is checked again before it is sent back.
final class ACPResumeRecordTests: XCTestCase {
    func testAcceptsTheSessionIDShapesProvidersReturn() {
        XCTAssertTrue(ACPResumeRecord.isValidSessionID("0b7c3f9e-5d1a-4c2e-9f61-1f2a3b4c5d6e"))
        XCTAssertTrue(ACPResumeRecord.isValidSessionID("ses_fictional01AbC"))
    }

    func testRejectsEmptyOversizedAndUnprintableIDs() {
        XCTAssertFalse(ACPResumeRecord.isValidSessionID(""))
        XCTAssertFalse(ACPResumeRecord.isValidSessionID(String(repeating: "a", count: 257)))
        XCTAssertTrue(ACPResumeRecord.isValidSessionID(String(repeating: "a", count: 256)))
        for bad in ["has space", "line\nbreak", "nul\u{0}", "../escape", "back\\slash", "caf\u{E9}"] {
            XCTAssertFalse(ACPResumeRecord.isValidSessionID(bad), bad)
        }
    }

    func testRecordNeedsAKnownProviderAndMatchesOnlyItsOwnFolder() {
        let record = ACPResumeRecord(provider: "claude", project: "/tmp/fictional-project", sessionID: "fictional-session")
        XCTAssertTrue(record.isValid)
        XCTAssertTrue(record.matches(provider: "claude", project: "/tmp/fictional-project", profile: ""))
        XCTAssertFalse(record.matches(provider: "codex", project: "/tmp/fictional-project", profile: ""))
        XCTAssertFalse(record.matches(provider: "claude", project: "", profile: ""))
        XCTAssertFalse(ACPResumeRecord(provider: "unknown", project: "", sessionID: "fictional-session").isValid)
        XCTAssertFalse(ACPResumeRecord(provider: "claude", project: "", sessionID: "bad id").isValid)
    }

    func testRecordRoundTripsThroughJSON() throws {
        let record = ACPResumeRecord(provider: "codex", project: "", sessionID: "fictional-session", savedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(try JSONDecoder().decode(ACPResumeRecord.self, from: JSONEncoder().encode(record)), record)
    }

    func testAProfileMustMatchAndAnOlderRecordReadsAsTheDefaultLogin() throws {
        let work = ACPResumeRecord(provider: "claude", project: "", sessionID: "fictional-session", profile: "/tmp/fictional-claude-work")
        XCTAssertTrue(work.isValid)
        XCTAssertTrue(work.matches(provider: "claude", project: "", profile: "/tmp/fictional-claude-work"))
        XCTAssertFalse(work.matches(provider: "claude", project: "", profile: ""), "the default login cannot continue another login's session")
        XCTAssertFalse(work.matches(provider: "claude", project: "", profile: "/tmp/fictional-claude-other"))
        XCTAssertEqual(try JSONDecoder().decode(ACPResumeRecord.self, from: JSONEncoder().encode(work)), work)

        let plain = ACPResumeRecord(provider: "claude", project: "", sessionID: "fictional-session")
        XCTAssertTrue(plain.matches(provider: "claude", project: "", profile: ""))
        XCTAssertFalse(plain.matches(provider: "claude", project: "", profile: "/tmp/fictional-claude-work"))
        XCTAssertTrue(ACPResumeRecord(provider: "claude", project: "", sessionID: "fictional-session", profile: "").matches(provider: "claude", project: "", profile: ""))

        let older = #"{"provider":"claude","project":"","sessionID":"fictional-session","savedAt":0}"#
        let record = try JSONDecoder().decode(ACPResumeRecord.self, from: Data(older.utf8))
        XCTAssertNil(record.profile)
        XCTAssertTrue(record.matches(provider: "claude", project: "", profile: ""), "a record saved before accounts existed belongs to the default login")

        let composed = ACPResumeRecord(provider: "codex", project: "", sessionID: "fictional-session", profile: "/tmp/fictional-caf\u{E9}")
        XCTAssertTrue(composed.matches(provider: "codex", project: "", profile: "/tmp/fictional-cafe\u{301}"), "file names compare the same in either Unicode form")
        for bad in ["fictional-claude-work", "/tmp/fictional\u{0}work"] {
            XCTAssertFalse(ACPResumeRecord(provider: "claude", project: "", sessionID: "fictional-session", profile: bad).isValid, bad)
        }
    }

    func testLoadSessionCapabilityIsReadOnlyWhenAdvertised() {
        XCTAssertTrue(ACPCapabilities.supportsLoadSession(#"{"loadSession":true}"#))
        XCTAssertFalse(ACPCapabilities.supportsLoadSession(#"{"loadSession":false}"#))
        XCTAssertFalse(ACPCapabilities.supportsLoadSession(#"{"promptCapabilities":{"embeddedContext":true}}"#))
        XCTAssertFalse(ACPCapabilities.supportsLoadSession("{}"))
        XCTAssertFalse(ACPCapabilities.supportsLoadSession("not json"))
    }
}
