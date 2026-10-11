import AppKit
import Combine
import VolantCore

/// The Accessibility state Settings shows for Type at the cursor. It talks to the input helper
/// only after the owner has chosen typing: choosing it asks once with the system prompt, and later
/// visits check without prompting. On macOS 15 even a check without the prompt adds Volant to the
/// Accessibility list, so nothing here runs while dictation copies. Choosing Copy to clipboard
/// disconnects, which stops the helper; the grant itself stays until the owner removes it.
final class DictationTypingAccess: ObservableObject {
    enum State: Equatable {
        /// Typing is off, or has not been checked yet.
        case idle
        case checking
        case allowed
        case notAllowed
        /// The helper could not be reached, for example in an unsigned development build.
        case unavailable
    }

    /// Privacy & Security → Accessibility. Not documented by Apple, but widely used.
    static let accessibilitySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    @Published private(set) var state = State.idle
    /// Set after the owner turns typing off here, so Settings can say how to remove the grant.
    @Published private(set) var stoppedHelper = false

    private let client: InputHostClient
    private let canReconnect: () -> Bool
    private var generation = 0

    /// `canReconnect` says whether no dictation is using the helper, so a refresh may replace the
    /// connection with a fresh helper process.
    init(client: InputHostClient, canReconnect: @escaping () -> Bool = { true }) {
        self.client = client
        self.canReconnect = canReconnect
    }

    /// The owner picked an output in Settings, after it was saved.
    func chose(_ output: DictationOutput) {
        switch output {
        case .type:
            stoppedHelper = false
            check(prompt: true)
        case .copy:
            generation += 1
            client.disconnect()
            stoppedHelper = state != .idle || stoppedHelper
            state = .idle
        }
    }

    /// Settings appeared or Volant became active again, perhaps after the owner changed the grant
    /// in System Settings. Checks without prompting, from a fresh helper when nothing is using it.
    func refresh(_ output: DictationOutput) {
        guard output == .type else {
            if state != .idle { state = .idle }
            return
        }
        guard state != .checking else { return }
        if canReconnect() { client.disconnect() }
        check(prompt: false)
    }

    /// Opens Privacy & Security → Accessibility, or Privacy & Security if that link fails.
    func openAccessibilitySettings() {
        if !NSWorkspace.shared.open(Self.accessibilitySettings),
           let privacy = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension") {
            NSWorkspace.shared.open(privacy)
        }
    }

    /// Asks the helper for its status; a reply that arrives after the owner switched back to
    /// copying is ignored.
    private func check(prompt: Bool) {
        generation += 1
        let current = generation
        state = .checking
        client.status(prompt: prompt) { [weak self] status in
            guard let self, self.generation == current else { return }
            guard let status else { self.state = .unavailable; return }
            self.state = status.trusted ? .allowed : .notAllowed
        }
    }
}
