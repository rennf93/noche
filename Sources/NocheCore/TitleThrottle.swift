import Foundation

/// A minimum interval between title writes of one tab (ruling M38): a page that changes its title every second writes at most once per
/// interval, and the last title is written when the interval ends (the caller schedules the flush and reads the tab's title then).
public struct TitleThrottle: Sendable {
    public enum Action: Equatable, Sendable { case writeNow, later(Date), pending }
    public let interval: TimeInterval
    private var last: [Int: Date] = [:]
    private var scheduled: Set<Int> = []

    public init(interval: TimeInterval) { self.interval = interval }

    /// A new title for |id| is there: write it now, schedule a flush at the returned date, or note that a flush is already scheduled.
    public mutating func offer(_ id: Int, now: Date) -> Action {
        if scheduled.contains(id) { return .pending }
        guard let l = last[id], now.timeIntervalSince(l) < interval else { last[id] = now; return .writeNow }
        scheduled.insert(id)
        return .later(l.addingTimeInterval(interval))
    }

    /// The scheduled flush ran and wrote.
    public mutating func flushed(_ id: Int, now: Date) { scheduled.remove(id); last[id] = now }

    public mutating func forget(_ id: Int) { scheduled.remove(id); last[id] = nil }
}
