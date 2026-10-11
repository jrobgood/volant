import Foundation

/// The input helper's whole interface. `VolantInputHost` is the only part of Volant that uses
/// Accessibility, and this is everything it accepts: a permission check, a dictation session bound
/// to the app that was in front when dictation started, and one phrase at a time to type into that
/// app. No method takes key codes, modifier flags, attribute names, process identifiers or bundle
/// identifiers, and none returns text from another app. Every reply is a small JSON value in `Data`
/// so both sides validate what they receive.
@objc public protocol VolantInputHostProtocol {
    /// `InputHostStatus`. With `prompt` true, macOS shows its Accessibility request once; it is sent
    /// only after the owner chooses Type at the cursor.
    func accessibilityStatus(prompt: Bool, reply: @escaping (Data) -> Void)
    /// `InputSessionStart`: records the frontmost app and returns a session token, or a refusal.
    func beginSession(reply: @escaping (Data) -> Void)
    /// `InputInsertion`: types one finalized phrase into the session's app, or refuses.
    func insert(phrase: String, token: Data, reply: @escaping (Data) -> Void)
    /// Forgets the session. Unknown or stale tokens are ignored.
    func endSession(token: Data)
}

/// The service name the app connects to; the helper's bundle identifier.
public enum InputHostService {
    public static let name = "com.mysticcoders.volant.InputHost"
    /// Only the signed Volant app from this team may connect.
    public static let callerRequirement = "anchor apple generic and identifier \"com.mysticcoders.volant\" and certificate leaf[subject.OU] = \"REMBT6JY4N\""
}

/// Whether the helper may use Accessibility, and whether secure input is on anywhere right now.
public struct InputHostStatus: Codable, Equatable {
    public var trusted: Bool
    public var secureInput: Bool

    public init(trusted: Bool, secureInput: Bool) {
        self.trusted = trusted
        self.secureInput = secureInput
    }
}

/// Why the helper would not type. Each one makes the app copy the transcript instead.
public enum InputRefusal: String, Codable, Equatable, CaseIterable {
    /// Accessibility is not allowed for Volant.
    case notTrusted
    /// Secure input is on, for example in a password field or Terminal's Secure Keyboard Entry.
    case secureInput
    /// The focused element is a password field.
    case secureField
    /// The app in front is no longer the one that was in front when dictation started.
    case appChanged
    /// No app other than Volant was in front when dictation started.
    case noTarget
    /// The token is unknown, already ended or expired.
    case staleSession
    /// The phrase is longer than `InputPhrasePolicy.maximumUTF16`.
    case tooLong
}

/// The reply to `beginSession`: a token, or why typing cannot start.
public struct InputSessionStart: Codable, Equatable {
    public var token: Data?
    public var refusal: InputRefusal?

    public init(token: Data? = nil, refusal: InputRefusal? = nil) {
        self.token = token
        self.refusal = refusal
    }
}

/// The reply to `insert`. Counts are characters as the owner reads them, never the text.
public enum InputInsertion: Codable, Equatable {
    /// Inserted through Accessibility into the focused text element.
    case typed(Int)
    /// Inserted with a synthesized Command-V because Accessibility did not change the element.
    case pasted(Int)
    case refused(InputRefusal)
    /// The paste could not be posted.
    case failed
}

/// What the helper accepts as a phrase: bounded, and without control characters other than
/// newline and tab. Nothing else about the text is changed.
public enum InputPhrasePolicy {
    public static let maximumUTF16 = 20_000

    /// The phrase with C0 control characters other than newline and tab removed, or nil when it is
    /// longer than the limit.
    public static func sanitize(_ phrase: String) -> String? {
        guard phrase.utf16.count <= maximumUTF16 else { return nil }
        let kept = phrase.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !(scalar.value < 0x20 || scalar.value == 0x7F)
        }
        return String(String.UnicodeScalarView(kept))
    }
}
