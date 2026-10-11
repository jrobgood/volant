import XCTest
@testable import VolantCore

/// The input helper's session rules with a fake system: no Accessibility, events or pasteboard.
final class InputSessionControllerTests: XCTestCase {
    /// A text element whose count changes only when `applies` is true, optionally late.
    final class FakeField: InputField {
        var pid: Int32? = 42
        var role: String? = "AXTextArea"
        var subrole: String?
        var count: Int? = 0
        var selection: Int? = 0
        var applies = true
        var appliesLate = false
        var sets: [String] = []
        var pendingLate = 0

        func characterCount() -> Int? {
            guard let count else { return nil }
            return count
        }
        func selectionLength() -> Int? { selection }
        func setSelectedText(_ text: String) {
            sets.append(text)
            if applies { count = (count ?? 0) + text.utf16.count }
            if appliesLate { pendingLate += text.utf16.count }
        }
    }

    final class FakeSystem: InputSystem {
        var trusted = true
        var secureInput = false
        var target: InputTarget? = InputTarget(pid: 42, launchDate: Date(timeIntervalSince1970: 100))
        var field: FakeField? = FakeField()
        var pasted: [String] = []
        var pasteWorks = true
        var waits: [TimeInterval] = []
        var prompts: [Bool] = []

        func isTrusted(prompt: Bool) -> Bool { prompts.append(prompt); return trusted }
        func isSecureInputEnabled() -> Bool { secureInput }
        func frontmostTarget() -> InputTarget? { target }
        func focusedField() -> InputField? { field }
        func paste(_ text: String) -> Bool { pasted.append(text); return pasteWorks }
        func wait(_ seconds: TimeInterval) {
            waits.append(seconds)
            if let field, field.appliesLate { field.count = (field.count ?? 0) + field.pendingLate; field.pendingLate = 0 }
        }
    }

    private var clock = Date(timeIntervalSince1970: 1_000)
    private var tokens = 0

    private func controller(_ system: FakeSystem, caller: Int32 = 7) -> InputSessionController {
        InputSessionController(system: system, callerPID: caller, now: { [unowned self] in self.clock }, makeToken: { [unowned self] in
            self.tokens += 1
            return Data([UInt8(self.tokens)])
        })
    }

    func testStatusPromptsOnlyWhenAsked() {
        let system = FakeSystem()
        let host = controller(system)
        XCTAssertEqual(host.status(prompt: false), InputHostStatus(trusted: true, secureInput: false))
        system.secureInput = true
        system.trusted = false
        XCTAssertEqual(host.status(prompt: true), InputHostStatus(trusted: false, secureInput: true))
        XCTAssertEqual(system.prompts, [false, true])
    }

    func testAccessibilityInsertionVerifiedByCount() {
        let system = FakeSystem()
        let host = controller(system)
        let token = try! XCTUnwrap(host.begin().token)
        XCTAssertEqual(host.insert("Hello there.", token: token), .typed(12))
        XCTAssertEqual(host.insert(" Café 👍", token: token), .typed(7))
        XCTAssertEqual(system.field?.sets, ["Hello there.", " Café 👍"])
        XCTAssertTrue(system.pasted.isEmpty)
        XCTAssertTrue(system.waits.isEmpty, "A count that changes at once needs no recheck")
    }

    func testUnchangedCountRechecksOnceThenPastesAndSticks() {
        let system = FakeSystem()
        system.field?.applies = false
        let host = controller(system)
        let token = try! XCTUnwrap(host.begin().token)
        XCTAssertEqual(host.insert("One.", token: token), .pasted(4))
        XCTAssertEqual(system.waits, [InputSessionController.recheckDelay])
        XCTAssertEqual(system.field?.sets, ["One."])
        XCTAssertEqual(host.insert(" Two.", token: token), .pasted(5))
        XCTAssertEqual(system.field?.sets, ["One."], "Paste sticks for the rest of the session")
        XCTAssertEqual(system.pasted, ["One.", " Two."])
        system.field?.applies = true
        let next = try! XCTUnwrap(host.begin().token)
        XCTAssertEqual(host.insert("Three.", token: next), .typed(6), "A new session tries Accessibility again")
    }

