// Opt-in profiling fixture: real production models, fictional data, no normal app startup.
import AppKit
import CryptoKit
import Darwin
import Synchronization
import VolantCore

func memory() -> (UInt64, UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(status == KERN_SUCCESS)
    return (info.phys_footprint, info.resident_size)
}
final class Sampler {
    private let queue = DispatchQueue(label: "volant.memory.sample")
    private var timer: DispatchSourceTimer?
    private var peak: UInt64 = 0
    func start() {
        peak = memory().0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.peak = max(self?.peak ?? 0, memory().0) }
        self.timer = timer; timer.resume()
    }
    func stop() -> UInt64 {
        queue.sync { timer?.cancel(); timer = nil; peak = max(peak, memory().0) }
        return peak
    }
}
let allocatedBytes = Atomic<UInt64>(0)
let allocationCount = Atomic<UInt64>(0)
let countingAllocations = Atomic<Bool>(true)
typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
/// Counts every allocation and reallocation through libmalloc's logging hook. It must not allocate.
/// Allocation type 2 carries the size in arg2; a reallocation (types 2 and 4) carries it in arg3.
let mallocLogger: MallocLogger = { type, _, size, reallocated, _, _ in
    guard type & 2 != 0, countingAllocations.load(ordering: .relaxed) else { return }
    allocatedBytes.add(UInt64(type & 4 != 0 ? reallocated : size), ordering: .relaxed)
    allocationCount.add(1, ordering: .relaxed)
}
let environment = ProcessInfo.processInfo.environment
/// Installs the counter unless MallocStackLogging is on: it uses the same hook for the stacks
/// malloc_history reads, so a stack-logging run reports no allocation counts.
func countAllocations() {
    guard environment["MallocStackLogging"] == nil else { return }
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")!.assumingMemoryBound(to: Optional<MallocLogger>.self).pointee = mallocLogger
}
countAllocations()
/// Runs work whose allocations belong to the fixture rather than the measured path.
func uncounted<T>(_ body: () throws -> T) rethrows -> T {
    countingAllocations.store(false, ordering: .relaxed)
    defer { countingAllocations.store(true, ordering: .relaxed) }
    return try body()
}
let scenario = CommandLine.arguments.dropFirst().first ?? "idle"
let inspectionDirectory = environment["VOLANT_MEMORY_INSPECT"].map { URL(fileURLWithPath: $0) }
let inspectedPhases = Set((environment["VOLANT_MEMORY_INSPECT_PHASES"] ?? "after_relief").split(separator: ",").map(String.init))
/// Runs vmmap and heap, and malloc_history when stack logging is on, against this fixture process
/// only, after the phases named in VOLANT_MEMORY_INSPECT_PHASES. Object contents are never printed.
func inspect(_ name: String) {
    guard let inspectionDirectory, inspectedPhases.contains(name) else { return }
    var tools = [("vmmap", ["-summary"]), ("heap", ["-s", "-q"])]
    if environment["MallocStackLogging"] != nil { tools.append(("malloc_history", ["-q", "-allBySize"])) }
    uncounted {
        for (tool, arguments) in tools {
            let output = inspectionDirectory.appendingPathComponent("\(scenario)-\(name)-\(tool).txt")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/" + tool)
            process.arguments = arguments + [String(getpid())]
            process.standardOutput = try! FileHandle(forWritingTo: output)
            process.standardError = FileHandle.nullDevice
            try! process.run()
            process.waitUntilExit()
        }
    }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("volant-memory-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
setbuf(stdout, nil)
print("scenario,phase,footprint_bytes,rss_bytes,sampled_peak_bytes,heap_in_use_bytes,elapsed_ms,units,allocated_bytes,allocations")
/// Measures one phase inside its own autorelease pool. Allocated bytes and counts are the total
/// churn during the phase, including memory freed again before it ends.
func phase(_ name: String, units: Int = 0, _ body: () throws -> Void) rethrows {
    let sampler = Sampler(); sampler.start()
    let start = ProcessInfo.processInfo.systemUptime
    let bytesBefore = allocatedBytes.load(ordering: .relaxed), countBefore = allocationCount.load(ordering: .relaxed)
    try autoreleasepool { try body() }
    let bytes = allocatedBytes.load(ordering: .relaxed) - bytesBefore, count = allocationCount.load(ordering: .relaxed) - countBefore
    let peak = sampler.stop(), current = memory()
    var heap = malloc_statistics_t()
    malloc_zone_statistics(nil, &heap)
    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
    print("\(scenario),\(name),\(current.0),\(current.1),\(max(peak, current.0)),\(heap.size_in_use),\(String(format: "%.3f", elapsed)),\(units),\(bytes),\(count)")
    inspect(name)
}
/// Complete notes search: the immediate matches, then the background file scan, waited for on the main run loop.
func searchAll(_ store: NotesStore, _ term: String) -> [Note] {
    var result: [Note]?
    guard store.searchFiles(term, limit: Int.max, completion: { result = $0 }) != nil else { return store.search(term, limit: Int.max) }
    while result == nil { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    return result!
}
func settle(_ name: String) { phase(name) { Thread.sleep(forTimeInterval: 0.3) } }
func clipboard(_ name: String = "clips") -> ClipboardStore {
    ClipboardStore(retention: 100, storageURL: root.appendingPathComponent(name + ".sqlite"), encryptionKey: SymmetricKey(size: .bits256))
}
func imageData(side: Int, seed: UInt64, noisy: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32)!
    var state = seed + 1
    for offset in stride(from: 0, to: side * side * 4, by: 4) {
        state = state &* 6364136223846793005 &+ 1
        for channel in 0..<3 { rep.bitmapData![offset + channel] = noisy ? UInt8(truncatingIfNeeded: state >> (channel * 8 + 24)) : UInt8(truncatingIfNeeded: seed * 17) }
        rep.bitmapData![offset + 3] = 255
    }
    let data = rep.representation(using: .png, properties: [:])!
    precondition(data.count <= 8_000_000)
    return data
}
phase("baseline") {}
autoreleasepool {
switch scenario {
case "idle", "emoji":
    var model: LauncherModel?
    phase("model_loaded") {
        model = LauncherModel(index: AppIndex(entries: []), clipboard: clipboard(), notes: NotesStore(directory: root.appendingPathComponent("notes")), config: Preferences(), usage: UsageStore(url: root.appendingPathComponent("usage.sqlite"))) { _ in }
        model!.searchesSecondarySources = false
        model!.reset()
    }
    if scenario == "emoji" {
        precondition(EmojiIndex.all.count > 1000, "Bundled catalog required")
        for batch in 1...4 {
            phase("cycles_\(batch * 25)", units: 25) {
                for _ in 0..<25 {
                    autoreleasepool {
                        for query in [":", ":cat", ":heart", ":missing-fixture", ":"] {
                            model!.query = query
                            for _ in 0..<20 { model!.moveEmojiSelection(1) }
                        }
                        model!.reset()
                    }
                }
            }
        }
    } else { phase("idle_3s") { Thread.sleep(forTimeInterval: 3) } }
    model = nil; settle("released")
case "clipboard", "image-decode":
    var store: ClipboardStore? = clipboard()
    let count = scenario == "clipboard" ? 12 : 3
    phase("seed_images", units: count) {
        for index in 0..<count {
            autoreleasepool {
                store!.recordImage(imageData(side: scenario == "clipboard" ? 1400 : 4096, seed: UInt64(index), noisy: scenario == "clipboard"))
                _ = store!.recent(limit: 1) // Drain async writes without accumulating queued payloads.
            }
        }
        store!.record("fictional searchable text")
        _ = store!.recent(limit: 1)
    }
    settle("seed_settled")
    var rows: [ClipEntry] = []
    phase("rows_loaded", units: count) { rows = store!.recent(limit: 12) }
    if scenario == "image-decode" {
        var decoded: [CGImage] = []
        phase("decoded_full_size", units: count) {
            for row in rows {
                guard let data = row.imageData, let image = NSImage(data: data), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                decoded.append(context.makeImage()!)
            }
        }
        withExtendedLifetime(decoded) { settle("decoded_retained") }
        decoded = []
    }
    rows = []; settle("rows_released")
    for batch in 1...3 {
        phase("text_queries_\(batch * 10)", units: 10) {
            for _ in 0..<10 { autoreleasepool { precondition(store!.recent(limit: 12, matching: "searchable").count == 1) } }
        }
    }
    store = nil; settle("released")
case "notes", "notes-small":
    let count = scenario == "notes" ? 1000 : 300
    phase("seed_notebook", units: count) {
        let body = String(repeating: "Fictional profiling text for note search.\n", count: scenario == "notes" ? 1600 : 100)
        for index in 0..<count { try! ("# Fixture \(index)\n" + body).write(to: root.appendingPathComponent("\(index).md"), atomically: false, encoding: .utf8) }
    }
    var store: NotesStore?
    phase("notebook_loaded", units: count) { store = NotesStore(directory: root); precondition(store!.notes.count == count) }
    for batch in 1...3 {
        phase("reload_\(batch)", units: count) { store!.reload(); precondition(store!.search("profiling").count == 8) }
    }
    let typed = "absent fixture phrase"
    phase("main_thread_keystrokes_10", units: 10) {
        for length in 12...21 { autoreleasepool { precondition(store!.search(String(typed.prefix(length))).isEmpty) } }
    }
    phase("search_absent_3", units: count) {
        for _ in 0..<3 { autoreleasepool { precondition(searchAll(store!, "absent fixture phrase").isEmpty) } }
    }
    store = nil; settle("released")
case "acp":
    var state = ACPState()
    phase("transcript_loaded", units: 1800) {
        state.messages = (0..<1800).map { ACPMessage(role: "assistant", text: "Fixture \($0): " + String(repeating: "x", count: 480)) }
    }
    var latest: ACPState?
    for batch in 1...4 {
        phase("snapshots_\(batch * 100)", units: 100) {
            for _ in 0..<100 { autoreleasepool {
                let data = try! JSONEncoder().encode(state)
                let next = try! JSONDecoder().decode(ACPState.self, from: data)
                if latest != next { latest = next }
            } }
        }
    }
    latest = nil; state.messages = []; settle("released")
case "acp-poll-small", "acp-poll-200k", "acp-poll-1m":
    let turns = ["acp-poll-small": 3, "acp-poll-200k": 40, "acp-poll-1m": 190][scenario]!
    var poll: ACPPollFixture! = ACPPollFixture()
    phase("transcript_built", units: turns) { poll.build(turns: turns) }
    phase("first_read") { poll.round(legacy: true) }
    uncounted { FileHandle.standardError.write(Data("\(scenario): \(poll.describe())\n".utf8)) }
    let full = uncounted { try! JSONEncoder().encode(poll.acp.queue.sync { poll.acp.state }) }
    phase("helper_encode_40", units: 40) {
        for _ in 0..<40 { autoreleasepool { _ = poll.acp.queue.sync { try! JSONEncoder().encode(poll.acp.state) } } }
    }
    phase("app_decode_40", units: 40) {
        for _ in 0..<40 { autoreleasepool { precondition(poll.model.receive(full, revision: -1, after: -1) == .applied) } }
    }
    phase("full_idle_40", units: 40) { for _ in 0..<40 { poll.round(legacy: true) } }
    poll.startTurn()
    phase("full_streaming_40", units: 40) { for _ in 0..<40 { poll.stream(); poll.round(legacy: true) } }
    poll.endTurn()
    uncounted { poll.round(legacy: false) }
    phase("revision_idle_40", units: 40) { for _ in 0..<40 { poll.round(legacy: false) } }
    precondition(poll.unchanged == 40, "idle revision polls skip the snapshot")
    poll.startTurn()
    phase("revision_streaming_40", units: 40) { for _ in 0..<40 { poll.stream(); poll.round(legacy: false) } }
    poll.endTurn()
    uncounted { poll.round(legacy: false) }
    precondition(poll.model.state == poll.acp.queue.sync { poll.acp.state }, "app state matches helper")
    poll.close(); poll = nil; settle("released")
default: fatalError("Unknown scenario")
}

}
settle("pool_drained")

// Diagnostic only: distinguish releasable allocator pages from live allocations.
// This is not a proposed production "purge memory" strategy.
phase("allocator_relief") { _ = malloc_zone_pressure_relief(nil, 0) }
settle("after_relief")
