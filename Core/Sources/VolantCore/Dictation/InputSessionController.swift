import Foundation

/// The app that was in front when a dictation session began. A later insertion types only while
/// the same process, identified by its pid and launch date, is still in front.
public struct InputTarget: Equatable {
    public var pid: Int32
    public var launchDate: Date?

    public init(pid: Int32, launchDate: Date?) {
        self.pid = pid
        self.launchDate = launchDate
    }
}

/// The focused text element, as the helper sees it through Accessibility. It exposes the role,
/// counts and positions it needs to decide and verify an insertion, never the element's text.
public protocol InputField {
    /// The process that owns the element, when it can be read.
    var pid: Int32? { get }
    var role: String? { get }
    var subrole: String? { get }
    /// `kAXNumberOfCharactersAttribute`, or nil when the element does not report it.
    func characterCount() -> Int?
    /// The length of the current selection in UTF-16 units, or nil when it is not reported.
    func selectionLength() -> Int?
    /// Sets `kAXSelectedTextAttribute`. The result is not trusted; the count is checked instead.
    func setSelectedText(_ text: String)
}

/// The system calls the helper makes. The real one lives in `VolantInputHost`; tests inject fakes.
public protocol InputSystem {
    func isTrusted(prompt: Bool) -> Bool
    func isSecureInputEnabled() -> Bool
    func frontmostTarget() -> InputTarget?
    func focusedField() -> InputField?
    /// Writes `text` to the pasteboard with transient and concealed markers, posts Command-V and
    /// restores the previous contents if nothing else changed them. Returns whether it was posted.
    func paste(_ text: String) -> Bool
    func wait(_ seconds: TimeInterval)
}

/// The helper's rules for one dictation session at a time, independent of Accessibility so it
/// can be tested with fakes. Every insertion re-checks trust, secure input, the focused element's
/// role and the target app at the moment of use.
///
/// Insertion tries Accessibility first and verifies it by the element's character count. When the
/// count does not change, it re-checks once after `recheckDelay`, then pastes that phrase and keeps
/// pasting for the rest of the session, because apps that ignore the attribute keep ignoring it.
public final class InputSessionController {
    public static let idleLimit: TimeInterval = 300
    public static let lifetimeLimit: TimeInterval = 3600
    public static let recheckDelay: TimeInterval = 0.1
    public static let secureRole = "AXSecureTextField"

    private struct Session {
        let token: Data
        let target: InputTarget
        let started: Date
        var lastUsed: Date
        var pastes = false
    }

    private let system: InputSystem
    private let callerPID: Int32
    private let now: () -> Date
    private let makeToken: () -> Data
    private var session: Session?

    public init(system: InputSystem, callerPID: Int32, now: @escaping () -> Date = Date.init,
                makeToken: @escaping () -> Data = InputSessionController.randomToken) {
        self.system = system
        self.callerPID = callerPID
        self.now = now
        self.makeToken = makeToken
    }

    /// Whether a session is open, for tests.
    public var hasSession: Bool { session != nil }

    /// Trust and secure input. Prompts only when asked to, which the app does once, after the
    /// owner chooses Type at the cursor.
    public func status(prompt: Bool) -> InputHostStatus {
        InputHostStatus(trusted: system.isTrusted(prompt: prompt), secureInput: system.isSecureInputEnabled())
    }

    /// Starts a session bound to the frontmost app, replacing any earlier one. Refuses without
    /// Accessibility, and when Volant itself or nothing is in front.
    public func begin() -> InputSessionStart {
        session = nil
        guard system.isTrusted(prompt: false) else { return InputSessionStart(refusal: .notTrusted) }
        guard let target = system.frontmostTarget(), target.pid != callerPID else { return InputSessionStart(refusal: .noTarget) }
        let token = makeToken()
        let time = now()
        session = Session(token: token, target: target, started: time, lastUsed: time)
        return InputSessionStart(token: token)
    }

    /// Types one phrase into the session's app, or says why not.
    public func insert(_ phrase: String, token: Data) -> InputInsertion {
        guard var current = session, current.token == token else { return .refused(.staleSession) }
        let time = now()
        guard time.timeIntervalSince(current.lastUsed) <= Self.idleLimit,
              time.timeIntervalSince(current.started) <= Self.lifetimeLimit else {
            session = nil
            return .refused(.staleSession)
        }
        guard let text = InputPhrasePolicy.sanitize(phrase) else { return .refused(.tooLong) }
        guard system.isTrusted(prompt: false) else { return .refused(.notTrusted) }
        guard !system.isSecureInputEnabled() else { return .refused(.secureInput) }
        guard system.frontmostTarget() == current.target else { return .refused(.appChanged) }
        let field = system.focusedField()
        if let owner = field?.pid, owner != current.target.pid { return .refused(.appChanged) }
        if let field, Self.isSecure(role: field.role, subrole: field.subrole) { return .refused(.secureField) }
        current.lastUsed = time
        defer { session = current }
        let characters = text.count
        guard !text.isEmpty else { return .typed(0) }
        if !current.pastes, let field, let before = field.characterCount() {
            if (field.selectionLength() ?? 0) == 0 {
                field.setSelectedText(text)
                if Self.changed(field.characterCount(), from: before) { return .typed(characters) }
                system.wait(Self.recheckDelay)
                if Self.changed(field.characterCount(), from: before) { return .typed(characters) }
                current.pastes = true
            }
        } else {
            current.pastes = true
        }
        return system.paste(text) ? .pasted(characters) : .failed
    }

    /// Ends the session when the token matches; anything else is ignored.
    public func end(token: Data) {
        if session?.token == token { session = nil }
    }

    /// A password field, by role or subrole.
    public static func isSecure(role: String?, subrole: String?) -> Bool {
        role == secureRole || subrole == secureRole
    }

    /// A count that is known and different from the one before the insertion.
    private static func changed(_ count: Int?, from before: Int) -> Bool {
        guard let count else { return false }
        return count != before
    }

    /// 32 random bytes.
    public static func randomToken() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
