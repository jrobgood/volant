import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin

// SPIKE ONLY. Not shipped, not part of any app target. See docs/input-host-spike.md.
//
// Sandboxed container app standing in for Volant. It is launched by LaunchServices
// (`open -g -n -W`) so that it is its own responsible process rather than the guest agent's,
// never activates, runs one command against the embedded service and exits.

/// Prints and flushes, so output survives the process exiting from a callback.
func say(_ text: String) {
    print(text)
    fflush(stdout)
}

/// This sandboxed process's own view of its TCC state. Never prompts.
func hostTrustLines() -> [String] {
    typealias Lookup = @convention(c) (pid_t) -> pid_t
    var responsible = "SPI unavailable"
    if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
        let owner = unsafeBitCast(symbol, to: Lookup.self)(getpid())
        var buffer = [CChar](repeating: 0, count: 4096)
        responsible = "\(owner) " + (proc_pidpath(owner, &buffer, 4096) > 0 ? String(cString: buffer) : "?")
    }
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
    return [
        "host.pid=\(getpid()) bundle=\(Bundle.main.bundleIdentifier ?? "?") build=\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?")",
        "host.responsible=\(responsible)",
        "host.sandboxed=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)",
        "host.AXIsProcessTrustedWithOptions(prompt:false)=\(AXIsProcessTrustedWithOptions(options))",
        "host.CGPreflightListenEventAccess=\(CGPreflightListenEventAccess())",
        "host.CGPreflightPostEventAccess=\(CGPreflightPostEventAccess())",
    ]
}

/// Tries to use Accessibility and event creation from the sandboxed process itself, to see
/// whether a grant charged to the container lets the sandboxed app act, not only read trusted.
func hostAccessibilityProbe() -> [String] {
    let system = AXUIElementCreateSystemWide()
    var value: CFTypeRef?
    let focusedApp = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &value)
    var lines = ["host AXUIElementCopyAttributeValue(systemWide, focusedApplication) AXError=\(focusedApp.rawValue)"]
    if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
        let app = AXUIElementCreateApplication(pid)
        var element: CFTypeRef?
        let focused = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &element)
        lines.append("host AXUIElementCopyAttributeValue(frontmost app, focusedUIElement) AXError=\(focused.rawValue)")
        if focused == .success, let element {
            let set = AXUIElementSetAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, "[host]" as CFString)
            lines.append("host AXUIElementSetAttributeValue(selectedText) AXError=\(set.rawValue)")
        }
    }
    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
    let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil)
    lines.append("host listen-only CGEvent.tapCreate=\(tap != nil)")
    if let tap { CFMachPortInvalidate(tap) }
    return lines
}

/// Carbon hot keys registered without modifiers, counted by key code.
final class BareHotKeys {
    var pressed: [UInt32: Int] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// Installs the handler and registers each key code with no modifiers; returns OSStatus per key.
    func register(_ codes: [UInt32]) -> [String] {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let keys = Unmanaged<BareHotKeys>.fromOpaque(info!).takeUnretainedValue()
            keys.pressed[id.id, default: 0] += 1
            return noErr
        }, 1, &spec, me, &handler)
        return codes.map { code in
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(code, 0, EventHotKeyID(signature: OSType(0x5653504B), id: code),
                                             GetApplicationEventTarget(), 0, &ref)
            if let ref { refs.append(ref) }
            return "RegisterEventHotKey(keyCode \(code), modifiers 0)=\(status)"
        }
    }

    /// Unregisters every key.
    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }
}

/// Runs one spike command against the embedded service.
final class Runner {
    let connection = NSXPCConnection(serviceName: "com.mysticcoders.volant.inputspike.InputHost")
    let keys = BareHotKeys()
    lazy var proxy: InputSpikeHostProtocol = {
        connection.remoteObjectInterface = NSXPCInterface(with: InputSpikeHostProtocol.self)
        connection.resume()
        return connection.remoteObjectProxyWithErrorHandler { error in
            say("XPC error: \(error.localizedDescription)")
            exit(3)
        } as! InputSpikeHostProtocol
    }()

