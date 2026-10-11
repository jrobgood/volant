import Foundation

/// The state behind the floating dictation indicator shown when dictation starts from the global
/// hotkey. It holds only what the indicator displays: the phase, the tail of what has been heard
/// and any volume problem. Nothing here is logged or persisted, and the heard text is cleared as
/// soon as the indicator hides.
///
/// Timing is injected so tests can step through listening, transcribing, the result and hiding
/// without waiting on a real clock.
final class DictationIndicatorModel: ObservableObject {
    /// How a dictation ended, which picks the result's symbol.
    enum Outcome: Equatable {
        case copied, nothing, cancelled, failed
    }

    enum Phase: Equatable {
        case hidden
        case listening
        case transcribing
        case result(String, Outcome)
    }

    /// Schedules `work` after a delay and returns a closure that cancels it.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    static let partialLimit = 120
    static let resultDuration: TimeInterval = 2

    @Published private(set) var phase: Phase = .hidden
    /// The last `partialLimit` characters heard so far, with a leading ellipsis when trimmed.
    @Published private(set) var partial = ""
    /// How to stop, for example "Release or press ⌥Space to stop".
    @Published private(set) var stopHint = ""
    /// Whether Escape is registered to cancel while listening; the hint mentions it only then.
    @Published var escapeCancels = false
    /// A volume problem met during this dictation, shown while it runs and added to the result.
    @Published private(set) var volumeProblem: String?

    private let schedule: Scheduler
    private var cancelHide: (() -> Void)?

    init(schedule: @escaping Scheduler = DictationIndicatorModel.mainQueueScheduler) {
        self.schedule = schedule
    }

    var isVisible: Bool { phase != .hidden }
    var isListening: Bool { phase == .listening }

    /// Shows the indicator for a new dictation, replacing anything still on screen.
    func listen(stopHint: String) {
        cancelPendingHide()
        self.stopHint = stopHint
        partial = ""
        volumeProblem = nil
        phase = .listening
    }

    /// Updates the heard text while listening or transcribing. Older text is dropped so the
    /// indicator keeps a fixed size however long the owner speaks.
    func heard(_ transcript: String) {
        guard phase == .listening || phase == .transcribing else { return }
        partial = Self.tail(of: transcript)
    }

    /// Recognition continues after the hotkey is released; the heard text stays visible.
    func transcribing() {
        guard phase == .listening else { return }
        phase = .transcribing
    }

    /// Shows how dictation ended, with any volume problem after it, and hides a moment later.
    func finish(_ message: String, outcome: Outcome) {
        cancelPendingHide()
        let text = [message, volumeProblem].compactMap { $0 }.joined(separator: " ")
        volumeProblem = nil
        partial = ""
        phase = .result(text, outcome)
        scheduleHide()
    }

    /// Records a volume problem. While dictation runs it is shown and kept for the result; once a
    /// result is up it is added to it, and with nothing on screen it is shown on its own.
    func note(volumeProblem problem: String) {
        switch phase {
        case .listening, .transcribing:
            volumeProblem = problem
        case .result(let text, let outcome):
            guard !text.contains(problem) else { return }
            finish(text + " " + problem, outcome: outcome)
        case .hidden:
            finish(problem, outcome: .failed)
        }
    }

    /// Removes the indicator at once and forgets what was heard.
    func hide() {
        cancelPendingHide()
        partial = ""
        volumeProblem = nil
        phase = .hidden
    }

    /// The last `limit` characters of `text`, starting after a space where one is close, with an
    /// ellipsis marking that earlier words were dropped.
    static func tail(of text: String, limit: Int = partialLimit) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        var tail = trimmed.suffix(limit - 1)
        if let space = tail.prefix(20).lastIndex(of: " ") {
            tail = tail[tail.index(after: space)...]
        }
        return "…" + tail
    }

    /// Starts the countdown that hides a result.
    private func scheduleHide() {
        cancelHide = schedule(Self.resultDuration) { [weak self] in
            self?.cancelHide = nil
            self?.hide()
        }
    }

    /// Stops a pending hide so a newer phase is not removed early.
    private func cancelPendingHide() {
        cancelHide?()
        cancelHide = nil
    }

    /// Runs work on the main queue after a delay; the returned closure cancels it.
    static func mainQueueScheduler(_ delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}
