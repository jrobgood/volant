import AppKit
import SwiftUI
import CryptoKit
import VolantCore

setbuf(stdout, nil)

func verify(_ condition: @autoclosure () -> Bool, _ message: String = "Assertion", line: Int = #line) {
    if !condition() { fputs("FAIL at line \(line): \(message)\n", stderr); exit(1) }
}

/// Runs the main run loop until the condition has held without interruption for `stable` seconds,
/// or until `timeout` passes. Loaded CI runners and guests can miss a fixed sleep, so readiness is
/// polled; the stability window covers SwiftUI work queued for a later run-loop turn.
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
let positionDefaults = UserDefaults(suiteName: "volant.launcher.test." + UUID().uuidString)!
let app = NSApplication.shared
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let dark = CommandLine.arguments.contains("dark")
app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
let clipboard = ClipboardStore(retention: 10, storageURL: root.appendingPathComponent("clipboard.sqlite"), encryptionKey: SymmetricKey(size: .bits256))
let usage = UsageStore(url: root.appendingPathComponent("usage.sqlite"))
let notes = NotesStore(directory: root.appendingPathComponent("Notes"))
var actions: [String] = []
let model = LauncherModel(index: AppIndex(), clipboard: clipboard, notes: notes, config: Preferences(), usage: usage) { action in
    if case .create(let value) = action { actions.append(value) }
}
model.sections = [ResultSection(title: "Notes", rows: [.newNote("first"), .newNote("second")])]
model.activate(rowID: "newnote:second")
verify(actions == ["second\n"])
model.sections = [ResultSection(title: "Notes", rows: [.newNote("first")])]
model.activate(rowID: "newnote:second")
verify(actions.count == 1, "Stale click must not activate index zero")
let old = ResultRow.app(AppEntry(id: "fixture", name: "Screen Sharing", url: URL(fileURLWithPath: "/System/Applications/Utilities/Screen Sharing.app"), lastUsed: nil))
let updated = ResultRow.app(AppEntry(id: "fixture", name: "Screen Sharing", url: URL(fileURLWithPath: "/System/Applications/Utilities/Screen Sharing.app"), lastUsed: Date()))
verify(old != updated && old.id == updated.id, "Metadata changes retain row identity")
model.sections = [ResultSection(title: "Applications", rows: [updated, .newNote("other")])]
model.selection = 1
verify(old.id != model.selectedRow?.id, "Stale app value must not inherit first-row highlight")
let a = ResultRow.snippet(Snippet(name: "One", keyword: "", body: "A"))
let b = ResultRow.snippet(Snippet(name: "Two", keyword: "", body: "B"))
verify(a.id != b.id, "Imported snippets without keywords have distinct identities")
model.sections = [ResultSection(title: "Duplicates", rows: [a, a, b])]
verify(model.rows.count == 2, "Duplicate identities are removed before rendering")
let search = FuzzyMatcher.score(query: "screen", candidate: "Screen Sharing")
verify(search != nil)
verify(AppIndex.isUserFacingApp("/System/Applications/Utilities/Screen Sharing.app"))
// Actual launcher view, fictional snippet data; no filesystem/contact search or real clipboard mutation.
var config = Preferences()
config.snippets = [Snippet(name: "Screen sharing steps", keyword: "", body: "Connect to the test Mac."), Snippet(name: "Screen recording checklist", keyword: "", body: "Use fictional data.")]
model.config = config; model.query = "snip screen"
let host = NSHostingView(rootView: LauncherView(model: model, agents: model.agents).background(Color(nsColor: .windowBackgroundColor)))
let window = NSWindow(contentRect: NSRect(origin: .zero, size: LauncherPanel.size), styleMask: [.titled], backing: .buffered, defer: false)
window.appearance = app.appearance; window.contentView = host; window.makeKeyAndOrderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
verify(window.firstResponder is NSTextView, "Search obtains initial editing focus")
window.makeFirstResponder(nil)
model.searchFocusRequest = UUID()
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
verify(window.firstResponder is NSTextView, "Summon request restores editing focus")
host.layoutSubtreeIfNeeded()
let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
host.cacheDisplay(in: host.bounds, to: rep)
try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])!.write(to: URL(fileURLWithPath: "/tmp/volant-launcher-\(dark ? "dark" : "light").jpg"))
// Calculator answers render as cards and copy the complete single-line answer.
model.searchesSecondarySources = false
CurrencyRates.current = CurrencyRates(date: "2026-10-05", perEuro: ["USD": 1.25, "GBP": 0.8, "JPY": 160, "CHF": 0.95, "SEK": 11.5])
for query in ["1pm EST in CET", "2026-12-31 3pm PST in CET", "time in Tokyo", "2 + 2", "5 km in mi", "7:30pm tomorrow", "15% tip on 42", "days until 31 Mar", "145 mins to timespan", "time diff Tokyo", "2024-03-15T14:30:00Z", "#ff6363", "oklch(70% 0.15 250)", "100 usd in eur", "2026-03-08 2:30am New York in Paris", "2026-11-01 1:30am New York in Paris"] {
    model.query = query
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    guard case .calculation(let answer, _) = model.selectedRow else { fatalError("Missing timezone answer") }
    verify(!answer.copyText.contains("UTC") && !answer.copyText.contains("GMT+"), "Calculator answer uses a human-readable label")
    var copied = ""
    model.copyText = { copied = $0 }
    model.activate(rowID: model.selectedRow!.id)
    verify(copied == answer.copyText, "Copy retains the readable answer and day context")
    host.layoutSubtreeIfNeeded()
    let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: image)
    let cards = model.rows.compactMap { row -> CalculationAnswer? in if case .calculation(let card, _) = row { return card }; return nil }
    if query.contains("2:30am") { verify(cards.first?.inputDetail == "2:30 AM is skipped · clocks jump to 3:00 AM", "Skipped wall time explains the nearest valid time") }
    if query.contains("1:30am") { verify(cards.prefix(2).map(\.input) == ["2026-11-01 1:30am (EDT) New York in Paris", "2026-11-01 1:30am (EST) New York in Paris"], "Repeated wall time offers both readings") }
    let name = query.contains("2:30am") ? "skipped" : query.contains("1:30am") ? "repeated" : query.hasPrefix("2026") ? "rollover" : query.hasPrefix("time diff") ? "diff" : query.hasPrefix("time") ? "clock" : query.hasPrefix("2 +") ? "arithmetic" : query.hasPrefix("5 km") ? "unit" : query.hasSuffix("tomorrow") ? "relative" : query.contains("tip") ? "percent" : query.hasPrefix("days") ? "count" : query.hasSuffix("timespan") ? "span" : query.hasPrefix("2024") ? "iso" : query.hasPrefix("100 usd") ? "currency" : query.hasPrefix("#") ? "hex" : query.hasPrefix("oklch") ? "oklch" : "conversion"
    try image.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!.write(to:
        URL(fileURLWithPath: "/tmp/volant-launcher-time-\(name)-\(dark ? "dark" : "light").jpg"))
}
model.query = "2 + 2"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify(model.selectedRow?.secondaryAction == "Use Answer", "Calculation offers Use Answer")
model.activateSecondary()
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify(model.query == "4", "Use Answer replaces the query with the answer")
model.query += " * 3"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
guard case .calculation(let continued, _) = model.selectedRow else { fatalError("Missing continued calculation") }
verify(continued.copyText == "12", "Calculation continues from the answer")
model.query = "5 km in mi"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
model.activateSwap()
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify(model.query == "3.106856 mi in km", "Swap reverses the conversion")
guard case .calculation(let swapped, _) = model.selectedRow else { fatalError("Missing swapped conversion") }
verify(swapped.copyText == "5 km", "Swapped conversion returns to the original amount")
model.query = "1pm EST in"
verify(!model.rows.contains { if case .calculation = $0 { return true }; return false }, "Incomplete time query has no answer")
model.query = "2026-11-01 1:30am New York in"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify(!model.rows.contains { if case .calculation = $0 { return true }; return false }, "Incomplete repeated-time query has no explanation")
// A briefly incomplete edit keeps the card's space with the last answer dimmed; it is never a row.
model.query = "12 * 4"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify(model.selectedRow?.id == "calc:0", "Calculator card has a stable identity")
model.query = "12 * 4 +"
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
verify(model.heldCalculation != nil && !model.rows.contains { $0.id.hasPrefix("calc:") }, "Held answer stays visible without becoming a row")
host.layoutSubtreeIfNeeded()
let heldImage = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
host.cacheDisplay(in: host.bounds, to: heldImage)
try heldImage.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!.write(to:
    URL(fileURLWithPath: "/tmp/volant-launcher-time-held-\(dark ? "dark" : "light").jpg"))
model.query = "12 * 4 + 2"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
guard case .calculation(let resumed, _) = model.selectedRow else { fatalError("Missing resumed calculation") }
verify(model.heldCalculation == nil && resumed.copyText == "50", "Completed edit replaces the held answer in the same card")
// Palette themes still color the selected card and the held card after rows moved to row state.
let palette = ResolvedTheme(ColorTheme.named(dark ? "catppuccin-mocha" : "catppuccin-latte"))
let paletteText = palette.textStyles
let paletteHost = NSHostingView(rootView: LauncherView(model: model, agents: model.agents)
    .environment(\.volantTheme, palette).tint(palette.accent).foregroundStyle(paletteText.0, paletteText.1)
    .background(palette.windowBackground))
