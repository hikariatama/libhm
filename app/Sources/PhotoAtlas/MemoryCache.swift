import Foundation

/// Values are immutable once inserted. Access and the charged memory budget are synchronized.
final class MemoryCache<Value>: @unchecked Sendable {
    private struct Entry { let value: Value; let cost: Int; var used: UInt64 }
    private var entries: [String: Entry] = [:]
    private var cost = 0
    private var clock: UInt64 = 0
    private let limit: Int
    private let lock = NSLock()
    init(limit: Int) { self.limit = max(0, limit) }
    var chargedBytes: Int { lock.lock(); defer { lock.unlock() }; return cost }

    func value(for key: String) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = entries[key] else { return nil }
        clock &+= 1; entry.used = clock; entries[key] = entry
        return entry.value
    }
    func insert(_ value: Value, for key: String, cost newCost: Int) {
        lock.lock(); defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) { cost -= old.cost }
        guard newCost >= 0, newCost <= limit else { return }
        while cost + newCost > limit, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            cost -= entries.removeValue(forKey: oldest)!.cost
        }
        clock &+= 1; entries[key] = Entry(value: value, cost: newCost, used: clock); cost += newCost
    }
    func removeAll() { lock.lock(); entries.removeAll(); cost = 0; lock.unlock() }
}
