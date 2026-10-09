import AppKit
import SwiftUI
import CryptoKit
import VolantCore

setbuf(stdout, nil)
func verify(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let dark = CommandLine.arguments.contains("dark")
app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
let entry = AppEntry(id: "/Applications/Fixture.app", name: "Fixture", url: URL(fileURLWithPath: "/Applications/Fixture.app"), lastUsed: Date())
var launched = 0
var spotlightAvailable = false
let index = AppIndex(entries: [entry], launch: { _ in launched += 1 }, startQuery: { _ in spotlightAvailable })
let fixtureFiles = FileSearch(startQuery: { _ in false })
let clipboardKey = SymmetricKey(size: .bits256)
var clipboardAvailable = true
var clipboardRetryDelay: TimeInterval = 0
let clipboard = ClipboardStore(retention: 2, storageURL: root.appendingPathComponent("actions-clipboard-\(UUID().uuidString).sqlite"), keyLoader: { _ in
    if clipboardRetryDelay > 0 { Thread.sleep(forTimeInterval: clipboardRetryDelay) }
    guard clipboardAvailable else { throw KeychainKey.Failure.access(-25308) }
    return clipboardKey
})
var preferences = Preferences()
if CommandLine.arguments.contains("compact") { preferences.appearance.scale = 0.8 }
if CommandLine.arguments.contains("large") { preferences.appearance.scale = 1.4 }
var chatRequests = 0
var settingsRequests = 0
var extensionSettingsRequests = 0
var chatConfig: AIConfiguration?
var panel: LauncherPanel!
panel = LauncherPanel(index: index, clipboard: clipboard, notes: NotesStore(directory: root.appendingPathComponent("Notes")), config: preferences, usage: UsageStore(url: root.appendingPathComponent("actions-usage.sqlite")), positionStore: UserDefaults(suiteName: "volant.actions.fixture")!, files: fixtureFiles) { action in
    switch action {
    case .ai:
        chatRequests += 1
        if !panel.model.acp.openChat(configuration: chatConfig, connect: { panel.model.acp.state.phase = "ready"; panel.model.acp.state.status = "Connected" }) {
            settingsRequests += 1; panel.orderOut(nil)
        }
    case .aiSettings: settingsRequests += 1; panel.orderOut(nil)
    case .extensionSettings: extensionSettingsRequests += 1; panel.orderOut(nil)
    default: break
    }
}
panel.model.searchesSecondarySources = false
panel.model.actionConfigURL = root.appendingPathComponent("actions-config.json")
try Data("{}".utf8).write(to: panel.model.actionConfigURL)
var copied: [String] = []
panel.model.copyText = { copied.append($0) }
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

/// Runs the main run loop until the condition has held without interruption for `stable` seconds,
/// or until `timeout` passes. Loaded CI runners and guests can miss a fixed sleep, so focus and
/// state are polled; the stability window covers SwiftUI focus work queued for a later turn.
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

let launcherSearchPlaceholder = "Search for apps, files, contacts, or calculate…"

/// The text field whose native editor holds keyboard focus in the key launcher panel, if any.
func focusedField() -> NSTextField? {
    guard panel.isKeyWindow, let editor = panel.firstResponder as? NSTextView else { return nil }
    return editor.delegate as? NSTextField
}

/// Whether the AI Chat prompt editor holds keyboard focus in the key launcher panel.
func chatPromptFocused() -> Bool {
    panel.isKeyWindow && panel.firstResponder is ACPPromptView.PromptTextView
}

/// Describes keyboard focus and launcher state for failure messages.
func focusState() -> String {
    "key=\(panel.isKeyWindow), visible=\(panel.isVisible), responder=\(String(describing: panel.firstResponder)), field=\(String(describing: focusedField()?.placeholderString)), chat=\(panel.model.showingACP), query=\(panel.model.query)"
}

/// Summons the launcher and waits until its search editor holds focus, so the next key reaches it.
func summon() {
    panel.toggle()
    verify(waitUntil(stable: 0.15) { focusedField()?.placeholderString == launcherSearchPlaceholder },
           "Summoned launcher focuses search: \(focusState())")
}

/// Waits until AI Chat is showing with its prompt focused, after Tab or a resume.
func awaitChatPrompt(_ message: String) {
    verify(waitUntil(stable: 0.1) { panel.model.showingACP && chatPromptFocused() }, "\(message): \(focusState())")
}

func key(_ text: String, _ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    // NSApplication dispatches command equivalents before the window's keyDown path.
    if !modifiers.contains(.command) || !panel.performKeyEquivalent(with: event) { panel.sendEvent(event) }
    settle()
}
func render(_ name: String, view supplied: NSView? = nil) throws {
    let view = supplied ?? panel.contentView!
    view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/volant-actions-\(name)-\(dark ? "dark" : "light")-\(preferences.appearance.scale).png"))
}
app.activate(ignoringOtherApps: true)
summon()
key("k", 40, .command)
verify(waitUntil { panel.model.actionTarget != nil }, "Command K opens actions")
verify(panel.firstResponder is NSTextView, "Action search receives editing focus")
try render("menu")
// Rendering may end editing; explicitly restore the action field through its native control.
func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
func focusActionSearch() {
    var field: NSTextField?
    verify(waitUntil { field = fields(panel.contentView!).first { $0.placeholderString == "Search for actions…" }; return field != nil },
           "Action search field appears: \(focusState())")
    panel.makeFirstResponder(field!)
    verify(waitUntil(stable: 0.1) { focusedField() === field }, "Action search field takes focus: \(focusState())")
}
focusActionSearch()
for _ in 0..<8 { key(String(UnicodeScalar(NSDownArrowFunctionKey)!), 125) }
try render("more")
focusActionSearch(); key("\u{1b}", 53)
key("k", 40, .command)
focusActionSearch()
(panel.firstResponder as? NSTextView)?.insertText("copy", replacementRange: NSRange(location: NSNotFound, length: 0)); settle()
verify(panel.model.query.isEmpty, "Action search does not alter launcher query")
key(String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)
key("\r", 36)
verify(copied == ["Fixture"] && launched == 0, "Filtered arrows and Return copy name without launching app")
verify(panel.model.actionTarget == nil && panel.isVisible, "Copy closes actions and keeps launcher visible")
key("k", 40, .command)
focusActionSearch()
(panel.firstResponder as? NSTextView)?.insertText("unmatched fixture", replacementRange: NSRange(location: NSNotFound, length: 0)); settle()
try render("empty")
focusActionSearch(); key("\r", 36)
verify(launched == 0 && panel.model.actionTarget != nil, "Empty menu Return cannot launch underlying app")
key("\u{1b}", 53)
verify(panel.model.actionTarget == nil && panel.isVisible, "Escape dismisses actions before launcher")
key("k", 40, .command)
focusActionSearch()
(panel.firstResponder as? NSTextView)?.insertText("favorites", replacementRange: NSRange(location: NSNotFound, length: 0)); settle()
key("\r", 36)
verify(panel.model.sections.first?.title == "Favorites", "Favorite appears in home section")
try render("favorites")
key("k", 40, .command)
focusActionSearch()
(panel.firstResponder as? NSTextView)?.insertText("copy name", replacementRange: NSRange(location: NSNotFound, length: 0)); settle()
// Native mouse activation of the filtered first row, at each supported panel size.
var point = NSPoint(x: LauncherPanel.size.width - 175, y: 48 + 40 + 9 + min(285, LauncherPanel.size.height - 150) - 18)
func mouse(_ type: NSEvent.EventType) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                      windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
}
func clickPoint() {
app.postEvent(mouse(.leftMouseUp), atStart: true)
panel.sendEvent(mouse(.leftMouseDown))
if let release = app.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { panel.sendEvent(release) }
settle()
}
clickPoint()
verify(copied == ["Fixture", "Fixture"] && launched == 0, "Native mouse click executes filtered action")
panel.orderOut(nil)
print("PASS: native action search, keyboard navigation, empty state, Escape, copying, and Favorites")

