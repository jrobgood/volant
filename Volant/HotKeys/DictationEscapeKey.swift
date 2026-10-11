import Carbon.HIToolbox

/// Lets Escape cancel, and Return finish, hotkey dictation while another app stays frontmost.
///
/// The indicator never becomes key, so neither key can reach a Volant window. Instead, unmodified
/// Escape is registered as a Carbon hotkey for exactly as long as the indicator is listening and
/// unregistered the moment listening ends. Return is registered the same way, but only when the
/// dictation types at the cursor, where finishing without reaching for the hotkey matters. Carbon
/// hotkeys need no Accessibility or Input Monitoring grant. While registered, a key is consumed
/// system-wide, so the frontmost app does not see it during those seconds. If another app already
/// holds a key, registration fails, the indicator leaves it out of its hint, and pressing the
/// dictation hotkey still stops.
final class DictationEscapeKey {
    static let combo = KeyCombo(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)
    static let returnCombo = KeyCombo(keyCode: UInt32(kVK_Return), carbonModifiers: 0)

    private let register: (KeyCombo, @escaping () -> Void) -> UInt32?
    private let unregister: (UInt32) -> Void
    private var registration: UInt32?
    private var returnRegistration: UInt32?

    init(register: @escaping (KeyCombo, @escaping () -> Void) -> UInt32?,
         unregister: @escaping (UInt32) -> Void) {
        self.register = register
        self.unregister = unregister
    }

    var isRegistered: Bool { registration != nil }
    var isReturnRegistered: Bool { returnRegistration != nil }

    /// Registers Escape while `listening` is true, and Return while `listening` and
    /// `finishesOnReturn` are both true, removing each as soon as its condition ends. Returns
    /// whether Escape is registered afterwards. Repeated calls with the same values change nothing.
    @discardableResult
    func update(listening: Bool, finishesOnReturn: Bool = false,
                onEscape: @escaping () -> Void, onReturn: @escaping () -> Void = {}) -> Bool {
        if listening, registration == nil {
            registration = register(Self.combo, onEscape)
        } else if !listening, let id = registration {
            registration = nil
            unregister(id)
        }
        let wantsReturn = listening && finishesOnReturn
        if wantsReturn, returnRegistration == nil {
            returnRegistration = register(Self.returnCombo, onReturn)
        } else if !wantsReturn, let id = returnRegistration {
            returnRegistration = nil
            unregister(id)
        }
        return registration != nil
    }
}
