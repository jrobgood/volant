import AppKit

struct Measurement {
    let fetches: Int
    let firstMs: Double
    let laterMedianMs: Double
}

/// Draws an icon into a 40-pixel bitmap, forcing the image representation a 20-point row shows
/// on a 2x display.
func draw(_ image: NSImage) {
    var rect = NSRect(x: 0, y: 0, width: 20, height: 20)
    let hints: [NSImageRep.HintKey: Any] = [.ctm: NSAffineTransform(transform: AffineTransform(scale: 2))]
    _ = image.cgImage(forProposedRect: &rect, context: nil, hints: hints)
}

/// Times `renders` redraws of a list showing every path's icon, counting calls that reach
/// NSWorkspace. The first redraw is reported apart from the median of the later ones.
func measure(paths: [String], renders: Int, icon: (String) -> NSImage, fetches: () -> Int) -> Measurement {
    var times: [Double] = []
    for _ in 0..<renders {
        let start = DispatchTime.now().uptimeNanoseconds
        for path in paths { draw(icon(path)) }
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    let later = times.dropFirst().sorted()
    return Measurement(fetches: fetches(), firstMs: times[0], laterMedianMs: later[later.count / 2])
}

/// Compares the icon work an application list redraw costs before and after IconCache.
/// "uncached" repeats what a Settings row body did before: one NSWorkspace lookup per row on every
/// redraw. "cached" goes through IconCache, so only the first redraw reaches NSWorkspace. Paths are
/// the standard /System/Applications bundles, so no owner data is read. Each mode runs in its own
/// process so the cached run does not inherit LaunchServices state warmed by the uncached one.
func run() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let mode = arguments.first, ["uncached", "cached"].contains(mode) else {
        FileHandle.standardError.write(Data("Usage: measure uncached|cached [renders]\n".utf8))
        exit(2)
    }
    let renders = max(2, Int(arguments.dropFirst().first ?? "") ?? 20)
    let root = URL(fileURLWithPath: "/System/Applications")
    let paths = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        .filter { $0.hasSuffix(".app") }.sorted().map { root.appendingPathComponent($0).path }
    guard !paths.isEmpty else {
        FileHandle.standardError.write(Data("No applications in /System/Applications.\n".utf8))
        exit(1)
    }
    var fetches = 0
    let fetch = { (path: String) -> NSImage in
        fetches += 1
        return NSWorkspace.shared.icon(forFile: path)
    }
    let cache = IconCache(fetch: fetch)
    let result = measure(paths: paths, renders: renders, icon: mode == "cached" ? { cache.icon(forFile: $0) } : fetch, fetches: { fetches })
    print(String(format: "%@ rows=%d renders=%d fetches=%d first_render_ms=%.2f later_render_median_ms=%.3f",
        mode, paths.count, renders, result.fetches, result.firstMs, result.laterMedianMs))
}

run()
