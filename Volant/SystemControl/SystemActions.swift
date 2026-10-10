import AppKit
import IOKit.pwr_mgt
import VolantCore

/// Performs session and power actions from inside App Sandbox. Measured in
/// docs/system-actions-spike.md: none needs the helper or raises a permission prompt.
enum SystemActions {
    /// Returns a message to show when the action could not be performed, or nil on success.
    static func perform(_ action: SystemAction) -> String? {
        switch action {
        case .lockScreen: return lock()
        case .sleep: return sleep()
        case .sleepDisplays:
            return pmset("displaysleepnow") == 0 ? nil : "Couldn’t turn off the displays."
        case .screenSaver:
            let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return nil
        case .restart, .shutDown, .logOut:
            return askLoginwindow(action)
        }
    }

    /// `SACLockScreenImmediate` is private API, so it is looked up at run time: if a future macOS
    /// removes it, Lock Screen reports that and sleeps the displays, which locks under the
    /// default "require password immediately" setting, instead of crashing.
    private static func lock() -> String? {
        typealias Lock = @convention(c) () -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
           let symbol = dlsym(handle, "SACLockScreenImmediate"),
           unsafeBitCast(symbol, to: Lock.self)() == 0 {
            return nil
        }
        return pmset("displaysleepnow") == 0
            ? "Lock Screen isn’t available on this version of macOS, so the displays were turned off instead."
            : "Couldn’t lock the screen."
    }

    /// `pmset sleepnow` first; if that is refused, IOKit's request, which the console user may make.
    private static func sleep() -> String? {
        if pmset("sleepnow") == 0 { return nil }
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        defer { if port != 0 { IOServiceClose(port) } }
        guard port != 0, IOPMSleepSystem(port) == kIOReturnSuccess else { return "Couldn’t put this Mac to sleep." }
        return nil
    }

    private static func pmset(_ argument: String) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = [argument]
        process.environment = ChildProcessEnvironment.appleTool(home: NSHomeDirectory(), user: NSUserName())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Asks loginwindow to show its own confirmation. Sending is the only reliable test:
    /// `AEDeterminePermissionToAutomateTarget` reports that consent is needed, yet sending
    /// proceeds without a prompt.
    private static func askLoginwindow(_ action: SystemAction) -> String? {
        guard let code = action.loginwindowEvent else { return nil }
        let id = code.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id, targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        do { _ = try event.sendEvent(options: [.noReply], timeout: 5); return nil }
        catch { return "Couldn’t ask macOS to " + action.title.lowercased().replacingOccurrences(of: "…", with: "") + "." }
    }
}