let paletteWindow = NSWindow(contentRect: NSRect(origin: .zero, size: LauncherPanel.size), styleMask: [.titled], backing: .buffered, defer: false)
paletteWindow.isReleasedWhenClosed = false
paletteWindow.appearance = app.appearance; paletteWindow.contentView = paletteHost; paletteWindow.orderFront(nil)
for (query, name) in [("12 * 4", "card"), ("12 * 4 +", "held")] {
    model.query = query
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    paletteHost.layoutSubtreeIfNeeded()
    let themed = paletteHost.bitmapImageRepForCachingDisplay(in: paletteHost.bounds)!
    paletteHost.cacheDisplay(in: paletteHost.bounds, to: themed)
    try themed.representation(using: .jpeg, properties: [.compressionFactor: 0.85])!.write(to:
        URL(fileURLWithPath: "/tmp/volant-launcher-time-palette-\(name)-\(dark ? "dark" : "light").jpg"))
}
verify(model.heldCalculation != nil, "Held answer renders under a palette theme")
paletteWindow.orderOut(nil)
paletteWindow.contentView = nil
model.query = "snip screen"
window.orderOut(nil)
print("PASS: launcher row identity, stale click, snippet identity, Screen Sharing eligibility, and native focus restoration")

// Identical result snapshots avoid invalidating the view; changed metadata still publishes.
var resultPublications = 0
let resultObservation = model.objectWillChange.sink { resultPublications += 1 }
model.sections = model.sections
verify(resultPublications == 0, "Identical result snapshots do not invalidate the view")
model.sections = [ResultSection(title: "Applications", rows: [old])]
model.sections = [ResultSection(title: "Applications", rows: [updated])]
verify(resultPublications == 2 && model.rows == [updated], "Changed metadata is published despite stable identity")
resultObservation.cancel()
model.query = "snip screen"
model.reset()
verify(model.query.isEmpty && model.selection == 0, "Search reset restores suggestions and first selection")
model.isPresented = true
model.selection = 1
let preservedSuggestion = model.selectedRow?.id
model.refreshForAppIndex()
verify(model.selectedRow?.id == preservedSuggestion, "Index refresh preserves same-query selection")
model.query = "snip screen"
let searchRows = model.rows.map(\.id)
model.refreshForAppIndex()
verify(model.rows.map(\.id) == searchRows, "Index refresh leaves a typed query intact")
model.isPresented = false

// Real non-activating panel: route actual in-process key and mouse events without opening an app.
var launched: [String] = []
let screenApp = AppEntry(id: "/System/Applications/Utilities/Screen Sharing.app", name: "Screen Sharing", url: URL(fileURLWithPath: "/System/Applications/Utilities/Screen Sharing.app"), lastUsed: Date())
let appIndex = AppIndex(entries: [screenApp], launch: { launched.append($0.id) })
let panel = LauncherPanel(index: appIndex, clipboard: clipboard, notes: notes, config: Preferences(), usage: usage, positionStore: positionDefaults, onNote: { _ in })
panel.model.searchesSecondarySources = false
panel.toggle()
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
verify(panel.isKeyWindow, "Actual launcher becomes key")
verify(panel.firstResponder is NSTextView, "Actual launcher has an editing responder")
for character in "screen" {
    let value = String(character)
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: UInt16(KeyCombo.keyCodes[value]!))!
    panel.sendEvent(event)
}
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
verify(panel.model.query == "screen", "Actual panel receives typed screen")
verify(panel.model.rows.first?.id == "app:" + screenApp.id)
for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
    let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 180, y: LauncherPanel.size.height - 110), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    panel.sendEvent(event)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
verify(launched == [screenApp.id], "Actual result button launches the clicked app")
verify(!panel.isVisible)
panel.toggle()
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
verify(panel.firstResponder is NSTextView, "Reopened panel restores keyboard focus")
// No run-loop grace period: the very first key must replace the old query.
for previous in ["", "screen", ":", "define test"] {
    panel.model.query = previous
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    panel.orderOut(nil)
    panel.toggle()
    verify(panel.firstResponder is NSTextView, "Summon synchronously installs its editing responder")
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: UInt16(KeyCombo.keyCodes["s"]!))!
    panel.sendEvent(event)
    verify(panel.model.query == "s", "First key survives reopen without stale text: " + previous)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    verify(panel.model.query == "s", "Deferred SwiftUI updates do not overwrite first key")
}
panel.model.query = "screen"
panel.orderOut(nil)
let keyWindowBeforePreparation = app.keyWindow
// Functional readiness, not a timing benchmark: loaded CI runners can miss a fixed sleep.
let preparationDeadline = Date().addingTimeInterval(3)
while (!panel.model.query.isEmpty || panel.model.isPresented) && Date() < preparationDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
verify(panel.model.query.isEmpty && !panel.model.isPresented, "Hidden preparation resets ordinary search")
verify(!panel.isVisible && !panel.isKeyWindow && app.keyWindow === keyWindowBeforePreparation, "Hidden preparation never shows a window or steals focus")
panel.toggle()
verify((panel.firstResponder as? NSTextView)?.string == "", "Prepared home editor contains no stale query")
panel.model.query = "screen"
panel.orderOut(nil)
panel.model.query = "snip changed while hidden"
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
verify(panel.model.query == "snip changed while hidden", "Stale hidden preparation cannot overwrite a newer query")
let modal = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
let session = app.beginModalSession(for: modal)
_ = app.runModalSession(session)
verify(app.modalWindow != nil)
panel.toggle()
verify(!panel.isVisible, "Modal session cannot leave a dead launcher visible")
app.endModalSession(session); modal.orderOut(nil)
print("PASS: real LauncherPanel screen typing, result mouse activation, repeat summon, and modal-session guard")

// Real search/Return/dismiss/idle/reopen cycles use a fake launch callback.
for _ in 0..<3 {
    let before = launched.count
    panel.toggle()
    for character in "screen" {
        let value = String(character)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: UInt16(KeyCombo.keyCodes[value]!))!
        panel.sendEvent(event)
    }
    verify(panel.model.query == "screen", "Reopened search accepts all immediately typed keys")
    let submit = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    panel.sendEvent(submit)
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    verify(launched.count == before + 1 && !panel.isVisible && panel.model.query.isEmpty, "Return launches once, dismisses, and prepares an empty home")
}
print("PASS: search/Return/dismiss/idle/reopen lifecycle with isolated launch callback")

// A new query must select its own first result, not the prior suggestion's identity.
let home = AppEntry(id: "fixture-home", name: "Home", url: URL(fileURLWithPath: "/System/Applications/Home.app"), lastUsed: Date(timeIntervalSince1970: 1))
let assistant = AppEntry(id: "fixture-assistant", name: "Home Assistant", url: URL(fileURLWithPath: "/Applications/Home Assistant.app"), lastUsed: Date())
var homeLaunches: [String] = []
let homeIndex = AppIndex(entries: [home, assistant], launch: { homeLaunches.append($0.id) })
let homeUsage = UsageStore(url: root.appendingPathComponent("home-\(dark ? "dark" : "light").sqlite"))
let homePanel = LauncherPanel(index: homeIndex, clipboard: clipboard, notes: notes, config: Preferences(), usage: homeUsage, positionStore: positionDefaults, onNote: { _ in })
homePanel.model.searchesSecondarySources = false
homePanel.toggle()
homePanel.model.promotedHarness = "all" // Render the footer status without connecting to any real harness.
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
verify(homePanel.model.selectedRow?.id == "app:" + assistant.id, "Fixture begins with Home Assistant as the recent suggestion")
func sendHomeKey(_ characters: String, code: UInt16) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: homePanel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    homePanel.sendEvent(event)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
// Check pixels away from text/icons: model assertions alone missed stale row styling.
func verifyHomeHighlight(firstSelected: Bool) {
    let content = homePanel.contentView!
    content.layoutSubtreeIfNeeded()
    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsHigh) / content.bounds.height
    func brightness(_ y: CGFloat) -> CGFloat {
        let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: Int(y * scale))!.usingColorSpace(.deviceRGB)!
        return (color.redComponent + color.greenComponent + color.blueComponent) / 3
    }
    // Rows start right below the search field; Herdr status lives in the footer, not above the results.
    let difference = brightness(109) - brightness(151)
    let expectedSign: CGFloat = (firstSelected == dark) ? 1 : -1
    verify(difference * expectedSign > 0.025, "Rendered highlight agrees with selection in both appearances")
}
for text in ["h", "o", "m"] {
    sendHomeKey(text, code: UInt16(KeyCombo.keyCodes[text]!))
    verify(homePanel.model.rows.first?.id == "app:" + home.id, "Home ranks first for each query prefix")
    verify(homePanel.model.selection == 0, "New query selects visible first result, not prior suggestion")
    verifyHomeHighlight(firstSelected: true)
}
sendHomeKey(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
verify(homePanel.model.selectedRow?.id == "app:" + assistant.id, "Down selects Home Assistant")
verifyHomeHighlight(firstSelected: false)
sendHomeKey(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126)
verify(homePanel.model.selectedRow?.id == "app:" + home.id, "Up returns to Home")
verify(homePanel.model.query == "hom", "Navigation does not rewrite the query")
verifyHomeHighlight(firstSelected: true)
if let content = homePanel.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
    content.cacheDisplay(in: content.bounds, to: bitmap)
    try bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75])!.write(to: URL(fileURLWithPath: "/tmp/volant-home-\(dark ? "dark" : "light").jpg"))
}
for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
    homePanel.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: 180, y: LauncherPanel.size.height - 109), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: homePanel.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
