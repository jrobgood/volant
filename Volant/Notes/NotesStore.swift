import Foundation
import Combine
import VolantCore

/// A file's modification date and byte size when it was last read, used to reuse unchanged notes.
struct NoteStamp: Hashable {
    let modified: Date
    let size: Int
}

/// One Markdown file. Listed notes keep only their title, preview and stamp; `text` is resident
/// only for the open note and unsaved edits, and is nil for unreadable files.
struct Note: Identifiable, Hashable {
    static let previewLimit = 200
    let id: String
    var url: URL
    private(set) var text: String?
    var modified: Date
    var readError: String?
    var stamp: NoteStamp?
    private var heading = ""
    private var snippet = ""

    init(id: String, url: URL, text: String?, modified: Date, readError: String? = nil, stamp: NoteStamp? = nil) {
        self.id = id
        self.url = url
        self.modified = modified
        self.readError = readError
        self.stamp = stamp
        if let text { load(text) }
    }

    var title: String { readError != nil ? url.lastPathComponent : heading.isEmpty ? "Untitled" : heading }

    var preview: String { readError ?? snippet }

    /// Makes the full text resident and refreshes the title and preview derived from it.
    mutating func load(_ text: String) {
        self.text = text
        (heading, snippet) = Self.summary(of: text)
    }

    /// Releases the full text while keeping the title and preview for listing.
    mutating func unload() {
        text = nil
    }

    /// Whether the stored title or preview contains the term. Both are cut from lines of the text, so this is a
    /// provisional full-text match shown at once; the background scan confirms it.
    func summaryContains(_ term: String) -> Bool {
        readError == nil && (heading.localizedCaseInsensitiveContains(term) || snippet.localizedCaseInsensitiveContains(term))
    }

    /// Title from the first non-empty line without heading markers (empty when there is none), preview from the
    /// second. Scans only as far as those two lines; the preview is capped because rows show one line.
    static func summary(of text: String) -> (heading: String, snippet: String) {
        var lines: [String] = []
        var rest = text[...]
        while lines.count < 2, !rest.isEmpty {
            let end = rest.firstIndex(of: "\n") ?? rest.endIndex
            let line = rest[..<end].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { lines.append(line) }
            rest = end == rest.endIndex ? rest[end...] : rest[rest.index(after: end)...]
        }
        let cleaned = (lines.first ?? "").drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        return (String(cleaned.prefix(80)), lines.count > 1 ? String(lines[1].prefix(previewLimit)) : "")
    }
}

/// Cancellation handle for one background notes search; a cancelled search never delivers results.
final class NotesSearchTask {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }

    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Plain Markdown files in a folder, one per note. Writes go through one serial queue; reload never