    /// Calls `body` with a reply callback and waits for the reply.
    func call(_ body: (@escaping (String) -> Void) -> Void) {
        let done = DispatchSemaphore(value: 0)
        body { say($0); done.signal() }
        if done.wait(timeout: .now() + 60) == .timedOut { say("timeout") }
    }

    /// Dispatches `arguments` to the matching probe.
    func run(_ arguments: [String]) {
        let command = arguments.first ?? "status"
        say("=== \(command) \(arguments.dropFirst().joined(separator: " "))")
        switch command {
        case "status":
            hostTrustLines().forEach(say)
            call { proxy.status(reply: $0) }
        case "host-status":
            hostTrustLines().forEach(say)
        case "host-ax":
            hostAccessibilityProbe().forEach(say)
        case "host-request-listen":
            say("host.CGRequestListenEventAccess=\(CGRequestListenEventAccess())")
        case "service-status":
            call { proxy.status(reply: $0) }
        case "request-ax":
            call { proxy.requestAccessibility(reply: $0) }
        case "request-listen":
            call { proxy.requestListenAccess(reply: $0) }
        case "focused":
            call { proxy.focused(reply: $0) }
        case "insert":
            let method = arguments[1]
            let delay = Double(arguments[2]) ?? 0.5
            call { proxy.insert(method: method, phrases: Array(arguments.dropFirst(3)), delay: delay, reply: $0) }
        case "read":
            call { proxy.readFocused(reply: $0) }
        case "windows":
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            for window in list where (window[kCGWindowLayer as String] as? Int ?? 0) > 0 || window[kCGWindowOwnerName as String] as? String == "universalAccessAuthWarn" {
                say("window owner=\(window[kCGWindowOwnerName as String] ?? "?") layer=\(window[kCGWindowLayer as String] ?? "?")")
            }
        case "manual-ax":
            call { proxy.enableManualAccessibility(reply: $0) }
        case "static":
            call { proxy.readStaticText(prefix: arguments[1], reply: $0) }
        case "key":
            call { proxy.postKey(code: Int(arguments[1]) ?? 0, flags: UInt64(arguments.count > 2 ? arguments[2] : "0") ?? 0, reply: $0) }
        case "tap":
            call { proxy.tapProbe(seconds: Double(arguments[1]) ?? 3, reply: $0) }
        case "hotkey":
            hotkey()
            return
        default:
            say("unknown command")
        }
        exit(0)
    }

    /// Registers bare Escape and Return, has the service post both at the HID tap, and checks
    /// whether the frontmost app's text changed; then repeats with the keys unregistered.
    func hotkey() {
        call { proxy.focused(reply: $0) }
        call { proxy.readFocused(reply: $0) }
        keys.register([UInt32(kVK_Escape), UInt32(kVK_Return)]).forEach(say)
        DispatchQueue.global().async { [self] in
            Thread.sleep(forTimeInterval: 0.5)
            call { proxy.postKey(code: kVK_Return, flags: 0, reply: $0) }
            call { proxy.postKey(code: kVK_Escape, flags: 0, reply: $0) }
            Thread.sleep(forTimeInterval: 1.0)
            DispatchQueue.main.sync {
                say("while registered: handler counts Return=\(keys.pressed[UInt32(kVK_Return)] ?? 0) Escape=\(keys.pressed[UInt32(kVK_Escape)] ?? 0)")
            }
            call { proxy.readFocused(reply: $0) }
            DispatchQueue.main.sync { keys.unregister() }
            call { proxy.postKey(code: kVK_Return, flags: 0, reply: $0) }
            Thread.sleep(forTimeInterval: 1.0)
            say("after unregister (control):")
            call { proxy.readFocused(reply: $0) }
            call { proxy.focused(reply: $0) }
            exit(0)
        }
    }
}

let runner = Runner()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
DispatchQueue.main.async {
    if arguments.first == "hotkey" {
        runner.run(arguments)
    } else {
        DispatchQueue.global().async { runner.run(arguments) }
    }
}
app.run()
