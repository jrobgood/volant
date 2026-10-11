import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import Security

// SPIKE ONLY. Not shipped, not part of any app target. See docs/input-host-spike.md.
//
// Unsandboxed XPC service embedded in the sandboxed spike app. It stands in for the proposed
// VolantInputHost so the guest can measure which bundle TCC charges its Accessibility and
// Input Monitoring checks to, and how each insertion method behaves in real apps.

/// Text helpers shared by the probes below.
enum Describe {
    /// Path of a process, or a placeholder when it cannot be read.
    static func path(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "?"
    }

    /// Responsible process as reported by the private responsibility SPI, used only to explain
    /// which process TCC is likely to attribute a check to.
    static func responsible(_ pid: pid_t) -> String {
        typealias Lookup = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return "SPI unavailable"
        }
        let owner = unsafeBitCast(symbol, to: Lookup.self)(pid)
        return "\(owner) \(path(owner))"
    }

    /// One line per fact about this process's own TCC-relevant state. Never prompts.
    static func trustLines(prefix: String) -> [String] {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        return [
            "\(prefix).pid=\(getpid()) path=\(path(getpid()))",
            "\(prefix).responsible=\(responsible(getpid()))",
            "\(prefix).sandboxed=\(sandboxed)",
            "\(prefix).AXIsProcessTrustedWithOptions(prompt:false)=\(AXIsProcessTrustedWithOptions(options))",
            "\(prefix).CGPreflightListenEventAccess=\(CGPreflightListenEventAccess())",
            "\(prefix).CGPreflightPostEventAccess=\(CGPreflightPostEventAccess())",
            "\(prefix).IsSecureEventInputEnabled=\(IsSecureEventInputEnabled())",
        ]
    }
}

/// Accessibility reads used by the probes.
enum AX {
    /// String value of an attribute, or nil.
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// The focused element, read system-wide first and then through the frontmost application
    /// (the system-wide read can fail with kAXErrorCannotComplete), or the last AXError.
    static func focusedElement() -> (AXUIElement?, AXError) {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 2.0)
        var value: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        if error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() { return ((value as! AXUIElement), error) }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return (nil, error) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2.0)
        value = nil
        error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil, error) }
        return ((value as! AXUIElement), error)
    }

    /// kAXNumberOfCharactersAttribute, which can confirm an insertion without reading any text.
    static func characterCount(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value) == .success else { return nil }
        return value as? Int
    }

    /// Bundle identifier of the app that owns `element`.
    static func owner(_ element: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "pid \(pid)"
    }

    /// Short description of the focused element, including whether selected text is settable.
    static func describeFocused() -> String {
        let (element, error) = focusedElement()
        guard let element else { return "focused=none AXError=\(error.rawValue)" }
        var settable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return "focused app=\(owner(element)) role=\(string(element, kAXRoleAttribute) ?? "-") "
            + "subrole=\(string(element, kAXSubroleAttribute) ?? "-") "
            + "selectedTextSettable=\(settable.boolValue)(AXError \(settableError.rawValue)) "
            + "secureInput=\(IsSecureEventInputEnabled())"
    }

    /// Depth-first search under the focused application's focused window for a static text
    /// whose value starts with `prefix`.
    static func staticText(prefix: String) -> String? {
        let (element, _) = focusedElement()
        guard let element else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var stack = [window as! AXUIElement]
        var visited = 0
        while let node = stack.popLast(), visited < 5000 {
            visited += 1
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let text = string(node, attribute), text.hasPrefix(prefix) { return text }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                stack.append(contentsOf: list.reversed())
            }
        }
        return nil
    }
}

/// Synthesized keyboard input.
enum Keys {
    /// Posts a key down and key up at the HID tap.
    static func press(_ code: CGKeyCode, flags: CGEventFlags = [], source: CGEventSource?) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Command-V using physical key codes, so layouts that remap under Command still paste.
    static func paste() {
        let source = CGEventSource(stateID: .privateState)
        let command = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        command?.flags = .maskCommand
        command?.post(tap: .cghidEventTap)
        press(0x09, flags: .maskCommand, source: source)
        let release = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
        release?.post(tap: .cghidEventTap)
    }

    /// Types `text` one grapheme per key event with CGEventKeyboardSetUnicodeString.
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            let units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
                event.post(tap: .cghidEventTap)
            }
            usleep(4_000)
        }
    }
}

