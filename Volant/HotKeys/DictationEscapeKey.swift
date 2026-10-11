import Carbon.HIToolbox

/// Lets Escape cancel hotkey dictation while another app stays frontmost.
///
/// The indicator never becomes key, so Escape cannot reach a Volant window. Instead, unmodified
/// Escape is registered as a Carbon hotkey for exactly as long as the indicator is listening and
/// unregistered the moment listening ends. Carbon hotkeys need no Accessibility or Input
/// Monitoring grant. While registered, Escape is consumed system-wide, so the frontmost app does
/// not see it during those seconds. If another app already holds Escape, registration fails, the
/// indicator leaves Escape out of its hint, and pressing the dictation hotkey still stops.
final class DictationEscapeKey {
    static let combo = KeyCombo(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)

    private let register: (KeyCombo, @escaping () -> Void) -> UInt32?
    private let unregister: (UInt32) -> Void
    private var registration: UInt32?

    init(register: @escaping (KeyCombo, @escaping () -> Void) -> UInt32?,
         unregister: @escaping (UInt32) -> Void) {
        self.register = register
        self.unregister = unregister
    }

    var isRegistered: Bool { registration != nil }

    /// Registers Escape while `listening` is true and removes it otherwise. Returns whether Escape
    /// is registered afterwards. Repeated calls with the same value change nothing.
    @discardableResult
    func update(listening: Bool, onEscape: @escaping () -> Void) -> Bool {
        if listening, registration == nil {
            registration = register(Self.combo, onEscape)
        } else if !listening, let id = registration {
            registration = nil
            unregister(id)
        }
        return registration != nil
    }
}