/// discards an edit that has not reached disk yet. Only the open note and dirty notes keep their full
/// text in memory; reload reuses notes whose modification date and size are unchanged. Search answers
/// at once from what is resident and reads other files on a background queue, one at a time.
final class NotesStore: ObservableObject {
    static let unreadableMessage = "This note couldn’t be read as UTF-8 Markdown. Check the file’s access and encoding, then retry."
    @Published private(set) var notes: [Note] = [] { didSet { generation += 1 } }
    /// Changes whenever the list changes, so a background search started on an older list is redone.
    private(set) var generation = 0
    @Published var lastError: String? = nil
    @Published private(set) var saveErrors: [String: String] = [:]
    @Published private(set) var loadError: String?
    var loadMessage: String? {
        if let loadError { return loadError }
        let count = notes.filter { $0.readError != nil }.count
        return count == 0 ? nil : "\(count) unreadable note\(count == 1 ? "" : "s"). Files and pins have been kept."
    }
    let directory: URL
    private let io = DispatchQueue(label: "com.mysticcoders.volant.notes", qos: .utility)
    private var pendingSave: [String: DispatchWorkItem] = [:]
    @Published private(set) var dirtyText: [String: String] = [:]
    private(set) var openID: String?
    private let searchQueue = DispatchQueue(label: "com.mysticcoders.volant.notes.search", qos: .userInitiated)
    private let searchReader: (URL) -> String?
    private var scanned: [String: [String: (stamp: NoteStamp, matched: Bool)]] = [:]
    private var scannedTerms: [String] = []
    private static let rememberedTerms = 4
    private static let stampKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]

    /// `searchReader` reads files for background search only; tests inject a slow or gated reader.
    init(directory: URL? = nil, searchReader: @escaping (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }) {
        self.searchReader = searchReader
        self.directory = directory ?? Preferences.supportDirectory.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        reload()
    }

    /// Re-reads the folder. Notes with unsaved edits keep their in-memory text; the disk copy never wins over a pending edit.
    /// Clean notes whose modification date and size match the last read are reused without reading the file; unreadable
    /// notes are always read again so Retry can restore them.
    func reload() {
        let fm = FileManager.default
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(Self.stampKeys), options: [.skipsHiddenFiles])
            loadError = nil
        } catch {
            loadError = "The notes folder couldn’t be read. Existing notes and unsaved edits have been kept. Check folder access, then retry."
            return
        }
        let previous = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var fresh = urls
            .filter { $0.pathExtension == "md" }
            .map { url -> Note in
                let id = url.lastPathComponent
                if let dirty = dirtyText[id] {
                    return Note(id: id, url: url, text: dirty, modified: Date())
                }
                let stamp = Self.stamp(of: url)
                if var known = previous[id], known.readError == nil, let stamp, known.stamp == stamp {
                    known.url = url
                    if id != openID { known.unload() }
                    return known
                }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    return Note(id: id, url: url, text: nil, modified: previous[id]?.modified ?? .distantPast, readError: Self.unreadableMessage)
                }
                var note = Note(id: id, url: url, text: text, modified: stamp?.modified ?? .distantPast, stamp: stamp)
                if id != openID { note.unload() }
                return note
            }
        let known = Set(fresh.map(\.id))
        for note in notes where dirtyText[note.id] != nil && !known.contains(note.id) { fresh.append(note) }
        notes = fresh.sorted { $0.modified > $1.modified }
    }

    /// Reads a file's modification date and size; taken before reading so a later change is never masked.
    private static func stamp(of url: URL) -> NoteStamp? {
        guard let values = try? url.resourceValues(forKeys: stampKeys),
              let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
        return NoteStamp(modified: modified, size: size)
    }

    /// Makes one note's full text resident for editing and releases the previously open clean note. A file that can
    /// no longer be read becomes the read-only placeholder instead of an empty editor.
    func open(_ id: String?) {
        openID = id
        var updated = notes
        var changed = false
        for index in updated.indices where updated[index].text != nil && updated[index].id != id && dirtyText[updated[index].id] == nil {
            updated[index].unload()
            changed = true
        }
        if let id, let index = updated.firstIndex(where: { $0.id == id }), updated[index].readError == nil, updated[index].text == nil {
            var url = updated[index].url
            url.removeAllCachedResourceValues()
            let stamp = Self.stamp(of: url)
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                updated[index].load(text)
                updated[index].stamp = stamp
            } else {
                updated[index].readError = Self.unreadableMessage
            }
            changed = true
        }
        if changed { notes = updated }
    }

    /// Full Markdown for a note: resident text when loaded, otherwise read from disk without retaining it.
    func text(of id: String) -> String? {
        guard let note = notes.first(where: { $0.id == id }), note.readError == nil else { return nil }
        return dirtyText[id] ?? note.text ?? searchReader(note.url)
    }

    /// Filenames are unique by construction: a date prefix for humans, a UUID suffix for safety.
    @discardableResult
    func create(initialText: String = "") -> Note {
        let day = Date().formatted(.iso8601.year().month().day())
        var url = directory.appendingPathComponent("\(day)-\(UUID().uuidString.prefix(8)).md")
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(day)-\(UUID().uuidString.prefix(8)).md")
        }
        do {
            try initialText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            dirtyText[url.lastPathComponent] = initialText
            saveErrors[url.lastPathComponent] = "Could not create note: \(error.localizedDescription)"
        }
        let note = Note(id: url.lastPathComponent, url: url, text: initialText, modified: Date())
        notes.insert(note, at: 0)
        return note
    }

    func update(_ id: String, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].readError == nil else { return }
        notes[i].load(text)
        notes[i].modified = Date()
        notes[i].stamp = nil
        dirtyText[id] = text
        let url = notes[i].url
        pendingSave[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let error = self.write(text, to: url)
            DispatchQueue.main.async { self.didWrite(text, id: id, error: error) }
        }
        pendingSave[id] = work
        io.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func write(_ text: String, to url: URL) -> String? {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "Could not save note: \(error.localizedDescription)"
        }
    }

    /// Clears dirty state once the latest text reached disk; a saved note that is not open releases its text.
    private func didWrite(_ text: String, id: String, error: String?) {
        guard dirtyText[id] == text, let i = notes.firstIndex(where: { $0.id == id }) else { return }
        if let error { saveErrors[id] = error; return }
        dirtyText[id] = nil
        saveErrors[id] = nil
        if id != openID { notes[i].unload() }
    }

    /// Retries every dirty note, including failed creation, and completes state updates before returning.
    func flush() {
        pendingSave.values.forEach { $0.cancel() }
        pendingSave.removeAll()
        io.sync {}
        for (id, text) in dirtyText {
            guard let url = notes.first(where: { $0.id == id })?.url else { continue }
            let error = io.sync { write(text, to: url) }
            didWrite(text, id: id, error: error)
        }
    }

    func delete(_ id: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].readError == nil else { return }
        // Drain writes before trashing so a queued save cannot recreate the deleted file.
        flush()
        guard dirtyText[id] == nil else { return }
        let url = notes[i].url
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            notes.remove(at: i)
            lastError = nil
        } catch {
            lastError = "Could not move note to Trash: \(error.localizedDescription)"
        }
    }

    /// Notes matching the term, in list order, up to the limit, without reading any file. Resident text, unreadable
    /// filenames and remembered scan results are exact; other notes match provisionally by title or preview until
    /// `searchFiles` reads them.
    func search(_ term: String, limit: Int = 8) -> [Note] {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return Array(notes.prefix(limit)) }
        var found: [Note] = []
        for note in notes {
            guard found.count < limit else { break }
            if knownMatch(note, t) ?? note.summaryContains(t) { found.append(note) }
        }
        return found
    }

    /// Completes `search` by reading the files whose match is unknown on a background queue, in list order, until
    /// `limit` matches are certain. Delivers the final list on the main queue only if the returned task was not
    /// cancelled; if the list changed meanwhile, the search is redone against the new list. Returns nil, and delivers
    /// nothing, when no file needs reading, since `search` is already final.
    @discardableResult
    func searchFiles(_ term: String, limit: Int = 8, completion: @escaping ([Note]) -> Void) -> NotesSearchTask? {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, notes.contains(where: { knownMatch($0, t) == nil }) else { return nil }
        let task = NotesSearchTask()
        scan(t, limit: limit, task: task, completion: completion)
        return task
    }

    /// Reads the undecided files for one search off the main queue and delivers the exact list if still wanted.
    private func scan(_ t: String, limit: Int, task: NotesSearchTask, completion: @escaping ([Note]) -> Void) {
        let plan = notes.map { note -> (id: String, url: URL, stamp: NoteStamp?, known: Bool?) in
            (note.id, note.url, note.stamp, knownMatch(note, t))
        }
        guard plan.contains(where: { $0.known == nil }) else { completion(search(t, limit: limit)); return }
        let generation = generation, read = searchReader
        searchQueue.async { [weak self] in
            var results: [String: (stamp: NoteStamp?, matched: Bool)] = [:]
            var matches = 0
            for entry in plan {
                if matches >= limit || task.isCancelled { break }
                if let known = entry.known {
                    if known { matches += 1 }
                    continue
                }
                let matched = autoreleasepool { read(entry.url)?.localizedCaseInsensitiveContains(t) ?? false }
                results[entry.id] = (entry.stamp, matched)
                if matched { matches += 1 }
            }
            DispatchQueue.main.async {
                guard let self, !task.isCancelled else { return }
                guard self.generation == generation else {
                    self.scan(t, limit: limit, task: task, completion: completion)
                    return
                }
                self.remember(results, for: t)
                var found: [Note] = []
                for note in self.notes {
                    guard found.count < limit else { break }
                    if self.knownMatch(note, t) ?? results[note.id]?.matched ?? false { found.append(note) }
                }
                completion(found)
            }
        }
    }

    /// An exact match decided without reading a file, or nil when the file must be read.
    private func knownMatch(_ note: Note, _ term: String) -> Bool? {
        if note.readError != nil { return note.id.localizedCaseInsensitiveContains(term) }
        if let text = note.text { return text.localizedCaseInsensitiveContains(term) }
        if let stamp = note.stamp, let cached = scanned[term]?[note.id], cached.stamp == stamp { return cached.matched }
        return nil
    }

    /// Keeps scan results per file for the few most recent terms while each file's stamp is unchanged, so repeated
    /// renders of one query do not reread the notebook. Only booleans are kept, never text.
    private func remember(_ results: [String: (stamp: NoteStamp?, matched: Bool)], for term: String) {
        scannedTerms.removeAll { $0 == term }
        scannedTerms.append(term)
        while scannedTerms.count > Self.rememberedTerms { scanned[scannedTerms.removeFirst()] = nil }
        for (id, result) in results {
            if let stamp = result.stamp { scanned[term, default: [:]][id] = (stamp, result.matched) }
        }
    }
}