var menuOpened: [URL] = []
panel.model.openURL = { menuOpened.append($0) }
summon()
// The Volant mark sits at the left of the footer, 10 points above the panel's bottom edge.
point = NSPoint(x: 24, y: 19)
clickPoint()
verify(waitUntil { panel.model.showingAppMenu }, "Clicking the Volant mark opens the Volant menu: \(focusState())")
verify(panel.model.actionTarget == nil && panel.isVisible, "Volant menu opens inside the panel without item actions")
verify(LauncherMenuItem.versionTitle() == "Volant v0.0.0", "Version header reads the fixture bundle version, saw \(LauncherMenuItem.versionTitle())")
focusActionSearch()
try render("app-menu")
focusActionSearch()
(panel.firstResponder as? NSTextView)?.insertText("no such item", replacementRange: NSRange(location: NSNotFound, length: 0)); settle()
key("\r", 36)
verify(menuOpened.isEmpty && panel.model.showingAppMenu, "Return on an empty Volant menu filter does nothing")
focusActionSearch()
(panel.firstResponder as? NSTextView)?.selectAll(nil)
(panel.firstResponder as? NSTextView)?.insertText("manual", replacementRange: NSRange(location: NSNotFound, length: 0)); settle()
verify(panel.model.query.isEmpty, "Volant menu search does not alter launcher query")
focusActionSearch(); key("\r", 36)
verify(waitUntil { menuOpened == [LauncherMenuItem.manualURL] } && !panel.model.showingAppMenu, "Return opens the filtered Manual link")
summon()
clickPoint()
verify(waitUntil { panel.model.showingAppMenu }, "Volant menu opens again")
focusActionSearch(); key("\u{1b}", 53)
verify(waitUntil { !panel.model.showingAppMenu } && panel.isVisible, "Escape closes the Volant menu before the launcher")
verify(waitUntil(stable: 0.1) { focusedField()?.placeholderString == launcherSearchPlaceholder }, "Launcher search regains focus after the menu closes: \(focusState())")
key("\u{1b}", 53)
verify(waitUntil { !panel.isVisible }, "A second Escape hides the launcher")
print("PASS: Volant menu click, version header, filtering, Return, and Escape order")

