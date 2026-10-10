import AppKit
import Combine
import ImageIO
import OSLog
import VolantCore

enum LauncherAction {
    case settings
    case extensionSettings
    case ai, aiSettings
    case reloadConfig
    case editApp(AppEntry)
    case agents
    case open(String)
    case create(String)
    case confetti
    case systemAction(SystemAction)
    case checkForUpdates, about, quit
}

enum ResultRow: Identifiable, Hashable {
    case core(CoreCommand)
    case systemAction(SystemAction)
    case appleShortcut(AppleShortcut)
    case caffeinate(CaffeinateCommand)
    case systemSettings(SystemSettingsDestination)
    case settings
    case reloadConfig
    case connectivity(ConnectivityItem)
    case audioRoute(AudioRoute)
    case volume(VolumeCommand, detail: String)
    case agents
    case agentSession(AgentSession)
    case herdrMachine(HerdrMachine?, enabled: Bool, busy: Bool)
    case snippet(Snippet)
    case emoji(EmojiEntry)
    case quicklink(Quicklink, query: String)
    case extensionRun(InstalledExtension, input: String)
    case extensionResult(String)
    case note(Note)
    case newNote(String)
    case calculation(CalculationAnswer, slot: Int)
    case app(AppEntry)
    case file(FileEntry)
    case contact(ContactEntry)
    case event(EventEntry)
    case clip(ClipEntry)

    var id: String {
        switch self {
        case .appleShortcut(let shortcut): return "apple-shortcut:" + shortcut.id
        case .core(let command): return "core:" + command.rawValue
        case .systemAction(let action): return "system-action:" + action.rawValue
        case .caffeinate(let command): return "caffeinate:" + command.id
        case .agentSession(let session): return "agent:" + session.id
        case .herdrMachine(let machine, _, _): return "herdr-machine:" + (machine?.id ?? "local")
        case .connectivity(let item): return item.id
        case .audioRoute(let route): return "audio:" + route.id
        case .volume(let command, _): return "volume:" + command.id
        case .systemSettings(let pane): return "system-settings:" + pane.id
        case .settings: return "command:settings"
        case .reloadConfig: return "command:reload"
        case .agents: return "command:agents"
        case .calculation(_, let slot): return "calc:\(slot)"
        case .app(let a): return "app:\(a.id)"
        case .file(let f): return "file:\(f.id)"
        case .contact(let c): return "contact:\(c.id)"
        case .event(let e): return "event:\(e.id)"
        case .clip(let c): return "clip:\(c.id)"
        case .note(let n): return "note:\(n.id)"
        case .newNote(let t): return "newnote:\(t)"
        case .extensionRun(let e, let i): return "ext:\(e.id):\(i)"
        case .extensionResult(let s): return "extresult:\(s)"
        case .snippet(let s): return "snip:\(s.name.utf8.count):\(s.name)\(s.keyword.utf8.count):\(s.keyword)\(s.body)"
        case .emoji(let e): return "emoji:\(e.symbol)"
        case .quicklink(let q, let t): return "ql:\(q.name):\(t)"
        }
    }

    /// Right-aligned kind label, as in Raycast's "Application" / "Command" column.
    var kind: String {
        switch self {
        case .appleShortcut: return "Apple Shortcut"
        case .core, .caffeinate, .systemAction: return "Command"
        case .agentSession(let session): return session.status
        case .herdrMachine(_, let enabled, _): return enabled ? "Enabled" : "Disabled"
        case .connectivity: return "Connectivity"
        case .audioRoute(let route): return route.current ? "Current" : "Device"
        case .volume: return "System"
        case .systemSettings: return "System Settings"
        case .settings, .reloadConfig: return "Command"
        case .agents: return "Command"
        case .calculation: return "Calculation"
        case .app: return "Application"
        case .file: return "File"
        case .contact: return "Contact"
        case .event: return "Event"
        case .clip: return "Clipboard"
        case .note, .newNote: return "Note"
        case .extensionRun: return "Extension"
        case .extensionResult: return "Result"
        case .snippet: return "Snippet"
        case .emoji: return "Emoji"
        case .quicklink: return "Quicklink"
        }
    }

    var isCoreCommand: Bool {
        switch self {
        case .core, .caffeinate, .settings, .reloadConfig, .agents, .volume, .audioRoute, .connectivity, .systemSettings, .systemAction: return true
        default: return false
        }
    }

    /// Footer label for return.
    var primaryAction: String {
        switch self {
        case .appleShortcut: return "Run Shortcut"
        case .core: return "Open Command"
        case .systemAction(let action): return action.title.replacingOccurrences(of: "…", with: "")
        case .caffeinate(let command): return command.stop ? "Stop" : "Start"
        case .agentSession: return "Focus in Herdr"
        case .herdrMachine(let machine, let enabled, let busy):
            if busy { return "Working…" }
            guard machine != nil else { return "Always on" }
            return enabled ? "Disable Machine" : "Enable Machine"
        case .connectivity(let item):
            if case .wifi(let network) = item { return network.current ? "Connected" : "Join Network" }
            if case .refresh = item { return "Refresh" }
            return "Open Settings"
        case .audioRoute(let route): return route.current ? "Keep Current Device" : "Use as " + route.direction.rawValue.capitalized
        case .volume: return "Apply"
        case .settings, .systemSettings: return "Open Settings"
        case .reloadConfig: return "Reload Configuration"
        case .agents: return "Open Agents"
        case .calculation: return "Copy Result"
        case .app: return "Open Application"
        case .file: return "Open File"
        case .contact(let c): return c.primaryField?.copyTitle ?? "Open Contact"
        case .event(let e): return e.joinURL != nil ? "Join Meeting" : "Open Calendar"
        case .clip: return "Copy to Clipboard"
        case .note: return "Open Note"
        case .newNote: return "Create Note"
        case .extensionRun(let ext, _): return ext.communityBlocked ? "Open Extension Settings" : (ext.enabled ? "Run Extension" : "Enable and Run…")
        case .extensionResult: return "Copy Result"
        case .snippet: return "Copy Snippet"
        case .emoji: return "Copy Emoji"
        case .quicklink: return "Open Link"
        }
    }

    /// Footer label for command-return, when a secondary action exists.
    var secondaryAction: String? {
        switch self {
        case .file: return "Reveal in Finder"
        case .app: return "Reveal in Finder"
        case .contact(let c): return c.secondaryField?.copyTitle
        case .calculation: return "Use Answer"
        default: return nil
        }
    }
}

struct ResultSection: Identifiable, Equatable {
    let title: String
    let rows: [ResultRow]
    var id: String { title }
}

/// What a result row draws besides its own payload: the selected identity, the current row for
/// each identity, contact thumbnails and cached icons. Rows observe this instead of the whole
/// launcher model, so notices, footer feedback and focus requests do not redraw every row, while
/// lazily created rows still observe selection directly.
final class LauncherRowState: ObservableObject {
    @Published fileprivate(set) var selectedID: String?
    @Published fileprivate(set) var rowsByID: [String: ResultRow] = [:]
    @Published fileprivate(set) var contactImages: [String: NSImage] = [:]
    private let icons: IconCache
    private let clipImages = NSCache<NSNumber, NSImage>()

    /// Uses the icon cache shared with Settings unless a test supplies its own.
    init(icons: IconCache = .shared) {
        self.icons = icons
        clipImages.countLimit = 32
    }