    func testLateCountChangeWithinRecheckIsTyped() {
        let system = FakeSystem()
        system.field?.applies = false
        system.field?.appliesLate = true
        let host = controller(system)
        let token = try! XCTUnwrap(host.begin().token)
        XCTAssertEqual(host.insert("Later.", token: token), .typed(6))
        XCTAssertTrue(system.pasted.isEmpty, "A late but in-time update is not pasted twice")
    }

    func testNoFocusedElementOrNoCountPastes() {
        let system = FakeSystem()
        system.field = nil
        let host = controller(system)
        let token = try! XCTUnwrap(host.begin().token)
        XCTAssertEqual(host.insert("Chrome.", token: token), .pasted(7), "Chrome and Electron expose no element; paste")
        let counted = FakeSystem()
        counted.field?.count = nil
        let other = controller(counted)
        let second = try! XCTUnwrap(other.begin().token)
        XCTAssertEqual(other.insert("x", token: second), .pasted(1))
        XCTAssertEqual(counted.field?.sets, [], "Without a count Accessibility cannot be verified, so it is not tried")
    }

    func testSelectionIsReplacedByPasteNotAccessibility() {
        let system = FakeSystem()
        system.field?.selection = 5
        let host = controller(system)
        let token = try! XCTUnwrap(host.begin().token)
        XCTAssertEqual(host.insert("hello", token: token), .pasted(5))
        XCTAssertEqual(system.field?.sets, [])
        system.field?.selection = 0
        XCTAssertEqual(host.insert(" again", token: token), .typed(6), "A selection does not make paste sticky")
    }