verify(homeLaunches == [home.id], "Clicking Home activates Home: launches=\(homeLaunches), key=\(homePanel.isKeyWindow), visible=\(homePanel.isVisible), responder=\(String(describing: homePanel.firstResponder))")
print("PASS: h/ho/hom initial selection, up/down navigation, and Home mouse activation with Herdr footer status")


// Volume uses fictional hardware; native Return exercises routing without changing host audio.
final class LauncherAudioFixture: AudioHardwareAccess {
    var value: Float32 = 0.35
    var muted = false
    var supported = true
    var available = true
    func output() throws -> AudioOutputState {
        guard available else { throw VolumeFailure(message: "No audio output is available. Connect an output and try again.") }
        return AudioOutputState(device: 1, name: "Fixture Speakers", volumes: [(0, value)], canSetVolume: supported, muted: muted, canSetMute: supported)
    }
    func setVolume(_ value: Float32, channel: UInt32, device: UInt32) throws { self.value = value }
    func setMute(_ value: Bool, device: UInt32) throws { muted = value }
}
let audioFixture = LauncherAudioFixture()
homePanel.model.volumeControl = VolumeControl(hardware: audioFixture)
homePanel.toggle()
homePanel.model.query = "volume"
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
verify(homePanel.model.rows.count == 3, "Volume command discovery")
func captureVolume(_ suffix: String) throws {
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let content = homePanel.contentView!
    content.layoutSubtreeIfNeeded()
    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: bitmap)
    try bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75])!.write(to: URL(fileURLWithPath: "/tmp/volant-volume-\(suffix)-\(dark ? "dark" : "light").jpg"))
}
try captureVolume("commands")
sendHomeKey("\r", code: 36)
verify(abs(audioFixture.value - 0.4) < 0.001 && homePanel.isVisible, "Return adjusts volume and keeps panel open")
verify(homePanel.model.actionFeedback?.contains("40%") == true, "Show actual volume readback")
homePanel.model.query = "volume 65%"
sendHomeKey("\r", code: 36)
verify(abs(audioFixture.value - 0.65) < 0.001, "Exact volume via native Return")
try captureVolume("applied")
homePanel.model.query = "mute"
sendHomeKey("\r", code: 36)
verify(audioFixture.muted, "Native mute command")
homePanel.model.query = "unmute"
sendHomeKey("\r", code: 36)
verify(!audioFixture.muted, "Native unmute command")
audioFixture.supported = false
homePanel.model.query = "volume"
sendHomeKey("\r", code: 36)
verify(homePanel.model.actionFeedback?.contains("doesn’t support") == true, "Unsupported hardware shows an actionable error")
if case .volume(_, let detail) = homePanel.model.rows[0] {
    verify(detail == "Hardware control only", "Unsupported control detail updates")
} else { verify(false, "Volume result expected") }
try captureVolume("unsupported")
homePanel.model.query = "volume 101"
verify(homePanel.model.rows.isEmpty && homePanel.model.notice != nil, "Invalid percentage has no action")
audioFixture.available = false
homePanel.model.query = "volume"
verify(homePanel.model.rows.isEmpty && homePanel.model.notice?.contains("No audio output") == true, "Missing output state")
try captureVolume("missing")
homePanel.orderOut(nil)
print("PASS: native volume discovery, Return, exact level, mute/unmute, unsupported and missing output")

final class RoutingFixture: AudioRouting {
    var output = "speakers"
    var input = "microphone"
    var connected = true
    var writes = 0
    func routes() throws -> [AudioRoute] {
        var result = [AudioRoute(uid: "speakers", device: 1, name: "Mac Speakers", direction: .output, current: output == "speakers"), AudioRoute(uid: "microphone", device: 2, name: "Mac Microphone", direction: .input, current: input == "microphone")]
        if connected {
            result += [AudioRoute(uid: "airpods", device: 3, name: "AirPods", direction: .output, current: output == "airpods"), AudioRoute(uid: "airpods", device: 3, name: "AirPods", direction: .input, current: input == "airpods")]
        }
        return result
    }
    func select(_ route: AudioRoute) throws {
        guard try routes().contains(where: { $0.id == route.id }) else { throw VolumeFailure(message: "This audio device disconnected. Refresh the list and try again.") }
        writes += 1
        if route.direction == .output { output = route.uid } else { input = route.uid }
    }
}
let routingFixture = RoutingFixture()
homePanel.model.audioRouting = routingFixture
homePanel.toggle()
homePanel.model.query = "audio"
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
verify(homePanel.model.rows.count == 4 && Set(homePanel.model.rows.map(\.id)).count == 4, "Input/output identities stay distinct")
try captureVolume("audio-devices")
homePanel.model.query = "output air"
sendHomeKey("\r", code: 36)
verify(routingFixture.output == "airpods" && routingFixture.input == "microphone", "Changing output leaves microphone alone")
verify(homePanel.model.rows.first?.kind == "Current", "Current marker updates after switching")
try captureVolume("audio-selected")
homePanel.model.query = "input air"
sendHomeKey("\r", code: 36)
verify(routingFixture.input == "airpods", "Input switching is independent")
homePanel.model.query = "audio output air"
let routeWrites = routingFixture.writes
routingFixture.connected = false
sendHomeKey("\r", code: 36)
verify(routingFixture.writes == routeWrites && homePanel.model.actionFeedback?.contains("disconnected") == true, "Disconnected selection does not fall back to another device")
try captureVolume("audio-disconnected")
homePanel.model.query = "audio missing"
verify(homePanel.model.rows.isEmpty && homePanel.model.notice != nil, "No matching audio devices")
verify(AudioRouteQuery("audiobook") == nil, "Audio command does not hijack unrelated names")
for command in ["audio", "input", "output"] { verify(LauncherRouting.isReserved(command), "Audio command reserved for import") }
homePanel.orderOut(nil)
print("PASS: native audio route listing, output/input independence, current marker, disconnect, empty search")

final class ConnectivityFixture: ConnectivityAccess {
    var delayed = false
    var callback: ((ConnectivitySnapshot) -> Void)?
    var joins = 0
    var completion: ((String?) -> Void)?
    let secured = WiFiChoice(ssid: Data("Studio".utf8), name: "Studio Wi-Fi", security: "WPA2 Personal", signal: -52, current: false)
    func load(_ source: String, refresh: Bool, completion: @escaping (ConnectivitySnapshot) -> Void) {
        callback = completion
        if delayed { return }
        if source == "bluetooth" {
            completion(ConnectivitySnapshot(items: [.bluetooth(id: "fixture-headphones", name: "Studio Headphones"), .bluetooth(id: "fixture-keyboard", name: "Desk Keyboard"), .settings("bluetooth")], message: nil))
        } else {
            completion(ConnectivitySnapshot(items: [.wifi(WiFiChoice(ssid: Data("Home".utf8), name: "Home Wi-Fi", security: "WPA3 Personal", signal: -35, current: true)), .wifi(secured), .settings("wifi")], message: nil))
        }
    }
    func join(_ network: WiFiChoice, password: String?, useSaved: Bool, completion: @escaping (String?) -> Void) {
        joins += 1
        self.completion = completion
    }
}
let connectivityFixture = ConnectivityFixture()
homePanel.model.connectivity = connectivityFixture
homePanel.toggle()
homePanel.model.query = "bluetooth"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify(homePanel.model.rows.count == 3, "Connected Bluetooth list")
try captureVolume("bluetooth")
homePanel.model.query = "wifi"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify(homePanel.model.rows.count == 3, "Wi-Fi network list")
try captureVolume("wifi")
homePanel.model.query = "wifi studio"
sendHomeKey("\r", code: 36)
verify(homePanel.model.wifiJoin?.id == connectivityFixture.secured.id && connectivityFixture.joins == 0, "Secured network opens password form without joining")
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify((homePanel.firstResponder as? NSTextView)?.isFieldEditor == true, "Password form gets a native editing responder")
try captureVolume("wifi-password")
for letter in "fixture" { sendHomeKey(String(letter), code: UInt16(KeyCombo.keyCodes[String(letter)]!)) }
sendHomeKey("\r", code: 36)
verify(connectivityFixture.joins == 1, "Native secure field Return submits exactly one join")
connectivityFixture.completion?("Incorrect fixture password")
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
sendHomeKey(String(UnicodeScalar(27)!), code: 53)
verify(homePanel.model.wifiJoin == nil && homePanel.isVisible, "Escape cancels password entry, not the launcher")
homePanel.model.joinWiFi(connectivityFixture.secured, password: "fictional-fixture", useSaved: false)
homePanel.model.joinWiFi(connectivityFixture.secured, password: "fictional-fixture", useSaved: false)
verify(connectivityFixture.joins == 2, "Duplicate joins are rejected")
connectivityFixture.completion?("Incorrect fixture password")
verify(!homePanel.model.connectivityBusy && homePanel.model.actionFeedback == "Incorrect fixture password", "Joining error remains visible")
connectivityFixture.delayed = true
homePanel.model.query = "wifi"
let stale = connectivityFixture.callback
homePanel.model.query = "output"
stale?(ConnectivitySnapshot(items: [.settings("wifi")], message: "Old scan"))
verify(homePanel.model.rows.allSatisfy { if case .audioRoute = $0 { return true }; return false }, "Old scans cannot overwrite a newer query")
homePanel.model.query = "wifi"
connectivityFixture.callback?(ConnectivitySnapshot(items: [.settings("wifi")], message: "Location access is off. Enable Volant in System Settings → Privacy & Security → Location Services."))
try captureVolume("wifi-denied")
homePanel.orderOut(nil)
print("PASS: connectivity lists, password form, cancel, duplicate joins, errors, stale scan rejection, denied state")


