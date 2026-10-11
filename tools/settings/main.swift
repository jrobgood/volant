import AppKit
import CryptoKit
import SwiftUI
import VolantCore

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.appearance = NSAppearance(named: CommandLine.arguments.contains("dark") ? .darkAqua : .aqua)
let root = FileManager.default.temporaryDirectory.appendingPathComponent("volant-settings-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let configURL = root.appendingPathComponent("config.json")
try Data(#"{"aliases":{"safari":"/Applications/Safari.app"},"appHotKeys":[],"syncSettingsWithICloud":true}"#.utf8).write(to: configURL)
let apps = [AppEntry(id: "/System/Applications/Calculator.app", name: "Calculator", url: URL(fileURLWithPath: "/System/Applications/Calculator.app"), lastUsed: nil), AppEntry(id: "/Applications/Safari.app", name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"), lastUsed: nil)]
/// Stands in for the input helper so the preview never launches it or prompts for Accessibility.
/// It reports Accessibility as not allowed until `trusted` is set.
final class PreviewInputHost: InputHostClient {
    var trusted = false
    func status(prompt: Bool, completion: @escaping (InputHostStatus?) -> Void) {
        let trusted = self.trusted
        DispatchQueue.main.async { completion(InputHostStatus(trusted: trusted, secureInput: false)) }
    }
    func beginSession(completion: @escaping (InputSessionStart?) -> Void) { completion(InputSessionStart(refusal: .notTrusted)) }
    func insert(phrase: String, token: Data, completion: @escaping (InputInsertion?) -> Void) { completion(.refused(.notTrusted)) }
    func endSession(token: Data) {}
    func disconnect() {}
}
let previewInputHost = PreviewInputHost()
let dictationAccess = DictationTypingAccess(client: previewInputHost)
var controller: SettingsWindowController!
controller = SettingsWindowController(configURL: configURL, dictationAccess: dictationAccess) {
    HotKeyCenter.shared.unregisterAll()
    AppHotKeys.register((try? JSONDecoder().decode(Preferences.self, from: Data(contentsOf: configURL)))?.appHotKeys ?? [])
    controller.refresh(try! JSONDecoder().decode(Preferences.self, from: Data(contentsOf: configURL)), apps: apps)
}
controller.refresh(try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: configURL)), apps: apps)
controller.state.iCloudStatus = ICloudSettingsSync.Status.synced(Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date())!).text
let clipboard = ClipboardStore(retention: 10, storageURL: root.appendingPathComponent("clipboard.sqlite"), encryptionKey: SymmetricKey(size: .bits256))
let notes = NotesStore(directory: root.appendingPathComponent("Notes"))
let usage = UsageStore(url: root.appendingPathComponent("usage.sqlite"))
final class PreviewPowerAssertions: CaffeinateAssertions {
    func create(display: Bool, timeout: TimeInterval) throws -> UInt32 { 1 }
    func release(_ id: UInt32) throws { }
}
let previewCaffeinate = CaffeinateService(assertions: PreviewPowerAssertions(), automaticTimer: false)
let panel = LauncherPanel(index: AppIndex(entries: apps), clipboard: clipboard, notes: notes, config: Preferences(), usage: usage, positionStore: UserDefaults(suiteName: "volant.settings.preview")!, caffeinate: previewCaffeinate) { action in
    if case .editApp(let entry) = action { controller.edit(entry) }
}
panel.model.searchesSecondarySources = false
panel.model.copyText = { print("Fictional preview copied: \($0)"); fflush(stdout) }
final class PreviewActions: NSObject {
    let show: () -> Void
    init(show: @escaping () -> Void) { self.show = show }
    @objc func showLauncher() { show() }
    @objc func settings() { controller.showWindow(nil) }
    @objc func updates() {}
}
let actions = PreviewActions { panel.toggle(); panel.setQuery("Calculator") }
let menu = NSMenu()
let item = NSMenuItem()
let submenu = NSMenu()
let launchItem = submenu.addItem(withTitle: "Show Launcher", action: #selector(PreviewActions.showLauncher), keyEquivalent: "l")
launchItem.target = actions
submenu.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
statusItem.isVisible = CommandLine.arguments.contains("--menu")
statusItem.button?.image = NSImage(named: "VolantWing")
statusItem.button?.image?.size = NSSize(width: 16, height: 16)
statusItem.button?.image?.isTemplate = true
statusItem.button?.setAccessibilityLabel("Volant Settings Preview")
statusItem.menu = StatusMenu.make(target: actions, show: #selector(PreviewActions.showLauncher), settings: #selector(PreviewActions.settings), update: #selector(PreviewActions.updates))
controller.window?.setFrame(NSWindow.frameRect(forContentRect: NSRect(x: 100, y: 100, width: 680, height: 500), styleMask: controller.window!.styleMask), display: true)
var destinationWindow: NSWindow?
if CommandLine.arguments.contains("--dictionary") || CommandLine.arguments.contains("--render-dictionary") || CommandLine.arguments.contains("--native-dictionary") {
    panel.model.dictionary.debounce = .zero
    panel.model.dictionary.lookup = { term in
        if term == "missing" { return nil }
        if term == "error" { throw CocoaError(.fileReadUnknown) }
        return DictionaryEntry(term: term, definition: "serendipity | ˌserənˈdipədē |\nnoun\nThe occurrence and development of events by chance in a happy or beneficial way.\n\nA fortunate discovery while looking for something else.")
    }
    if CommandLine.arguments.contains("--native-dictionary") {
        panel.model.dictionary.lookup = { try await NativeDictionaryLookup.shared.lookup($0) }
    }
    panel.model.query = "define"
    let host = NSHostingView(rootView: LauncherView(model: panel.model, agents: panel.model.agents).background(Color(nsColor: .windowBackgroundColor)))
    destinationWindow = NSWindow(contentRect: NSRect(origin: .zero, size: LauncherPanel.size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    destinationWindow?.title = "Volant Dictionary Preview"
    destinationWindow?.contentView = host
    destinationWindow?.center()
    destinationWindow?.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
} else if CommandLine.arguments.contains("--translation") || CommandLine.arguments.contains("--render-translation") || CommandLine.arguments.contains("--native-translation") {
    if !CommandLine.arguments.contains("--native-translation") {
    panel.model.translation.loadLanguages = { ["en", "es", "fr", "de", "ja", "ar"] }
    panel.model.translation.availability = { _ in .installed }
    panel.model.translation.translateFixture = { _ in TranslationResult(text: "Hola\n¿Cómo estás?", source: "en") }
    }
    panel.model.query = "translate"
    let host = NSHostingView(rootView: LauncherView(model: panel.model, agents: panel.model.agents).background(Color(nsColor: .windowBackgroundColor)))
    destinationWindow = NSWindow(contentRect: NSRect(origin: .zero, size: LauncherPanel.size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    destinationWindow?.title = "Volant Translation Preview"
    destinationWindow?.contentView = host
    destinationWindow?.center()
    destinationWindow?.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
} else if CommandLine.arguments.contains("--core") || CommandLine.arguments.contains("--render-core") {
    panel.model.query = "caffeinate"
    let host = NSHostingView(rootView: LauncherView(model: panel.model, agents: panel.model.agents).background(Color(nsColor: .windowBackgroundColor)))
    destinationWindow = NSWindow(contentRect: NSRect(origin: .zero, size: LauncherPanel.size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    destinationWindow?.title = "Volant Core Commands Preview"
    destinationWindow?.contentView = host
    destinationWindow?.center()
    destinationWindow?.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
} else if CommandLine.arguments.contains("--snap") {
    _ = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { _ in
        print("Snap fixture position: \(panel.frame.origin)"); fflush(stdout)
    }
    // Retain this isolated fixture when computer-use inspection shifts app focus.
    // No connectivity operation is started; ordinary blur is tested in check-launcher.
    panel.model.connectivityBusy = true
    DispatchQueue.main.async {
        app.activate(ignoringOtherApps: true)
        panel.toggle()
        panel.setQuery("Calculator")
    }
} else if CommandLine.arguments.contains("--destinations") {
    panel.model.query = "settings login"
    let host = NSHostingView(rootView: LauncherView(model: panel.model, agents: panel.model.agents).background(Color(nsColor: .windowBackgroundColor)))
    destinationWindow = NSWindow(contentRect: NSRect(origin: .zero, size: LauncherPanel.size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    destinationWindow?.title = "Settings Destination Preview"
    destinationWindow?.contentView = host
    destinationWindow?.center()
    destinationWindow?.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
} else if !CommandLine.arguments.contains("--render") {
    controller.showWindow(nil)
    app.activate(ignoringOtherApps: true)
}
print("Settings preview ready; isolated config: \(configURL.path)")
fflush(stdout)
if CommandLine.arguments.contains("--menu") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        statusItem.menu?.popUp(positioning: nil, at: NSPoint(x: 40, y: 100), in: controller.window?.contentView)
    }
}
if CommandLine.arguments.contains("--render-dictionary") {
    Task { @MainActor in
        for scale in [1.0, 0.8] {
            LauncherPanel.scale = scale
            destinationWindow?.contentView = NSHostingView(rootView: LauncherView(model: panel.model, agents: panel.model.agents).background(Color(nsColor: .windowBackgroundColor)))
            destinationWindow?.setContentSize(LauncherPanel.size)
            for theme in ["light", "dark"] {
                app.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
                destinationWindow?.appearance = app.appearance
                for (name, term) in [("empty", ""), ("result", "serendipity"), ("missing", "missing"), ("error", "error"), ("limit", String(repeating: "a", count: 257))] {
                    panel.model.dictionary.input = term
                    try! await Task.sleep(for: .milliseconds(300))
                    precondition(name != "result" || panel.model.dictionary.entry != nil)
                    precondition(name != "error" || panel.model.dictionary.failed)
                    let view = destinationWindow!.contentView!
                    view.layoutSubtreeIfNeeded()
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/volant-dictionary-\(name)-\(theme)\(scale == 1 ? "" : "-small").png"))
                }
            }
        }
        NSApp.terminate(nil)
    }
}
if CommandLine.arguments.contains("--render-translation") {
    Task { @MainActor in
        for scale in [1.0, 0.8] {
        LauncherPanel.scale = scale
        destinationWindow?.contentView = NSHostingView(rootView: LauncherView(model: panel.model, agents: panel.model.agents).background(Color(nsColor: .windowBackgroundColor)))
        destinationWindow?.setContentSize(LauncherPanel.size)
        for theme in ["light", "dark"] {
            app.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
            destinationWindow?.appearance = app.appearance
            for name in ["empty", "result", "unsupported", "caffeinate"] {
                previewCaffeinate.stop()
                if name == "caffeinate" { previewCaffeinate.perform(CaffeinateCommand(minutes: 30, display: false, stop: false)) }
                let translator = panel.model.translation
                translator.clear()
                if name != "empty" {
                    translator.text = "Hello\nHow are you?"
                    translator.target = "es"
                    translator.availability = { _ in name == "unsupported" ? .unsupported : .installed }
                    translator.start()
                }
                try! await Task.sleep(for: .milliseconds(400))
                precondition(name != "result" || !translator.output.isEmpty, "Translation result fixture must complete before capture")
                precondition(name != "unsupported" || translator.pairState == .unsupported, "Unsupported fixture must settle before capture")
                let view = destinationWindow!.contentView!
                view.layoutSubtreeIfNeeded()
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/volant-translation-\(name)-\(theme)\(scale == 1 ? "" : "-small").png"))
            }
        }
        }
        NSApp.terminate(nil)
    }
}
if CommandLine.arguments.contains("--render-core") {
    DispatchQueue.main.async {
        for theme in ["light", "dark"] {
            app.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
            destinationWindow?.appearance = app.appearance
            for (name, query) in [("commands", ""), ("caffeinate", "caffeinate"), ("active", "caffeinate 30m"), ("emoji", ":"), ("emoji-search", ":cat"), ("emoji-empty", ":nonexistent-fixture-emoji")] {
                if name == "active" { previewCaffeinate.perform(CaffeinateCommand.parse(query)[0]) }
                else { previewCaffeinate.stop() }
                panel.model.query = query
                if query.isEmpty { panel.model.reset() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                let view = destinationWindow!.contentView!
                view.layoutSubtreeIfNeeded()
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/volant-branded-\(name)-\(theme).png"))
                print("Rendered core \(name) \(theme)")
            }
        }
        app.terminate(nil)
    }
}
if CommandLine.arguments.contains("--render") {
    DispatchQueue.main.async {
        let output = URL(fileURLWithPath: "/tmp/volant-settings-renders")
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // Offscreen caching draws the glass sidebar selection as a black capsule, so renders come from the
        // window server. An app may capture its own windows without Screen Recording; the symbol is looked up
        // at runtime because it is marked unavailable from macOS 15.
        typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let windowImage = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage").map { unsafeBitCast($0, to: WindowImage.self) }
        controller.window!.orderFrontRegardless()
        func selectionViews(_ view: NSView) -> [NSVisualEffectView] {
            let own = (view as? NSVisualEffectView).flatMap { $0.material == .selection && !$0.isHidden ? [$0] : nil } ?? []
            return own + view.subviews.flatMap(selectionViews)
        }
        func verifySidebarSelection(_ rep: NSBitmapImageRep, window: NSWindow, name: String) {
            let selections = selectionViews(window.contentView!)
            precondition(selections.count == 1, "\(name): expected one sidebar selection, found \(selections.count)")
            let frame = selections[0].convert(selections[0].bounds, to: nil)
            let scale = CGFloat(rep.pixelsWide) / window.frame.width
            func brightness(x: CGFloat, y: CGFloat) -> CGFloat {
                let color = rep.colorAt(x: Int(x * scale), y: Int((window.frame.height - y) * scale))!.usingColorSpace(.deviceRGB)!
                return (color.redComponent + color.greenComponent + color.blueComponent) / 3
            }
            let selected = brightness(x: frame.maxX - 8, y: frame.midY)
            let unselected = brightness(x: frame.maxX - 8, y: frame.midY - frame.height)
            let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            precondition(selected > (dark ? 0.12 : 0.6), "\(name): sidebar selection draws black (\(selected))")
            precondition(abs(selected - unselected) > 0.02, "\(name): sidebar selection does not stand out (\(selected) vs \(unselected))")
        }
        func capture(_ name: String) {
            let window = controller.window!
            let view = window.contentView!
            view.layoutSubtreeIfNeeded()
            if let windowImage, let image = windowImage(.null, 1 << 3, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue() {
                let rep = NSBitmapImageRep(cgImage: image)
                try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
                verifySidebarSelection(rep, window: window, name: name)
            } else {
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                try! rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
                print("No window-server capture for \(name); its sidebar selection is an offscreen artifact")
            }
        }
        for theme in ["light", "dark"] {
            app.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
            for section in ["General", "Appearance", "Status Bar", "AI", "Extensions", "App Shortcuts", "Data & Configuration"] {
                controller.state.section = section
                controller.window!.setFrame(NSWindow.frameRect(forContentRect: NSRect(x: 100, y: 100, width: 680, height: 500), styleMask: controller.window!.styleMask), display: true)
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                let view = controller.window!.contentView!
                view.layoutSubtreeIfNeeded()
                precondition(abs(view.bounds.width - 680) < 1 && abs(view.bounds.height - 500) < 1, "Settings fixture changed size")
                func recorders(_ view: NSView) -> [RecorderButton] {
                    (view as? RecorderButton).map { [$0] } ?? view.subviews.flatMap(recorders)
                }
                if section == "General" {
                    let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: controller.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                    for recorder in recorders(view) where !recorder.value.isEmpty {
                        recorder.mouseEntered(with: event)
                        precondition(recorder.subviews.contains { !$0.isHidden && ($0 as? NSButton)?.toolTip == "Remove shortcut" })
                    }
                }
                capture(theme + "-" + section)
                print("Rendered \(theme) \(section): \(view.bounds.size)")
                if section == "Data & Configuration" || section == "Appearance" {
                    func scrollViews(_ view: NSView) -> [NSScrollView] {
                        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                    }
                    for scroll in scrollViews(view) {
                        guard let document = scroll.documentView else { continue }
                        document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.height : 0))
                    }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                    capture(theme + "-" + section + "-bottom")
                }
            }
        }
        // Dictation output states, with the fake input host: typing chosen but not allowed, allowed,
        // and copying again after typing was turned off. No helper runs and nothing prompts.
        func scrollGeneral(toFraction fraction: CGFloat) {
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            for scroll in scrollViews(controller.window!.contentView!) {
                guard let document = scroll.documentView else { continue }
                let range = max(0, document.bounds.height - scroll.contentView.bounds.height)
                document.scroll(NSPoint(x: 0, y: document.isFlipped ? range * fraction : range * (1 - fraction)))
            }
        }
        for theme in ["light", "dark"] {
            app.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
            controller.state.section = "General"
            for (name, output, trusted) in [("typing-not-allowed", DictationOutput.type, false), ("typing-allowed", .type, true), ("copy-after-typing", .copy, true)] {
                previewInputHost.trusted = trusted
                try! Preferences.updateDictationOutput(output, at: configURL)
                controller.refresh(try! JSONDecoder().decode(Preferences.self, from: Data(contentsOf: configURL)), apps: apps)
                dictationAccess.chose(output)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                scrollGeneral(toFraction: 0.45)
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                capture(theme + "-General-dictation-" + name)
                print("Rendered \(theme) General dictation \(name)")
            }
        }
        controller.refresh(try! JSONDecoder().decode(Preferences.self, from: Data(contentsOf: configURL)), apps: apps)
        for (colorTheme, mode) in [("volant", Appearance.Theme.light), ("catppuccin-mocha", .dark), ("rose-pine-dawn", .light)] {
            ThemeStore.shared.apply(Appearance(theme: mode, colorTheme: colorTheme))
            controller.state.section = "Appearance"
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            capture("theme-" + colorTheme + "-Appearance")
            print("Rendered Appearance in \(colorTheme)")
        }
        let imported = try! RaycastTheme.parse("raycast://theme?name=Harbor%20Night&appearance=dark&colors=%23101418,%230C1014,%23E8ECF0,%232A3440,%237A8490,%23F06060,%23F09050,%23E8C860,%2370C080,%236CA8F0,%23A890F0,%23E080C8")
        let before = try! JSONDecoder().decode(Preferences.self, from: Data(contentsOf: configURL)).appearance
        try! Preferences.saveCustomTheme(imported.customTheme, select: true, expected: before, at: configURL)
        let withImport = try! JSONDecoder().decode(Preferences.self, from: Data(contentsOf: configURL))
        controller.refresh(withImport, apps: apps)
        ThemeStore.shared.apply(withImport.appearance)
        controller.state.section = "Appearance"
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let importedView = controller.window!.contentView!
        func allScrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(allScrollViews)
        }
        for scroll in allScrollViews(importedView) {
            guard let document = scroll.documentView else { continue }
            document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.height * 0.45 : document.bounds.height * 0.55))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        capture("theme-imported-Appearance")
        print("Rendered Appearance with an imported theme")
        app.terminate(nil)
    }
}
app.run()