// Entering AI Chat invokes setup routing, never a real provider in the fixture.
summon(); key("\t", 48)
verify(waitUntil { settingsRequests == 1 && !panel.isVisible }, "Unconfigured AI Chat routes to Settings")
chatConfig = AIConfiguration(); chatConfig?.provider = "claude"
summon()
(panel.firstResponder as? NSTextView)?.insertText("A fictional question", replacementRange: NSRange(location: NSNotFound, length: 0)); settle()
key("\t", 48)
verify(waitUntil { panel.model.acp.draft == "A fictional question" } && !panel.model.acp.submitting, "Tab carries search text to an unsent chat draft")
panel.model.acp.draft = ""; settle()
verify(panel.model.acp.state.phase == "ready" && panel.model.acp.project.isEmpty, "Configured AI Chat automatically connects without a project")
awaitChatPrompt("Chat prompt receives focus")
(panel.firstResponder as? NSTextView)?.insertText("A fictional question", replacementRange: NSRange(location: NSNotFound, length: 0)); settle()
if panel.model.acp.draft != "A fictional question" || panel.model.query != "ai" {
    try render("chat-focus-failure")
    print("Chat focus diagnostic: draft length \(panel.model.acp.draft.count), query length \(panel.model.query.count), presented \(panel.model.showingACP)")
}
verify(panel.model.acp.draft == "A fictional question" && panel.model.query == "ai", "Typing edits the chat prompt instead of launcher search")
key("\r", 36, .shift)
verify(panel.model.acp.draft.contains("\n") && !panel.model.acp.submitting, "Shift Return inserts a newline without sending")
let draftBeforeUndo = panel.model.acp.draft
(panel.firstResponder as? NSTextView)?.undoManager?.undo(); settle()
// AppKit may coalesce adjacent typing into one undo group; the binding must follow the actual editor.
verify(panel.model.acp.draft != draftBeforeUndo && panel.model.acp.draft == (panel.firstResponder as? NSTextView)?.string, "Undo updates the chat draft binding")
panel.model.acp.draft = "A fictional question"; settle()
key("\r", 36)
verify(panel.model.acp.submitting, "Return submits through the native chat editor")
// The fixture has no XPC connection; reset the local submitting flag without sending a real prompt.
panel.model.acp.submitting = false
panel.model.acp.draft = ""; settle()
key("\r", 36)
verify(!panel.model.acp.submitting, "Return does not submit an empty draft")
panel.model.acp.draft = "A fictional question"; settle()
if let editor = panel.firstResponder as? NSTextView {
    editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    verify(editor.hasMarkedText(), "Fixture begins input method composition")
    key("\r", 36)
    verify(!panel.model.acp.submitting, "Return during marked text composition does not submit")
    editor.unmarkText()
}
panel.model.acp.draft = "A fictional follow-up"; settle()
panel.model.acp.state.messages = [
    ACPMessage(role: "You", text: "Show me a **literal** Markdown example."),
    ACPMessage(role: "Agent", text: "## A clearer answer\nUse **bold** for emphasis and `code` for names.\n\n- Keep messages readable\n- Copy code when needed\n\n```swift\nlet greeting = \"Hello, world!\"\nprint(greeting)")
]
settle()
try render("chat-streaming")
panel.model.acp.state.messages[1].text += "\n```\n\nSee [the example](https://example.com)."
settle()
verify(panel.model.acp.draft == "A fictional follow-up", "Streaming Markdown preserves the prompt draft")
try render("chat")
// The @ picker is driven by real keystrokes against a fictional clipboard entry.
clipboard.record("Fictional build error: expected ';' after expression"); settle()
if let editor = panel.firstResponder as? NSTextView { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }
key(" ", 49); key("@", 19, [.shift]); settle()
verify(controlFrame("chat.picker", in: panel) != nil, "Typing @ at the start of a word opens the picker")
try render("chat-context-picker")
key("\r", 36)
verify(panel.model.acp.attachments.count == 1 && panel.model.acp.attachments.first?.kind == .clipboard, "Return attaches the first candidate")
verify(!panel.model.acp.draft.contains("@"), "Choosing removes the @ that opened the picker")
verify(controlFrame("chat.picker", in: panel) == nil, "The picker closes after choosing")
verify(!panel.model.acp.submitting, "Choosing an attachment never sends")
panel.model.acp.state.messages.append(ACPMessage(role: "You", text: "Why does this fail?", attachments: ["Fictional build error: expected ';' after expression"]))
settle()
try render("chat-attached")
panel.model.acp.detach(panel.model.acp.attachments[0].id)
panel.model.acp.state.messages.removeLast()
panel.model.acp.draft = "A fictional follow-up"; settle()
print("PASS: @ opens the context picker at a word start, Return attaches a snapshot and removes the @, without sending")
let savedMessages = panel.model.acp.state.messages
let savedDraft = panel.model.acp.draft
panel.orderOut(nil); settle(); summon()
verify(!panel.model.showingACP && panel.model.query.isEmpty, "Summoning a hidden chat opens the default launcher")
verify(panel.model.acp.state.messages == savedMessages && panel.model.acp.draft == savedDraft && panel.model.acp.active, "Summoning preserves the active conversation and draft")
try render("chat-home")
panel.model.config.statusBar.sources = ["ai-chat"]
settle()
try render("chat-status-pinned")
panel.model.config.statusBar.sources = []
settle()
let search = fields(panel.contentView!).first { $0.placeholderString == launcherSearchPlaceholder }!
panel.makeFirstResponder(search)
verify(waitUntil(stable: 0.1) { focusedField() === search }, "Launcher search takes focus before typing: \(focusState())")
(panel.firstResponder as? NSTextView)?.insertText("Do not replace my draft", replacementRange: NSRange(location: NSNotFound, length: 0)); settle()
key("\t", 48)
awaitChatPrompt("Tab resumes chat")
verify(panel.model.acp.draft == savedDraft, "Tab resumes chat without overwriting its draft")
// A busy chat stays visible on blur, but a subsequent summon returns to search.
panel.model.acp.state.phase = "working"
let backgroundWindow = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 180, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
backgroundWindow.makeKeyAndOrderFront(nil); settle()
verify(panel.isVisible && !panel.isKeyWindow && panel.model.showingACP, "Working chat remains visible on real focus loss")
summon()
verify(!panel.model.showingACP && panel.model.query.isEmpty && panel.model.acp.state.phase == "working", "Summoning a visible inactive chat returns home without stopping the turn")
verify(panel.model.acp.state.messages == savedMessages && panel.model.acp.draft == savedDraft, "Focus loss and summon preserve conversation state")
key("\t", 48)
awaitChatPrompt("Tab resumes the working conversation")
backgroundWindow.orderOut(nil)
panel.model.acp.state.phase = "ready"
(panel.firstResponder as? NSTextView)?.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0)); settle()
verify(panel.model.acp.draft.contains("!") && panel.model.query == "ai", "Resuming chat restores native prompt focus")
point = NSPoint(x: 20, y: LauncherPanel.size.height - 18)
clickPoint()
verify(!panel.model.showingACP && panel.model.acp.active && !panel.model.acp.draft.isEmpty, "Back returns to search without ending chat or discarding its draft")
try render("chat-back")
panel.orderOut(nil)
let settings = SettingsWindowController(configURL: panel.model.actionConfigURL, conversations: panel.model.conversations) {}
try chatConfig!.save(at: panel.model.actionConfigURL)
settings.state.section = "AI"
settings.window!.setContentSize(NSSize(width: 680, height: 500))
settings.showWindow(nil); settle()
try render("ai-settings-active", view: settings.window!.contentView!)
panel.model.acp.state.phase = "disconnected"
settle()
try render("ai-settings", view: settings.window!.contentView!)
settings.window!.orderOut(nil)
print("PASS: AI Chat setup routing, automatic general-chat connection, prompt focus, and active-draft preservation")