// A real key-window transfer must preserve a live conversation and unsent input.
var openedSettings = 0
let sticky = LauncherPanel(index: AppIndex(), clipboard: clipboard, notes: notes, config: Preferences(), usage: usage, positionStore: positionDefaults, onNote: { action in
    if case .settings = action { openedSettings += 1 }
})
sticky.model.searchesSecondarySources = false
sticky.model.presentAIChat()
sticky.model.acp.state.phase = "working"
sticky.model.acp.state.sessionID = "fictional-session"
sticky.model.acp.draft = "Keep this fictional draft"
sticky.toggle()
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
let otherWindow = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 180, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
for phase in ["starting", "working", "cancelling", "ready"] {
    sticky.model.presentAIChat()
    sticky.model.acp.state.phase = phase
    otherWindow.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    verify(sticky.isVisible && !sticky.isKeyWindow, "ACP remains visible after real focus loss in \(phase)")
    sticky.toggle()
    verify(sticky.isVisible && sticky.isKeyWindow && !sticky.model.showingACP && sticky.model.query.isEmpty, "Summon returns a visible inactive conversation to search")
}
/// Returns whether `upper` is in front of `lower` among this process's on-screen windows.
func isOrdered(_ upper: NSWindow, above lower: NSWindow) -> Bool {
    let order = (NSWindow.windowNumbers(options: []) ?? []).map(\.intValue)
    guard let top = order.firstIndex(of: upper.windowNumber), let bottom = order.firstIndex(of: lower.windowNumber) else { return false }
    return top < bottom
}
let orderedNotes = NotesPanel(store: notes)
orderedNotes.floatingPeer = sticky
sticky.floatingPeer = orderedNotes
sticky.model.presentAIChat()
sticky.model.acp.state.phase = "working"
orderedNotes.toggle()
verify(waitUntil(stable: 0.1) { orderedNotes.isKeyWindow && sticky.isVisible }, "Notes takes key focus while the ACP conversation stays visible")
verify(isOrdered(orderedNotes, above: sticky), "Notes opened during an ACP conversation is in front of the launcher")
verify(sticky.model.showingACP && sticky.model.acp.state.sessionID == "fictional-session", "Opening notes preserves the ACP conversation")
orderedNotes.cancelOperation(nil)
verify(!orderedNotes.isVisible && sticky.isVisible && sticky.model.showingACP, "Escape in notes closes only notes")
orderedNotes.toggle()
verify(waitUntil(stable: 0.1) { orderedNotes.isKeyWindow } && isOrdered(orderedNotes, above: sticky), "Reopened notes returns in front of the conversation")
sticky.toggle()
verify(waitUntil(stable: 0.1) { sticky.isKeyWindow } && orderedNotes.isVisible && isOrdered(sticky, above: orderedNotes), "Summoning the launcher orders it in front of visible notes")
orderedNotes.close()
verify(!orderedNotes.isVisible && sticky.isVisible, "Closing notes leaves the launcher visible")
sticky.cancelOperation(nil)
verify(!sticky.isVisible && sticky.model.acp.state.sessionID == "fictional-session", "Explicit dismissal keeps the ACP session")
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
verify(sticky.model.query.isEmpty && sticky.model.acp.draft == "Keep this fictional draft", "Hidden idle work preserves ACP session and draft")
sticky.toggle()
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify(sticky.model.query.isEmpty && sticky.model.acp.draft == "Keep this fictional draft", "Reopening shows search and preserves the chat draft")
otherWindow.makeKeyAndOrderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
verify(!sticky.isVisible && sticky.model.acp.state.sessionID == "fictional-session", "Untouched home dismisses on blur despite a retained ACP session")
sticky.toggle()
let settingsKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sticky.windowNumber, context: nil,
    characters: ",", charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43)!
sticky.sendEvent(settingsKey)
verify(openedSettings == 1 && !sticky.isVisible, "Command comma routes to Settings after hiding launcher")
verify(sticky.model.acp.state.sessionID == "fictional-session" && !sticky.model.acp.draft.isEmpty, "Opening Settings preserves chat and draft")
sticky.toggle()
sticky.model.acp.state.phase = "disconnected"
sticky.model.presentAIChat()
otherWindow.makeKeyAndOrderFront(nil)
verify(sticky.isVisible, "Unsent ACP draft survives focus loss")
sticky.toggle()
sticky.model.acp.draft = ""
sticky.model.query = "screen"
otherWindow.makeKeyAndOrderFront(nil)
verify(!sticky.isVisible, "Ordinary launcher search still dismisses on blur")
otherWindow.orderOut(nil)

// Native movement notifications save the position; re-summon does not recenter it.
sticky.toggle()
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
let screenFrame = NSScreen.main!.visibleFrame
let movedOrigin = NSPoint(x: screenFrame.minX + 24, y: screenFrame.minY + 36)
sticky.setFrameOrigin(movedOrigin)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
verify(positionDefaults.dictionary(forKey: "launcherPosition") != nil, "Window move saves position")
sticky.orderOut(nil)
sticky.toggle()
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify(sticky.frame.origin == movedOrigin, "Re-summon keeps the moved position")
sticky.orderOut(nil)
positionDefaults.set(["x": 100000.0, "y": 100000.0], forKey: "launcherPosition")
sticky.toggle()
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify(NSScreen.screens.contains { $0.visibleFrame.contains(sticky.frame) }, "Offscreen saved position is recovered onto a visible display")
sticky.orderOut(nil)
print("PASS: actual ACP focus loss/refocus, explicit dismissal, draft preservation, ordinary blur, saved placement, and offscreen recovery")

// Notes shortcuts with unavailable controls are absorbed instead of falling through to the alert.
/// Builds a key-down event addressed to `window`.
func notesKey(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16, in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                     windowNumber: window.windowNumber, context: nil, characters: characters,
                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}
let shortcutNotes = NotesStore(directory: root.appendingPathComponent("ShortcutNotes"))
let keyNotes = NotesPanel(store: shortcutNotes)
let keyNote = shortcutNotes.create(initialText: "Fictional shortcut note")
keyNotes.open(noteID: keyNote.id)
verify(waitUntil(stable: 0.1) { keyNotes.isKeyWindow }, "Notes takes key focus")
let previewKey = notesKey("e", .command, keyCode: 14, in: keyNotes)
let deleteKey = notesKey("\u{7F}", .command, keyCode: 51, in: keyNotes)
keyNotes.model.show(.actions)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
verify(keyNotes.performKeyEquivalent(with: previewKey), "Unavailable Command-E is absorbed under an overlay")
verify(keyNotes.model.editing && keyNotes.model.overlay == .actions, "Absorbed Command-E changes nothing")
verify(!keyNotes.performKeyEquivalent(with: deleteKey), "Command-Delete stays available to text editing")
verify(!keyNotes.performKeyEquivalent(with: notesKey("j", .command, keyCode: 38, in: keyNotes)), "Unrelated combinations are not claimed")
verify(shortcutNotes.notes.contains { $0.id == keyNote.id }, "Command-Delete under an overlay never trashes the note")
keyNotes.model.overlay = nil
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
verify(keyNotes.performKeyEquivalent(with: previewKey) && waitUntil { !keyNotes.model.editing }, "Available Command-E still toggles preview")
keyNotes.model.editing = true
keyNotes.close()
verify(!keyNotes.isVisible, "Notes closes after the shortcut checks")
print("PASS: notes shortcuts absorb unavailable combinations and keep available ones")

