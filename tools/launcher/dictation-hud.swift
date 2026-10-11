import AppKit
import SwiftUI
import VolantCore

setbuf(stdout, nil)

func verify(_ condition: @autoclosure () -> Bool, _ message: String = "Assertion", line: Int = #line) {
    if !condition() { fputs("FAIL at line \(line): \(message)\n", stderr); exit(1) }
}

/// Runs the main run loop until the condition has held for `stable` seconds or `timeout` passes.
@discardableResult
func waitUntil(timeout: TimeInterval = 3, stable: TimeInterval = 0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var heldSince: Date?
    while Date() < deadline {
        if condition() {
            let start = heldSince ?? Date()
            heldSince = start
            if Date().timeIntervalSince(start) >= stable { return true }
        } else {
            heldSince = nil
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

/// Spins the run loop briefly so the panel's deferred update and SwiftUI layout settle.
func settle(_ seconds: TimeInterval = 0.3) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

let app = NSApplication.shared
let dark = CommandLine.arguments.contains("dark")
let appearanceName = dark ? "dark" : "light"
app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
app.setActivationPolicy(.accessory)
let ownPID = ProcessInfo.processInfo.processIdentifier

/// Captures the indicator's actual hosted view over a neutral desktop-like backdrop, so its
/// rounded edge and border are visible in the JPEG.
func capture(_ panel: NSPanel, _ state: String) throws {
    guard let view = panel.contentView else { verify(false, "Indicator has a content view"); return }
    view.layoutSubtreeIfNeeded()
    let bounds = view.bounds
    guard let content = view.bitmapImageRepForCachingDisplay(in: bounds) else { verify(false, "Bitmap for \(state)"); return }
    view.cacheDisplay(in: bounds, to: content)
    let margin: CGFloat = 24
    let size = NSSize(width: bounds.width + margin * 2, height: bounds.height + margin * 2)
    let image = NSImage(size: size)
    image.lockFocus()
    (dark ? NSColor(white: 0.32, alpha: 1) : NSColor(white: 0.78, alpha: 1)).setFill()
    NSRect(origin: .zero, size: size).fill()
    content.draw(in: NSRect(x: margin, y: margin, width: bounds.width, height: bounds.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
        verify(false, "JPEG for \(state)"); return
    }
    let path = "/tmp/volant-launcher-dictation-hud-\(state)-\(appearanceName).jpg"
    try jpeg.write(to: URL(fileURLWithPath: path))
    print("Captured \(path)")
}

/// A hand-driven clock so the result's two-second hide is stepped, not waited on.
var pendingHides: [() -> Void] = []
let model = DictationIndicatorModel(schedule: { _, work in
    pendingHides.append(work)
    return {}
})
let panel = DictationIndicatorPanel(model: model)

verify(!panel.canBecomeKey && !panel.canBecomeMain, "Indicator can never become key or main")
verify(panel.styleMask.contains(.nonactivatingPanel) && panel.styleMask.contains(.borderless), "Borderless non-activating panel")
verify(panel.ignoresMouseEvents, "Indicator ignores the mouse")
verify(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary),
       "Indicator joins all Spaces and full-screen apps")
verify(!panel.isVisible, "Indicator starts hidden")

// Phase 1: Volant is in the background behind a real editor, as it is when the global hotkey fires
// over another app. TextEdit is made frontmost first, so an unchanged frontmost app means it kept focus.
let editorID = "com.apple.TextEdit"
if let editorURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editorID) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: editorURL, configuration: configuration) { _, _ in }
    verify(waitUntil(timeout: 20) { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == editorID },
           "TextEdit becomes the frontmost app before dictation starts")
} else {
    print("NOTE: TextEdit is not installed here; the frontmost check uses whichever app is in front")
}
let frontmostBefore = NSWorkspace.shared.frontmostApplication?.processIdentifier
let startedActive = app.isActive
if startedActive { print("NOTE: fixture process started active; background-only checks use the key-window phase") }
model.listen(stopHint: "Release or press ⌥Space to stop")
model.escapeCancels = true
verify(waitUntil { panel.isVisible }, "Listening shows the indicator")
settle()
verify(startedActive || !app.isActive, "Showing the indicator does not activate Volant")
verify(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostBefore,
       "The frontmost app is unchanged by the indicator")