/// General pasteboard snapshot, marked write and guarded restore, as the design proposes.
enum Clipboard {
    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    /// Copies every item and type eagerly.
    static func snapshot(_ board: NSPasteboard) -> Snapshot {
        (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    /// Writes `text` with transient, concealed and session markers; returns the change count.
    static func writeMarked(_ text: String, session: String, to board: NSPasteboard) -> Int {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString(session, forType: NSPasteboard.PasteboardType("com.mysticcoders.volant.dictation-session"))
        board.writeObjects([item])
        return board.changeCount
    }

    /// Restores `snapshot` only if the board still holds this session's write.
    static func restore(_ snapshot: Snapshot, ifChangeCount expected: Int, on board: NSPasteboard) -> String {
        guard board.changeCount == expected else { return "skipped (changeCount moved)" }
        board.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        return items.isEmpty ? "restored empty" : (board.writeObjects(items) ? "restored" : "restore failed")
    }
}

/// Counts events seen by a tap; passed through the tap's user info pointer.
final class TapCounter {
    var count = 0
}

/// Tap callback: counts key downs and re-enables a tap the system disabled.
private let tapCallback: CGEventTapCallBack = { _, type, event, info in
    if let info { Unmanaged<TapCounter>.fromOpaque(info).takeUnretainedValue().count += 1 }
    return Unmanaged.passUnretained(event)
}

final class InputSpikeHost: NSObject, InputSpikeHostProtocol, NSXPCListenerDelegate {
    /// Requires the caller to be signed by the same team as this service when it has one, as
    /// setCodeSigningRequirement would in the product. Ad-hoc builds skip the check.
    private static let callerRequirement: String? = {
        var code: SecCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if let requirement = Self.callerRequirement { connection.setCodeSigningRequirement(requirement) }
        connection.exportedInterface = NSXPCInterface(with: InputSpikeHostProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { exit(0) }
        connection.resume()
        return true
    }

    func status(reply: @escaping (String) -> Void) {
        reply((Describe.trustLines(prefix: "service") + ["service.callerRequirement=\(Self.callerRequirement ?? "none (ad-hoc)")"]).joined(separator: "\n"))
    }

    func requestAccessibility(reply: @escaping (String) -> Void) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        reply("service.AXIsProcessTrustedWithOptions(prompt:true)=\(AXIsProcessTrustedWithOptions(options))")
    }

    func requestListenAccess(reply: @escaping (String) -> Void) {
        reply("service.CGRequestListenEventAccess=\(CGRequestListenEventAccess())")
    }

    func focused(reply: @escaping (String) -> Void) {
        reply(AX.describeFocused())
    }

    func insert(method: String, phrases: [String], delay: Double, reply: @escaping (String) -> Void) {
        var lines = ["method=\(method) before: \(AX.describeFocused())"]
        let board = NSPasteboard.general
        let session = UUID().uuidString
        for (index, phrase) in phrases.enumerated() {
            let started = Date()
            switch method {
            case "ax":
                let (element, error) = AX.focusedElement()
                guard let element else { lines.append("phrase \(index): no focused element (AXError \(error.rawValue))"); continue }
                let before = AX.characterCount(element)
                let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, phrase as CFString)
                let after = AX.characterCount(element)
                lines.append("phrase \(index): AXUIElementSetAttributeValue(selectedText) AXError=\(result.rawValue) "
                             + "numberOfCharacters \(before.map(String.init) ?? "n/a")->\(after.map(String.init) ?? "n/a")")
            case "paste":
                let saved = Clipboard.snapshot(board)
                let expected = Clipboard.writeMarked(phrase, session: session, to: board)
                usleep(100_000)
                Keys.paste()
                usleep(300_000)
                lines.append("phrase \(index): pasted; clipboard \(Clipboard.restore(saved, ifChangeCount: expected, on: board))")
            case "unicode":
                Keys.type(phrase)
                lines.append("phrase \(index): typed \(phrase.count) graphemes")
            default:
                lines.append("unknown method \(method)")
            }
            lines[lines.count - 1] += String(format: " (%.0f ms)", Date().timeIntervalSince(started) * 1000)
            if index < phrases.count - 1 { Thread.sleep(forTimeInterval: delay) }
        }
        lines.append("after: \(AX.describeFocused())")
        reply(lines.joined(separator: "\n"))
    }

    func readFocused(reply: @escaping (String) -> Void) {
        let (element, error) = AX.focusedElement()
        guard let element else { reply("value=<no focused element AXError \(error.rawValue)>"); return }
        let value = AX.string(element, kAXValueAttribute).map { String($0.suffix(400)) } ?? "<unreadable>"
        reply("value=\(value.debugDescription)")
    }

    func readStaticText(prefix: String, reply: @escaping (String) -> Void) {
        reply("static=\(AX.staticText(prefix: prefix) ?? "<not found>")")
    }

    func enableManualAccessibility(reply: @escaping (String) -> Void) {
        guard let app = NSWorkspace.shared.frontmostApplication else { reply("no frontmost app"); return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let manual = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let enhanced = AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        reply("on \(app.bundleIdentifier ?? "?"): AXManualAccessibility AXError=\(manual.rawValue), AXEnhancedUserInterface AXError=\(enhanced.rawValue)")
    }

    func postKey(code: Int, flags: UInt64, reply: @escaping (String) -> Void) {
        Keys.press(CGKeyCode(code), flags: CGEventFlags(rawValue: flags), source: CGEventSource(stateID: .hidSystemState))
        reply("posted key \(code) flags \(flags)")
    }

    func tapProbe(seconds: Double, reply: @escaping (String) -> Void) {
        let thread = Thread {
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            let listenCount = TapCounter()
            let filterCount = TapCounter()
            let listen = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: tapCallback,
                                           userInfo: Unmanaged.passUnretained(listenCount).toOpaque())
            let filter = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: tapCallback,
                                           userInfo: Unmanaged.passUnretained(filterCount).toOpaque())
            for tap in [listen, filter].compactMap({ $0 }) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                Keys.press(105, source: CGEventSource(stateID: .hidSystemState))
            }
            CFRunLoopRunInMode(.defaultMode, seconds, false)
            for tap in [listen, filter].compactMap({ $0 }) { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
            reply("listenOnly tap created=\(listen != nil) keyDowns=\(listenCount.count); "
                  + "filtering tap created=\(filter != nil) keyDowns=\(filterCount.count); "
                  + "CGPreflightListenEventAccess=\(CGPreflightListenEventAccess())")
        }
        thread.start()
    }
}

let delegate = InputSpikeHost()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
