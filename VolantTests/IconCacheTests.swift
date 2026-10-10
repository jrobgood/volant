import AppKit
import XCTest
@testable import Volant

final class IconCacheTests: XCTestCase {
    /// Repeated redraws of the same rows reach the fetcher once per path, and a cache lookup alone
    /// never fetches.
    func testRepeatedRendersFetchEachPathOnce() {
        var fetched: [String] = []
        let cache = IconCache(fetch: { path in
            fetched.append(path)
            return NSImage(size: NSSize(width: 16, height: 16))
        })
        let paths = ["/System/Applications/Calculator.app", "/System/Applications/Chess.app", "/System/Applications/TextEdit.app"]
        XCTAssertNil(cache.cachedIcon(forFile: paths[0]))
        var first: [NSImage] = []
        for render in 0..<10 {
            let images = paths.map { cache.icon(forFile: $0) }
            if render == 0 { first = images } else { XCTAssertTrue(zip(images, first).allSatisfy { $0 === $1 }) }
        }
        XCTAssertEqual(fetched, paths)
        XCTAssertTrue(cache.cachedIcon(forFile: paths[1]) === first[1])
        XCTAssertEqual(fetched.count, paths.count)
    }

    /// Clearing after an app index change advances the generation views observe and fetches a
    /// replacement icon on the next request.
    func testClearAdvancesGenerationAndRefetches() {
        var fetches = 0
        let cache = IconCache(fetch: { _ in
            fetches += 1
            return NSImage(size: NSSize(width: 16, height: 16))
        })
        let path = "/System/Applications/Calculator.app"
        let before = cache.icon(forFile: path)
        XCTAssertEqual(cache.generation, 0)
        cache.clear()
        XCTAssertEqual(cache.generation, 1)
        XCTAssertNil(cache.cachedIcon(forFile: path))
        XCTAssertFalse(cache.icon(forFile: path) === before)
        XCTAssertEqual(fetches, 2)
    }

    /// Launcher rows share the cache Settings rows read, so clearing launcher icons also
    /// invalidates the icons Settings shows.
    func testLauncherRowStateUsesAndClearsSharedCache() {
        var fetches = 0
        let cache = IconCache(fetch: { _ in
            fetches += 1
            return NSImage(size: NSSize(width: 16, height: 16))
        })
        let state = LauncherRowState(icons: cache)
        let path = "/System/Applications/Chess.app"
        let icon = state.icon(forFile: path)
        XCTAssertTrue(cache.cachedIcon(forFile: path) === icon)
        _ = state.icon(forFile: path)
        XCTAssertEqual(fetches, 1)
        state.clearIcons()
        XCTAssertEqual(cache.generation, 1)
        XCTAssertNil(cache.cachedIcon(forFile: path))
    }

    /// The real fetcher returns an icon for a standard system application.
    func testDefaultFetcherReturnsSystemApplicationIcon() {
        let cache = IconCache()
        let icon = cache.icon(forFile: "/System/Applications/Calculator.app")
        XCTAssertGreaterThan(icon.size.width, 0)
        XCTAssertTrue(cache.cachedIcon(forFile: "/System/Applications/Calculator.app") === icon)
    }
}