// App binding writes preserve nested unknown fields and reject conflicts/stale editors.
let bindingURL = root.appendingPathComponent("binding-config.json")
let bindingBytes = Data(#"{"future":{"keep":true},"aliases":{"other":"/Other.app","old":"/Test.app"},"appHotKeys":[{"bundleIdentifier":"test.app","hotKey":"ctrl+option+t","future":42}]}"#.utf8)
try bindingBytes.write(to: bindingURL)
try AppBindingStore.save(bundleID: "test.app", path: "/Test.app", originalAlias: "old", alias: "t", hotKey: "ctrl+option+y", expected: bindingBytes, at: bindingURL, available: { _ in true })
let changed = try Data(contentsOf: bindingURL)
let bindingObject = try JSONSerialization.jsonObject(with: changed) as! [String: Any]
verify((bindingObject["future"] as? [String: Bool])?["keep"] == true)
verify((bindingObject["appHotKeys"] as? [[String: Any]])?.first?["future"] as? Int == 42)
let bindingConfig = try JSONDecoder().decode(Preferences.self, from: changed)
verify(bindingConfig.aliases["old"] == nil && bindingConfig.aliases["t"] == "/Test.app" && bindingConfig.aliases["other"] == "/Other.app")
for (alias, shortcut, stale, available) in [("other", "ctrl+option+y", false, true), ("settings", "ctrl+option+y", false, true), ("t", "c", false, true), ("t", "option+space", false, true), ("t", "ctrl+option+y", true, true), ("t", "ctrl+option+y", false, false)] {
    do {
        try AppBindingStore.save(bundleID: "test.app", path: "/Test.app", originalAlias: "t", alias: alias, hotKey: shortcut, expected: stale ? bindingBytes : changed, at: bindingURL, available: { _ in available })
        verify(false, "Invalid binding must fail")
    } catch { verify(try! Data(contentsOf: bindingURL) == changed, "Failed edit preserves file") }
}
try AppBindingStore.save(bundleID: "test.app", path: "/Test.app", originalAlias: "t", alias: "", hotKey: "", expected: changed, at: bindingURL, available: { _ in true })
let cleared = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: bindingURL))
verify(cleared.appHotKeys.isEmpty && cleared.aliases["t"] == nil && cleared.aliases["other"] != nil)
model.query = "volant settings"
verify(model.rows.first?.id == "command:settings")
model.query = "reload config"
verify(model.rows.first?.id == "command:reload")
print("PASS: app binding persistence, conflicts and launcher settings commands")

let systemSettings = AppEntry(id: "/System/Applications/System Settings.app", name: "System Settings", url: URL(fileURLWithPath: "/System/Applications/System Settings.app"), lastUsed: nil)
let settingsSearch = LauncherModel(index: AppIndex(entries: [systemSettings]), clipboard: clipboard, notes: notes, config: Preferences(), usage: usage, onNote: { _ in })
settingsSearch.searchesSecondarySources = false
for query in ["sett", "Settings", " SETTINGS "] {
    settingsSearch.query = query
    verify(settingsSearch.rows.map(\.id) == ["app:" + systemSettings.id, "command:settings"], "Apps precede Volant commands")
    verify(settingsSearch.selectedRow?.id == "app:" + systemSettings.id, "System Settings starts selected")
}
settingsSearch.query = "volant settings"
verify(settingsSearch.rows.map(\.id) == ["command:settings"], "Explicit Volant Settings stays direct")
print("PASS: Settings search prioritizes System Settings over Volant Settings")

let globalURL = root.appendingPathComponent("global-shortcuts.json")
let globalBytes = Data(#"{"summonHotKey":"option+space","notesHotKey":"option+n","unknown":{"keep":true},"appHotKeys":[{"bundleIdentifier":"fixture.app","hotKey":"ctrl+option+t","unknown":42}]}"#.utf8)
try globalBytes.write(to: globalURL)
try GlobalShortcutStore.save(key: "summonHotKey", value: "ctrl+option+space", expectedValue: "option+space", at: globalURL, available: { _ in true })
try GlobalShortcutStore.save(key: "notesHotKey", value: "ctrl+option+n", expectedValue: "option+n", at: globalURL, available: { _ in true })
let globalSaved = try Data(contentsOf: globalURL)
let globalConfig = try JSONDecoder().decode(Preferences.self, from: globalSaved)
verify(globalConfig.summonHotKey == "ctrl+option+space" && globalConfig.notesHotKey == "ctrl+option+n")
let globalObject = try JSONSerialization.jsonObject(with: globalSaved) as! [String: Any]
verify((globalObject["unknown"] as? [String: Bool])?["keep"] == true)
verify((globalObject["appHotKeys"] as? [[String: Any]])?.first?["unknown"] as? Int == 42)
for (value, expected, available) in [("ctrl+option+n", "ctrl+option+space", true), ("ctrl+option+t", "ctrl+option+space", true), ("space", "ctrl+option+space", true), ("ctrl+option+y", "option+space", true), ("ctrl+option+y", "ctrl+option+space", false)] {
    do {
        try GlobalShortcutStore.save(key: "summonHotKey", value: value, expectedValue: expected, at: globalURL, available: { _ in available })
        verify(false, "Conflicting or stale global shortcut must fail")
    } catch { verify(try! Data(contentsOf: globalURL) == globalSaved, "Failed global shortcut edit preserves file") }
}
print("PASS: global shortcut changes, conflicts, stale edits and unknown-field preservation")

// Hover removal persists empty global keys rather than reverting to defaults.
try GlobalShortcutStore.save(key: "summonHotKey", value: "", expectedValue: "ctrl+option+space", at: globalURL, available: { _ in false })
try GlobalShortcutStore.save(key: "notesHotKey", value: "", expectedValue: "ctrl+option+n", at: globalURL, available: { _ in false })
let removedGlobals = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: globalURL))
verify(removedGlobals.summonHotKey.isEmpty && removedGlobals.notesHotKey.isEmpty)
try bindingBytes.write(to: bindingURL)
_ = try AppBindingStore.updateHotKey(bundleID: "test.app", path: "/Test.app", value: "ctrl+option+y", expectedValue: "ctrl+option+t", at: bindingURL, available: { _ in true })
let autoSavedApp = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: bindingURL))
verify(autoSavedApp.aliases["old"] == "/Test.app" && autoSavedApp.appHotKeys.first?.hotKey == "ctrl+option+y" && autoSavedApp.appHotKeys.first?.path == "/Test.app", "Autosaving a shortcut must not apply or clear aliases")
_ = try AppBindingStore.updateHotKey(bundleID: "test.app", path: "/Test.app", value: "", expectedValue: "ctrl+option+y", at: bindingURL, available: { _ in false })
let removedApp = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: bindingURL))
verify(removedApp.appHotKeys.isEmpty && removedApp.aliases["old"] == "/Test.app")
print("PASS: immediate shortcut persistence and removal preserve aliases and disabled global keys")

verify(SystemSettingsDestination.search("settings").isEmpty, "Generic settings must preserve the System Settings app ranking")
verify(SystemSettingsDestination.search("settings login").first?.title == "Login Items & Extensions")
verify(SystemSettingsDestination.search("dark mode").first?.title == "Appearance")
verify(SystemSettingsDestination.search("system settings software update").first?.title == "Software Update")
verify(SystemSettingsDestination.search("nonexistent pane").isEmpty)
verify(Set(SystemSettingsDestination.all.map(\.id)).count == SystemSettingsDestination.all.count)
print("PASS: System Settings destination search, synonyms and stable identities")

panel.model.query = "wifi settings"
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
verify(panel.model.rows.first?.id == "system-settings:com.apple.wifi-settings-extension", "Explicit Wi-Fi settings must bypass network discovery")
panel.model.query = "settings login"
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
verify(panel.model.rows.first?.kind == "System Settings")
let destinationHost = NSHostingView(rootView: LauncherView(model: panel.model, agents: panel.model.agents).background(Color(nsColor: .windowBackgroundColor)))
destinationHost.frame = NSRect(origin: .zero, size: LauncherPanel.size)
let destinationWindow = NSWindow(contentRect: destinationHost.frame, styleMask: [.titled], backing: .buffered, defer: false)
destinationWindow.appearance = app.appearance
destinationWindow.contentView = destinationHost
destinationHost.layoutSubtreeIfNeeded()
let destinationRep = destinationHost.bitmapImageRepForCachingDisplay(in: destinationHost.bounds)!
destinationHost.cacheDisplay(in: destinationHost.bounds, to: destinationRep)
try destinationRep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/volant-destinations-\(dark ? "dark" : "light").png"))
print("PASS: direct Settings queries bypass connectivity discovery; rendered destination row")

// Snap geometry uses visible screen coordinates, including negative monitor origins.
let snapScreen = NSRect(x: -1600, y: 40, width: 1600, height: 900)
let centeredFrame = NSRect(x: -1175, y: 250, width: 750, height: 480)
let centerSnap = LauncherSnapPlacement.resolve(centeredFrame.offsetBy(dx: 8, dy: -10), in: snapScreen)
verify(centerSnap.frame == centeredFrame && centerSnap.vertical == -800 && centerSnap.horizontal == 490)
let edgeSnap = LauncherSnapPlacement.resolve(NSRect(x: -1584, y: 447, width: 750, height: 480), in: snapScreen)
verify(edgeSnap.frame.origin == NSPoint(x: -1580, y: 440), "Snap uses usable screen inset, not menu bar or Dock area")
let freeFrame = NSRect(x: -1450, y: 150, width: 750, height: 480)
let freeSnap = LauncherSnapPlacement.resolve(freeFrame, in: snapScreen)
verify(freeSnap.frame == freeFrame && freeSnap.vertical == nil && freeSnap.horizontal == nil)
let oversized = LauncherSnapPlacement.resolve(NSRect(x: 0, y: 0, width: 1800, height: 1100), in: snapScreen)
verify(oversized.vertical == nil && oversized.horizontal == nil)

