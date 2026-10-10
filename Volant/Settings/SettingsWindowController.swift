import AppKit
import SwiftUI
import ServiceManagement
import VolantCore

final class SettingsState: ObservableObject {
    @Published var config = Preferences()
    @Published var apps: [AppEntry] = []
    @Published var section = "General"
    @Published var editing: AppEntry?
    @Published var registrationErrors: [String] = []
    @Published var iCloudStatus = ICloudSettingsSync.Status.off.text
}

/// Native settings; the injected configuration URL also supports isolated UI fixtures.
final class SettingsWindowController: NSWindowController {
    private lazy var raycastImport = RaycastImportWindowController(onChange: onChange)
    let state = SettingsState()
    private let onChange: () -> Void
    private let configURL: URL

    init(configURL: URL = Preferences.configURL, acp: ACPModel = ACPModel(), openAI: @escaping (AIConfiguration) -> Void = { _ in }, onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.configURL = configURL
        let window = SettingsPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 680, height: 500)
        window.title = "Volant Settings"
        window.collectionBehavior = [.fullScreenNone]
        window.setAccessibilitySubrole(.dialog)
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VolantSettings")
        super.init(window: window)
        let hosting = NSHostingView(rootView: ThemedRoot(paletteText: false) {
            SettingsView(state: state, acp: acp, configURL: configURL, onChange: onChange, openAI: openAI,
                         chooseAIProject: { [weak self] completion in self?.chooseAIProject(completion) },
                         importRaycast: { [weak self] in self?.showRaycastImport() })
                .frame(minWidth: 680, idealWidth: 760, maxWidth: .infinity, minHeight: 500, idealHeight: 540, maxHeight: .infinity)
        })
        hosting.sizingOptions = []
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 540))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: content.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.contentView = content
        window.contentMinSize = NSSize(width: 680, height: 500)
        window.setFrame(NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 760, height: 540), styleMask: window.styleMask), display: false)
        window.center()
    }
    private func chooseAIProject(_ completion: @escaping (URL?) -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        picker.prompt = "Use Project"
        picker.beginSheetModal(for: window) { result in completion(result == .OK ? picker.url : nil) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh(_ config: Preferences, apps: [AppEntry]? = nil, errors: [String]? = nil) {
        state.config = config
        if let apps { state.apps = apps }
        if let errors { state.registrationErrors = errors }
    }
    func edit(_ app: AppEntry) { state.section = "App Shortcuts"; state.editing = app; showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
    func showRaycastImport() { raycastImport.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
}

private struct SettingsView: View {
    @ObservedObject var state: SettingsState
    @ObservedObject var acp: ACPModel
    let configURL: URL
    let onChange: () -> Void
    let openAI: (AIConfiguration) -> Void
    let chooseAIProject: (@escaping (URL?) -> Void) -> Void
    let importRaycast: () -> Void
    @State private var search = ""
    @State private var error: String?
    @State private var loginStatus = SMAppService.mainApp.status
    private let sections = ["General", "Appearance", "Status Bar", "AI", "Extensions", "App Shortcuts", "Data & Configuration"]
    private let symbols = ["General": "gearshape", "Appearance": "circle.lefthalf.filled", "Status Bar": "menubar.rectangle", "AI": "sparkles",
                           "Extensions": "puzzlepiece.extension", "App Shortcuts": "command", "Data & Configuration": "externaldrive"]

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { state.section }, set: { if let section = $0 { state.section = section } })) {
                ForEach(sections, id: \.self) { section in
                    Label(section, systemImage: symbols[section] ?? "circle").tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 215)
            Divider()
            Group {
                if state.section == "General" { general }
                else if state.section == "Appearance" { AppearanceSettingsView(appearance: state.config.appearance, configURL: configURL, onChange: onChange) }
                else if state.section == "Status Bar" { statusBar }
                else if state.section == "AI" { AISettingsView(model: acp, configURL: configURL, onChange: onChange, openConversation: openAI, chooseProject: chooseAIProject) }
                else if state.section == "Extensions" { ExtensionSettingsView(configURL: configURL, onChange: onChange) }
                else if state.section == "App Shortcuts" { shortcuts }
                else { data }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $state.editing) { app in
            AppBindingEditor(app: app, configURL: configURL, onChange: onChange)
        }
        .alert("Couldn’t apply change", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Show Volant in the Dock", isOn: boolean("showInDock", state.config.showInDock))
                Toggle("Show launcher when Volant starts", isOn: boolean("showOnLaunch", state.config.showOnLaunch))
                Toggle("Launch at Login", isOn: Binding(get: { loginStatus == .enabled }, set: { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginStatus = SMAppService.mainApp.status
                    } catch { self.error = error.localizedDescription; loginStatus = SMAppService.mainApp.status }
                }))
                if loginStatus == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("Allow Volant in System Settings → General → Login Items.").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Toggle("Keep display on and unlocked", isOn: boolean("caffeinateKeepsDisplayAwake", state.config.caffeinateKeepsDisplayAwake))
            } header: {
                Text("Caffeinate")
            } footer: {
                SettingsFooter("Caffeinate sessions keep the display from dimming, sleeping or locking. Turn this off to keep only the Mac awake and let the display sleep. Add display or system to a caffeinate command to choose for one session.")
            }
            Section {
                if !state.registrationErrors.isEmpty { Text(state.registrationErrors.joined(separator: "\n")).foregroundStyle(.red) }
                GlobalShortcutRow(title: "Show Volant", key: "summonHotKey", value: state.config.summonHotKey, configURL: configURL, onChange: onChange)
                GlobalShortcutRow(title: "Open Notes", key: "notesHotKey", value: state.config.notesHotKey, configURL: configURL, onChange: onChange)
                GlobalShortcutRow(title: "Search Emoji", key: "emojiHotKey", value: state.config.emojiHotKey, configURL: configURL, onChange: onChange)
                GlobalShortcutRow(title: "Dictate Text", key: "talkHotKey", value: state.config.talkHotKey, configURL: configURL, onChange: onChange)
                GlobalShortcutRow(title: "Lock Screen", key: "lockScreenHotKey", value: state.config.lockScreenHotKey, configURL: configURL, onChange: onChange)
                GlobalShortcutRow(title: "Sleep Displays", key: "sleepDisplaysHotKey", value: state.config.sleepDisplaysHotKey, configURL: configURL, onChange: onChange)
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                SettingsFooter("Click a shortcut and press a new combination; changes save immediately. Hold the dictation shortcut while you speak and let go to copy the text, or tap it to start and again to stop.")
            }
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private var statusBar: some View {
        Form {
            Section {
                Toggle("Herdr agent activity", isOn: Binding(get: { state.config.statusBar.sources.contains("herdr") }, set: { value in
                    apply { try Preferences.updateStatusBar(enabled: value, at: configURL) }
                }))
                Picker("Agents", selection: Binding(get: { state.config.statusBar.herdrFilter }, set: { value in
                    apply { try Preferences.updateStatusBar(filter: value, at: configURL) }
                })) {
                    ForEach(Preferences.harnessOptions, id: \.id) { Text($0.title).tag($0.id) }
                }.disabled(!state.config.statusBar.sources.contains("herdr"))
            } header: {
                Text("Herdr")
            } footer: {
                SettingsFooter("Shows “Herdr: 3 waiting” in the launcher footer when agents need you. Click it, or type herdr, to see the panes with waiting ones first and answer supported questions. Includes Local and enabled machines saved in Herdr. Manage remote connections in Herdr.")
            }
            Section {
                Toggle("AI Chat activity", isOn: Binding(get: { state.config.statusBar.sources.contains("ai-chat") }, set: { value in
                    apply { try Preferences.updateStatusBar(source: "ai-chat", enabled: value, at: configURL) }
                }))
            } header: {
                Text("AI Chat")
            } footer: {
                SettingsFooter("Links to your active conversation, its provider, and whether it needs you. Hidden when no conversation is active. AI Chat activity appears below the launcher’s search field; Herdr appears in the footer.")
            }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search applications", text: $search).textFieldStyle(.roundedBorder)
                Text("Type an alias to open the app from the launcher, or record a global hotkey. Aliases save on Return or when you leave the field.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !state.registrationErrors.isEmpty {
                    Text(state.registrationErrors.joined(separator: "\n")).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            }.padding(12)
            Divider()
            List {
                ForEach(state.apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { app in
                    AppBindingRow(app: app, config: state.config, configURL: configURL, onChange: onChange)
                }
            }.listStyle(.plain).overlay {
                if state.apps.isEmpty { Text("No applications indexed yet. This list updates automatically.").foregroundStyle(.secondary) }
            }
        }
    }

    private var data: some View {
        Form {
            Section {
                LabeledContent("config.json") {
                    Button("Open") { NSWorkspace.shared.open(configURL) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([configURL]) }
                }
                LabeledContent("Apply edits made outside Settings") {
                    Button("Reload Configuration") { onChange() }
                }
            } header: {
                Text("Configuration")
            } footer: {
                SettingsFooter("Aliases, shortcuts and preferences live in one portable JSON file.")
            }
            Section {
                Toggle("Sync settings with iCloud", isOn: boolean("syncSettingsWithICloud", state.config.syncSettingsWithICloud))
                if state.config.syncSettingsWithICloud {
                    LabeledContent("Status") { Text(state.iCloudStatus).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                }
            } header: {
                Text("iCloud")
            } footer: {
                SettingsFooter("Keyboard shortcuts, snippets, quicklinks, aliases, appearance and clipboard history length follow you to Macs signed in to the same Apple Account. App shortcuts, favorites, Dock, status bar, AI and extension settings stay on this Mac. When turned on, settings already in iCloud replace these, and a copy of this Mac's config.json is kept beside it.")
            }
            Section {
                LabeledContent("Raycast") {
                    Button("Import from Raycast…", action: importRaycast)
                }
                LabeledContent("Volant backup") {
                    Button("Import…") { if Backup.importBackup() { onChange() } }
                    Button("Export…") { Backup.export() }
                }
            } header: {
                Text("Import & Backup")
            } footer: {
                SettingsFooter("Imports show a preview before applying changes. Export a backup before moving to another Mac.")
            }
            CryptoKeySection(onChange: onChange)
            Section {
                LabeledContent("City time zones") {
                    Link("GeoNames", destination: URL(string: "https://www.geonames.org")!)
                }
                LabeledContent("Airport codes") {
                    Link("mwgg/Airports", destination: URL(string: "https://github.com/mwgg/Airports")!)
                }
                LabeledContent("Exchange rates") {
                    Link("Rates By Exchange Rate API", destination: WorldRates.attribution)
                }
                LabeledContent("Crypto prices") {
                    Link("Data provided by CoinGecko", destination: URL(string: "https://www.coingecko.com")!)
                }
                LabeledContent("Color themes") {
                    Text("Catppuccin, Nord, Dracula, Gruvbox, Solarized, Tokyo Night, Rosé Pine, One Dark")
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Acknowledgements")
            } footer: {
                SettingsFooter("City names for calculator time conversions come from GeoNames, licensed under Creative Commons Attribution 4.0. Airport codes come from mwgg/Airports, licensed under MIT; its license is included with Volant. Color theme palettes come from their projects under MIT licenses, also included.")
            }
        }
        .formStyle(.grouped)
    }
    private func boolean(_ key: String, _ value: Bool) -> Binding<Bool> {
        Binding(get: { value }, set: { newValue in apply { try Preferences.updateBoolean(key, value: newValue, at: configURL) } })
    }
    private func apply(_ action: () throws -> Void) {
        do { try action(); onChange() } catch { self.error = error.localizedDescription }
    }
}

/// A dialog-style panel tells tiling window managers to float Settings.
final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        // Escape inside a recorder or sheet belongs to that control first.
        guard attachedSheet == nil else { return }
        orderOut(sender)
    }
}
