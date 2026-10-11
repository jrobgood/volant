import AppKit
import ApplicationServices
import Carbon.HIToolbox
import OSLog
import VolantCore

/// The focused element through Accessibility. It reads only the role, subrole, character count
/// and selection length, and writes only the selected text. It never reads the element's value.
final class AccessibilityField: InputField {
    private let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    var pid: Int32? {
        var owner: pid_t = 0
        return AXUIElementGetPid(element, &owner) == .success ? owner : nil
    }
    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }

    func characterCount() -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success else { return nil }
        return value as? Int
    }

    func selectionLength() -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.length
    }

    func setSelectedText(_ text: String) {
        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
    }

    /// A string attribute that names what the element is, never its contents.
    private func string(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

/// The real system calls behind `InputSessionController`: trust, secure input, the frontmost app,
/// the focused element, and a marked paste that restores the owner's clipboard.
final class SystemInput: InputSystem {
    static let logger = Logger(subsystem: "com.mysticcoders.volant", category: "InputHost")
    static let messagingTimeout: Float = 1.0
    static let pasteDelay: TimeInterval = 0.1
    static let restoreDelay: TimeInterval = 0.25
    static let restoreLimit = 32 * 1024 * 1024

    func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func isSecureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// The app in front, confirmed by its own Accessibility element reporting `AXFrontmost`.
    ///
    /// Two shortcuts failed in the VM run of this service: system-wide Accessibility queries
    /// (focused application and focused element) always returned `kAXErrorCannotComplete`, and
    /// `NSWorkspace.frontmostApplication` stayed on the app that was in front when the service
    /// started, so a switch to Finder went unnoticed. Candidates therefore come from NSWorkspace,
    /// the on-screen window order and the running regular apps, and the first one whose own
    /// element says it is frontmost wins. The launch date is looked up fresh, so a relaunched app
    /// that reuses the pid is a different target.
    func frontmostTarget() -> InputTarget? {
        guard let pid = Self.frontmostCandidates().first(where: Self.isFrontmost) else { return nil }
        return InputTarget(pid: pid, launchDate: NSRunningApplication(processIdentifier: pid)?.launchDate)
    }

    /// The focused element of the app in front, read from that app's own element. Chrome and
    /// Electron expose none until their accessibility tree is turned on, which the helper never does.
    func focusedField() -> InputField? {
        guard let pid = frontmostTarget()?.pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        return element(app, kAXFocusedUIElementAttribute).map(AccessibilityField.init)
    }

    /// Possible frontmost apps, most likely first, without duplicates.
    private static func frontmostCandidates() -> [pid_t] {
        var pids: [pid_t] = []
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { pids.append(pid) }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        for window in (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? [] {
            guard (window[kCGWindowLayer as String] as? Int) == 0, let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            pids.append(pid)
        }
        pids += NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)
        var seen = Set<pid_t>()
        return pids.filter { seen.insert($0).inserted }
    }

    /// Whether the app's own Accessibility element reports that it is frontmost.
    private static func isFrontmost(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) == true
    }

    /// An attribute whose value is another element, such as the focused element or app. Failures
    /// are logged by attribute name and error code only.
    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            Self.logger.info("\(attribute, privacy: .public) unavailable: AXError \(error.rawValue, privacy: .public)")
            return nil
        }
        return (value as! AXUIElement)
    }

    /// Saves the general pasteboard, writes the phrase with transient, concealed and session
    /// markers, posts Command-V with physical key codes, and after `restoreDelay` puts the saved
    /// contents back, marked transient, only if the pasteboard still holds this write. A
    /// snapshot larger than `restoreLimit` is not kept, and the phrase stays on the clipboard.
    func paste(_ text: String) -> Bool {
        let board = NSPasteboard.general
        let snapshot = Self.snapshot(board)
        let marker = UUID().uuidString
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        Self.mark(item, session: marker)
        guard board.writeObjects([item]) else { return false }
        let written = board.changeCount
        wait(Self.pasteDelay)
        guard Self.postCommandV() else { return false }
        wait(Self.restoreDelay)
        if let snapshot, board.changeCount == written {
            board.clearContents()
            let items = snapshot.map { types -> NSPasteboardItem in
                let restored = NSPasteboardItem()
                for (type, data) in types { restored.setData(data, forType: type) }
                Self.mark(restored, session: marker, concealed: false)
                return restored
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
        return true
    }

    func wait(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Every item and type, read eagerly, or nil when the contents are too large to keep.
    private static func snapshot(_ board: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]]? {
        var total = 0
        var items: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in board.pasteboardItems ?? [] {
            var types: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > restoreLimit { return nil }
                types.append((type, data))
            }
            items.append(types)
        }
        return items
    }

    /// The nspasteboard.org markers that keep clipboard managers, including Volant's own history,
    /// from recording a dictation paste or the restore that follows it. Only the dictated phrase
    /// is marked concealed; the owner's restored contents are marked transient, not re-recorded,
    /// and otherwise left as they were.
    private static func mark(_ item: NSPasteboardItem, session: String, concealed: Bool = true) {
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        if concealed { item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
        item.setString(session, forType: NSPasteboard.PasteboardType(PasteboardFilter.dictationSessionType))
    }

    /// Command-V from a private event source, using the physical V key so layouts that remap
    /// under Command still paste.
    private static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        let command = CGKeyCode(kVK_Command)
        let v = CGKeyCode(kVK_ANSI_V)
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false) else { return false }
        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        for event in [commandDown, vDown, vUp, commandUp] { event.post(tap: .cghidEventTap) }
        return true
    }
}
