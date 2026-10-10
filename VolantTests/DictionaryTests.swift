import XCTest
import CoreServices
import VolantCore
@testable import Volant

@MainActor final class DictionaryTests: XCTestCase {
    private func settle(_ model: DictionaryModel) async throws {
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.busy)
    }

    func testCommandAndUnicodeRanges() {
        XCTAssertEqual(DictionaryQuery.term(" DEFINE  New York \n"), "New York")
        XCTAssertEqual(DictionaryQuery.term("define"), "")
        XCTAssertNil(DictionaryQuery.term("defined"))
        XCTAssertTrue(LauncherRouting.isReserved("define New York"))
        let text = "😀 café 日本語"
        XCTAssertEqual(DictionaryQuery.string(in: text, range: CFRange(location: 3, length: 4)), "café")
        XCTAssertEqual(DictionaryQuery.string(in: text, range: CFRange(location: 8, length: 3)), "日本語")
        for range in [CFRange(location: -1, length: 1), CFRange(location: 1, length: 1), CFRange(location: 0, length: Int.max), CFRange(location: Int.max, length: 1)] {
            XCTAssertNil(DictionaryQuery.string(in: text, range: range))
        }
        let term = "café / ?#% 日本語"
        XCTAssertEqual(DictionaryQuery.url(for: term)?.absoluteString.removingPercentEncoding, "dict://" + term)
        XCTAssertNil(DictionaryQuery.url(for: " "))
        XCTAssertNil(DictionaryQuery.url(for: String(repeating: "x", count: 257)))
    }

    func testCandidateRangesKeepPhrasesAndDropOnlySurroundingPunctuation() {
        func pairs(_ ranges: [CFRange]) -> [[Int]] { ranges.map { [$0.location, $0.length] } }
        var offsets: [CFIndex] = []
        let detect: (CFRange) -> (CFIndex) -> CFRange = { range in { offsets.append($0); return range } }
        XCTAssertEqual(pairs(DictionaryQuery.candidateRanges(in: "zorbles", detect: detect(CFRange(location: 0, length: 7)))), [[0, 7]])
        XCTAssertEqual(pairs(DictionaryQuery.candidateRanges(in: "zorbles.", detect: detect(CFRange(location: 0, length: 7)))), [[0, 8], [0, 7]])
        XCTAssertEqual(pairs(DictionaryQuery.candidateRanges(in: "\u{201C}zorbles\u{201D}", detect: detect(CFRange(location: 1, length: 7)))), [[0, 9], [1, 7]])
        XCTAssertEqual(offsets, [0, 0, 1])
        XCTAssertEqual(pairs(DictionaryQuery.candidateRanges(in: "red zorblax", detect: detect(CFRange(location: 0, length: 3)))), [[0, 11]])
        XCTAssertEqual(pairs(DictionaryQuery.candidateRanges(in: "zorbles!", detect: detect(CFRange(location: kCFNotFound, length: 0)))), [[0, 8]])
        XCTAssertEqual(pairs(DictionaryQuery.candidateRanges(in: "😀 zorb", detect: detect(CFRange(location: 3, length: 4)))), [[0, 7], [3, 4]])
        XCTAssertEqual(pairs(DictionaryQuery.candidateRanges(in: "😀 zorb", detect: detect(CFRange(location: 1, length: 6)))), [[0, 7]])
        XCTAssertEqual(pairs(DictionaryQuery.candidateRanges(in: "zorb", detect: detect(CFRange(location: 0, length: 9)))), [[0, 4]])
        XCTAssertEqual(DictionaryQuery.candidateRanges(in: "", detect: detect(CFRange(location: 0, length: 0))).count, 0)
    }

    /// Exercises the real Dictionary Services range path. Skips when the host has no active English dictionary.
    func testNativeLookupNormalizesInflectionsAndKeepsPhrases() async throws {
        let lookup = NativeDictionaryLookup()
        guard try await lookup.lookup("cat") != nil else { throw XCTSkip("No active English dictionary on this host") }
        for term in ["cats", "geese", "went", "happier", "cats.", "\u{201C}geese\u{201D}", "New York"] {
            let entry = try await lookup.lookup(term)
            XCTAssertNotNil(entry, term)
            XCTAssertEqual(entry?.term, term)
        }
        let phrase = try await lookup.lookup("red zorblaxian")
        XCTAssertNil(phrase, "A phrase must not be reduced to its first word")
    }

    func testCopyMissingFailureRetryAndClear() async throws {
        let model = DictionaryModel(); model.debounce = .zero
        model.lookup = { DictionaryEntry(term: $0, definition: "Fictional definition") }
        var copies: [String] = []
        model.copy { copies.append($0) }
        model.input = "  phrase  "
        try await settle(model)
        XCTAssertEqual(model.entry?.term, "phrase")
        XCTAssertTrue(copies.isEmpty)
        model.copy { copies.append($0) }
        XCTAssertEqual(copies, ["Fictional definition"])
        XCTAssertEqual(model.message, "Definition copied")
        model.lookup = { _ in nil }; model.input = "missing"
        try await settle(model)
        XCTAssertTrue(model.searched); XCTAssertNil(model.entry); XCTAssertFalse(model.failed)
        model.lookup = { _ in throw CocoaError(.fileReadUnknown) }; model.search(immediate: true)
        try await settle(model)
        XCTAssertTrue(model.failed); XCTAssertNotNil(model.message)
        model.lookup = { DictionaryEntry(term: $0, definition: "Recovered") }; model.search(immediate: true)
        try await settle(model)
        XCTAssertEqual(model.entry?.definition, "Recovered"); XCTAssertFalse(model.failed)
        model.input = String(repeating: "x", count: 257)
        XCTAssertFalse(model.canLookup); XCTAssertNil(model.entry)
        model.clear()
        XCTAssertTrue(model.input.isEmpty); XCTAssertFalse(model.searched); XCTAssertNil(model.message)
    }

    func testStaleCompletionAndClearCannotRestoreText() async throws {
        let model = DictionaryModel(); model.debounce = .zero
        var pending: CheckedContinuation<DictionaryEntry?, Error>?
        model.lookup = { term in
            if term == "old" { return try await withCheckedThrowingContinuation { pending = $0 } }
            return DictionaryEntry(term: term, definition: "Current")
        }
        for clear in [false, true] {
            model.input = "old"
            for _ in 0..<100 where pending == nil { try await Task.sleep(for: .milliseconds(5)) }
            let continuation = try XCTUnwrap(pending); pending = nil
            if clear { model.clear() } else { model.input = "new"; try await settle(model) }
            continuation.resume(returning: DictionaryEntry(term: "old", definition: "Stale"))
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(model.entry?.term, clear ? nil : "new")
            XCTAssertEqual(model.input, clear ? "" : "new")
        }
    }

    func testOpenIsExplicitAndFailureCanRetry() async throws {
        let model = DictionaryModel(); model.debounce = .zero; model.lookup = { _ in nil }
        var opened: [String] = []
        model.openApplication = { opened.append($0); throw CocoaError(.fileNoSuchFile) }
        model.input = "New York"; try await settle(model)
        XCTAssertTrue(opened.isEmpty)
        model.open()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(opened, ["New York"]); XCTAssertNotNil(model.message)
        model.openApplication = { opened.append($0) }
        model.open()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(model.message)
        model.clear(); model.open()
        XCTAssertEqual(opened.count, 2)
    }
}
