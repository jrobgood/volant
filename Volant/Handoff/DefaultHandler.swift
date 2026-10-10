import AppKit
import UniformTypeIdentifiers

/// The Launch Services calls used to choose and start a handler. Tests substitute a fake so nothing is launched.
protocol HandlerWorkspace {
    func defaultApplication(toOpen url: URL) -> URL?
    func defaultApplication(toOpen type: UTType) -> URL?
    func application(withBundleIdentifier identifier: String) -> URL?
    func open(_ url: URL, withApplication application: URL) async throws
    func launch(application: URL) async throws
}

extension NSWorkspace: HandlerWorkspace {
    func defaultApplication(toOpen url: URL) -> URL? { urlForApplication(toOpen: url) }
    func defaultApplication(toOpen type: UTType) -> URL? { urlForApplication(toOpen: type) }
    func application(withBundleIdentifier identifier: String) -> URL? { urlForApplication(withBundleIdentifier: identifier) }

    /// Opens `url` in the given application, surfacing a Launch Services failure to the caller.
    func open(_ url: URL, withApplication application: URL) async throws {
        _ = try await open([url], withApplicationAt: application, configuration: OpenConfiguration())
    }

    /// Launches or activates the given application without opening a document.
    func launch(application: URL) async throws {
        _ = try await openApplication(at: application, configuration: OpenConfiguration())
    }
}

/// Opens content in the user's chosen application. Apple's own app is used only when no handler is registered.
enum DefaultHandler {
    static let calendarBundleIdentifier = "com.apple.iCal"
    static let dictionaryBundleIdentifier = "com.apple.Dictionary"

    /// The application Launch Services picks for `url`, including a site-specific handler, else the named fallback.
    static func application(for url: URL, fallback: String? = nil, workspace: HandlerWorkspace = NSWorkspace.shared) -> URL? {
        workspace.defaultApplication(toOpen: url) ?? fallback.flatMap { workspace.application(withBundleIdentifier: $0) }
    }

    /// The user's calendar app: the handler for calendar files, then for webcal links, then Apple Calendar.
    static func calendarApplication(workspace: HandlerWorkspace = NSWorkspace.shared) -> URL? {
        let types = [UTType(filenameExtension: "ics"), UTType.calendarEvent].compactMap { $0 }
        for type in types {
            if let application = workspace.defaultApplication(toOpen: type) { return application }
        }
        if let webcal = URL(string: "webcal://localhost/calendar.ics"),
           let application = workspace.defaultApplication(toOpen: webcal) { return application }
        return workspace.application(withBundleIdentifier: calendarBundleIdentifier)
    }

    /// Opens `url` in its handler or the fallback app, and throws when neither is installed.
    static func open(_ url: URL, fallback: String? = nil, workspace: HandlerWorkspace = NSWorkspace.shared) async throws {
        guard let application = application(for: url, fallback: fallback, workspace: workspace) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try await workspace.open(url, withApplication: application)
    }

    /// Launches the user's calendar app, and throws when no calendar app is installed.
    static func openCalendar(workspace: HandlerWorkspace = NSWorkspace.shared) async throws {
        guard let application = calendarApplication(workspace: workspace) else { throw CocoaError(.fileNoSuchFile) }
        try await workspace.launch(application: application)
    }
}
