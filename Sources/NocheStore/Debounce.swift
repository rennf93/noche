import Foundation

/// Pure coalescing logic for store writes: due once events go quiet for |delay|, or |cap| after the first pending event.
public struct Debouncer {
    private let delay: TimeInterval
    private let cap: TimeInterval
    private let now: () -> Date
    private var first: Date?
    private var last: Date?

    public init(delay: TimeInterval = 0.25, cap: TimeInterval = 2, now: @escaping () -> Date) {
        self.delay = delay
        self.cap = cap
        self.now = now
    }

    public mutating func event() {
        let t = now()
        if first == nil { first = t }
        last = t
    }

    public func due() -> Bool {
        guard let first, let last else { return false }
        let t = now()
        return t.timeIntervalSince(last) >= delay || t.timeIntervalSince(first) >= cap
    }

    public mutating func fired() { first = nil; last = nil }
}
