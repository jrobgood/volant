import CryptoKit
import XCTest
import VolantCore

@testable import Volant

/// Settings' Accessibility state and the temporary Return key, with fakes only: no helper is
/// launched, nothing prompts and no hotkey is registered.
final class DictationTypingTests: XCTestCase {
    final class FakeClient: InputHostClient {
        var statusCalls: [Bool] = []
        var replies: [(InputHostStatus?) -> Void] = []
        var disconnects = 0
        var sessions = 0

        func status(prompt: Bool, completion: @escaping (InputHostStatus?) -> Void) {
            statusCalls.append(prompt)
            replies.append(completion)
        }
        func beginSession(completion: @escaping (InputSessionStart?) -> Void) { sessions += 1 }
        func insert(phrase: String, token: Data, completion: @escaping (InputInsertion?) -> Void) { XCTFail("Settings never types") }
        func endSession(token: Data) {}
        func disconnect() { disconnects += 1 }
    }

    func testCopyNeverTouchesTheHelper() {
        let client = FakeClient()
        let access = DictationTypingAccess(client: client)
        access.refresh(.copy)
        access.refresh(.copy)
        XCTAssertTrue(client.statusCalls.isEmpty, "Copy to clipboard must never check Accessibility, which adds a Privacy entry on macOS 15")
        XCTAssertEqual(client.sessions, 0)
        XCTAssertEqual(access.state, .idle)
        XCTAssertFalse(access.stoppedHelper)
    }

    func testChoosingTypePromptsOnceAndLaterVisitsDoNot() {
        let client = FakeClient()
        let access = DictationTypingAccess(client: client)
        access.chose(.type)
        XCTAssertEqual(client.statusCalls, [true], "Choosing Type at the cursor is what asks")
        XCTAssertEqual(access.state, .checking)
        access.refresh(.type)
        XCTAssertEqual(client.statusCalls, [true], "No second check while one is in flight")
        client.replies[0](InputHostStatus(trusted: false, secureInput: false))
        XCTAssertEqual(access.state, .notAllowed)
        access.refresh(.type)
        XCTAssertEqual(client.statusCalls, [true, false], "Returning from System Settings checks without prompting")
        XCTAssertEqual(client.disconnects, 1, "A fresh helper answers the recheck")
        client.replies[1](InputHostStatus(trusted: true, secureInput: false))
        XCTAssertEqual(access.state, .allowed)
    }

    func testUnavailableHelperAndBusyDictation() {
        let client = FakeClient()
        var busy = true
        let access = DictationTypingAccess(client: client, canReconnect: { !busy })
        access.refresh(.type)
        XCTAssertEqual(client.disconnects, 0, "A dictation using the helper keeps its connection")
        client.replies[0](nil)
        XCTAssertEqual(access.state, .unavailable)
        busy = false
        access.refresh(.type)
        XCTAssertEqual(client.disconnects, 1)
    }

    func testChoosingCopyStopsTheHelperAndIgnoresLateReplies() {
        let client = FakeClient()
        let access = DictationTypingAccess(client: client)
        access.chose(.type)
        access.chose(.copy)
        XCTAssertEqual(client.disconnects, 1, "Turning typing off stops the helper")
        XCTAssertTrue(access.stoppedHelper, "Settings then explains how to remove the grant")
        client.replies[0](InputHostStatus(trusted: true, secureInput: false))
        XCTAssertEqual(access.state, .idle, "A reply after switching back to copy is ignored")
        access.chose(.type)
        XCTAssertFalse(access.stoppedHelper)
    }

    func testReturnRegisteredOnlyWhileListeningAndTyping() {
        var registered: [UInt32: (KeyCombo, () -> Void)] = [:]
        var unregistered: [UInt32] = []
        var next: UInt32 = 1
        var finished = 0
        let keys = DictationEscapeKey(register: { combo, handler in
            defer { next += 1 }
            registered[next] = (combo, handler)
            return next
        }, unregister: { id in
            unregistered.append(id)
            registered[id] = nil
        })
        keys.update(listening: true, finishesOnReturn: false, onEscape: {}, onReturn: { finished += 1 })
        XCTAssertFalse(keys.isReturnRegistered, "Copying dictation leaves Return to the frontmost app")
        XCTAssertEqual(registered.values.map(\.0), [DictationEscapeKey.combo])
        keys.update(listening: true, finishesOnReturn: true, onEscape: {}, onReturn: { finished += 1 })
        XCTAssertTrue(keys.isReturnRegistered)
        let returnEntry = registered.first { $0.value.0 == KeyCombo(keyCode: 36, carbonModifiers: 0) }
        XCTAssertNotNil(returnEntry, "Only unmodified Return")
        returnEntry?.value.1()
        XCTAssertEqual(finished, 1)
        keys.update(listening: true, finishesOnReturn: true, onEscape: {}, onReturn: {})
        XCTAssertEqual(registered.count, 2, "Repeated updates keep one registration each")
        keys.update(listening: false, finishesOnReturn: true, onEscape: {}, onReturn: {})
        XCTAssertFalse(keys.isReturnRegistered)
        XCTAssertFalse(keys.isRegistered)
        XCTAssertTrue(registered.isEmpty, "Both keys are removed as soon as listening ends")
        XCTAssertEqual(unregistered.count, 2)
    }

    func testIndicatorHintNamesOnlyRegisteredKeys() {
        XCTAssertEqual(DictationIndicatorText.keyHint(escape: true, return: true), ". Return finishes, Escape cancels.")
        XCTAssertEqual(DictationIndicatorText.keyHint(escape: true, return: false), ". Escape cancels.")
        XCTAssertEqual(DictationIndicatorText.keyHint(escape: false, return: true), ". Return finishes.")
        XCTAssertEqual(DictationIndicatorText.keyHint(escape: false, return: false), ".")
    }

    /// A launcher model with no input host copies; one is set only by the app delegate.
    func testLauncherModelHasNoInputHostByDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("volant-typing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LauncherModel(index: AppIndex(entries: []),
                                  clipboard: ClipboardStore(retention: 1, storageURL: root.appendingPathComponent("clips.sqlite"), encryptionKey: SymmetricKey(size: .bits256)),
                                  notes: NotesStore(directory: root.appendingPathComponent("Notes")), config: Preferences(),
                                  usage: UsageStore(url: root.appendingPathComponent("usage.sqlite"))) { _ in }
        XCTAssertNil(model.inputHost)
        XCTAssertFalse(model.dictationTypesAtCursor)
    }
}