// Bundled extensions are discoverable but never run before explicit consent.
panel.toggle()
panel.model.query = "hello Andrew"
settle()
verify(panel.model.rows.first?.primaryAction == "Enable and Run…", "Hello World starts disabled")
verify(!panel.model.extensionRunning && panel.model.pendingExtension == nil, "Typing an extension name never executes or enables it")
try render("direct-extension-launcher")
panel.model.query = "hello world Andrew"; settle()
verify(panel.model.rows.contains { if case .extensionRun(_, let input) = $0 { return input == "Andrew" }; return false }, "Full display name separates arguments")
panel.model.query = "ext hello Andrew"; settle()
verify(panel.model.rows.first?.primaryAction == "Enable and Run…", "Legacy ext prefix remains supported")
panel.model.query = "hello Andrew"; settle()

key("\r", 36)
verify(panel.model.pendingExtension?.input == "Andrew", "First invocation requests consent without executing")
verify(panel.keepsVisibleOnBlur, "Extension consent keeps its parent panel visible")
let permission = panel.model.pendingExtension!
let consentView = NSHostingView(rootView: ExtensionPermissionView(request: permission, enable: {}, cancel: {}))
consentView.frame = NSRect(x: 0, y: 0, width: 438, height: 240)
try render("extension-consent", view: consentView)
panel.model.pendingExtension = nil
settle()
panel.orderOut(nil)
settings.state.section = "Extensions"
settings.showWindow(nil); settle()
try render("extension-settings", view: settings.window!.contentView!)
settings.window!.orderOut(nil)

// The master gate applies to installed community code, never a manifest's claimed origin/ID.
let bundledExtension = Bundle.main.url(forResource: "HelloWorld", withExtension: nil)!
let communityDirectory = root.appendingPathComponent("community-example-" + UUID().uuidString)
try FileManager.default.copyItem(at: bundledExtension, to: communityDirectory)
let communityManifestURL = communityDirectory.appendingPathComponent("manifest.json")
var communityManifest = try JSONDecoder().decode(ExtensionManifest.self, from: Data(contentsOf: communityManifestURL))
communityManifest.id = "fixture.community"; communityManifest.name = "Community Greeting"
try JSONEncoder().encode(communityManifest).write(to: communityManifestURL)
let extensionRoots = [bundledExtension, communityDirectory]
let communityManager = ExtensionManager(configURL: panel.model.actionConfigURL, roots: extensionRoots)
communityManager.reload()
verify(!communityManager.communityAllowed, "Community extensions default off")
verify(!communityManager.extensions.first(where: { !$0.isCommunity })!.communityBlocked, "Bundled example is independent of master gate")
panel.model.extensions = communityManager
communityManifest.name = "Fixture"
try JSONEncoder().encode(communityManifest).write(to: communityManifestURL)
communityManager.reload()
panel.model.query = "Fixture"; settle()
verify(panel.model.rows.contains { if case .app = $0 { return true }; return false }, "An extension name cannot hide a matching application")
verify(communityManager.loadErrors.isEmpty, "Copied community extension loads: \(communityManager.loadErrors)")
verify(panel.model.rows.contains { if case .extensionRun = $0 { return true }; return false }, "Extension and app name collisions remain selectable")
communityManifest.name = "Community Greeting"
try JSONEncoder().encode(communityManifest).write(to: communityManifestURL)
communityManager.reload()

panel.model.query = "community"; settle()
verify(panel.model.rows.contains { if case .extensionRun = $0 { return true }; return false }, "Direct search discovers master-blocked commands without execution")