func samePixelPosition(_ actual: NSPoint, _ expected: NSPoint) -> Bool {
    abs(actual.x - expected.x) <= 1 && abs(actual.y - expected.y) <= 1
}
sticky.toggle()
let guideScreen = sticky.screen!.visibleFrame
let idealOrigin = NSPoint(x: guideScreen.midX - sticky.frame.width / 2, y: guideScreen.midY - sticky.frame.height / 2)
let proposedOrigin = NSPoint(x: idealOrigin.x + 5, y: idealOrigin.y - 5)
sticky.drag(to: proposedOrigin, pointer: NSPoint(x: guideScreen.midX, y: guideScreen.midY), freely: false)
verify(samePixelPosition(sticky.frame.origin, idealOrigin), "Native snap origin \(sticky.frame.origin), expected \(idealOrigin) within one display pixel")
verify(sticky.snapGuides.isVisible, "Snapped drag shows guide overlay")
verify(sticky.isKeyWindow, "Alignment guides never steal typing focus")
sticky.drag(to: proposedOrigin, pointer: NSPoint(x: guideScreen.midX, y: guideScreen.midY), freely: true)
verify(samePixelPosition(sticky.frame.origin, proposedOrigin) && !sticky.snapGuides.isVisible, "Option bypasses snapping")
sticky.drag(to: proposedOrigin, pointer: NSPoint(x: guideScreen.midX, y: guideScreen.midY), freely: false)
sticky.endDragging()
verify(!sticky.snapGuides.isVisible, "Releasing drag clears guides")
sticky.drag(to: proposedOrigin, pointer: NSPoint(x: guideScreen.midX, y: guideScreen.midY), freely: false)
sticky.orderOut(nil)
verify(!sticky.snapGuides.isVisible, "Dismissing launcher clears guides")

// Render the actual guide view around an excluded launcher-sized area.
let guideView = SnapGuideView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
guideView.appearance = app.appearance
guideView.vertical = 500; guideView.horizontal = 350
guideView.exclusion = NSRect(x: 125, y: 110, width: 750, height: 480)
let guideCanvas = NSView(frame: guideView.frame)
guideCanvas.appearance = app.appearance
guideCanvas.wantsLayer = true
guideCanvas.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
let guideLauncher = NSHostingView(rootView: LauncherView(model: panel.model, agents: panel.model.agents).background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14)))
guideLauncher.frame = guideView.exclusion
guideCanvas.addSubview(guideLauncher)
guideCanvas.addSubview(guideView)
guideCanvas.layoutSubtreeIfNeeded()
let guideRep = guideCanvas.bitmapImageRepForCachingDisplay(in: guideCanvas.bounds)!
guideCanvas.cacheDisplay(in: guideCanvas.bounds, to: guideRep)
try guideRep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/volant-snap-\(dark ? "dark" : "light").png"))
print("PASS: snap center/edges, multi-display geometry, free positioning, focus and guide cleanup")

// Exercise the native wing responder, not only the placement helper.
sticky.toggle()
sticky.setFrameOrigin(NSPoint(x: idealOrigin.x - 70, y: idealOrigin.y - 50))
func findDragHandle(_ view: NSView) -> WindowDragView? {
    if let handle = view as? WindowDragView { return handle }
    return view.subviews.lazy.compactMap(findDragHandle).first
}
let dragHandle = findDragHandle(sticky.contentView!)!
let startLocation = NSPoint(x: 30, y: sticky.frame.height - 30)
func dragEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                      windowNumber: sticky.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}
dragHandle.mouseDown(with: dragEvent(.leftMouseDown, at: startLocation))
dragHandle.mouseDragged(with: dragEvent(.leftMouseDragged, at: NSPoint(x: startLocation.x + 75, y: startLocation.y + 55)))
verify(samePixelPosition(sticky.frame.origin, idealOrigin) && sticky.snapGuides.isVisible, "Native wing drag reaches snapped placement")
dragHandle.mouseUp(with: dragEvent(.leftMouseUp, at: startLocation))
verify(!sticky.snapGuides.isVisible)
sticky.orderOut(nil)
print("PASS: native wing drag and release use snap geometry and clear guides")

// Dispatch through NSWindow hit testing, rather than calling the drag view directly.
sticky.toggle()
sticky.contentView!.layoutSubtreeIfNeeded()
func dragHandles(_ view: NSView) -> [WindowDragView] {
    (view as? WindowDragView).map { [$0] } ?? view.subviews.flatMap(dragHandles)
}
let topGrip = dragHandles(sticky.contentView!).first { $0.bounds.width > 100 }!
let gripPoint = topGrip.convert(NSPoint(x: topGrip.bounds.midX, y: topGrip.bounds.midY), to: nil)
let beforeGripDrag = sticky.frame.origin
sticky.sendEvent(dragEvent(.leftMouseDown, at: gripPoint))
sticky.sendEvent(dragEvent(.leftMouseDragged, at: NSPoint(x: gripPoint.x + 58, y: gripPoint.y - 43)))
sticky.sendEvent(dragEvent(.leftMouseUp, at: gripPoint))
verify(sticky.frame.origin != beforeGripDrag, "Full-width top grip receives actual window-dispatched drag events")
verify(!sticky.snapGuides.isVisible, "Window-dispatched mouse release clears guides")
sticky.orderOut(nil)
print("PASS: top grip hit testing moves the launcher through NSWindow event dispatch")

// Built-in discovery, power commands and emoji grid use fictional services and clipboard.
final class FixtureCaffeinateAssertions: CaffeinateAssertions {
    var created = 0
    var released = 0
    func create(display: Bool, timeout: TimeInterval) throws -> UInt32 { created += 1; return 7 }
    func release(_ id: UInt32) throws { released += 1 }
}
let power = FixtureCaffeinateAssertions()
let awake = CaffeinateService(assertions: power, automaticTimer: false)
var requestedSystemActions: [SystemAction] = []
let corePanel = LauncherPanel(index: AppIndex(entries: []), clipboard: clipboard, notes: notes,
    config: Preferences(), usage: usage, positionStore: positionDefaults, caffeinate: awake, onNote: { action in
        if case .systemAction(let system) = action { requestedSystemActions.append(system) }
    })
corePanel.model.searchesSecondarySources = false
var copiedEmoji: [String] = []
corePanel.model.copyText = { copiedEmoji.append($0) }
let fixtureEmoji = zip(
    ["😀", "🐱", "☕️", "🎉", "🚀", "❤️", "🌈", "🍎", "🌻", "👍", "😃", "😄", "😁", "😆", "😅", "😂", "🙂", "🙃", "😉", "😊", "😍", "🥰", "😘", "😎", "🤩", "🥳", "🤔", "🤗", "😴", "🤓", "🐶", "🦊", "🐼", "🦁", "🐸", "🐵", "🐧", "🦋", "🌍", "⭐️"],
    ["Grinning face", "Cat", "Hot beverage", "Party popper", "Rocket", "Red heart", "Rainbow", "Red apple", "Sunflower", "Thumbs up", "Grinning face with big eyes", "Grinning face with smiling eyes", "Beaming face", "Squinting face", "Grinning face with sweat", "Face with tears of joy", "Slightly smiling face", "Upside-down face", "Winking face", "Smiling face", "Heart eyes", "Smiling face with hearts", "Blowing a kiss", "Sunglasses", "Star-struck", "Partying face", "Thinking face", "Hugging face", "Sleeping face", "Nerd face", "Dog", "Fox", "Panda", "Lion", "Frog", "Monkey", "Penguin", "Butterfly", "Globe", "Star"]
).map { EmojiEntry(symbol: $0.0, name: $0.1) }
corePanel.model.emojiSearch = { term in term == "missing" ? [] : fixtureEmoji }
corePanel.toggle()
verify(corePanel.model.rows.contains { $0.id == "core:caffeinate" })
verify(corePanel.model.rows.contains { $0.id == "core:emoji" })
verify(ResultRow.core(.emoji).isCoreCommand && !ResultRow.emoji(fixtureEmoji[0]).isCoreCommand)
func sendCoreKey(_ characters: String, code: UInt16) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: corePanel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)!
    corePanel.sendEvent(event)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