    func testRefusals() {
        let system = FakeSystem()
        let host = controller(system)
        let token = try! XCTUnwrap(host.begin().token)
        system.secureInput = true
        XCTAssertEqual(host.insert("pw", token: token), .refused(.secureInput))
        system.secureInput = false
        system.field?.subrole = InputSessionController.secureRole
        XCTAssertEqual(host.insert("pw", token: token), .refused(.secureField))
        system.field?.subrole = nil
        system.field?.role = InputSessionController.secureRole
        XCTAssertEqual(host.insert("pw", token: token), .refused(.secureField))
        system.field?.role = "AXTextField"
        system.target = InputTarget(pid: 43, launchDate: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(host.insert("x", token: token), .refused(.appChanged))
        system.target = InputTarget(pid: 42, launchDate: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(host.insert("x", token: token), .refused(.appChanged), "A relaunched app reusing the pid is a different app")
        system.target = InputTarget(pid: 42, launchDate: Date(timeIntervalSince1970: 100))
        system.trusted = false
        XCTAssertEqual(host.insert("x", token: token), .refused(.notTrusted))
        system.trusted = true
        XCTAssertEqual(host.insert(String(repeating: "a", count: InputPhrasePolicy.maximumUTF16 + 1), token: token), .refused(.tooLong))
        XCTAssertTrue(system.pasted.isEmpty)
        XCTAssertEqual(system.field?.sets, [], "Nothing is typed by a refused insertion")
        XCTAssertEqual(host.insert("ok", token: token), .typed(2))
    }

    /// Even when the frontmost app still reads as the target, a focused element owned by another
    /// process is not typed into.
    func testFocusedElementFromAnotherAppIsRefused() {
        let system = FakeSystem()
        let host = controller(system)
        let token = try! XCTUnwrap(host.begin().token)
        system.field?.pid = 99
        XCTAssertEqual(host.insert("x", token: token), .refused(.appChanged))
        XCTAssertEqual(system.field?.sets, [])
        system.field?.pid = nil
        XCTAssertEqual(host.insert("x", token: token), .typed(1), "An element whose owner cannot be read relies on the frontmost check")
    }

    func testBeginRefusesWithoutTrustOrTarget() {
        let system = FakeSystem()
        system.trusted = false
        XCTAssertEqual(controller(system).begin(), InputSessionStart(refusal: .notTrusted))
        system.trusted = true
        system.target = nil
        XCTAssertEqual(controller(system).begin(), InputSessionStart(refusal: .noTarget))
        system.target = InputTarget(pid: 7, launchDate: nil)
        XCTAssertEqual(controller(system, caller: 7).begin(), InputSessionStart(refusal: .noTarget), "Volant never types into itself")
    }

    func testStaleTokens() {
        let system = FakeSystem()
        let host = controller(system)
        let first = try! XCTUnwrap(host.begin().token)
        let second = try! XCTUnwrap(host.begin().token)
        XCTAssertEqual(host.insert("x", token: first), .refused(.staleSession), "A new session replaces the old one")
        XCTAssertEqual(host.insert("x", token: Data([9])), .refused(.staleSession))
        host.end(token: first)
        XCTAssertTrue(host.hasSession, "Ending with a stale token changes nothing")
        XCTAssertEqual(host.insert("x", token: second), .typed(1))
        clock += InputSessionController.idleLimit + 1
        XCTAssertEqual(host.insert("x", token: second), .refused(.staleSession), "An idle session expires")
        XCTAssertFalse(host.hasSession)
        let third = try! XCTUnwrap(host.begin().token)
        for _ in 0..<13 {
            clock += InputSessionController.idleLimit - 1
            _ = host.insert("x", token: third)
        }
        XCTAssertEqual(host.insert("x", token: third), .refused(.staleSession), "Sessions have a fixed lifetime")
        let fourth = try! XCTUnwrap(host.begin().token)
        host.end(token: fourth)
        XCTAssertEqual(host.insert("x", token: fourth), .refused(.staleSession), "An ended token cannot be reused")
    }

    func testFailedPasteIsReported() {
        let system = FakeSystem()
        system.field = nil
        system.pasteWorks = false
        let host = controller(system)
        let token = try! XCTUnwrap(host.begin().token)
        XCTAssertEqual(host.insert("x", token: token), .failed)
    }

    func testPhrasePolicy() {
        XCTAssertEqual(InputPhrasePolicy.sanitize("a\u{0}b\u{7}c\nd\te\u{1B}[0m\u{7F}"), "abc\nd\te[0m")
        XCTAssertEqual(InputPhrasePolicy.sanitize("Café 👍 مرحبا"), "Café 👍 مرحبا")
        XCTAssertEqual(InputPhrasePolicy.sanitize("line\r\nnext"), "line\nnext")
        XCTAssertNotNil(InputPhrasePolicy.sanitize(String(repeating: "a", count: InputPhrasePolicy.maximumUTF16)))
        XCTAssertNil(InputPhrasePolicy.sanitize(String(repeating: "👍", count: InputPhrasePolicy.maximumUTF16 / 2 + 1)))
    }

    func testRandomTokensAreLongAndDistinct() {
        let a = InputSessionController.randomToken()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, InputSessionController.randomToken())
    }

    /// The XPC replies decode from the JSON the helper sends, so both sides agree on the shape.
    func testRepliesRoundTripAsJSON() throws {
        let values: [InputInsertion] = [.typed(3), .pasted(4), .refused(.secureField), .failed]
        for value in values {
            XCTAssertEqual(try JSONDecoder().decode(InputInsertion.self, from: JSONEncoder().encode(value)), value)
        }
        let start = InputSessionStart(token: Data([1, 2]))
        XCTAssertEqual(try JSONDecoder().decode(InputSessionStart.self, from: JSONEncoder().encode(start)), start)
        let status = InputHostStatus(trusted: true, secureInput: false)
        XCTAssertEqual(try JSONDecoder().decode(InputHostStatus.self, from: JSONEncoder().encode(status)), status)
    }

    /// The XPC protocol stays narrow: exactly these four methods, none taking key codes, pids or
    /// attribute names, and none replying with text from another app.
    func testProtocolShape() {
        var count: UInt32 = 0
        guard let list = protocol_copyMethodDescriptionList(VolantInputHostProtocol.self, true, true, &count) else {
            return XCTFail("No methods")
        }
        defer { free(list) }
        let names = Set((0..<Int(count)).compactMap { list[$0].name.map(NSStringFromSelector) })
        XCTAssertEqual(names, ["accessibilityStatusWithPrompt:reply:", "beginSessionWithReply:",
                               "insertWithPhrase:token:reply:", "endSessionWithToken:"])
        XCTAssertEqual(InputHostService.name, "com.mysticcoders.volant.InputHost")
        XCTAssertTrue(InputHostService.callerRequirement.contains("identifier \"com.mysticcoders.volant\""))
        XCTAssertTrue(InputHostService.callerRequirement.contains("REMBT6JY4N"))
    }
}
