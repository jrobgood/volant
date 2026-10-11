import Foundation

/// The app's side of the input helper. The real client connects over XPC only when one of these
/// is first called, and only while the owner has chosen Type at the cursor. Completions arrive on
/// the main queue; an error means the helper could not be reached or did not answer in time.
public protocol InputHostClient: AnyObject {
    func status(prompt: Bool, completion: @escaping (InputHostStatus?) -> Void)
    func beginSession(completion: @escaping (InputSessionStart?) -> Void)
    func insert(phrase: String, token: Data, completion: @escaping (InputInsertion?) -> Void)
    func endSession(token: Data)
    /// Drops the connection so the helper exits.
    func disconnect()
}

/// One dictation typed at the cursor. While speaking, each finalized phrase is sent as it arrives;
/// when finished, the whole transcript is sent once. Phrases go one at a time and in order. The
/// first refusal stops typing for the rest of the dictation, and the caller then copies the
/// transcript and gives the reason.
public final class DictationTypingSession {
    public enum Timing: Equatable {
        case whileSpeaking, whenFinished
    }

    public enum Outcome: Equatable {
        /// Nothing was heard and nothing was typed.
        case nothing
        /// Every phrase went in through Accessibility.
        case typed(Int)
        /// At least one phrase was pasted because the app ignored Accessibility.
        case pasted(Int)
        /// Typing stopped or never started. `reason` is nil when the helper was unavailable.
        /// `typedBefore` characters were already in the app when it stopped.
        case copy(reason: InputRefusal?, typedBefore: Int)

        /// The indicator's result line. A copy outcome tells the caller to copy the transcript.
        public var message: String {
            switch self {
            case .nothing: return "Nothing was heard."
            case .typed(let count): return "Typed \(count) characters."
            case .pasted(let count): return "Pasted \(count) characters."
            case .copy(let reason, let typed):
                let prefix = typed > 0 ? "Stopped after \(typed) characters and copied the transcript" : "Copied"
                return prefix + " — " + Self.explanation(reason) + "."
            }
        }

        /// Why typing stopped, worded for the indicator.
        static func explanation(_ reason: InputRefusal?) -> String {
            switch reason {
            case .secureField: return "typing isn’t allowed in password fields"
            case .secureInput: return "secure input is on, so Volant won’t type"
            case .appChanged: return "the app in front changed"
            case .noTarget: return "no other app was in front"
            case .notTrusted: return "Volant needs Accessibility permission to type"
            case .tooLong: return "too long to type at once"
            case .staleSession: return "the typing session ended"
            case nil: return "the input helper didn’t respond"
            }
        }
    }

    private enum State {
        case starting
        case ready(Data)
        case stopped(InputRefusal?)
        case cancelled
    }

    public let timing: Timing
    private let client: InputHostClient
    private var state = State.starting
    private var queue: [String] = []
    private var sending = false
    private var typed = 0
    private var pasted = false
    private var heardAnything = false
    private var completion: ((Outcome) -> Void)?

    public init(client: InputHostClient, timing: Timing) {
        self.client = client
        self.timing = timing
    }

    /// Characters inserted so far.
    public var typedCount: Int { typed }

    /// Opens the helper session. Phrases that arrive before it answers wait in order. Replies hold
    /// the session strongly, because the caller lets go of it once dictation has finished and the
    /// last phrases may still be in flight; the client always answers, with nil on a timeout.
    public func start() {
        client.beginSession { reply in
            guard case .starting = self.state else {
                if let token = reply?.token { self.client.endSession(token: token) }
                return
            }
            if let token = reply?.token { self.state = .ready(token) }
            else { self.stop(reply?.refusal ?? (reply == nil ? nil : .noTarget)) }
            self.pump()
        }
    }

    /// A finalized phrase while speaking. Volatile text never comes here. The first phrase loses
    /// its leading whitespace so the dictation starts where the cursor is.
    public func phraseFinalized(_ phrase: String) {
        guard timing == .whileSpeaking, isOpen else { return }
        let text = typed == 0 && queue.isEmpty && !sending ? String(phrase.drop { $0.isWhitespace }) : phrase
        guard !text.isEmpty else { return }
        heardAnything = true
        queue.append(text)
        pump()
    }

    /// Dictation ended with `transcript` (nil when nothing was heard). Calls `completion` once
    /// every queued phrase is answered, then ends the helper session.
    public func finish(transcript: String?, completion: @escaping (Outcome) -> Void) {
        guard isOpen || isStopped else { return }
        self.completion = completion
        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { heardAnything = true }
        if timing == .whenFinished, !text.isEmpty, isOpen { queue.append(text) }
        pump()
    }

    /// Escape: nothing more is typed and no completion is called. Text already typed stays.
    public func cancel() {
        if case .ready(let token) = state { client.endSession(token: token) }
        state = .cancelled
        queue.removeAll()
        completion = nil
    }

    private var isOpen: Bool {
        switch state {
        case .starting, .ready: return true
        default: return false
        }
    }

    private var isStopped: Bool {
        if case .stopped = state { return true }
        return false
    }

    /// Sends the next phrase when the session is ready and nothing is in flight, and completes
    /// the dictation once the queue is empty after `finish`.
    private func pump() {
        if case .ready(let token) = state, !sending, !queue.isEmpty {
            sending = true
            let phrase = queue.removeFirst()
            client.insert(phrase: phrase, token: token) { result in
                guard case .ready = self.state else { return }
                self.sending = false
                switch result {
                case .typed(let count): self.typed += count
                case .pasted(let count): self.typed += count; self.pasted = true
                case .refused(let reason): self.stop(reason)
                case .failed, nil: self.stop(nil)
                }
                self.pump()
            }
            return
        }
        guard let completion, !sending else { return }
        switch state {
        case .starting, .cancelled:
            return
        case .ready(let token):
            guard queue.isEmpty else { return }
            client.endSession(token: token)
            state = .cancelled
            self.completion = nil
            if !heardAnything && typed == 0 { completion(.nothing) }
            else { completion(pasted ? .pasted(typed) : .typed(typed)) }
        case .stopped(let reason):
            self.completion = nil
            state = .cancelled
            completion(heardAnything ? .copy(reason: reason, typedBefore: typed) : .nothing)
        }
    }

    /// Stops typing for the rest of the dictation and ends the helper session.
    private func stop(_ reason: InputRefusal?) {
        if case .ready(let token) = state { client.endSession(token: token) }
        state = .stopped(reason)
        queue.removeAll()
    }
}
