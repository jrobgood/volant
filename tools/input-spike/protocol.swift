import Foundation

// SPIKE ONLY. Not shipped, not part of any app target. See docs/input-host-spike.md.
//
// This is a diagnostic vocabulary for measuring TCC attribution and insertion behavior in a
// disposable Tart guest. It is deliberately broader than the product API sketched in
// docs/dictation-at-cursor-design.md (it can read the focused value and post arbitrary keys so
// the harness can verify results). Nothing here should be copied into VolantInputHost as-is.

@objc protocol InputSpikeHostProtocol {
    /// Trust and secure-input state as seen from the service. Never prompts.
    func status(reply: @escaping (String) -> Void)

    /// AXIsProcessTrustedWithOptions with the prompt option set to true.
    func requestAccessibility(reply: @escaping (String) -> Void)

    /// CGRequestListenEventAccess (Input Monitoring).
    func requestListenAccess(reply: @escaping (String) -> Void)

    /// Describes the focused element: owning app, role, subrole, settable attributes.
    func focused(reply: @escaping (String) -> Void)

    /// Inserts each phrase into the focused element with `method` ("ax", "paste" or "unicode"),
    /// waiting `delay` seconds between phrases, as live dictation would.
    func insert(method: String, phrases: [String], delay: Double, reply: @escaping (String) -> Void)

    /// Reads the focused element's value so the harness can verify an insertion.
    func readFocused(reply: @escaping (String) -> Void)

    /// Reads the value of the first static text whose value starts with `prefix` in the
    /// frontmost app's focused window (used to read a page's password-length mirror).
    func readStaticText(prefix: String, reply: @escaping (String) -> Void)

    /// Sets AXManualAccessibility on the frontmost app so Chromium and Electron expose their
    /// tree. Used to read results back, and to test AX insertion with the tree enabled.
    func enableManualAccessibility(reply: @escaping (String) -> Void)

    /// Posts one key press at the HID tap with the given virtual key code and modifier flags.
    func postKey(code: Int, flags: UInt64, reply: @escaping (String) -> Void)

    /// Creates a listen-only and a filtering session tap for keyDown, counts what each sees for
    /// `seconds` while posting a probe key, then removes both.
    func tapProbe(seconds: Double, reply: @escaping (String) -> Void)
}