model.heard("Fictional words heard while TextEdit stays in front")
settle()
verify(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmostBefore && !app.isActive,
       "Live text in the indicator leaves the frontmost app in front")
verify(!panel.isKeyWindow && app.keyWindow == nil || startedActive, "No Volant window becomes key while in the background")
if let screen = DictationIndicatorPanel.targetScreen() {
    verify(abs(panel.frame.midX - screen.visibleFrame.midX) <= 1, "Indicator is centered horizontally: \(panel.frame) on \(screen.visibleFrame)")
    verify(panel.frame.minY >= screen.visibleFrame.minY && panel.frame.minY < screen.visibleFrame.midY, "Indicator sits near the bottom")
}
try capture(panel, "listening")

// Phase 2: another window is key (and its app active); the indicator must leave it key.
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
let other = NSWindow(contentRect: NSRect(x: 200, y: 400, width: 420, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
other.title = "Fictional editor"
let field = NSTextField(frame: NSRect(x: 20, y: 60, width: 380, height: 24))
field.stringValue = "Fictional draft text"
other.contentView?.addSubview(field)
other.makeKeyAndOrderFront(nil)
other.makeFirstResponder(field)
let otherResponder = other.firstResponder
let keyBefore = waitUntil { other.isKeyWindow }
if !keyBefore { print("NOTE: the other window could not become key here (key: \(String(describing: app.keyWindow)))") }
let stepsWithKeyChecks: [(String, () -> Void)] = [
    ("partial", { model.heard("Pick up the fictional order from the bakery at four and bring two extra boxes for the class") }),
    ("transcribing", { model.transcribing() }),
    ("copied", { model.finish("Copied 92 characters — press ⌘V to paste.", outcome: .copied) }),
    ("failed-volume", {
        model.listen(stopHint: "Release or press ⌥Space to stop")
        model.note(volumeProblem: "Couldn’t restore Fictional Speakers. Check its volume.")
        model.finish("Dictation needs microphone access.", outcome: .failed)
    }),
    ("cancelled", { model.finish("Dictation cancelled.", outcome: .cancelled) }),
    ("typing-listening", {
        model.listen(stopHint: "Release or press ⌥Space to stop")
        model.returnFinishes = true
        model.heard("Fictional notes typed into the editor while speaking")
    }),
    ("typed", { model.finish(DictationTypingSession.Outcome.typed(42).message, outcome: .typed) }),
    ("pasted", { model.finish(DictationTypingSession.Outcome.pasted(57).message, outcome: .typed) }),
    ("refused-password", {
        model.finish(DictationTypingSession.Outcome.copy(reason: .secureField, typedBefore: 0).message, outcome: .copied)
    }),
    ("refused-app-changed", {
        model.finish(DictationTypingSession.Outcome.copy(reason: .appChanged, typedBefore: 18).message, outcome: .copied)
    }),
]
for (state, step) in stepsWithKeyChecks {
    step()
    settle()
    verify(panel.isVisible, "Indicator visible for \(state)")
    verify(!panel.isKeyWindow && !panel.isMainWindow, "Indicator never becomes key or main in \(state)")
    if keyBefore {
        verify(other.isKeyWindow && app.keyWindow === other, "The other window stays key in \(state)")
        verify(other.firstResponder === otherResponder, "The other window keeps its first responder in \(state)")
    }
    try capture(panel, state)
}

// The result hides through the injected timer and the panel fades out.
verify(!pendingHides.isEmpty, "A result schedules its hide")
pendingHides.last?()
verify(model.phase == .hidden, "The scheduled hide clears the result")
verify(waitUntil { !panel.isVisible }, "Hiding removes the indicator")
if keyBefore { verify(other.isKeyWindow, "The other window is still key after the indicator hides") }
NSRunningApplication.runningApplications(withBundleIdentifier: editorID).forEach { $0.terminate() }
print("PASS: dictation indicator (\(appearanceName))")
