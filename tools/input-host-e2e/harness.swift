import AppKit
import VolantCore

// End-to-end harness for the shipped input helper. Not part of any app target. It is built as a
// sandboxed, Developer ID signed container with Volant's bundle identifier (the helper accepts no
// other caller) around the real VolantInputHost.xpc from an xcodebuild build, and runs only in a
// disposable Tart clone (tools/input-host-e2e/run-vm.py). It stands in for speech recognition and
// the global hotkey: phrases come from its arguments. Everything else is production code: the XPC
// client (InputHostConnection), the typing coordinator (DictationTypingSession), the Carbon Return
// and Escape keys (DictationEscapeKey, HotKeyCenter) and the helper itself. It never reads text.
//
// Commands:
//   status | status-prompt                 Accessibility status, prompting with the second
//   type <live|finished> <delay> <phrase>…  types the phrases as dictation would, `delay` apart
//   type-until-return <phrase>…            types live, registers Return like hotkey dictation, and
//                                          finishes when Return is pressed (or after 20 s)
//   two-sessions <pause> <first> <second>  two dictations over one helper connection, `pause` apart
//   stale                                  inserts with a token the helper never issued

/// Prints and flushes, so output survives exiting from a callback.
func say(_ text: String) {
    print(text)
    fflush(stdout)
}

/// One line describing how typing ended, then exits.
func report(_ outcome: DictationTypingSession.Outcome, started: Date) {
    say(String(format: "outcome=%@ message=%@ elapsed=%.0fms", String(describing: outcome), outcome.message,
               Date().timeIntervalSince(started) * 1000))
    exit(0)
}

let client = InputHostConnection()
let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
let keys = DictationEscapeKey(register: { HotKeyCenter.shared.register($0, handler: $1) },
                              unregister: { HotKeyCenter.shared.unregister($0) })

/// Runs one command against the helper.
func run(_ arguments: [String]) {
    let started = Date()
    say("frontmost at start: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
    switch arguments.first {
    case "status", "status-prompt":
        client.status(prompt: arguments.first == "status-prompt") { status in
            say(status.map { "trusted=\($0.trusted) secureInput=\($0.secureInput)" } ?? "helper unavailable")
            exit(status == nil ? 1 : 0)
        }
    case "type":
        let timing: DictationTypingSession.Timing = arguments[1] == "live" ? .whileSpeaking : .whenFinished
        let delay = Double(arguments[2]) ?? 0.4
        let phrases = Array(arguments.dropFirst(3))
        let session = DictationTypingSession(client: client, timing: timing)
        session.start()
        for (index, phrase) in phrases.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * Double(index)) { session.phraseFinalized(phrase) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay * Double(phrases.count)) {
            session.finish(transcript: phrases.joined()) { report($0, started: started) }
        }
    case "type-until-return":
        let phrases = Array(arguments.dropFirst())
        let session = DictationTypingSession(client: client, timing: .whileSpeaking)
        session.start()
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            keys.update(listening: false, finishesOnReturn: true, onEscape: {}, onReturn: {})
            say("Return and Escape unregistered: \(!keys.isRegistered && !keys.isReturnRegistered)")
            session.finish(transcript: phrases.joined()) { report($0, started: started) }
        }
        let escape = keys.update(listening: true, finishesOnReturn: true, onEscape: { say("Escape received"); exit(2) }, onReturn: {
            say("Return received by Volant")
            finish()
        })
        say("Escape registered: \(escape), Return registered: \(keys.isReturnRegistered)")
        for (index, phrase) in phrases.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(index)) { session.phraseFinalized(phrase) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { say("no Return within 20 s"); finish() }
    case "two-sessions":
        let pause = Double(arguments[1]) ?? 5
        let first = DictationTypingSession(client: client, timing: .whenFinished)
        first.start()
        first.finish(transcript: arguments[2]) { outcome in
            say("first session: \(outcome.message)")
            DispatchQueue.main.asyncAfter(deadline: .now() + pause) {
                say("frontmost for the second session: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
                let second = DictationTypingSession(client: client, timing: .whenFinished)
                second.start()
                second.finish(transcript: arguments[3]) { report($0, started: started) }
            }
        }
    case "stale":
        client.insert(phrase: "never typed", token: Data(repeating: 7, count: 32)) { result in
            say("stale token insert: \(result.map { String(describing: $0) } ?? "no reply")")
            exit(0)
        }
    default:
        say("unknown command")
        exit(64)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.main.async { run(arguments) }
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { say("timed out"); exit(1) }
app.run()
