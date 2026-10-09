import Foundation
import XCTest

@testable import VolantCore

/// The helper's conversation count: a fixed number of slots, never exceeded and never negative.
final class ACPConversationSlotsTests: XCTestCase {
    func testAcquiresUpToTheLimitAndRefusesBeyondIt() {
        let slots = ACPConversationSlots(limit: 3)
        XCTAssertTrue(slots.acquire())
        XCTAssertTrue(slots.acquire())
        XCTAssertTrue(slots.acquire())
        XCTAssertFalse(slots.acquire())
        XCTAssertEqual(slots.inUse, 3)
    }

    func testReleaseFreesExactlyOneSlot() {
        let slots = ACPConversationSlots(limit: 2)
        XCTAssertTrue(slots.acquire())
        XCTAssertTrue(slots.acquire())
        slots.release()
        XCTAssertEqual(slots.inUse, 1)
        XCTAssertTrue(slots.acquire())
        XCTAssertFalse(slots.acquire())
    }

    func testExtraReleasesNeverGoBelowZero() {
        let slots = ACPConversationSlots(limit: 1)
        slots.release()
        XCTAssertEqual(slots.inUse, 0)
        XCTAssertTrue(slots.acquire())
        slots.release()
        slots.release()
        XCTAssertEqual(slots.inUse, 0)
        XCTAssertTrue(slots.acquire())
        XCTAssertFalse(slots.acquire(), "an extra release must not create a second slot")
    }

    func testConcurrentAcquireAndReleaseNeverExceedTheLimit() {
        let slots = ACPConversationSlots(limit: 3)
        let holders = Holders()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            guard slots.acquire() else { return }
            holders.enter()
            holders.leave()
            slots.release()
        }
        XCTAssertLessThanOrEqual(holders.peak, 3)
        XCTAssertGreaterThan(holders.peak, 0)
        XCTAssertEqual(slots.inUse, 0)
    }

    func testTheHelperSharesOneCountAtTheLiveLimit() {
        XCTAssertEqual(ACPConversationLimit.live, 6)
        XCTAssertEqual(ACPConversationSlots.shared.limit, ACPConversationLimit.live)
    }
}

/// Counts callers holding a slot at the same moment, and the most there ever were.
private final class Holders {
    private let lock = NSLock()
    private var now = 0
    private var most = 0

    func enter() {
        lock.lock(); defer { lock.unlock() }
        now += 1
        most = max(most, now)
    }

    func leave() {
        lock.lock(); defer { lock.unlock() }
        now -= 1
    }

    var peak: Int {
        lock.lock(); defer { lock.unlock() }
        return most
    }
}
