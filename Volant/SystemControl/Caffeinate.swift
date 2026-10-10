import Foundation
import Combine
import IOKit.pwr_mgt

struct CaffeinateCommand: Hashable {
    let minutes: Int? // nil means until stopped
    let display: Bool
    let stop: Bool
    static let off = Self(minutes: nil, display: false, stop: true)
    var id: String { stop ? "off" : "\(minutes.map(String.init) ?? "unlimited"):\(display)" }
    var title: String { stop ? "Stop Caffeinate" : "Caffeinate" + (display ? "" : " · Display May Sleep") }
    var detail: String { stop ? "Allow normal idle sleep" : minutes.map { "\($0) minutes" } ?? "Until stopped" }

    static func matches(_ query: String) -> Bool {
        query.lowercased().split(whereSeparator: \.isWhitespace).first == "caffeinate"
    }
    /// Without a modifier, sessions follow the owner's setting, which keeps the display on and unlocked
    /// by default because a dark display that locks reads as sleep. A trailing `display` or `system`
    /// (`mac`) chooses the mode for one session. The bare list offers the default mode first.
    static func parse(_ query: String, keepsDisplayAwake: Bool = true) -> [Self] {
        var words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.first == "caffeinate" else { return [] }
        words.removeFirst()
        if words == ["off"] || words == ["stop"] { return [.off] }
        let modifier = words.last.flatMap { ["display", "system", "mac"].contains($0) ? $0 : nil }
        if modifier != nil { words.removeLast() }
        let display = modifier == nil ? keepsDisplayAwake : modifier == "display"
        if words.isEmpty {
            let modes = modifier == nil ? [keepsDisplayAwake, !keepsDisplayAwake] : [display]
            return modes.flatMap { mode in
                [15, 30, 60].map { Self(minutes: $0, display: mode, stop: false) } + [Self(minutes: nil, display: mode, stop: false)]
            }
        }
        if words == ["on"] { return [Self(minutes: nil, display: display, stop: false)] }
        guard words.count == 1, let token = words.first, let suffix = token.last, ["m", "h"].contains(suffix),
              let amount = Int(token.dropLast()), amount > 0, amount <= (suffix == "h" ? 24 : 1440) else { return [] }
        return [Self(minutes: amount * (suffix == "h" ? 60 : 1), display: display, stop: false)]
    }
}

protocol CaffeinateAssertions {
    func create(display: Bool, timeout: TimeInterval) throws -> UInt32
    func release(_ id: UInt32) throws
}

struct NativeCaffeinateAssertions: CaffeinateAssertions {
    struct Failure: LocalizedError {
        let code: IOReturn
        var errorDescription: String? { "macOS couldn’t update Caffeinate (\(code)). Try again." }
    }
    func create(display: Bool, timeout: TimeInterval) throws -> UInt32 {
        var id: IOPMAssertionID = 0
        // Display-idle prevention also prevents system idle sleep. Timed assertions turn off
        // in macOS even if our run loop stalls; we retain ownership until explicit release.
        let type = display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithDescription(type as CFString, "Volant Caffeinate" as CFString,
            "Keep awake for your Caffeinate session" as CFString, nil, nil, timeout,
            kIOPMAssertionTimeoutActionTurnOff as CFString, &id)
        guard result == kIOReturnSuccess else { throw Failure(code: result) }
        return id
    }
    func release(_ id: UInt32) throws {
        let result = IOPMAssertionRelease(id)
        guard result == kIOReturnSuccess else { throw Failure(code: result) }
    }
}

/// Main-thread owned, session-only state. No preferences, subprocesses or startup assertion.
final class CaffeinateService: ObservableObject {
    @Published private(set) var command: CaffeinateCommand?
    @Published private(set) var remaining: Int?
    @Published private(set) var error: String?
    private let assertions: CaffeinateAssertions
    private let now: () -> TimeInterval
    private let automaticTimer: Bool
    private var assertion: UInt32?
    private var deadline: TimeInterval?
    private var timer: Timer?
    var isActive: Bool { command != nil }
    var summary: String {
        let mode = command?.display == true ? "Mac & display awake" : "Mac awake · display may sleep"
        guard let remaining else { return mode + " · until stopped" }
        return mode + String(format: " · %d:%02d remaining", remaining / 60, remaining % 60)
    }
    init(assertions: CaffeinateAssertions = NativeCaffeinateAssertions(), now: (() -> TimeInterval)? = nil, automaticTimer: Bool = true) {
        self.assertions = assertions
        let clock = ContinuousClock(), start = ContinuousClock.now
        self.now = now ?? { let elapsed = start.duration(to: clock.now).components; return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18 }
        self.automaticTimer = automaticTimer
    }
    @discardableResult func perform(_ next: CaffeinateCommand) -> Bool {
        if next.stop { return stop() }
        if let minutes = next.minutes, !(1...1440).contains(minutes) { error = "Choose a duration from 1 minute to 24 hours."; return false }
        guard !isActive else { error = "Stop the current Caffeinate session before starting another."; return false }
        do {
            let seconds = TimeInterval((next.minutes ?? 0) * 60)
            assertion = try assertions.create(display: next.display, timeout: seconds)
            command = next; deadline = next.minutes == nil ? nil : now() + seconds
            remaining = next.minutes.map { $0 * 60 }; error = nil
            if automaticTimer {
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
                self.timer = timer; RunLoop.main.add(timer, forMode: .common)
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func tick() {
        guard let deadline else { return }
        remaining = max(0, Int(ceil(deadline - now())))
        if remaining == 0 { _ = stop() }
    }
    @discardableResult func stop() -> Bool {
        if let assertion {
            do { try assertions.release(assertion) }
            catch { self.error = error.localizedDescription; return false }
        }
        assertion = nil; command = nil; deadline = nil; remaining = nil
        timer?.invalidate(); timer = nil; error = nil
        return true
    }
    deinit { timer?.invalidate(); if let assertion { try? assertions.release(assertion) } }
}
