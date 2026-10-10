import AppKit
import OSLog
import VolantCore

/// Per-app hotkeys: press once to activate or launch, press again while frontmost to hide.
enum AppHotKeys {
    private static let logger = Logger(subsystem: "com.mysticcoders.volant", category: "AppShortcuts")

    @discardableResult
    static func register(_ entries: [AppHotKey], onFailure: @escaping (String) -> Void = { _ in }) -> [String] {
        var failures: [String] = []
        for entry in entries {
            guard let combo = KeyCombo(parsing: entry.hotKey) else { failures.append("Invalid shortcut for " + entry.bundleIdentifier); continue }
            let bundleID = entry.bundleIdentifier
            let path = entry.path
            if HotKeyCenter.shared.register(combo, handler: {
                toggle(bundleID, path: path) { message in onFailure(bundleID + ": " + message) }
            }) == nil {
                failures.append("Shortcut unavailable: " + KeyCombo.display(entry.hotKey) + " (" + bundleID + ")")
            }
        }
        return failures
    }

    /// Activates, launches or hides the configured application copy. A saved path wins over Launch Services'
    /// choice among copies sharing a bundle identifier; the bundle identifier is used only for legacy entries
    /// or when the saved copy is gone or now holds a different application.
    static func toggle(_ bundleID: String, path: String? = nil, onFailure: @escaping (String) -> Void = { _ in }) {
        let configured = configuredPath(path, bundleID: bundleID) { Bundle(url: URL(fileURLWithPath: $0))?.bundleIdentifier }
        if path != nil && configured == nil { logger.notice("App shortcut copy unavailable; using bundle identifier") }
        let running = matchingCopy(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID), path: configured) { $0.bundleURL }
        logger.notice("App shortcut delivered; running=\(running != nil), active=\(running?.isActive == true)")
        perform(isActive: running?.isActive == true, hide: { running?.hide() == true }, applicationURL: {
            running?.bundleURL ?? configured.map { URL(fileURLWithPath: $0) } ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }, open: { url, completion in
            // Launch Services also sends reopen to an existing process, restoring its windows.
            // activate() alone can leave a running app invisible and silently reject focus.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.hides = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
                DispatchQueue.main.async {
                    completion(application != nil && error == nil)
                }
            }
        }, onFailure: { message in
            logger.error("App shortcut failed: \(message, privacy: .public)")
            NSSound.beep()
            onFailure(message)
        })
    }

    /// The saved copy's path when it still holds the same application, otherwise nil so the caller falls back
    /// to the bundle identifier. The injected lookup keeps tests away from real bundles.
    static func configuredPath(_ path: String?, bundleID: String, bundleIdentifierAt: (String) -> String?) -> String? {
        guard let path, !path.isEmpty, bundleIdentifierAt(path) == bundleID else { return nil }
        return path
    }

    /// The running process for the configured copy. Without a saved path any process with the bundle
    /// identifier qualifies; with one, another copy's process is ignored so it is neither hidden nor focused.
    static func matchingCopy<Process>(_ candidates: [Process], path: String?, bundleURL: (Process) -> URL?) -> Process? {
        guard let path else { return candidates.first }
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return candidates.first { bundleURL($0)?.resolvingSymlinksInPath().standardizedFileURL.path == target }
    }

    /// Keep OS handoff injectable: logic tests must never launch or hide the owner's apps.
    static func perform(isActive: Bool, hide: () -> Bool, applicationURL: () -> URL?,
                        open: (URL, @escaping (Bool) -> Void) -> Void, onFailure: @escaping (String) -> Void) {
        if isActive {
            if !hide() { onFailure("macOS could not hide the application.") }
            return
        }
        guard let url = applicationURL() else {
            onFailure("Application not found. Check its shortcut in Settings.")
            return
        }
        open(url) { succeeded in
            if !succeeded { onFailure("macOS could not open the application. Try opening it from Finder.") }
        }
    }
}