panel.toggle(); panel.model.query = "community Andrew"; settle()
verify(panel.model.rows.first?.primaryAction == "Open Extension Settings", "Blocked community command points to Settings")
try render("community-blocked-launcher")
key("\r", 36)
verify(extensionSettingsRequests == 1 && panel.model.pendingExtension == nil, "Master off routes to Settings without offering enable or executing")
func renderCommunitySettings(_ name: String) throws {
    let view = NSHostingView(rootView: ExtensionSettingsView(configURL: panel.model.actionConfigURL, onChange: {}, roots: extensionRoots)
        .background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view; window.makeKeyAndOrderFront(nil); settle()
    try render(name, view: view)
    window.orderOut(nil)
}
try renderCommunitySettings("community-off")
try communityManager.setCommunityAllowed(true, expected: false)
panel.toggle(); panel.model.query = "community Andrew"; settle()
verify(panel.model.rows.first?.primaryAction == "Enable and Run…", "Allowing community code still requires individual consent")
try render("community-first-use-launcher")
key("\r", 36)
verify(panel.model.pendingExtension?.extensionItem.id == "fixture.community", "Community first use requests per-extension consent")
try communityManager.setCommunityAllowed(false, expected: true)
panel.model.enablePendingExtension()
verify(!panel.model.extensionRunning && !ExtensionApproval.enabled(communityManifest, at: panel.model.actionConfigURL), "Stale consent cannot bypass revoked master gate")
panel.orderOut(nil)
try communityManager.setCommunityAllowed(true, expected: false)
try communityManager.setEnabled(communityManager.search("community").first!, true)
try renderCommunitySettings("community-on")
try communityManager.setCommunityAllowed(false, expected: true)
try renderCommunitySettings("community-paused")
print("PASS: community master default, Settings routing, individual consent, stale consent rejection and retained individual choices")
panel.model.query = ""

// Local panes remain visible while remote machines are still loading.
panel.model.agents.connected = true
panel.model.agents.busy = true
panel.model.agents.sessions = [AgentSession(agent: "codex", agentStatus: "working", paneID: "w1:p1", terminalID: "local-fixture", cwd: "/fictional/local-project", terminalTitle: nil, agentSession: nil)]
panel.model.agents.machines = [
    .init(id: "local", label: "Local", state: "connected", detail: "1 pane"),
    .init(id: "remote:fixture", label: "Build Mac", state: "loading", detail: "Loading panes…")
]
panel.toggle()
panel.model.query = "agents"
settle()
verify(panel.model.showingAgents && panel.model.rows.count == 1, "Local pane is usable while the remote machine loads")
try render("machines-loading")
panel.orderOut(nil)
panel.model.query = ""
panel.model.agents.busy = false

// Passive Herdr previews use fictional terminal output and no helper connection.
panel.model.agents.connected = true
panel.model.promotedHarness = "all"
var waitingClaude = AgentSession(agent: "claude", agentStatus: "blocked", paneID: "w1:p1", terminalID: "question-one", cwd: "/fictional/orbit", terminalTitle: nil, agentSession: .init(value: "claude-fictional"))
let waitingCodex = AgentSession(agent: "codex", agentStatus: "blocked", paneID: "w1:p2", terminalID: "question-two", cwd: "/fictional/comet", terminalTitle: nil, agentSession: .init(value: "codex-fictional"))
waitingClaude.machine = HerdrMachine(id: "fixture-remote", label: "Build Mac", target: "fictional-host", session: "agents", enabled: true)
panel.model.agents.machines = [
    .init(id: "local", label: "Local", state: "connected", detail: "1 pane"),
    .init(id: "fixture-remote", label: "Build Mac", state: "connected", detail: "1 pane"),
    .init(id: "fixture-offline", label: "Lab", state: "unavailable", detail: "Check SSH access and Herdr 0.9.1 or later on this machine.")
]
var previewReply: ((Data?, String?) -> Void)?
panel.model.agents.attentionReader = { _, reply in previewReply = reply }
panel.model.agents.sessions = [waitingClaude, waitingCodex]
panel.toggle()
// The footer shows the waiting count; the question itself lives in the herdr view.
verify(panel.model.promotedHarness == "all", "Herdr status is enabled for the footer")
panel.model.showPromotedAgents()
verify(panel.model.query == "herdr" && panel.model.showingAgents, "Footer status opens the herdr view")
// SwiftUI starts the preview in .task after presentation. A fixed 200 ms delay
// can expire on a loaded CI runner before that task starts; wait for its effect.
let previewDeadline = Date().addingTimeInterval(3)
while (!panel.model.agents.attentionLoading || previewReply == nil) && Date() < previewDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
verify(panel.model.agents.attentionLoading && previewReply != nil, "Waiting agent in the herdr view starts a passive preview read")
try render("attention-loading")
previewReply?(try JSONEncoder().encode(HerdrResponseController.Snapshot(text: "Allow running npm test in /fictional/orbit?\n\n1. Yes, once\n2. Yes, for this session\n3. No", token: nil, question: nil)), nil); settle()
verify(panel.model.agents.attention?.text.contains("npm test") == true, "Waiting question appears at the top of the herdr view")
try render("attention")
panel.model.agents.sessions = [waitingCodex]; settle()
verify(panel.model.agents.attention == nil && panel.model.agents.attentionLoading, "Changing waiting agent clears the previous question")
let codexQuestionText = """
Question 1/1 (1 unanswered)
Which fictional theme should the demo use?

› 1. Amber              warm colors
  2. Violet             cool colors
  3. None of the above  Optionally, add details in notes (tab).

tab to add notes | enter to submit answer | esc to interrupt
"""
let codexQuestion = HerdrQuestion.parse(codexQuestionText, provider: "codex")!
previewReply?(try JSONEncoder().encode(HerdrResponseController.Snapshot(text: codexQuestionText, token: "fictional-token", question: codexQuestion)), nil); settle()
verify(panel.model.agents.canAnswerAttention, "Verified Codex question enables answers")
try render("attention-choices")
var answered: [Int] = []
var answerReply: ((String?, String?) -> Void)?
panel.model.agents.attentionResponder = { token, choice, reply in
    verify(token == "fictional-token", "Response binds the displayed question token")
    answered.append(choice); answerReply = reply
}
// Native click on Answer with keyboard; card geometry is fixed above the scrollable results.
point = NSPoint(x: 90, y: panel.contentView!.bounds.height - 234)
clickPoint()
key("2", 19, [.command, .option])
verify(answered == [2], "Focused question shortcut sends the selected answer")
panel.model.agents.answerAttention(2)
verify(answered == [2] && !panel.model.agents.canAnswerAttention, "Duplicate clicks cannot send a second answer")
try render("attention-sending")
answerReply?("Answer sent; Codex resumed.", nil); settle()
verify(panel.model.agents.attentionResponse == "Answer sent; Codex resumed.", "Delivery feedback shows provider acknowledgement")
try render("attention-answered")
panel.model.agents.refreshAttention()
previewReply?(nil, "This question changed or could not be read. Open the pane in Herdr to review it."); settle()
verify(panel.model.agents.attentionError == nil && panel.model.agents.attentionResponse != nil, "Post-answer refresh cannot replace delivery feedback with a stale error")
try render("attention-transition")
panel.model.agents.watchAttention(nil); panel.model.agents.watchAttention(waitingCodex)
previewReply?(nil, "This question changed or could not be read. Open the pane in Herdr to review it."); settle()
try render("attention-error")
// Claude uses its own observed screen, including the complete approval scope.
panel.model.agents.sessions = [waitingClaude]; settle()
let claudePermissionText = """
─────────────────────────────────────────────
 Create file
 /fictional/approval.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
  1 Violet demo
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to create approval.txt?
 ❯ 1. Yes
   2. Yes, and switch to accept edits (auto-approve file edits and common file
      commands) for this session (shift+tab)
   3. No

 Esc to cancel · Tab to amend
"""
let claudePermission = HerdrQuestion.parse(claudePermissionText, provider: "claude")!
previewReply?(try JSONEncoder().encode(HerdrResponseController.Snapshot(text: claudePermissionText, token: "fictional-token", question: claudePermission)), nil); settle()
verify(panel.model.agents.canAnswerAttention, "Claude approval exposes the verified choices")
try render("attention-claude-approval")
func nativeScrollViews(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(nativeScrollViews)
}
if let scroll = nativeScrollViews(panel.contentView!).first, let document = scroll.documentView {
    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
    scroll.reflectScrolledClipView(scroll.contentView); settle()
}
try render("attention-claude-scope")
point = NSPoint(x: 90, y: panel.contentView!.bounds.height - 286)
clickPoint()
key("3", 20, [.command, .option])
verify(answered == [2, 3], "Claude No shortcut delivers only the selected denial")
answerReply?("Answer sent; Claude Code resumed.", nil); settle()
try render("attention-claude-answered")
panel.model.agents.sessions = []; settle()
verify(panel.model.agents.attention == nil, "Resolved questions remove the preview")
try render("attention-empty")
// Equal pane IDs remain independently searchable by machine.
let localTwin = AgentSession(agent: "codex", agentStatus: "working", paneID: "w1:p1", terminalID: "same-pane", cwd: "/fictional/shared", terminalTitle: nil, agentSession: nil)
var remoteTwin = localTwin; remoteTwin.machine = waitingClaude.machine
panel.model.agents.sessions = [localTwin, remoteTwin]
panel.model.query = "agents Build Mac"; settle()
verify(panel.model.rows.count == 1 && panel.model.rows.first?.id == ResultRow.agentSession(remoteTwin).id, "Machine search selects only the remote pane with a colliding ID")
try render("machines-filtered")
panel.model.query = "agents"; settle()
verify(panel.model.rows.count == 2, "Local and remote panes with identical IDs remain separate rows")
try render("machines-overview")
// The footer status replaces the old strip: it counts waiting panes and names an unavailable machine.
panel.model.agents.sessions = [waitingClaude, waitingCodex]
panel.model.query = ""; settle()
verify(HerdrStatusSummary(sessions: panel.model.agents.sessions, connected: true, busy: false, machines: panel.model.agents.machines).text == "Herdr: 2 waiting", "Footer counts both waiting panes")
try render("herdr-footer-waiting")
panel.model.agents.sessions = [localTwin]; settle()
verify(HerdrStatusSummary(sessions: panel.model.agents.sessions, connected: true, busy: false, machines: panel.model.agents.machines).text == "Herdr: Lab unavailable", "Footer names the unavailable machine when nothing waits")
try render("herdr-footer-unavailable")
panel.orderOut(nil)
print("PASS: passive Herdr question previews, target changes, loading, error, and resolved states")

/// Finds a control's frame in window coordinates by the identifier of the `ControlAnchor` behind
/// it, or by an AppKit button title, so Settings clicks follow the layout instead of hard-coded
/// points. On a miss it prints what it saw so a layout change is diagnosable from one run.
func controlFrame(_ name: String, in window: NSWindow) -> NSRect? {
    var seen: [String] = []
    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    for view in views(window.contentView!) where !view.isHiddenOrHasHiddenAncestor {
        if let identifier = view.identifier?.rawValue, identifier.hasPrefix("settings.") || identifier.hasPrefix("chat.") {
            seen.append(identifier)
            if identifier == name { return view.convert(view.bounds, to: nil) }
        }
        if let button = view as? NSButton, !button.title.isEmpty {
            seen.append(button.title)
            if button.title == name { return button.convert(button.bounds, to: nil) }
        }
    }
    print("Controls seen while looking for \(name): \(seen)")
    return nil
}

// API/local Settings use fictional discovery and credentials, never host services or owner keys.
let aiFixtureURL = root.appendingPathComponent("api-settings.json")
try Data("{}".utf8).write(to: aiFixtureURL)
var credentialWrites = 0
let fakeCredentials = AICredentials(read: { _ in nil }, write: { _, _ in credentialWrites += 1 })
func renderAPISettings(_ kind: AIConnectionKind, provider: AIAPIProvider = .openAI, offline: Bool = false) throws {
    var config = AIConfiguration(); config.connection = kind; config.api.provider = provider; config.api.endpoint = provider.endpoint
    try config.save(at: aiFixtureURL)
    let discovery = AIModelDiscovery()
    discovery.lookupOverride = { candidate, _, completion in
        if candidate.endpoint.contains("11434") && !offline { completion(["fictional-local-model", "fictional-second-model"], nil) }
        else { completion(nil, "Server unavailable. Start it or enter a custom URL.") }
    }
    let conversations = ACPConversations()
    let model = conversations.current
    let view = NSHostingView(rootView: AISettingsView(conversations: conversations, configURL: aiFixtureURL, onChange: {}, openConversation: { _ in }, chooseProject: { _ in }, credentials: fakeCredentials, discovery: discovery)
        .background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view; window.makeKeyAndOrderFront(nil); settle()
    try render("ai-\(kind.rawValue)-\(provider.rawValue)\(offline ? "-offline" : "")", view: view)
    verify(!model.active && credentialWrites == 0, "Opening AI Settings never starts chat or writes credentials")
    if kind == .local && !offline {
        guard let use = controlFrame("settings.use-server", in: window) else { verify(false, "Local server offers Use"); return }
        let point = NSPoint(x: use.midX, y: use.midY)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        app.postEvent(event(.leftMouseUp), atStart: true)
        window.sendEvent(event(.leftMouseDown))
        if let release = app.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { window.sendEvent(release) }
        settle()
        verify(try! AIConfiguration.load(at: aiFixtureURL).localAPI.model == "fictional-local-model", "Use persists the discovered local model")
        verify(discovery.models.count == 2, "Use keeps the discovered model picker populated")
        try render("ai-local-selected", view: view)
    }
    window.orderOut(nil); discovery.cancel()
}
try renderAPISettings(.byok)
try renderAPISettings(.byok, provider: .anthropic)
try renderAPISettings(.byok, provider: .compatible)
try renderAPISettings(.local)
try renderAPISettings(.local, offline: true)
// ACP detection renders a fictional result; the real helper and the owner's installs are never read.
do {
    var config = AIConfiguration(); config.connection = .acp; config.provider = "claude"
    try config.save(at: aiFixtureURL)
    let detection = ACPAgentDetection()
    detection.reader = { reply in
        reply(try? JSONEncoder().encode([
            ACPAgentAvailability(provider: "claude", state: .ready, detail: "Found at ~/.local/bin/claude", path: "/Users/fixture/.local/bin/claude"),
            ACPAgentAvailability(provider: "qwen", state: .ready, detail: "Found at /opt/homebrew/bin/qwen", path: "/opt/homebrew/bin/qwen"),
            ACPAgentAvailability(provider: "codex", state: .needsAdapter, detail: "Codex’s ACP adapter is missing. Install Volant’s ACP adapters and retry.", path: nil),
            ACPAgentAvailability(provider: "gemini", state: .notInstalled, detail: "Gemini CLI was not found. Install it and sign in, then retry.", path: nil)
        ]), nil)
    }
    let conversations = ACPConversations()
    let model = conversations.current
    let view = NSHostingView(rootView: AISettingsView(conversations: conversations, configURL: aiFixtureURL, onChange: {}, openConversation: { _ in }, chooseProject: { _ in },
                                                      credentials: fakeCredentials, discovery: AIModelDiscovery(), agentDetection: detection)
        .background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view; window.makeKeyAndOrderFront(nil)
    verify(waitUntil { detection.agents.map(\.provider) == ["claude", "qwen", "codex", "gemini"] },
           "Detected agents list ready providers first, saw \(detection.agents.map(\.provider))")
    settle()
    try render("ai-acp-detected", view: view)
    guard let use = controlFrame("settings.use-agent-qwen", in: window) else { verify(false, "A ready agent offers Use"); exit(1) }
    func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: use.midX, y: use.midY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }
    app.postEvent(event(.leftMouseUp), atStart: true)
    window.sendEvent(event(.leftMouseDown))
    if let release = app.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { window.sendEvent(release) }
    settle()
    verify(try! AIConfiguration.load(at: aiFixtureURL).provider == "qwen", "Use saves a detected provider")
    verify(!model.active, "Choosing a detected agent never connects")
    try render("ai-acp-detected-selected", view: view)
    window.orderOut(nil)
}
print("PASS: detected ACP agents render, sort and select without connecting")
let apiModel = ACPModel()
var localConfig = AIConfiguration(); localConfig.connection = .local; localConfig.localAPI.model = "Fictional local model"
apiModel.configure(localConfig); apiModel.state.phase = "ready"
apiModel.state.messages = [ACPMessage(role: "You", text: "Show a fictional example"), ACPMessage(role: "Agent", text: "**Hello** from a local model.\n\n- Runs on your machine\n- Uses the same chat controls")]
let apiChat = NSHostingView(rootView: ACPConversationView(model: apiModel)
    .background(Color(nsColor: .windowBackgroundColor)))
let apiChatWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
apiChatWindow.contentView = apiChat; apiChatWindow.makeKeyAndOrderFront(nil); settle()
try render("ai-local-chat", view: apiChat)
apiChatWindow.orderOut(nil)
apiModel.state.phase = "disconnected"
print("PASS: BYOK/local Settings and chat fixtures use no real servers or credentials")
let resumeSuite = "volant.actions.fixture.acp-resume"
UserDefaults().removePersistentDomain(forName: resumeSuite)
let resumeStore = UserDefaults(suiteName: resumeSuite)!
resumeStore.set(try JSONEncoder().encode(ACPResumeRecord(provider: "claude", project: "", sessionID: "fictional-session")), forKey: ACPModel.resumeKey)
let resumeModel = ACPModel(resumeStore: resumeStore)
var resumeConfig = AIConfiguration(); resumeConfig.provider = "claude"
var resumeConnects = 0
verify(resumeModel.openChat(configuration: resumeConfig) { resumeConnects += 1 } && resumeConnects == 0 && resumeModel.canResume, "Opening chat offers Resume without connecting")
let resumeChat = NSHostingView(rootView: ACPConversationView(model: resumeModel)
    .background(Color(nsColor: .windowBackgroundColor)))
let resumeChatWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
resumeChatWindow.contentView = resumeChat; resumeChatWindow.makeKeyAndOrderFront(nil); settle()
try render("ai-acp-resume", view: resumeChat)
resumeChatWindow.orderOut(nil)
UserDefaults().removePersistentDomain(forName: resumeSuite)
print("PASS: a recorded ACP conversation offers Resume and New without connecting")
// Several conversations in one list. Starting one only marks it ready, so no helper connection opens.
let severalSuite = "volant.actions.fixture.acp-several"
UserDefaults().removePersistentDomain(forName: severalSuite)
let several = ACPConversations(make: { ACPModel(resumeStore: UserDefaults(suiteName: severalSuite)!) },
                               start: { model in model.state.phase = "ready"; model.state.status = "Ready" })
var severalConfig = AIConfiguration(); severalConfig.provider = "claude"; severalConfig.project = "/fictional/orbit-web"
verify(several.newConversation(configuration: severalConfig), "An unused conversation starts in place")
let severalAwaiting = several.current
severalAwaiting.state.phase = "working"; severalAwaiting.state.status = "Needs your permission"
severalAwaiting.state.permissions = [ACPPermission(id: "fictional-permission", title: "Read fictional notes", detail: "{}",
                                                   options: [ACPPermission.Option(optionId: "once", name: "Allow once", kind: "allow_once")])]
severalConfig.provider = "codex"
verify(several.newConversation(configuration: severalConfig) && several.live.count == 2 && severalAwaiting.active, "New keeps the first conversation running")
several.current.state.messages = [ACPMessage(role: "You", text: "Summarize the fictional release notes."),
                                  ACPMessage(role: "Agent", text: "The fictional release adds **two** settings.")]
verify(several.nextToOpen === severalAwaiting && severalAwaiting.background && !several.current.background,
       "The launcher opens the conversation awaiting permission first, and only the shown one polls at the foreground interval")
let severalChat = NSHostingView(rootView: ACPConversationView(model: several.current, conversations: several)
    .background(Color(nsColor: .windowBackgroundColor)))
let severalChatWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
severalChatWindow.contentView = severalChat; severalChatWindow.makeKeyAndOrderFront(nil); settle()
try render("ai-acp-several", view: severalChat)
severalChatWindow.orderOut(nil)
let severalStrip = NSHostingView(rootView: VStack(spacing: 0) {
    ACPActivityStrip(conversations: several) { _ in }
    Spacer(minLength: 0)
}.background(Color(nsColor: .windowBackgroundColor)))
let severalStripWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
severalStripWindow.contentView = severalStrip; severalStripWindow.makeKeyAndOrderFront(nil); settle()
try render("ai-acp-several-strip", view: severalStrip)
severalStripWindow.orderOut(nil)
// AI Settings counts the running conversations. Detection reads a fictional result, never the helper.
try severalConfig.save(at: aiFixtureURL)
let severalDetection = ACPAgentDetection()
severalDetection.reader = { reply in
    reply(try? JSONEncoder().encode([ACPAgentAvailability(provider: "codex", state: .ready, detail: "Found at /opt/homebrew/bin/codex", path: "/opt/homebrew/bin/codex")]), nil)
}
let severalSettings = NSHostingView(rootView: AISettingsView(conversations: several, configURL: aiFixtureURL, onChange: {}, openConversation: { _ in }, chooseProject: { _ in },
                                                             credentials: fakeCredentials, discovery: AIModelDiscovery(), agentDetection: severalDetection)
    .background(Color(nsColor: .windowBackgroundColor)))
let severalSettingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
severalSettingsWindow.contentView = severalSettings; severalSettingsWindow.makeKeyAndOrderFront(nil); settle()
verify(several.live.count == 2 && several.current.active, "AI Settings is drawn with two running conversations")
try render("ai-acp-several-settings", view: severalSettings)
severalSettingsWindow.orderOut(nil)
for model in several.all { model.state.phase = "disconnected" }
UserDefaults().removePersistentDomain(forName: severalSuite)
print("PASS: several ACP conversations render their buttons and one launcher row without a helper connection")

// Clipboard failures never access the owner's Keychain or pasteboard.
clipboard.record("Fictional clipboard recovery fixture")
verify(!clipboard.recent().isEmpty, "Fixture clipboard row persisted")
clipboardAvailable = false
clipboard.retry(); settle()
panel.toggle(); settle(); panel.model.query = "clip"; settle()
verify(panel.model.clipboardMessage != nil && panel.model.rows.isEmpty, "Clipboard failure is distinct from empty history")
try render("clipboard-unavailable")
// A real SwiftUI command equivalent invokes the native Retry button.
clipboardAvailable = true; clipboardRetryDelay = 0.8
key("r", 15, .command)
verify(panel.model.clipboardRetrying, "Command R activates clipboard Retry")
try render("clipboard-retrying")
let clipboardDeadline = Date().addingTimeInterval(5)
while (panel.model.clipboardRetrying || panel.model.rows.isEmpty) && Date() < clipboardDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
verify(panel.model.clipboardMessage == nil && !panel.model.rows.isEmpty, "Retry restores preserved clipboard history")
try render("clipboard-recovered")
panel.model.query = "clip no-fixture-match"; settle()
verify(panel.model.notice == "No matching clipboard items" && panel.model.clipboardMessage == nil, "A healthy empty search offers no error or Retry")
try render("clipboard-no-match")
panel.orderOut(nil)
print("PASS: clipboard error, native Retry shortcut, progress, retained history and empty search")

// Refused Spotlight starts keep useful results and expose a native Retry action.
index.start()
panel.toggle(); settle(); panel.model.query = "Fixture"; settle()
verify(panel.model.searchRecoveryMessage != nil && !panel.model.rows.isEmpty, "App discovery failure coexists with existing rows")
try render("spotlight-app-unavailable")
spotlightAvailable = true
key("r", 15, .command)
verify(panel.model.searchRecoveryMessage == nil, "Native Retry restarts app discovery")
panel.model.query = "/fictional"; settle(); settle()
verify(panel.model.filesUnavailable, "Refused file query produces a visible failure")
try render("spotlight-file-unavailable")
key("r", 15, .command); settle()
verify(panel.model.filesUnavailable, "A repeated failure remains retryable")
panel.model.query = "clip"; settle()
verify(panel.model.searchRecoveryMessage == nil, "Search errors do not leak into another command")
panel.orderOut(nil)

let recoveryNotes = NotesStore(directory: root.appendingPathComponent("recovery-notes-\(UUID().uuidString)"))
let damagedURL = recoveryNotes.directory.appendingPathComponent("Fictional travel plans.md")
try Data([0xFF, 0xFE, 0xFA]).write(to: damagedURL)
recoveryNotes.reload()
let recoveryPanel = NotesPanel(store: recoveryNotes)
recoveryPanel.setContentSize(NSSize(width: preferences.appearance.scale == 0.8 ? 380 : 560,
                                   height: preferences.appearance.scale == 0.8 ? 300 : 620))
recoveryPanel.open(noteID: damagedURL.lastPathComponent); settle()
verify(recoveryNotes.notes.first?.readError != nil, "Unreadable note remains selectable")
try render("notes-unreadable", view: recoveryPanel.contentView!)
func notesKey(_ text: String, _ code: UInt16) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: recoveryPanel.windowNumber,
        context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    verify(recoveryPanel.performKeyEquivalent(with: event), "Notes keyboard shortcut is handled")
    settle()
}
notesKey("p", 35)
try render("notes-unreadable-browser", view: recoveryPanel.contentView!)
recoveryPanel.cancelOperation(nil); settle()
try "# Fictional travel plans\n\nRepaired Markdown note.".write(to: damagedURL, atomically: true, encoding: .utf8)
notesKey("r", 15)
verify(recoveryNotes.loadMessage == nil && recoveryNotes.notes.first?.readError == nil, "Native Notes Retry reloads repaired text")
try render("notes-recovered", view: recoveryPanel.contentView!)
recoveryPanel.close()
print("PASS: Spotlight refusal/retry and unreadable Notes recovery with native keyboard controls")