func renderCore(_ name: String) throws {
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let view = corePanel.contentView!
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/volant-core-\(name)-\(dark ? "dark" : "light").png"))
}
try renderCore("commands")
// System actions are only requested from the app delegate on Return; searching never performs one.
corePanel.model.query = "restart"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify(corePanel.model.rows.first?.id == "system-action:restart", "Restart is found by name")
corePanel.model.query = "sleep"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify(corePanel.model.rows.contains { $0.id == "system-action:sleep" } && corePanel.model.rows.contains { $0.id == "system-action:sleepDisplays" }, "Sleep lists both sleep actions")
try renderCore("system-actions")
corePanel.model.query = "lock screen"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
verify(requestedSystemActions.isEmpty, "Typing never performs a system action")
verify(corePanel.model.selectedRow?.id == "system-action:lockScreen", "Lock Screen is selected for its name")
verify(corePanel.makeFirstResponder(coreSearchField(in: corePanel.contentView!)!), "Restore native editor after render capture")
sendCoreKey("\r", code: 36)
verify(requestedSystemActions == [.lockScreen], "Return hands Lock Screen to the app delegate once")
print("PASS: system actions are searchable, render as commands, and run only on Return")
// Fictional Apple Shortcuts: native Return uses stable IDs and late catalogs keep selection.
let recipe = AppleShortcut(id: "11111111-1111-4111-8111-111111111111", name: "Leftover Recipes")
let volumeShortcut = AppleShortcut(id: "22222222-2222-4222-8222-222222222222", name: "Set Volume to 50%")
var shortcutRuns: [String] = []
var finishShortcut: ((String?) -> Void)?
corePanel.model.appleShortcuts.loadOverride = { $0([recipe, volumeShortcut], nil) }
corePanel.model.appleShortcuts.runOverride = { shortcutRuns.append($0); finishShortcut = $1 }
corePanel.model.appleShortcuts.refresh()
corePanel.model.query = "apple shortcuts"
let expectedShortcutIDs = ["apple-shortcut:" + recipe.id, "apple-shortcut:" + volumeShortcut.id]
let shortcutResultsDeadline = Date().addingTimeInterval(3)
while corePanel.model.rows.map(\.id) != expectedShortcutIDs && Date() < shortcutResultsDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
verify(corePanel.model.rows.map(\.id) == expectedShortcutIDs, "Apple Shortcuts results arrive before the bounded deadline")
verify(corePanel.model.selectedRow?.primaryAction == "Run Shortcut")
try renderCore("shortcuts")
verify(corePanel.makeFirstResponder(coreSearchField(in: corePanel.contentView!)!), "Restore native editor after render capture")
sendCoreKey("\r", code: 36)
sendCoreKey("\r", code: 36)
verify(shortcutRuns == [recipe.id], "Return runs the selected shortcut exactly once: runs=\(shortcutRuns), key=\(corePanel.isKeyWindow), visible=\(corePanel.isVisible), query=\(corePanel.model.query), row=\(String(describing: corePanel.model.selectedRow?.id)), responder=\(String(describing: corePanel.firstResponder))")
finishShortcut?("Fictional run failure")
verify(waitUntil { corePanel.model.actionFeedback == "Fictional run failure" }, "Shortcut run failure reaches the status bar")
try renderCore("shortcuts-error")
corePanel.model.selection = 1
corePanel.model.appleShortcuts.loadOverride = { $0(nil, "Fictional refresh failure") }
corePanel.model.appleShortcuts.refresh(force: true)
verify(waitUntil { corePanel.model.actionFeedback == "Fictional refresh failure" }, "Refresh failure remains visible alongside cached rows")
verify(corePanel.model.selectedRow?.id == "apple-shortcut:" + volumeShortcut.id, "Failed refresh preserves selection and cached results")
try renderCore("shortcuts-stale")
corePanel.model.query = "shortcuts missing"
try renderCore("shortcuts-empty")
verify(corePanel.model.rows.isEmpty && corePanel.model.notice != nil)
corePanel.model.query = "recipes"
verify(corePanel.model.rows.contains { $0.id == "apple-shortcut:" + recipe.id }, "Shortcuts match ordinary search")
corePanel.model.appleShortcuts.loadOverride = { $0([], nil) }
corePanel.model.appleShortcuts.refresh(force: true)
corePanel.model.query = "caffeinate"
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
verify(corePanel.model.rows.allSatisfy { !$0.id.hasPrefix("apple-shortcut:") }, "Late discovery cannot replace a newer command")
print("PASS: Apple Shortcuts discovery, Return, duplicate guard, errors, empty state and stale-query protection")
corePanel.model.query = "caffeinate 30m"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
// Set up native text focus without entering AppKit's synchronous mouse tracking loop.
// Summon/typing focus is covered above; this fixture checks command keyboard delivery.
func coreSearchField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField,
       field.placeholderString == "Search for apps, files, contacts, or calculate…" { return field }
    return view.subviews.lazy.compactMap { coreSearchField(in: $0) }.first
}
verify(corePanel.makeFirstResponder(coreSearchField(in: corePanel.contentView!)!), "Focus core command search")
verify(corePanel.firstResponder is NSTextView, "Core command search has a native field editor")
sendCoreKey("\r", code: 36)
verify(awake.isActive && power.created == 1, "Return starts a Caffeinate session: key=\(corePanel.isKeyWindow), responder=\(String(describing: corePanel.firstResponder)), query=\(corePanel.model.query), row=\(String(describing: corePanel.model.selectedRow?.id)), created=\(power.created), active=\(awake.isActive)")
verify(corePanel.model.rows.map(\.id) == ["caffeinate:off"], "Active session offers Stop")
verify(corePanel.model.actionFeedback == nil, "Active cup replaces the success status bar")
try renderCore("active")
sendCoreKey("\r", code: 36)
verify(!awake.isActive && power.released == 1, "Return stops a Caffeinate session")
corePanel.model.query = "caffeinate nonsense"
verify(corePanel.model.rows.isEmpty && corePanel.model.notice != nil)
try renderCore("invalid")
/// Describes the emoji grid's keyboard state for failure messages.
func emojiGridState() -> String {
    "selection=\(corePanel.model.selection), rows=\(corePanel.model.rows.count), query=\(corePanel.model.query), key=\(corePanel.isKeyWindow), responder=\(String(describing: corePanel.firstResponder)), delegate=\(String(describing: (corePanel.firstResponder as? NSTextView)?.delegate)), placeholder=\(String(describing: ((corePanel.firstResponder as? NSTextView)?.delegate as? NSTextField)?.placeholderString))"
}
/// Whether the launcher's search field editor holds keyboard focus, so arrow keys reach the grid
/// handlers. The picker renames the field's placeholder, so the field is found as the editor's owner.
func coreSearchEditorFocused() -> Bool {
    guard corePanel.isKeyWindow, let editor = corePanel.firstResponder as? NSTextView,
          let field = editor.delegate as? NSTextField else { return false }
    return field.placeholderString == "Search emoji…" && field.isDescendant(of: corePanel.contentView!)
}
corePanel.model.query = ":"
verify(waitUntil(stable: 0.15) { corePanel.model.searchText.isEmpty && corePanel.model.rows.count == fixtureEmoji.count && coreSearchEditorFocused() },
       "Picker hides command prefix with the search editor focused: \(emojiGridState())")
let emojiArrows: [(String, UInt16, Int, String)] = [("\u{F701}", 125, 10, "Down moves one emoji grid row"),
                                                    ("\u{F703}", 124, 11, "Right moves one emoji grid cell"),
                                                    ("\u{F702}", 123, 10, "Left moves one emoji grid cell"),
                                                    ("\u{F700}", 126, 0, "Up moves one emoji grid row")]
for (characters, code, expected, name) in emojiArrows {
    sendCoreKey(characters, code: code)
    verify(waitUntil { corePanel.model.selection == expected }, "\(name): \(emojiGridState())")
}
try renderCore("emoji")
sendCoreKey("\r", code: 36)
verify(copiedEmoji == [fixtureEmoji[0].symbol] && !corePanel.isVisible, "Return copies selected emoji and dismisses")
corePanel.toggle(); corePanel.model.query = ":missing"
verify(corePanel.model.rows.isEmpty)
try renderCore("emoji-empty")
corePanel.model.searchText = "fixture"
verify(corePanel.model.query == ":fixture" && corePanel.model.selection == 0)
corePanel.orderOut(nil)
print("PASS: core command marks/discovery, Caffeinate Return/start/stop/errors, emoji grid arrows and copy")

try GlobalShortcutStore.save(key: "emojiHotKey", value: "ctrl+option+e", expectedValue: "", at: globalURL, available: { _ in true })
do {
    try GlobalShortcutStore.save(key: "notesHotKey", value: "ctrl+option+e", expectedValue: "", at: globalURL, available: { _ in true })
    verify(false, "Emoji shortcut must conflict with other global commands")
} catch { }
try GlobalShortcutStore.save(key: "emojiHotKey", value: "", expectedValue: "ctrl+option+e", at: globalURL, available: { _ in false })
let emojiSettings = try JSONSerialization.jsonObject(with: Data(contentsOf: globalURL)) as! [String: Any]
verify(emojiSettings["emojiHotKey"] as? String == "")
print("PASS: emoji shortcut save, conflict and removal")