    /// Finder's icon for a path, fetched once. A fresh NSImage on every redraw would make SwiftUI
    /// treat each row as changed and refetch icons on every keystroke and arrow press.
    func icon(forFile path: String) -> NSImage { icons.icon(forFile: path) }

    /// A clipboard image's row thumbnail, decoded once per entry rather than on every redraw. Rows
    /// draw it at 24 points, so it is downsampled to `thumbnailPixels` and keeps no reference to
    /// the decrypted image bytes; `NSImage(data:)` would hold both the bytes and a full-size decode.
    func image(for clip: ClipEntry) -> NSImage? {
        if let cached = clipImages.object(forKey: NSNumber(value: clip.id)) { return cached }
        guard let data = clip.imageData, let image = Self.thumbnail(data) else { return nil }
        clipImages.setObject(image, forKey: NSNumber(value: clip.id))
        return image
    }

    static let thumbnailPixels = 72

    /// A thumbnail at most `thumbnailPixels` on its longer side, or nil if the data is not an image.
    static func thumbnail(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// Drops cached icons after the app index changes, since an update can change an app's icon.
    /// The cache is shared, so Settings rows refetch their icons too.
    func clearIcons() { icons.clear() }
}

/// Routes a query. Prefixes force one source: `/` files, `@` contacts, `cal` or `today` agenda, `clip` history.
/// Otherwise results merge: math and units first, then apps, contacts, and files once the query is long enough.
final class LauncherModel: ObservableObject {
    @Published var query: String = "" { didSet { if oldValue != query { showingACP = false; actionTarget = nil; showingAppMenu = false; refresh() } } }
    private var flattenedRows: [ResultRow] = []
    @Published private var displayedSections: [ResultSection] = []
    var sections: [ResultSection] {
        get { displayedSections }
        set {
            assert(Thread.isMainThread, "Launcher results must update on the main thread")
            var seen = Set<String>()
            var normalized: [ResultSection] = []
            var duplicates = 0
            for section in newValue {
                let unique = section.rows.filter { row in
                    if seen.insert(row.id).inserted { return true }
                    duplicates += 1
                    return false
                }
                guard !unique.isEmpty else { continue }
                if let index = normalized.firstIndex(where: { $0.id == section.id }) {
                    normalized[index] = ResultSection(title: section.title, rows: normalized[index].rows + unique)
                } else { normalized.append(ResultSection(title: section.title, rows: unique)) }
            }
            if duplicates > 0 { Logger(subsystem: "com.mysticcoders.volant", category: "Launcher").warning("Duplicate result identities ignored: \(duplicates)") }
            guard normalized != displayedSections else { return }
            flattenedRows = normalized.flatMap(\.rows)
            if let target = actionTarget, !flattenedRows.contains(where: { $0.id == target.id }) { actionTarget = nil }
            displayedSections = normalized
            rowState.rowsByID = Dictionary(flattenedRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            publishSelection()
        }
    }
    let rowState = LauncherRowState()
    @Published var searchFocusRequest = UUID()
    @Published var selection: Int = 0 { didSet { if oldValue != selection { actionTarget = nil; publishSelection() } } }

    private func publishSelection() {
        let id = selectedRow?.id
        if rowState.selectedID != id { rowState.selectedID = id }
    }
    @Published var actionTarget: ResultRow?
    /// The launcher's own menu, opened from the Volant mark in the footer.
    @Published var showingAppMenu = false
    /// Opens a link in the default browser; fixtures and tests record it instead.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var actionConfigURL: URL = Preferences.configURL
    @Published var actionFeedback: String?
    let dictionary = DictionaryModel()
    var showingDictionary: Bool { DictionaryQuery.term(query) != nil }
    let translation = TranslationModel()
    var showingTranslation: Bool { ["translate", "translation", "translator"].contains(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    let caffeinate: CaffeinateService
    private var caffeinateSubscription: AnyCancellable?
    var showingEmoji: Bool { query.trimmingCharacters(in: .whitespaces).hasPrefix(":") }
    var emojiSearch: (String) -> [EmojiEntry] = { EmojiIndex.search($0, limit: Int.max) }
    var searchText: String {
        get { showingEmoji ? String(query.dropFirst()) : query }
        set { query = showingEmoji ? ":" + newValue : newValue }
    }
    static let emojiColumns = 10
    var volumeControl = VolumeControl()
    var audioRouting: AudioRouting = CoreAudioRouting()
    lazy var connectivity: ConnectivityAccess = ConnectivityService()
    @Published var wifiJoin: WiFiChoice?
    @Published var connectivityBusy = false
    @Published var notice: String? = nil
    var dismiss: () -> Void = {}
    let appleShortcuts = AppleShortcutsModel()
    private var shortcutsSubscription: AnyCancellable?
    private var shortcutRunQuery: String?
    var showingAppleShortcuts: Bool { AppleShortcut.queryTerm(query) != nil }
    let agents: AgentsModel
    let acp = ACPModel()
    @Published private(set) var showingACP = false
    @Published var promotedHarness: String?
    var isPresented = false {
        didSet {
            guard isPresented != oldValue else { return }
            prefixBranch = nil
            if !isPresented { clipboard.endSearchSession() }
        }
    }
    private var agentSubscription: AnyCancellable?
    private var indexSubscription: AnyCancellable?
    var showingAgents: Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q == "agents" || q == "herdr" || q.hasPrefix("agents ") || q.hasPrefix("herdr ")
    }
    /// `herdr machine` lists saved destinations instead of panes, so enabling one is reachable
    /// without leaving the launcher. A trailing term filters by label.
    var showingMachines: Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return ["agents machine", "herdr machine", "agents machines", "herdr machines"].contains(q)
            || ["agents machine ", "herdr machine ", "agents machines ", "herdr machines "].contains(where: q.hasPrefix)
    }
    var promotedTitle: String { Preferences.harnessOptions.first { $0.id == promotedHarness }?.title ?? "Agents" }
    var promotedSessions: [AgentSession] { agents.sessions.filter { promotedHarness == "all" || $0.agent == promotedHarness } }
    func promoteHarness(_ id: String?) {
        do {
            try Preferences.updatePromotedHarness(id)
            config.promotedHarness = id
            if id != nil && isPresented && !agents.connected { agents.connect() }
        } catch { notice = "Couldn’t save status bar: " + error.localizedDescription }
    }
    func resumeAgentsIfNeeded() {
        if promotedHarness != nil && !agents.connected { agents.connect() }
    }
    /// The footer's Herdr status opens the `herdr` list, which puts waiting panes first, narrowed
    /// to the agent chosen in Settings when there is one.
    func showPromotedAgents() {
        guard let filter = promotedHarness else { query = "herdr"; return }
        query = filter == "all" ? "herdr" : "herdr " + filter
    }
    private func refreshMachineResults() {
        let selectedID = selectedRow?.id
        let parts = query.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
        let term = parts.count > 2 ? String(parts[2]) : ""
        var rows: [ResultRow] = []
        let localMatches = term.isEmpty || "local".localizedCaseInsensitiveContains(term)
        if localMatches { rows.append(.herdrMachine(nil, enabled: true, busy: false)) }
        for machine in agents.profiles where term.isEmpty || machine.label.localizedCaseInsensitiveContains(term) || machine.id.localizedCaseInsensitiveContains(term) {
            rows.append(.herdrMachine(machine, enabled: machine.enabled, busy: agents.machineToggleInFlight == machine.id))
        }
        sections = rows.isEmpty ? [] : [ResultSection(title: "Herdr machines", rows: rows)]
        if !agents.connected { notice = agents.message }
        else if rows.isEmpty { notice = agents.profiles.isEmpty ? "No machines saved in Herdr. Add one with herdr machine add." : "No matching machines" }
        else { notice = agents.actionMessage }
        if let selectedID, let index = self.rows.firstIndex(where: { $0.id == selectedID }) { selection = index }
        else { selection = min(selection, max(0, self.rows.count - 1)) }
    }

    private func refreshAgentResults() {
        guard showingAgents else { return }
        if showingMachines { refreshMachineResults(); return }
        let selectedID = selectedRow?.id
        let parts = query.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        let term = parts.count > 1 ? String(parts[1]) : ""
        let sessions = agents.sessions.filter {
            term.isEmpty || [$0.machineLabel, $0.project, $0.provider, $0.agent, $0.status, $0.cwd ?? "", $0.terminalTitle ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(term)
        }
        sections = sessions.isEmpty ? [] : [ResultSection(title: "Herdr panes", rows: sessions.map(ResultRow.agentSession))]
        notice = agents.connected ? (agents.busy && agents.sessions.isEmpty ? "Loading Herdr panes…" : (sessions.isEmpty && !agents.sessions.isEmpty ? "No matching panes" : agents.message)) : agents.message
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) { selection = index }
        else { selection = min(selection, max(0, rows.count - 1)) }
    }


    var rows: [ResultRow] { flattenedRows }
    var selectedRow: ResultRow? { rows.indices.contains(selection) ? rows[selection] : nil }

    private let index: AppIndex
    private var clipboardSubscription: AnyCancellable?
    private let clipboard: ClipboardStore
    private let notes: NotesStore
    private let onNote: (LauncherAction) -> Void
    var extensions = ExtensionManager()
    @Published var pendingExtension: ExtensionPermissionRequest?
    @Published private(set) var extensionRunning = false
    let usage: UsageStore
    var config: Preferences { didSet { promotedHarness = config.promotedHarness; extensions.invalidateCatalog() } }
    var searchesSecondarySources = true
    let files: FileSearch
    @Published private(set) var filesUnavailable = false
    private var indexStateSubscription: AnyCancellable?
    private let contacts = ContactSearch()
    let dictation = SpeechDictation()
    private let agenda = CalendarAgenda()
    private var searchesAppIndex = false
    private var generation = 0
    private var immediate: [ResultSection] = []
    private var contactRows: [ResultRow] = []
    private var fileRows: [ResultRow] = []
    private var notesSearch: NotesSearchTask?
    /// The prefix source the last refresh routed to (`ext`, `notes`, `clip`), so a source reloads
    /// from disk when it is entered rather than on every keystroke inside it.
    private var prefixBranch: String?
    /// The last query that produced a calculator answer, and that answer.
    private var calculationAnchor: (query: String, answer: CalculationAnswer)?
    private var holdExpiry: DispatchWorkItem?
    /// While an expression is briefly incomplete (`5+` on the way to `5+3`), the last answer stays
    /// in place, dimmed, for up to `calculationHoldDuration`, so the list below does not jump up by
    /// a card's height and back on each keystroke. It is not a row: it cannot be selected or
    /// activated, so Return never acts on an answer that no longer matches the query.
    @Published private(set) var heldCalculation: CalculationAnswer?
    var calculationHoldDuration: TimeInterval = 0.6

    init(index: AppIndex, clipboard: ClipboardStore, notes: NotesStore, config: Preferences, usage: UsageStore = UsageStore(), caffeinate: CaffeinateService = CaffeinateService(), files: FileSearch = FileSearch(), agents: AgentsModel = AgentsModel(), onNote: @escaping (LauncherAction) -> Void) {
        self.agents = agents
        self.files = files
        self.caffeinate = caffeinate
        self.usage = usage
        self.index = index
        self.clipboard = clipboard
        self.notes = notes
        self.config = config
        self.onNote = onNote
        self.promotedHarness = config.promotedHarness
        clipboardSubscription = clipboard.changes.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self, self.showingClipboard else { return }
            self.objectWillChange.send()
            self.refreshClipboardResults()
        }
        caffeinateSubscription = caffeinate.$command.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if CaffeinateCommand.matches(self.query) { self.refreshCaffeinateResults() }
            }
        }
        indexStateSubscription = index.$unavailable.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // Spotlight may finish after the first window is already visible.
        // Receive on the next main turn, after @Published has assigned index.apps.
        indexSubscription = index.$apps.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshForAppIndex()
        }
        shortcutsSubscription = appleShortcuts.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.objectWillChange.send()
                if self.isPresented { self.refreshShortcutResults() }
                if self.shortcutRunQuery == self.query, let message = self.appleShortcuts.runMessage { self.actionFeedback = message }
            }
        }
        agentSubscription = agents.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshAgentResults() }
        }
    }

    func enablePendingExtension() {
        guard let request = pendingExtension else { return }
        pendingExtension = nil
        guard !extensionRunning else { notice = "An extension is already running."; return }
        do {
            try extensions.setEnabled(request.extensionItem, true)
            guard let enabled = extensions.extensions.first(where: { $0.id == request.extensionItem.id }) else { throw ExtensionManager.ExtensionError.changed }
            sections = [ResultSection(title: "Extensions", rows: [.extensionRun(enabled, input: request.input)])]
            runExtension(enabled, input: request.input)
        } catch { notice = error.localizedDescription }
    }
    private func runExtension(_ ext: InstalledExtension, input: String) {
        guard !extensionRunning else { return }
        extensionRunning = true
        let gen = generation
        notice = "Running \(ext.name)…"
        extensions.run(ext, input: input) { [weak self] result in
            guard let self else { return }
            self.extensionRunning = false
            guard gen == self.generation else { return }
            switch result {
            case .success(let output):
                self.notice = nil
                self.sections = [ResultSection(title: ext.name, rows: [.extensionResult(output)])]
            case .failure(let error): self.notice = "Extension failed: \(error.localizedDescription)"
            }
        }
    }
    func reset() {
        pendingExtension = nil
        showingACP = false
        actionTarget = nil
        showingAppMenu = false
        wifiJoin = nil
        actionFeedback = nil
        files.cancel()
        notesSearch?.cancel()
        // Changing the query already refreshes suggestions. Empty-query reopens still
        // refresh recency, which may have changed while the panel was hidden.
        if query.isEmpty { showSuggestions() }
        else { query = "" }
        selection = 0
    }

    /// Sees every typed query before calculator answers are built; the app uses it to fetch
    /// exchange rates the first time a currency conversion is typed. Fixtures leave it empty.
    var onCalculationQuery: (String) -> Void = { _ in }

    /// Redraws answers when exchange rates arrive for the query still being typed, keeping the
    /// selected row as same-query asynchronous updates do.
    /// Only the merged results are rebuilt: contacts and files already found for this query stay,
    /// and their searches are not restarted.
    func refreshForCurrencyRates() {
        guard isPresented, searchesAppIndex else { return }
        rebuildMergedResults()
    }

    func refreshForAppIndex() {
        rowState.clearIcons()
        guard isPresented, query.isEmpty || searchesAppIndex else { return }
        if query.isEmpty {
            let selectedID = selectedRow?.id
            showSuggestions()
            if let selectedID, let offset = rows.firstIndex(where: { $0.id == selectedID }) { selection = offset }
            else { selection = 0 }
        } else {
            rebuildMergedResults()
        }
    }

    /// Recomputes the synchronous sections for the current query and merges them with the
    /// asynchronous ones already delivered, keeping the selected row by identity.
    private func rebuildMergedResults() {
        immediate = mergedSections(for: query.trimmingCharacters(in: .whitespaces))
        if immediate.contains(where: { $0.title == "Calculator" }) { releaseHeldCalculation() }
        compose()
    }

    private func refreshShortcutResults() {
        guard showingAppleShortcuts || searchesAppIndex else { return }
        if showingAppleShortcuts {
            let selectedID = selectedRow?.id
            sections = [ResultSection(title: "Apple Shortcuts", rows: appleShortcuts.matches(query).map(ResultRow.appleShortcut))]
            notice = appleShortcuts.loading ? "Loading Apple Shortcuts…" : appleShortcuts.message
                ?? (rows.isEmpty ? "No matching shortcuts. Create one in the Shortcuts app, then refresh." : nil)
            if !rows.isEmpty { actionFeedback = notice }
            selection = selectedID.flatMap { id in rows.firstIndex { $0.id == id } } ?? 0
        } else {
            immediate.removeAll { $0.title == "Apple Shortcuts" }
            let matches = appleShortcuts.matches(query).prefix(6).map(ResultRow.appleShortcut)
            if !matches.isEmpty { immediate.append(ResultSection(title: "Apple Shortcuts", rows: matches)) }
            compose()
        }
    }

    private func showSuggestions() {
        let favorites = config.favoriteApps.compactMap { id in index.apps.first { $0.id == id } }.map(ResultRow.app)
        let apps = index.suggestions(usage: usage).filter { !config.favoriteApps.contains($0.id) }.map(ResultRow.app)
        sections = (favorites.isEmpty ? [] : [ResultSection(title: "Favorites", rows: favorites)]) + (apps.isEmpty ? [] : [ResultSection(title: "Suggestions", rows: apps)]) + [ResultSection(title: "Commands", rows: CoreCommand.allCases.map(ResultRow.core) + [.settings, .reloadConfig])]
    }

    var showingNotes: Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q == "notes" || q == "note" || q.hasPrefix("note ")
    }
    var searchRecoveryMessage: String? {
        if showingNotes { return notes.loadMessage }
        var messages: [String] = []
        if (query.isEmpty || searchesAppIndex) && index.unavailable {
            messages.append("Spotlight couldn’t start app discovery. Existing app results have been kept.")
        }
        if filesUnavailable { messages.append("Spotlight couldn’t start file search.") }
        return messages.isEmpty ? nil : messages.joined(separator: " ") + " Check Spotlight availability, then retry."
    }
    var searchRetryTitle: String { showingNotes ? "Retry Loading Notes" : "Retry Spotlight" }
    func retrySearch() {
        guard searchRecoveryMessage != nil else { return }
        if showingNotes { notes.reload() }
        else if index.unavailable { index.start() }
        let selected = selectedRow?.id
        refresh()
        if let selected, let offset = rows.firstIndex(where: { $0.id == selected }) { selection = offset }
    }
    private func receiveFiles(_ result: FileSearch.SearchResult, generation: Int, limit: Int) {
        deliver(generation) { model in
            switch result {
            case .success(let hits): model.fileRows = hits.prefix(limit).map(ResultRow.file); model.filesUnavailable = false
            case .failure: model.fileRows = []; model.filesUnavailable = true
            }
        }
    }

    var showingClipboard: Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q == "clip" || q.hasPrefix("clip ")
    }
    /// What the chat's @ picker offers: recent clipboard text and notes, snapshotted when chosen.
    /// A note with unsaved edits contributes the text on screen. Images and unreadable notes are
    /// left out of this first version. Notes match without scanning files (resident text, title or
    /// preview), and only the offered notes' text is read.
    func contextCandidates(_ query: String) -> [ChatAttachment] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = RelativeDateTimeFormatter()
        // Anything from the last minute reads as just now, including a copy stamped a moment ahead.
        let age: (Date) -> String = { date in
            Date().timeIntervalSince(date) < 60 ? "just now" : formatter.localizedString(for: date, relativeTo: Date())
        }
        let clips = clipboard.recent(limit: 16, matching: term).filter {
            $0.kind == .text && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (term.isEmpty || $0.text.localizedCaseInsensitiveContains(term))
        }.prefix(8).map { clip in
            let first = clip.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? clip.text
            return ChatAttachment(id: "clip:\(clip.id)", kind: .clipboard, title: String(first.trimmingCharacters(in: .whitespaces).prefix(60)),
                                  detail: "Clipboard · " + age(clip.copiedAt), text: clip.text)
        }
        let found = notes.search(term, limit: 16).filter { $0.readError == nil }.prefix(8).compactMap { note in
            notes.text(of: note.id).map { text in
                ChatAttachment(id: "note:" + note.id, kind: .note, title: note.title,
                               detail: "Note · edited " + age(note.modified), text: text)
            }
        }
        return Array(clips) + Array(found)
    }

    var clipboardMessage: String? { showingClipboard ? clipboard.state.message : nil }
    var clipboardRetrying: Bool { clipboard.state == .retrying }
    func retryClipboard() { guard showingClipboard else { return }; clipboard.retry() }
    private func refreshClipboardResults() {
        let selected = selectedRow?.id
        let q = query.trimmingCharacters(in: .whitespaces)
        let term = q.dropFirst(4).trimmingCharacters(in: .whitespaces)
        let clips = clipboard.recent(limit: 12, matching: term).map { ResultRow.clip($0) }
        sections = clips.isEmpty ? [] : [ResultSection(title: "Clipboard History", rows: clips)]
        notice = clipboard.state.message == nil ? (term.isEmpty ? "No clipboard history yet" : "No matching clipboard items") : nil
        if let selected, let index = rows.firstIndex(where: { $0.id == selected }) { selection = index }
        else { selection = 0 }
    }

    /// Contacts and files found for the previous query stay visible while their replacements are
    /// fetched, narrowed to rows that still match, so the bottom of the list does not empty and
    /// refill on every keystroke.
    private func refresh() {
        let wasMerged = searchesAppIndex
        let previousContacts = contactRows, previousFiles = fileRows
        let previousBranch = prefixBranch
        prefixBranch = nil
        var keepsCalculation = false
        defer {
            if !keepsCalculation { calculationAnchor = nil; releaseHeldCalculation() }
            if previousBranch == "clip" && prefixBranch != "clip" { clipboard.endSearchSession() }
        }
        searchesAppIndex = false
        selection = 0
        generation += 1
        let gen = generation
        immediate = []; contactRows = []; fileRows = []
        filesUnavailable = false
        notice = nil
        actionFeedback = nil
        wifiJoin = nil
        files.cancel()
        notesSearch?.cancel()
        notesSearch = nil
        let q = query.trimmingCharacters(in: .whitespaces)
        if !showingDictionary { dictionary.clear() }
        if showingAppleShortcuts {
            sections = []
            if searchesSecondarySources { appleShortcuts.refresh() }
            refreshShortcutResults()
            return
        }
        guard !q.isEmpty else { showSuggestions(); return }

        if let term = DictionaryQuery.term(query) { dictionary.input = term; sections = []; return }
        if showingTranslation { sections = []; return }
        if CaffeinateCommand.matches(q) { refreshCaffeinateResults(); return }
        if q.lowercased() == "emoji" {
            sections = []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.query.trimmingCharacters(in: .whitespaces).lowercased() == "emoji" else { return }
                self.query = ":"
            }
            return
        }
        if ["volant settings", "reload", "reload config", "reload configuration"].contains(q.lowercased()) {
            sections = [ResultSection(title: "Volant", rows: [q.lowercased().contains("reload") ? .reloadConfig : .settings])]
            return
        }
        let settingTerms = q.lowercased().split(whereSeparator: { $0.isWhitespace })
        if settingTerms.count > 1 && settingTerms.contains("settings") {
            let panes = SystemSettingsDestination.search(q).map { ResultRow.systemSettings($0) }
            if !panes.isEmpty {
                sections = [ResultSection(title: "System Settings", rows: panes)]
                return
            }
        }
        if q.lowercased() == "notes" { enterNotes(from: previousBranch); sections = [ResultSection(title: "Notes", rows: notes.search("").map { .note($0) } + [.newNote("")])]; return }
        if connectivitySource != nil { refreshConnectivity(); return }
        if AudioRouteQuery(q) != nil { refreshAudioRoutes(); return }
        if VolumeCommand.matches(q) {
            refreshVolumeResults()
            return
        }
        if showingACP { sections = []; return }
        if showingAgents {
            refreshAgentResults()
            return
        }
        if q.hasPrefix("/") {
            let term = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            sections = []
            files.search(term) { [weak self] result in self?.receiveFiles(result, generation: gen, limit: 8) }
            return
        }
        if q.hasPrefix("@") {
            let term = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            sections = []
            contacts.search(term, askIfNeeded: true) { [weak self] hits in
                self?.deliver(gen) { $0.cacheContactImages(hits); $0.contactRows = hits.map { .contact($0) } }
            }
            return
        }
        if q.lowercased() == "cal" || q.lowercased() == "today" || q.lowercased().hasPrefix("cal ") {
            sections = []
            agenda.upcoming { [weak self] outcome in
                self?.deliver(gen) { model in
                    switch outcome {
                    case .denied:
                        model.notice = "Calendar access is off. Enable it in System Settings, Privacy & Security, Calendars."
                        model.immediate = []
                    case .events(let events):
                        model.notice = events.isEmpty ? "Nothing scheduled through tomorrow." : nil
                        let today = events.filter { Calendar.current.isDateInToday($0.start) }
                        let tomorrow = events.filter { !Calendar.current.isDateInToday($0.start) }
                        model.immediate = []
                        if !today.isEmpty { model.immediate.append(ResultSection(title: "Today", rows: today.map { .event($0) })) }
                        if !tomorrow.isEmpty { model.immediate.append(ResultSection(title: "Tomorrow", rows: tomorrow.map { .event($0) })) }
                    }
                }
            }
            return
        }
        if q.hasPrefix(":") {
            let rows = emojiSearch(String(q.dropFirst())).map { ResultRow.emoji($0) }
            sections = rows.isEmpty ? [] : [ResultSection(title: "Emoji", rows: rows)]
            return
        }
        if q.lowercased() == "snip" || q.lowercased().hasPrefix("snip ") {
            let rows = SnippetExpander.search(config.snippets, q.dropFirst(4).trimmingCharacters(in: .whitespaces)).map { ResultRow.snippet($0) }
            notice = rows.isEmpty ? "No snippets. Add them under \"snippets\" in config.json." : nil
            sections = rows.isEmpty ? [] : [ResultSection(title: "Snippets", rows: rows)]
            return
        }
        if q.lowercased() == "ext" || q.lowercased().hasPrefix("ext ") {
            let rest = q.dropFirst(3).trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            let name = parts.first ?? ""
            let input = parts.count > 1 ? parts[1] : ""
            extensions.configURL = actionConfigURL
            if previousBranch == "ext" { extensions.loadIfNeeded() } else { extensions.reload() }
            prefixBranch = "ext"
            let rows = extensions.search(name).map { ResultRow.extensionRun($0, input: input) }
            notice = rows.isEmpty ? "No matching extensions. Manage extensions in Settings → Extensions." : nil
            sections = rows.isEmpty ? [] : [ResultSection(title: "Extensions", rows: rows)]
            return
        }
        if q.lowercased() == "note" || q.lowercased().hasPrefix("note ") {
            let term = q.dropFirst(4).trimmingCharacters(in: .whitespaces)
            enterNotes(from: previousBranch)
            showNotes(notes.search(term), term: term)
            notesSearch = notes.searchFiles(term) { [weak self] found in
                guard let self, gen == self.generation else { return }
                self.showNotes(found, term: term, preservingSelection: true)
            }
            return
        }
        if showingClipboard {
            prefixBranch = "clip"
            refreshClipboardResults()
            return
        }

        searchesAppIndex = true
        onCalculationQuery(q)
        immediate = mergedSections(for: q)
        keepsCalculation = holdCalculation(for: q)
        let letters = q.filter(\.isLetter).count
        let searchesContacts = searchesSecondarySources && letters >= 2 && q.count <= 40
        let searchesFiles = searchesSecondarySources && q.count >= 3
        if wasMerged {
            let needle = q.lowercased()
            if searchesContacts {
                contactRows = previousContacts.filter { if case .contact(let c) = $0 { return Self.contact(c, matches: needle) }; return false }
            }
            if searchesFiles {
                fileRows = previousFiles.filter { if case .file(let f) = $0 { return Self.file(f, matches: q) }; return false }
            }
        }
        compose(preservingSelection: false)
        if searchesSecondarySources && q.count >= 2 { appleShortcuts.refresh() }

        if searchesContacts {
            contacts.search(q, askIfNeeded: false) { [weak self] hits in
                let needle = q.lowercased()
                let tight = Array(hits.filter { Self.contact($0, matches: needle) }.prefix(3))
                self?.deliver(gen) { $0.cacheContactImages(tight); $0.contactRows = tight.map { .contact($0) } }
            }
        }
        if searchesFiles {
            files.search(q) { [weak self] result in self?.receiveFiles(result, generation: gen, limit: 5) }
        }
    }

    /// The default search's synchronous sections, in display order: alias, calculator, snippets,
    /// quicklinks, extensions, applications, System Settings panes, Volant commands and shortcuts.
    private func mergedSections(for q: String) -> [ResultSection] {
        var immediate: [ResultSection] = []
        let answers = CalculationAnswer.answers(for: q).enumerated().map { ResultRow.calculation($0.element, slot: $0.offset) }
        let builtins: [(String, ResultRow)] = [("Volant Settings", .settings), ("Reload Configuration", .reloadConfig)]
        let matchingCommands = CoreCommand.search(q).map(ResultRow.core) + builtins.filter { $0.0.localizedCaseInsensitiveContains(q) }.map { $0.1 }
        let words = q.split(separator: " ", maxSplits: 1).map(String.init)
        let head = words.first?.lowercased() ?? ""
        let tail = words.count > 1 ? words[1] : ""
        if let target = config.aliases[head] ?? config.aliases.sorted(by: { $0.key < $1.key }).first(where: { $0.key.lowercased() == head })?.value, words.count == 1, let app = index.resolveAlias(target) {
            immediate.append(ResultSection(title: "Alias", rows: [.app(app)]))
        }
        if !answers.isEmpty { immediate.append(ResultSection(title: "Calculator", rows: answers)) }
        let snips = config.snippets.filter { $0.keyword.lowercased() == q.lowercased() }.map { ResultRow.snippet($0) }
        if !snips.isEmpty { immediate.append(ResultSection(title: "Snippets", rows: snips)) }
        let links = QuicklinkResolver.search(config.quicklinks, head).map { ResultRow.quicklink($0, query: tail) }
        if !links.isEmpty { immediate.append(ResultSection(title: "Quicklinks", rows: links)) }
        extensions.configURL = actionConfigURL
        let extensionRows = extensions.commandMatches(q).map { ResultRow.extensionRun($0.extensionItem, input: $0.input) }
        if !extensionRows.isEmpty { immediate.append(ResultSection(title: "Extensions", rows: extensionRows)) }
        let aliased = Set(immediate.flatMap(\.rows).map(\.id))
        let apps = index.search(q, limit: 6, usage: usage).map { ResultRow.app($0) }.filter { !aliased.contains($0.id) }
        if !apps.isEmpty { immediate.append(ResultSection(title: "Applications", rows: apps)) }
        let actions = SystemAction.search(q).map(ResultRow.systemAction)
        if !actions.isEmpty { immediate.append(ResultSection(title: "System", rows: actions)) }
        let panes = SystemSettingsDestination.search(q).map { ResultRow.systemSettings($0) }
        if !panes.isEmpty { immediate.append(ResultSection(title: "System Settings", rows: panes)) }
        if !matchingCommands.isEmpty { immediate.append(ResultSection(title: "Volant", rows: matchingCommands)) }
        let shortcuts = appleShortcuts.matches(q).prefix(6).map(ResultRow.appleShortcut)
        if !shortcuts.isEmpty { immediate.append(ResultSection(title: "Apple Shortcuts", rows: shortcuts)) }
        return immediate
    }

    /// Records the answer when the query has one; otherwise keeps the last answer visible while the
    /// query is still an edit of the one that produced it, for at most the hold duration. Returns
    /// whether calculator state should survive this refresh.
    private func holdCalculation(for q: String) -> Bool {
        if let section = immediate.first(where: { $0.title == "Calculator" }), case .calculation(let answer, _)? = section.rows.first {
            calculationAnchor = (q, answer)
            releaseHeldCalculation()
            return true
        }
        guard let anchor = calculationAnchor, q.hasPrefix(anchor.query) || anchor.query.hasPrefix(q) else { return false }
        if heldCalculation == nil {
            heldCalculation = anchor.answer
            let expiry = DispatchWorkItem { [weak self] in
                self?.calculationAnchor = nil
                self?.releaseHeldCalculation()
            }
            holdExpiry = expiry
            DispatchQueue.main.asyncAfter(deadline: .now() + calculationHoldDuration, execute: expiry)
        }
        return true
    }

    private func releaseHeldCalculation() {
        holdExpiry?.cancel()
        holdExpiry = nil
        if heldCalculation != nil { heldCalculation = nil }
    }

    /// Reads the notes folder when the notes source is entered, not on every keystroke inside it.
    /// Edits made in Volant update the store directly, so typing never needs a fresh read.
    private func enterNotes(from previousBranch: String?) {
        if previousBranch != "notes" { notes.reload() }
        prefixBranch = "notes"
    }

    /// A contact shown for a typed name: some word of the name, or the whole name, starts with it.
    static func contact(_ contact: ContactEntry, matches needle: String) -> Bool {
        let name = contact.name.lowercased()
        return name.hasPrefix(needle) || name.split(separator: " ").contains { $0.hasPrefix(needle) }
    }

    /// A file kept from the previous query while its replacement search runs: its name still
    /// contains the query, as Spotlight's case- and diacritic-insensitive name search requires.
    static func file(_ file: FileEntry, matches term: String) -> Bool {
        file.url.lastPathComponent.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Dictation goes to the clipboard rather than into whatever app was focused. Typing into
    /// another app needs the Accessibility grant Volant deliberately does not request, so the
    /// transcript is copied and the paste stays the owner's keystroke.
    func toggleDictation(stopHint: String = "press Return to stop") {
        if dictation.isListening { finishDictation(); return }
        let availability = SpeechDictation.availability
        guard availability.isReady else {
            actionFeedback = availability.reason
            return
        }
        actionFeedback = "Listening… \(stopHint), or Escape to cancel."
        dictation.start { [weak self] _ in
            guard let self, case .failed(let reason) = self.dictation.phase else { return }
            self.actionFeedback = reason
        }
    }

    /// Escape discards what was heard rather than copying it, so the microphone can always be
    /// stopped without touching the clipboard. Once transcription has begun it runs to the end.
    func cancelDictation() {
        guard dictation.isListening else { return }
        dictation.cancel()
        actionFeedback = "Dictation cancelled."
    }

    func finishDictation() {
        guard dictation.isListening else { return }
        actionFeedback = "Transcribing…"
        dictation.stop { [weak self] transcript in
            guard let self else { return }
            guard let transcript else {
                if case .failed(let reason) = self.dictation.phase { self.actionFeedback = reason }
                else { self.actionFeedback = "Nothing was heard." }
                return
            }
            self.copy(transcript)
            self.actionFeedback = "Copied \(transcript.count) characters. Press Command-V to paste."
        }
    }

    /// Row images are built once per result set. Building an NSImage inside a row body rebuilds it
    /// on every redraw, which is the cost issue #33 describes for application icons. Called only
    /// for the current generation, so a late reply for an old query cannot replace thumbnails.
    private func cacheContactImages(_ entries: [ContactEntry]) {
        var images: [String: NSImage] = [:]
        for entry in entries {
            if let data = entry.thumbnail, let image = NSImage(data: data) { images[entry.id] = image }
        }
        rowState.contactImages = images
    }

    private func deliver(_ gen: Int, _ apply: (LauncherModel) -> Void) {
        guard gen == generation else { return }
        apply(self)
        compose()
    }

    /// Shows the `note` prefix results: matches found at once, then the full-text matches for the same query,
    /// which keep the selected row by identity.
    private func showNotes(_ found: [Note], term: String, preservingSelection: Bool = false) {
        let selectedID = preservingSelection ? selectedRow?.id : nil
        var rows = found.map { ResultRow.note($0) }
        if !term.isEmpty { rows.append(.newNote(term)) }
        sections = rows.isEmpty ? [] : [ResultSection(title: term.isEmpty ? "Recent Notes" : "Notes", rows: rows)]
        if let selectedID, let index = self.rows.firstIndex(where: { $0.id == selectedID }) { selection = index }
        else if preservingSelection { selection = 0 }
    }

    /// Keeps the selected row by identity when async sections arrive above it.
    private func compose(preservingSelection: Bool = true) {
        let selectedID = preservingSelection ? selectedRow?.id : nil
        var out = immediate
        if !contactRows.isEmpty { out.append(ResultSection(title: "Contacts", rows: contactRows)) }
        if !fileRows.isEmpty { out.append(ResultSection(title: "Files", rows: fileRows)) }
        sections = Self.promoting(usage.choice(forQuery: query.trimmingCharacters(in: .whitespaces)), in: out)
        if let selectedID, let i = rows.firstIndex(where: { $0.id == selectedID }) { selection = i }
        else { selection = 0 }
    }

    /// What was chosen last time for exactly this query comes first: its row leads its section
    /// and that section leads the results. Apps already did this inside their own section; this
    /// extends it to commands, system actions, settings panes and everything else that records use.
    static func promoting(_ id: String?, in sections: [ResultSection]) -> [ResultSection] {
        guard let id, let index = sections.firstIndex(where: { $0.rows.contains { $0.id == id } }) else { return sections }
        let rows = sections[index].rows
        let promoted = rows.filter { $0.id == id } + rows.filter { $0.id != id }
        var result = sections
        result.remove(at: index)
        result.insert(ResultSection(title: sections[index].title, rows: promoted), at: 0)
        return result
    }

    private var connectivitySource: String? {
        let head = query.lowercased().split(whereSeparator: \.isWhitespace).first ?? ""
        if head == "wifi" || head == "wi-fi" { return "wifi" }
        if head == "bluetooth" || head == "bt" { return "bluetooth" }
        return nil
    }
    private func refreshConnectivity(force: Bool = false) {
        guard let source = connectivitySource else { return }
        let gen = generation
        let selectedID = force ? selectedRow?.id : nil
        let term = query.split(whereSeparator: \.isWhitespace).dropFirst().joined(separator: " ")
        sections = []; notice = "Loading…"
        connectivity.load(source, refresh: force) { [weak self] snapshot in
            guard let self, self.generation == gen else { return }
            let items = snapshot.items.filter { item in
                switch item {
                case .settings, .refresh: return true
                default: return term.isEmpty || item.title.localizedCaseInsensitiveContains(term)
                }
            }
            self.sections = [ResultSection(title: source == "wifi" ? "Wi-Fi Networks" : "Connected Bluetooth Devices", rows: items.map(ResultRow.connectivity))]
            if let selectedID, let index = self.rows.firstIndex(where: { $0.id == selectedID }) { self.selection = index }
            else { self.selection = 0 }
            self.actionFeedback = snapshot.items.isEmpty ? nil : snapshot.message
            self.notice = snapshot.message
        }
    }
    func joinWiFi(_ network: WiFiChoice, password: String?, useSaved: Bool) {
        guard !connectivityBusy else { return }
        connectivityBusy = true
        let gen = generation
        connectivity.join(network, password: password, useSaved: useSaved) { [weak self] error in
            guard let self else { return }
            self.connectivityBusy = false
            guard gen == self.generation else { return }
            if let error { self.actionFeedback = error }
            else {
                self.wifiJoin = nil
                self.refreshConnectivity(force: true)
                self.actionFeedback = "Connected to " + network.name
                self.searchFocusRequest = UUID()
            }
        }
    }

    private func refreshAudioRoutes() {
        guard let search = AudioRouteQuery(query) else { return }
        do {
            let routes = try audioRouting.routes().filter { search.directions.contains($0.direction) && (search.term.isEmpty || $0.name.localizedCaseInsensitiveContains(search.term)) }
            sections = search.directions.map { direction in
                ResultSection(title: direction.title, rows: routes.filter { $0.direction == direction }.map(ResultRow.audioRoute))
            }
            notice = routes.isEmpty ? "No matching audio devices. Connect the device and search again." : nil
        } catch { sections = []; notice = error.localizedDescription }
    }

    private func refreshVolumeResults() {
        do {
            let state = try volumeControl.state()
            let commands = VolumeCommand.parse(query, muted: state.muted)
            let volumeRows = commands.map { command -> ResultRow in
                let supported = (command == .mute || command == .unmute) ? state.canSetMute : state.canSetVolume
                let detail = supported ? (command == .up ? "+5%" : command == .down ? "−5%" : "") : "Hardware control only"
                return .volume(command, detail: detail)
            }
            sections = [ResultSection(title: "Volume · " + state.summary, rows: volumeRows)]
            notice = commands.isEmpty ? "Try volume up, volume down, mute, unmute, or volume 40%." : nil
        } catch {
            sections = []
            notice = error.localizedDescription
        }
    }

    private func refreshCaffeinateResults() {
        let selectedID = selectedRow?.id
        var commands = CaffeinateCommand.parse(query, keepsDisplayAwake: config.caffeinateKeepsDisplayAwake)
        if caffeinate.isActive { commands = [.off] }
        sections = [ResultSection(title: "Caffeinate", rows: commands.map(ResultRow.caffeinate))]
        notice = commands.isEmpty ? "Try caffeinate 30m, caffeinate 1h system, or caffeinate off (up to 24 hours)." : nil
        if let selectedID, let index = rows.firstIndex(where: { $0.id == selectedID }) { selection = index }
        else { selection = 0 }
    }

    func moveEmojiSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(0, selection + delta), rows.count - 1)
    }

    func moveSelection(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    var copyText: (String) -> Void = { text in
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func copy(_ text: String) { copyText(text) }

    /// Clicks resolve the visible row's stable identity against the current results.
    /// A stale row must never fall back to index zero or launch a different app.
    func activate(rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        selection = index
        activateSelection()
    }

    func activateSelection() {
        guard let row = selectedRow else { return }
        switch row {
        case .appleShortcut, .connectivity, .audioRoute, .volume, .extensionResult, .newNote, .calculation: break
        default: usage.record(key: row.id, query: query)
        }
        switch row {
        case .appleShortcut(let shortcut): shortcutRunQuery = query; appleShortcuts.run(shortcut); return
        case .systemAction(let action): onNote(.systemAction(action)); return
        case .core(let command):
            if command == .ai { presentAIChat() }
            else if command == .talk { toggleDictation() }
            else if command == .confetti { onNote(.confetti); dismiss(); return }
            else { query = command.query }
            return
        case .caffeinate(let command):
            let succeeded = caffeinate.perform(command)
            refreshCaffeinateResults()
            actionFeedback = succeeded ? nil : caffeinate.error
            return
        case .connectivity(let item):
            switch item {
            case .settings(let source): ConnectivityService.openSettings(source)
            case .refresh: refreshConnectivity(force: true)
            case .bluetooth: ConnectivityService.openSettings("bluetooth")
            case .wifi(let network):
                guard !connectivityBusy else { return }
                if network.current { refreshConnectivity(force: true) }
                else if network.security == "Managed / Other" { ConnectivityService.openSettings("wifi") }
                else if network.security == "Open" { joinWiFi(network, password: nil, useSaved: false) }
                else { wifiJoin = network; actionFeedback = nil }
            }
            return
        case .audioRoute(let route):
            do {
                try audioRouting.select(route)
                refreshAudioRoutes()
                if let index = rows.firstIndex(where: { $0.id == row.id }) { selection = index }
                else { selection = 0 }
                actionFeedback = route.direction.title + ": " + route.name
            } catch { actionFeedback = error.localizedDescription }
            return
        case .volume(let command, _):
            do {
                let state = try volumeControl.perform(command)
                refreshVolumeResults()
                if let index = rows.firstIndex(where: { $0.id == row.id }) { selection = index }
                else { selection = 0 }
                actionFeedback = state.summary
            } catch { actionFeedback = error.localizedDescription }
            return
        case .systemSettings(let pane):
            guard NSWorkspace.shared.open(pane.url) else {
                actionFeedback = "Couldn’t open " + pane.title + " in System Settings."
                return
            }
            dismiss(); return
        case .settings: dismiss(); onNote(.settings); return
        case .reloadConfig: dismiss(); onNote(.reloadConfig); return
        case .agentSession(let session): agents.focus(session); return
        case .agents: query = "agents"; return
        case .calculation(let answer, _): copy(answer.copyText)
        case .clip(let clip):
            if clip.kind == .image, let data = clip.imageData {
                let pb = NSPasteboard.general; pb.clearContents(); pb.setData(data, forType: .png)
            } else { copy(clip.text) }
        case .app(let app): index.launch(app)
        case .file(let file): FileSearch.open(file)
        case .herdrMachine(let machine, let enabled, let busy):
            guard let machine, !busy else { return }
            agents.setMachineEnabled(machine, !enabled)
            return
        case .contact(let contact): if let field = contact.primaryField { copy(field.value) }
        case .event(let event): CalendarAgenda.open(event)
        case .note(let note): onNote(.open(note.id))
        case .newNote(let text): onNote(.create(text + "\n"))
        case .extensionRun(let ext, let input):
            guard !extensionRunning else { notice = "An extension is already running."; return }
            if extensions.isBlocked(ext) { dismiss(); onNote(.extensionSettings); return }
            if !ext.enabled { pendingExtension = ExtensionPermissionRequest(extensionItem: ext, input: input) }
            else { runExtension(ext, input: input) }
            return
        case .extensionResult(let text): copy(text)
        case .snippet(let snippet): copy(SnippetExpander.expand(snippet.body))
        case .emoji(let e): copy(e.symbol)
        case .quicklink(let link, let query):
            if QuicklinkResolver.needsQuery(link) && query.isEmpty { self.query = link.name + " "; return }
            guard let url = QuicklinkResolver.url(for: link, query: query) else {
                notice = "This quicklink URL is invalid or unsupported. Check it in config.json."
                generation += 1
                files.cancel()
                sections = []
                return
            }
            guard QuicklinkResolver.open(url) else {
                notice = "Could not open this quicklink. Check that its app is installed."
                generation += 1
                files.cancel()
                sections = []
                return
            }
        }
        dismiss()
    }

    var canTabToAIChat: Bool {
        !showingACP && !showingDictionary && !showingTranslation && !showingEmoji &&
        !showingAppleShortcuts && !showingAgents && wifiJoin == nil && actionTarget == nil
    }

    func chatFromSearch() {
        guard canTabToAIChat else { return }
        if acp.draft.isEmpty { acp.draft = query }
        presentAIChat()
    }

    func presentAIChat() {
        query = "ai"
        showingACP = true
        sections = []
        searchFocusRequest = UUID()
    }
    func openAIChat() { onNote(.ai) }
    func openSettings() { dismiss(); onNote(.settings) }
    func openAISettings() { dismiss(); onNote(.aiSettings) }

    func toggleActions() {
        guard let selectedRow, selectedRow.supportsActions else { return }
        showingAppMenu = false
        actionTarget = actionTarget == nil ? selectedRow : nil
    }

    /// Opens or closes the Volant menu; it replaces any open item actions so only one popover shows.
    func toggleAppMenu() {
        actionTarget = nil
        showingAppMenu.toggle()
    }

    /// Runs a Volant menu item. Links open in the browser and app commands go to the app delegate;
    /// both hide the launcher first, as every other command that leaves it does.
    func performMenuItem(_ item: LauncherMenuItem) {
        showingAppMenu = false
        switch item {
        case .feedback: dismiss(); openURL(LauncherMenuItem.feedbackURL())
        case .manual: dismiss(); openURL(LauncherMenuItem.manualURL)
        case .changelog: dismiss(); openURL(LauncherMenuItem.changelogURL)
        case .updates: dismiss(); onNote(.checkForUpdates)
        case .about: dismiss(); onNote(.about)
        case .settings: openSettings()
        case .quit: onNote(.quit)
        }
    }

    func performAction(_ action: LauncherItemAction, target snapshot: ResultRow) {
        // A menu snapshot never authorizes a different or removed result.
        guard let target = selectedRow, target.id == snapshot.id, rows.contains(where: { $0.id == target.id }),
              let url = target.actionURL else { actionTarget = nil; return }
        if case .app(let app) = target, !index.apps.contains(where: { $0.id == app.id }) { actionTarget = nil; return }
        actionTarget = nil
        switch action {
        case .open: activate(rowID: target.id)
        case .reveal: activateSecondary()
        case .contents:
            guard case .app = target else { return }
            if NSWorkspace.shared.open(url.appendingPathComponent("Contents", isDirectory: true)) { dismiss() }
            else { actionFeedback = "Could not open package contents." }
        case .copyPath: copyText(url.path); actionFeedback = "Path copied."
        case .copyName: copyText(target.actionTitle); actionFeedback = "Name copied."
        case .copyBundleID:
            guard case .app = target, let identifier = Bundle(url: url)?.bundleIdentifier else { actionFeedback = "Bundle identifier unavailable."; return }
            copyText(identifier); actionFeedback = "Bundle identifier copied."
        case .configure:
            if case .app(let app) = target { editApp(app) }
        case .favorite:
            guard case .app(let app) = target else { return }
            do {
                config = try Preferences.updateFavorite(app.id, expected: config.favoriteApps.contains(app.id), at: actionConfigURL)
                refresh()
                actionFeedback = config.favoriteApps.contains(app.id) ? "Added to Favorites." : "Removed from Favorites."
            } catch { actionFeedback = "Could not save Favorites. Reload configuration and try again." }
        case .resetRanking:
            if usage.resetRanking(for: target.id) { refresh(); actionFeedback = "Learned ranking reset." }
            else { actionFeedback = "Could not reset ranking. Try again." }
        }
        searchFocusRequest = UUID()
    }

    func editApp(_ app: AppEntry) {
        guard index.apps.contains(where: { $0.id == app.id }) else { return }
        dismiss()
        onNote(.editApp(app))
    }

    /// Shift-Command-Return on a conversion: run it the other way, with the answer as the input.
    func activateSwap() {
        guard case .calculation(let answer, _)? = selectedRow, let swap = answer.swapQuery else { return }
        query = swap
        searchFocusRequest = UUID()
    }

    /// Command-Return: reveal, copy the other field, or for a calculation put its answer in the
    /// search field and stay open, so the next calculation can build on it.
    func activateSecondary() {
        guard let row = selectedRow else { return }
        switch row {
        case .calculation(let answer, _):
            query = answer.copyText
            searchFocusRequest = UUID()
            return
        case .file(let file): FileSearch.reveal(file)
        case .app(let app): NSWorkspace.shared.activateFileViewerSelecting([app.url])
        case .contact(let contact): if let field = contact.secondaryField { copy(field.value) }
        default: activateSelection(); return
        }
        dismiss()
    }
}
