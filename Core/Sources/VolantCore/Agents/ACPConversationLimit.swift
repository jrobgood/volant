import Foundation

/// How many ACP conversations Volant runs at once. Each one is its own agent process with its own
/// provider usage, and the app polls each one for its transcript, so the number has a fixed cap.
public enum ACPConversationLimit {
    /// Counted in the agent helper across every connection the app opens, and checked again in the
    /// app before it asks for another.
    public static let live = 6
}

/// The conversation slots of one helper process, shared by every connection in it. A connection
/// takes a slot before it resolves or launches an agent and returns it when the conversation
/// stops, so the count holds however connections start, fail or are invalidated.
public final class ACPConversationSlots {
    public static let shared = ACPConversationSlots(limit: ACPConversationLimit.live)

    public let limit: Int
    private let lock = NSLock()
    private var used = 0

    public init(limit: Int) {
        self.limit = limit
    }

    /// Takes a slot, or returns false when every slot is in use.
    public func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard used < limit else { return false }
        used += 1
        return true
    }

    /// Returns one slot. A release without a matching acquire never takes the count below zero.
    public func release() {
        lock.lock(); defer { lock.unlock() }
        used = max(0, used - 1)
    }

    /// Slots taken and not yet returned.
    public var inUse: Int {
        lock.lock(); defer { lock.unlock() }
        return used
    }
}