// Translation uses fictional catalog, availability, output and clipboard throughout.
let translator = corePanel.model.translation
translator.loadLanguages = { ["en", "es", "fr"] }
translator.availability = { _ in .installed }
translator.translateFixture = { _ in TranslationResult(text: "Hola\n¿Cómo estás?", source: "en") }
corePanel.toggle()
corePanel.model.query = "translate"
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
verify(corePanel.model.showingTranslation && corePanel.model.rows.isEmpty)
try renderCore("translation-empty")
translator.text = "Hello\nHow are you?"
translator.target = "es"
verify(corePanel.keepsVisibleOnBlur, "Translation draft survives focus loss")
Task { @MainActor in translator.start() }
verify(waitUntil { translator.output == "Hola\n¿Cómo estás?" }, "Translation session view delivers fixture result")
try renderCore("translation-result")
var translationCopies: [String] = []
translator.copy { translationCopies.append($0) }
verify(translationCopies == [translator.output], "Explicit copy delivers translation")
translator.target = "fr"
verify(translator.output.isEmpty, "Language change clears stale translation")
translator.availability = { _ in .unsupported }
Task { @MainActor in translator.start() }
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
verify(translator.pairState == .unsupported && !translator.busy)
try renderCore("translation-unsupported")
translator.availability = { _ in .installed }
translator.target = "es"
translator.text = "Good morning"
RunLoop.main.run(until: Date().addingTimeInterval(1.2))
verify(translator.output == "Hola\n¿Cómo estás?" && !translator.outputIsStale, "A pause in typing translates without ⌘T")
translator.text = "Hello\nHow are you?"
corePanel.orderOut(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
verify(corePanel.model.query == "translate" && translator.text == "Hello\nHow are you?", "Hidden idle work preserves translation draft")
corePanel.toggle()
translator.clear()
verify(!corePanel.keepsVisibleOnBlur)
corePanel.orderOut(nil)
print("PASS: translation view, draft lifetime, explicit copy, language changes and unsupported pair")

let dictionary = corePanel.model.dictionary
dictionary.debounce = .zero
dictionary.lookup = { DictionaryEntry(term: $0, definition: "A fictional definition.") }
corePanel.toggle()
corePanel.model.query = "define"
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
verify(corePanel.model.showingDictionary && corePanel.model.rows.isEmpty)
func dictionaryField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.placeholderString == "Word or phrase…" { return field }
    return view.subviews.lazy.compactMap { dictionaryField(in: $0) }.first
}
verify(corePanel.makeFirstResponder(dictionaryField(in: corePanel.contentView!)!), "Focus dictionary search")
(corePanel.firstResponder as? NSTextView)?.insertText("serendipity", replacementRange: NSRange(location: NSNotFound, length: 0))
sendCoreKey("\r", code: 36)
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
verify(dictionary.entry?.term == "serendipity", "Native dictionary field and Return deliver query")
try renderCore("dictionary-result")
corePanel.model.query = "Calculator"
verify(dictionary.input.isEmpty && dictionary.entry == nil, "Leaving dictionary clears transient state")
corePanel.model.query = "define phrase"
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
verify(dictionary.entry?.term == "phrase", "Inline define query preserves phrase")
sendCoreKey("\u{1b}", code: 53)
verify(!corePanel.isVisible && dictionary.input.isEmpty, "Escape dismisses and clears dictionary")
print("PASS: dictionary routing, native text editing, Return, mode exit and Escape cleanup")

/// Finds a control's frame in window coordinates by the identifier of the `ControlAnchor` behind
/// it, or by an AppKit button title, so Settings clicks follow the layout instead of hard-coded
/// points. On a miss it prints what it saw so a layout change is diagnosable from one run. An
/// identified control is scrolled into view first, as a person would, because taller macOS 27 form
/// rows can leave later controls such as color theme tiles below the fold of a fixed window.
func controlFrame(_ name: String, in window: NSWindow, reportMissing: Bool = true) -> NSRect? {
    var seen: [String] = []
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    for view in views(window.contentView!) where !view.isHiddenOrHasHiddenAncestor {
        if let identifier = view.identifier?.rawValue, identifier.hasPrefix("settings.") || identifier.hasPrefix("chat.") {
            seen.append(identifier)
            if identifier == name {
                view.scrollToVisible(view.bounds)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                return view.convert(view.bounds, to: nil)
            }
        }
        if let button = view as? NSButton, !button.title.isEmpty {
            seen.append(button.title)
            if button.title == name { return button.convert(button.bounds, to: nil) }
        }
    }
    if reportMissing { print("Controls seen while looking for \(name): \(seen)") }
    return nil
}

/// The topmost visible switch, which in the Status Bar pane is the Herdr source.
func topSwitchFrame(in window: NSWindow) -> NSRect? {
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    return views(window.contentView!).compactMap { $0 as? NSSwitch }.filter { !$0.isHiddenOrHasHiddenAncestor }
        .map { $0.convert($0.bounds, to: nil) }.max { $0.midY < $1.midY }
}

// Settings navigation uses real clicks across the sidebar row, with isolated configuration.
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
let settingsURL = root.appendingPathComponent("settings.json")
try Data(#"{"promotedHarness":"claude","ai":{"provider":"claude","project":""}}"#.utf8).write(to: settingsURL)
let settingsBeforeNavigation = try Data(contentsOf: settingsURL)
var openedAI: [AIConfiguration] = []
var settingsController: SettingsWindowController!
settingsController = SettingsWindowController(configURL: settingsURL, openAI: { openedAI.append($0) }) {
    settingsController.refresh(try! JSONDecoder().decode(Preferences.self, from: Data(contentsOf: settingsURL)))
}
settingsController.refresh(try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: settingsURL)))
let settingsWindow = settingsController.window!
settingsWindow.setContentSize(NSSize(width: 680, height: 500))
settingsController.showWindow(nil)
settingsWindow.makeKeyAndOrderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
func clickSettings(_ point: NSPoint) {
    func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: settingsWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }
    // Native bordered buttons track synchronously until they consume mouse-up.
    app.postEvent(event(.leftMouseUp), atStart: true)
    settingsWindow.sendEvent(event(.leftMouseDown))
    if let release = app.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
        settingsWindow.sendEvent(release)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
}
func clickSettings(_ name: String) {
    waitUntil { controlFrame(name, in: settingsWindow, reportMissing: false) != nil }
    guard let frame = controlFrame(name, in: settingsWindow) else { verify(false, "Settings shows \(name)"); return }
    clickSettings(NSPoint(x: frame.midX, y: frame.midY))
}
func clickHerdrSwitch() {
    guard let frame = topSwitchFrame(in: settingsWindow) else { verify(false, "Status Bar shows the Herdr switch"); return }
    clickSettings(NSPoint(x: frame.midX, y: frame.midY))
}
/// SwiftUI draws sidebar text without a readable field, so rows are found by their fixed order.
/// A native table ignores a first click while its window is not key, which is how the headless
/// guest leaves this fixture; the row is then selected through the table so the SwiftUI selection
/// binding is still exercised, and the miss is reported.
func clickSidebarRow(_ index: Int) {
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    guard let table = views(settingsWindow.contentView!).compactMap({ $0 as? NSTableView }).first(where: { $0.numberOfRows == 7 }) else {
        verify(false, "Settings shows a seven-row sidebar"); return
    }
    let frame = table.convert(table.rect(ofRow: index), to: nil)
    clickSettings(NSPoint(x: frame.midX, y: frame.midY))
    if table.selectedRow != index {
        print("NOTE: sidebar click not delivered (Settings key: \(settingsWindow.isKeyWindow)); selecting row \(index) through the table")
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
}
clickSidebarRow(2)
verify(settingsController.state.section == "Status Bar", "Status Bar sidebar row selects its section")
clickSidebarRow(3)
verify(settingsController.state.section == "AI", "AI sidebar row selects its section")
for section in ["General", "Appearance", "Status Bar", "AI", "Extensions", "App Shortcuts", "Data & Configuration"] {
    settingsController.state.section = section
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    let content = settingsWindow.contentView!
    content.layoutSubtreeIfNeeded()
    verify(abs(content.bounds.width - 680) < 1 && abs(content.bounds.height - 500) < 1, "Settings respects minimum size after navigation")
    let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/volant-core-settings-\(section)-\(dark ? "dark" : "light").png"))
}
settingsWindow.cancelOperation(nil)
verify(!settingsWindow.isVisible, "Escape dismisses Settings")
verify(openedAI.isEmpty, "Navigating AI settings never connects automatically")
let settingsAfterNavigation = try Data(contentsOf: settingsURL)
verify(settingsAfterNavigation == settingsBeforeNavigation, "Navigating AI settings never rewrites configuration")
settingsController.showWindow(nil)
settingsController.state.section = "Appearance"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
clickSettings("settings.theme-dark")
verify(waitUntil { settingsController.state.config.appearance.theme == .dark }, "Dark theme tile saves the theme")
clickSettings("settings.theme-system")
verify(waitUntil { settingsController.state.config.appearance.theme == .system }, "System theme tile restores following macOS")
clickSettings("settings.color-theme-nord")
verify(waitUntil { settingsController.state.config.appearance.colorTheme == "nord" }, "Nord color theme tile saves the color theme")
clickSettings("settings.color-theme-system")
verify(waitUntil { settingsController.state.config.appearance.colorTheme == "system" }, "System color theme tile restores the default")
settingsController.showWindow(nil)
settingsController.state.section = "AI"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
print("CHECK: Settings Connect ACP")
clickSettings("settings.connect")
verify(openedAI.count == 1 && openedAI[0].provider == "claude" && openedAI[0].project.isEmpty, "Connect ACP starts general chat with no project selection")
print("CHECK: Settings project sheet")
clickSettings("settings.choose-folder")
let sheetDeadline = Date().addingTimeInterval(3)
while settingsWindow.attachedSheet == nil && Date() < sheetDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
verify(settingsWindow.attachedSheet != nil, "Choose Project opens a native sheet")
print("CHECK: Cancel project sheet")
// Modern macOS can present an Open/Save panel service sheet, not an NSOpenPanel subclass.
settingsWindow.endSheet(settingsWindow.attachedSheet!, returnCode: .cancel)
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
verify(settingsWindow.attachedSheet == nil, "Project selection can be cancelled")
settingsController.state.section = "Status Bar"
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
clickHerdrSwitch()
verify(settingsController.state.config.promotedHarness == nil, "Disabling Herdr hides its status source")
clickHerdrSwitch()
verify(settingsController.state.config.promotedHarness == "claude", "Re-enabling Herdr preserves the chosen filter")
settingsWindow.cancelOperation(nil)
print("PASS: Status Bar and AI Settings native navigation, minimum size and dismissal")
