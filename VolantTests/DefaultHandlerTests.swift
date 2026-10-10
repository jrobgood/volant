import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import Volant

/// Records handler requests and never touches Launch Services, so no app is launched and no URL is opened.
private final class FakeWorkspace: HandlerWorkspace {
    var urlHandlers: [String: URL] = [:]
    var typeHandlers: [String: URL] = [:]
    var installed: [String: URL] = [:]
    var opened: [(URL, URL)] = []
    var launched: [URL] = []

    func defaultApplication(toOpen url: URL) -> URL? { urlHandlers[url.scheme ?? ""] }
    func defaultApplication(toOpen type: UTType) -> URL? { typeHandlers[type.identifier] }
    func application(withBundleIdentifier identifier: String) -> URL? { installed[identifier] }
    func open(_ url: URL, withApplication application: URL) async throws { opened.append((url, application)) }
    func launch(application: URL) async throws { launched.append(application) }
}

@MainActor final class DefaultHandlerTests: XCTestCase {
    private let apple = URL(fileURLWithPath: "/Applications/Fictional Apple.app")
    private let chosen = URL(fileURLWithPath: "/Applications/Fictional Chosen.app")

    /// Waits for work the code under test hands to an unstructured task.
    private func settle(_ done: () -> Bool) async throws {
        for _ in 0..<100 where !done() { try await Task.sleep(for: .milliseconds(5)) }
    }

    func testDictionaryPrefersRegisteredHandlerAndFallsBackToApple() async throws {
        let workspace = FakeWorkspace()
        workspace.installed[DefaultHandler.dictionaryBundleIdentifier] = apple
        workspace.urlHandlers["dict"] = chosen
        try await DictionaryApplication.open("fictional term", workspace: workspace)
        XCTAssertEqual(workspace.opened.map(\.1), [chosen])
        XCTAssertEqual(workspace.opened.first?.0.scheme, "dict")

        workspace.urlHandlers = [:]
        try await DictionaryApplication.open("fictional term", workspace: workspace)
        XCTAssertEqual(workspace.opened.map(\.1), [chosen, apple])

        workspace.installed = [:]
        do {
            try await DictionaryApplication.open("fictional term", workspace: workspace)
            XCTFail("Expected a missing-application error")
        } catch {}
        XCTAssertEqual(workspace.opened.count, 2)
    }

    func testCalendarPrefersUserChoiceAndOtherwiseOpensAppleCalendar() throws {
        let workspace = FakeWorkspace()
        XCTAssertNil(DefaultHandler.calendarApplication(workspace: workspace))
        workspace.installed[DefaultHandler.calendarBundleIdentifier] = apple
        XCTAssertEqual(DefaultHandler.calendarApplication(workspace: workspace), apple)
        workspace.urlHandlers["webcal"] = chosen
        XCTAssertEqual(DefaultHandler.calendarApplication(workspace: workspace), chosen)
        workspace.urlHandlers = [:]
        let ics = try XCTUnwrap(UTType(filenameExtension: "ics"))
        workspace.typeHandlers[ics.identifier] = chosen
        XCTAssertEqual(DefaultHandler.calendarApplication(workspace: workspace), chosen)
    }

    func testEventOpensJoinLinkHandlerOrCalendarApp() async throws {
        let workspace = FakeWorkspace()
        workspace.installed[DefaultHandler.calendarBundleIdentifier] = apple
        workspace.urlHandlers["webcal"] = chosen
        let start = Date(timeIntervalSince1970: 0)
        let plain = EventEntry(id: "a", title: "Fictional", start: start, end: start, isAllDay: false, joinURL: nil, calendar: "Work")
        CalendarAgenda.open(plain, workspace: workspace)
        try await settle { !workspace.launched.isEmpty }
        XCTAssertEqual(workspace.launched, [chosen])

        let link = try XCTUnwrap(URL(string: "https://meet.example.invalid/fictional"))
        workspace.urlHandlers["https"] = chosen
        let meeting = EventEntry(id: "b", title: "Fictional", start: start, end: start, isAllDay: false, joinURL: link, calendar: "Work")
        CalendarAgenda.open(meeting, workspace: workspace)
        try await settle { !workspace.opened.isEmpty }
        XCTAssertEqual(workspace.opened.map(\.0), [link])
        XCTAssertEqual(workspace.opened.map(\.1), [chosen])
        XCTAssertEqual(workspace.launched.count, 1)
    }

    func testQuicklinkUsesResolvedHandlerAndReportsMissingHandler() async throws {
        let workspace = FakeWorkspace()
        let link = try XCTUnwrap(URL(string: "https://example.invalid/search?q=fictional"))
        XCTAssertFalse(QuicklinkResolver.open(link, workspace: workspace))
        workspace.urlHandlers["https"] = chosen
        XCTAssertTrue(QuicklinkResolver.open(link, workspace: workspace))
        try await settle { !workspace.opened.isEmpty }
        XCTAssertEqual(workspace.opened.map(\.0), [link])
        XCTAssertEqual(workspace.opened.map(\.1), [chosen])
    }
}
