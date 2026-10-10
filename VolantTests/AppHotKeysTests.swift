import XCTest
@testable import Volant

final class AppHotKeysTests: XCTestCase {
    func testInactiveTargetUsesLaunchServicesIncludingAlreadyRunningApps() {
        let url = URL(fileURLWithPath: "/Applications/Fictional.app")
        var opened: [URL] = []
        var completion: ((Bool) -> Void)?
        var failures: [String] = []
        AppHotKeys.perform(isActive: false, hide: { XCTFail("Must not hide an inactive app"); return false },
                           applicationURL: { url }, open: { target, callback in opened.append(target); completion = callback },
                           onFailure: { failures.append($0) })
        XCTAssertEqual(opened, [url])
        XCTAssertTrue(failures.isEmpty)
        completion?(false)
        XCTAssertEqual(failures.count, 1, "Asynchronous launch failure must not disappear")
    }

    func testFrontmostTargetHidesWithoutReopening() {
        var hidden = 0
        AppHotKeys.perform(isActive: true, hide: { hidden += 1; return true },
                           applicationURL: { XCTFail("No lookup needed to hide"); return nil },
                           open: { _, _ in XCTFail("Must not reopen frontmost app") }, onFailure: { XCTFail($0) })
        XCTAssertEqual(hidden, 1)
    }

    func testMissingApplicationAndRejectedHideReportFailures() {
        var failures: [String] = []
        AppHotKeys.perform(isActive: false, hide: { false }, applicationURL: { nil },
                           open: { _, _ in XCTFail("Cannot launch a missing app") }, onFailure: { failures.append($0) })
        AppHotKeys.perform(isActive: true, hide: { false }, applicationURL: { nil },
                           open: { _, _ in XCTFail("Cannot reopen after failed hide") }, onFailure: { failures.append($0) })
        XCTAssertEqual(failures.count, 2)
        XCTAssertNotEqual(failures[0], failures[1])
    }

    func testSavedCopyWinsUntilItIsGoneOrReplaced() {
        let beta = "/Applications/Beta/Fictional.app"
        let installed = [beta: "fixture.fictional", "/Applications/Other.app": "fixture.other"]
        XCTAssertEqual(AppHotKeys.configuredPath(beta, bundleID: "fixture.fictional") { installed[$0] }, beta)
        XCTAssertNil(AppHotKeys.configuredPath("/Applications/Moved.app", bundleID: "fixture.fictional") { installed[$0] },
                     "a missing copy falls back to the bundle identifier")
        XCTAssertNil(AppHotKeys.configuredPath("/Applications/Other.app", bundleID: "fixture.fictional") { installed[$0] },
                     "a different application at the saved path is never opened")
        XCTAssertNil(AppHotKeys.configuredPath(nil, bundleID: "fixture.fictional") { installed[$0] })
    }

    func testRunningProcessMustBeTheConfiguredCopy() {
        struct Process: Equatable { let url: URL?; let active: Bool }
        let release = Process(url: URL(fileURLWithPath: "/Applications/Fictional.app"), active: true)
        let beta = Process(url: URL(fileURLWithPath: "/Applications/Beta/Fictional.app"), active: false)
        XCTAssertEqual(AppHotKeys.matchingCopy([release, beta], path: "/Applications/Beta/Fictional.app") { $0.url }, beta,
                       "the frontmost release copy is neither hidden nor focused for a beta shortcut")
        XCTAssertNil(AppHotKeys.matchingCopy([release], path: "/Applications/Beta/Fictional.app") { $0.url },
                     "only another copy running means the configured copy must be opened")
        XCTAssertEqual(AppHotKeys.matchingCopy([release, beta], path: nil) { $0.url }, release, "legacy entries keep bundle-identifier behavior")
    }

    func testSuccessfulOpenDoesNotReportFailure() {
        AppHotKeys.perform(isActive: false, hide: { false }, applicationURL: { URL(fileURLWithPath: "/Fixture.app") },
                           open: { _, completion in completion(true) }, onFailure: { XCTFail($0) })
    }
}
