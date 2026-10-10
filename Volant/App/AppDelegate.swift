import AppKit
import ServiceManagement
import Combine
import VolantCore

/// Owns the long-lived services: menu bar item, hotkeys, app index, clipboard monitor, and the panel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var settingsPanel: SettingsWindowController = SettingsWindowController(acp: panel.model.acp, openAI: { [weak self] configuration in
        guard let self else { return }
        self.settingsPanel.window?.orderOut(nil)
        self.panel.model.acp.configure(configuration)
        if !self.panel.isVisible { self.panel.toggle() }
        self.panel.model.presentAIChat()
        self.panel.makeKeyAndOrderFront(nil)
        if !self.panel.model.acp.active, !self.panel.model.acp.canResume { self.panel.model.acp.start() }
    }, onChange: { [weak self] in self?.reloadConfig(); self?.notesStore.reload() })
    private func showAISettings() {
        panel.orderOut(nil)
        showSettings()
        settingsPanel.state.section = "AI"
    }

    private func openAIChat() {
        guard !panel.model.acp.active else { return }
        let acp = panel.model.acp
        if !acp.openChat(configuration: try? AIConfiguration.load(), connect: acp.start) { showAISettings() }
    }

    private lazy var settingsSync: ICloudSettingsSync = {
        let sync = ICloudSettingsSync(onApplied: { [weak self] in self?.reloadConfig() })
        sync.onStatus = { [weak self] status in self?.settingsPanel.state.iCloudStatus = status.text }
        return sync
    }()

    private let currencyRates = CurrencyRatesStore()
    private let updater = AppUpdater()
    private var statusItem: NSStatusItem?
    private var memoryCheck: MemoryCheck?
    private var config = Preferences.load()
    private let index = AppIndex()
    private var indexObserver: AnyCancellable?
    private lazy var clipboardStore = ClipboardStore(retention: config.clipboardRetention)
    private lazy var clipboardMonitor = ClipboardMonitor(store: clipboardStore)
    private let notesStore = NotesStore()
    private lazy var notesPanel: NotesPanel = {
        let notes = NotesPanel(store: notesStore)
        notes.floatingPeer = panel
        panel.floatingPeer = notes
        return notes
    }()
    private lazy var panel: LauncherPanel = LauncherPanel(index: index, clipboard: clipboardStore, notes: notesStore, config: config) { [weak self] action in
        switch action {
        case .settings: self?.showSettings()
        case .extensionSettings:
            self?.showSettings()
            self?.settingsPanel.state.section = "Extensions"
        case .ai: self?.openAIChat()
        case .aiSettings: self?.showAISettings()
        case .reloadConfig: self?.reloadConfig()
        case .editApp(let app):
            self?.showSettings()
            self?.settingsPanel.edit(app)
        case .agents: self?.showAgents()
        case .open(let id): self?.notesPanel.open(noteID: id)
        case .create(let text): self?.notesPanel.openNew(text: text)
        case .confetti: ConfettiWindow.celebrate()
        case .systemAction(let action): self?.performSystemAction(action)
        case .checkForUpdates: self?.checkForUpdates()
        case .about:
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        case .quit: NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--acp-check") {
            // The smoke check keeps its resume record in its own suite, apart from the owner's.
            let model = ACPModel(resumeStore: UserDefaults(suiteName: "volant.acp-check")!)
            model.project = "/tmp/volant-acp-fixture"
            if let index = CommandLine.arguments.firstIndex(of: "--acp-provider"), CommandLine.arguments.indices.contains(index + 1) {
                model.provider = CommandLine.arguments[index + 1]
            }
            model.start()
            var submitted = false
            var checkTimer: Timer?
            checkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                if model.state.phase == "failed" {
                    print("ACP check failed: " + model.state.status)
                    checkTimer?.invalidate(); model.disconnect(); NSApp.terminate(nil)
                } else if model.state.phase == "ready" && !model.submitting {
                    if CommandLine.arguments.contains("--acp-prompt-check") && !submitted {
                        submitted = true
                        model.draft = "Reply with exactly VOLANT_ACP_OK. Do not use tools or read or change files."
                        model.send()
                    } else {
                        let output = model.state.messages.filter { $0.role == "Agent" }.map(\.text).joined()
                        print("ACP initialized: " + model.state.agentName + "; session: " + (model.state.sessionID == nil ? "missing" : "created"))
                        if submitted { print("ACP prompt: " + (output.contains("VOLANT_ACP_OK") ? "passed" : "failed: " + model.state.status)) }
                        checkTimer?.invalidate(); model.disconnect(); NSApp.terminate(nil)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 80) {
                print("ACP check timed out: " + model.state.status)
                checkTimer?.invalidate(); model.disconnect(); NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--agents-check") {
            let model = panel.model.agents
            model.connect()
            if CommandLine.arguments.contains("--focus-current-pane"), let pane = ProcessInfo.processInfo.environment["HERDR_PANE_ID"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if let session = model.sessions.first(where: { $0.paneID == pane }) { model.focus(session) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                print("Herdr bridge: \(model.connected && !model.busy ? "connected" : "failed"); sessions: \(model.sessions.count); \(model.message)")
                if CommandLine.arguments.contains("--focus-current-pane") { print("Focus current pane: \(model.lastFocusSucceeded == true ? "passed" : "failed")") }
                model.disconnect()
                NSApp.terminate(nil)
            }
            return
        }
        if CommandLine.arguments.contains("--agents") {
            DispatchQueue.main.async { [weak self] in self?.showAgents() }
        }

        NSApp.setActivationPolicy(config.showInDock ? .regular : .accessory)
        applyTheme()
        if let ai = try? AIConfiguration.load() { panel.model.acp.configure(ai) }
        if config.syncSettingsWithICloud { settingsSync.update(enabled: true) }
        currencyRates.loadCache()
        currencyRates.onUpdate = { [weak self] in self?.panel.model.refreshForCurrencyRates() }
        panel.model.onCalculationQuery = { [weak self] query in self?.currencyRates.noteQuery(query) }
        updater.start()
        installApplicationMenu()
        installStatusItem()
        indexObserver = index.$apps.sink { [weak self] apps in self?.settingsPanel.state.apps = apps }
        index.start()
        clipboardMonitor.start()
        registerHotKeys()
        if let i = CommandLine.arguments.firstIndex(of: "--run-extension"), CommandLine.arguments.indices.contains(i + 1) {
            let manager = ExtensionManager()
            manager.onLog = { print("log: \($0)") }
            manager.reload()
            let input = CommandLine.arguments.indices.contains(i + 2) ? CommandLine.arguments[i + 2] : ""
            guard let ext = manager.search(CommandLine.arguments[i + 1]).first else { print("no such extension"); exit(2) }
            manager.run(ext, input: input) { result in
                switch result {
                case .success(let out): print("result: \(out)"); exit(0)
                case .failure(let err): print("error: \(err.localizedDescription)"); exit(1)
                }
            }
            return
        }
        if CommandLine.arguments.contains("--import-raycast") {
            DispatchQueue.main.async { [weak self] in self?.settingsPanel.showRaycastImport() }
        }
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { [weak self] in self?.showSettings() }
        }
        if CommandLine.arguments.contains("--register-login") {
            try? SMAppService.mainApp.register()
            print("login item: \(SMAppService.mainApp.status == .enabled ? "enabled" : "not enabled")")
        }
        if config.showOnLaunch && !CommandLine.arguments.contains("--import-raycast") && !CommandLine.arguments.contains("--settings") && !CommandLine.arguments.contains("--agents") && !CommandLine.arguments.contains("--show") && !CommandLine.arguments.contains("--notes") {
            // AppKit is ready on the next main turn; Spotlight results refresh independently.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.panel.isVisible else { return }
                self.panel.toggle()
            }
        }
        if CommandLine.arguments.contains("--notes") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.notesPanel.toggle() }
        }
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.panel.toggle()
                if let i = CommandLine.arguments.firstIndex(of: "--query"), CommandLine.arguments.indices.contains(i + 1) {
                    self.panel.setQuery(CommandLine.arguments[i + 1])
                }
            }
        }
        if CommandLine.arguments.contains("--memory-check") {
            let check = MemoryCheck(steps: .init(
                showLauncher: { [weak self] in if self?.panel.isVisible == false { self?.panel.toggle() } },
                setQuery: { [weak self] in self?.panel.setQuery($0) },
                hideLauncher: { [weak self] in if self?.panel.isVisible == true { self?.panel.toggle() } },
                showSettings: { [weak self] in self?.showSettings() },
                closeSettings: { [weak self] in self?.settingsPanel.window?.close() }))
            memoryCheck = check
            check.run()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !panel.isVisible { panel.toggle(source: .workspace) }
        else { panel.makeKeyAndOrderFront(nil) }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel.model.caffeinate.stop()
        clipboardMonitor.stop()
        notesStore.flush()
        HotKeyCenter.shared.unregisterAll()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let wing = NSImage(named: "VolantWing") {
            wing.size = NSSize(width: 16, height: 16)
            wing.isTemplate = true
            item.button?.image = wing
        } else {
            item.button?.image = NSImage(systemSymbolName: "arrow.up.forward.circle", accessibilityDescription: "Volant")
        }
        item.button?.setAccessibilityLabel("Volant")
        let menu = StatusMenu.make(target: self, show: #selector(togglePanel), settings: #selector(showSettings), update: #selector(checkForUpdates))
        item.menu = menu
        statusItem = item
    }

    private func registerHotKeys() {
        HotKeyCenter.shared.unregisterAll()
        var failures: [String] = []
        if let combo = KeyCombo(parsing: config.summonHotKey) {
            if HotKeyCenter.shared.register(combo, handler: { [weak self] in self?.togglePanelFromHotkey() }) == nil {
                failures.append("Show Volant shortcut unavailable: " + KeyCombo.display(config.summonHotKey))
            }
        }
        if let combo = KeyCombo(parsing: config.notesHotKey) {
            if HotKeyCenter.shared.register(combo, handler: { [weak self] in self?.toggleNotes() }) == nil {
                failures.append("Open Notes shortcut unavailable: " + KeyCombo.display(config.notesHotKey))
            }
        }
        if let combo = KeyCombo(parsing: config.emojiHotKey) {
            if HotKeyCenter.shared.register(combo, handler: { [weak self] in
                self?.panel.showEmoji()
            }) == nil { failures.append("Search Emoji shortcut unavailable: " + KeyCombo.display(config.emojiHotKey)) }
        }
        if let combo = KeyCombo(parsing: config.talkHotKey) {
            // The only hotkey that also acts on release: hold it to dictate, let go to transcribe.
            // A quick tap starts and the next tap stops, so both habits work.
            if HotKeyCenter.shared.register(combo, handler: { [weak self] in
                self?.beginDictationFromHotkey()
            }, onRelease: { [weak self] in
                self?.endDictationFromHotkey()
            }) == nil { failures.append("Dictate Text shortcut unavailable: " + KeyCombo.display(config.talkHotKey)) }
        }
        for (value, action) in [(config.lockScreenHotKey, SystemAction.lockScreen), (config.sleepDisplaysHotKey, .sleepDisplays)] {
            guard let combo = KeyCombo(parsing: value) else { continue }
            if HotKeyCenter.shared.register(combo, handler: { [weak self] in self?.performSystemAction(action) }) == nil {
                failures.append(action.title + " shortcut unavailable: " + KeyCombo.display(value))
            }
        }
        failures += AppHotKeys.register(config.appHotKeys) { [weak self] message in
            guard let state = self?.settingsPanel.state else { return }
            if !state.registrationErrors.contains(message) { state.registrationErrors.append(message) }
        }
        settingsPanel.state.registrationErrors = failures
    }

    private func installApplicationMenu() {
        let bar = NSMenu()
        let item = NSMenuItem()
        bar.addItem(item)
        let menu = NSMenu(title: "Volant")
        menu.addItem(withTitle: "Agents…", action: #selector(showAgents), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Volant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        item.submenu = menu
        // Preserve standard text-editing shortcuts in the native notes editor.
        let editItem = NSMenuItem()
        bar.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editItem.submenu = edit
        NSApp.mainMenu = bar
    }

    @objc private func showAgents() {
        NSApp.activate(ignoringOtherApps: true)
        panel.showAgents()
    }

    @objc private func checkForUpdates() { updater.checkForUpdates() }

    @objc private func showSettings() {
        panel.orderOut(nil)
        settingsPanel.refresh(config, apps: index.apps)
        settingsPanel.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleNotes() { notesPanel.toggle() }

    /// Held long enough to be a hold rather than a tap, the release stops dictation. A tap leaves
    /// it listening so the same key can stop it, which is how push-to-talk and toggle both work.
    private var dictationPressedAt: Date?

    private func beginDictationFromHotkey() {
        let model = panel.model
        if model.dictation.isListening {
            dictationPressedAt = nil
            model.finishDictation()
            return
        }
        dictationPressedAt = Date()
        panel.showForDictation()
        model.toggleDictation(stopHint: "release or press \(KeyCombo.display(config.talkHotKey)) to stop")
    }

    private func endDictationFromHotkey() {
        guard let pressedAt = dictationPressedAt else { return }
        dictationPressedAt = nil
        guard Date().timeIntervalSince(pressedAt) >= 0.4 else { return }
        panel.model.finishDictation()
    }

    private func togglePanelFromHotkey() {
        let started = ProcessInfo.processInfo.systemUptime
        panel.toggle(source: .hotkey, requestedAt: started)
    }
    @objc private func togglePanel() { panel.toggle(source: .menu) }

    /// One path for the launcher and the hotkeys. The launcher is hidden first and the action
    /// runs a moment later, so it is not on screen when the Mac locks or a dialog appears. A
    /// failure reopens the launcher with the reason rather than failing silently.
    private func performSystemAction(_ action: SystemAction) {
        panel.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let problem = SystemActions.perform(action) else { return }
            if !self.panel.isVisible { self.panel.toggle() }
            self.panel.model.actionFeedback = problem
        }
    }

    /// Applies the color theme and its light or dark appearance; a nil appearance follows macOS,
    /// including its automatic switching.
    private func applyTheme() {
        let appearance = config.appearance
        MainActor.assumeIsolated { ThemeStore.shared.apply(appearance) }
    }

    @objc private func reloadConfig() {
        let loaded = Preferences.load()
        if let error = Preferences.loadError {
            let alert = NSAlert()
            alert.messageText = "Configuration not applied"
            alert.informativeText = error
            if let window = settingsPanel.window { settingsPanel.showWindow(nil); alert.beginSheetModal(for: window) }
            return
        }
        config = loaded
        NSApp.setActivationPolicy(config.showInDock ? .regular : .accessory)
        applyTheme()
        settingsPanel.refresh(config, apps: index.apps)
        registerHotKeys()
        panel.apply(config: config)
        if let ai = try? AIConfiguration.load() { panel.model.acp.configure(ai) }
        clipboardStore.retention = config.clipboardRetention
        settingsSync.update(enabled: config.syncSettingsWithICloud)
        currencyRates.keyChanged()
    }
}
