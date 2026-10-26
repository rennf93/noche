import Foundation

/// A minimum interval between title writes of one tab (ruling M38): a page that changes its title every second writes at most once per
/// interval, and the last title is written when the interval ends. A title that has to wait is held with the address it was seen at, so a
/// later flush (the timer, a navigation, a tab close, the quit) writes that pair and never reads the tab again.
public struct TitleThrottle: Sendable {
    public struct Pending: Equatable, Sendable {
        public let url: String
        public let title: String
        public init(url: String, title: String) { self.url = url; self.title = title }
    }
    public enum Action: Equatable, Sendable { case writeNow, later(Date), pending }
    public let interval: TimeInterval
    private var last: [Int: Date] = [:]
    private var held: [Int: (pending: Pending, due: Date)] = [:]

    public init(interval: TimeInterval) { self.interval = interval }

    /// A new title for |id| is there: write it now, or hold it (the caller arms a timer for the returned date; a pair already held is replaced and
    /// keeps its timer).
    public mutating func offer(_ id: Int, url: String, title: String, now: Date) -> Action {
        let pair = Pending(url: url, title: title)
        if let h = held[id] { held[id] = (pair, h.due); return .pending }
        guard let l = last[id], now.timeIntervalSince(l) < interval else { last[id] = now; return .writeNow }
        let due = l.addingTimeInterval(interval)
        held[id] = (pair, due)
        return .later(due)
    }

    public func peek(_ id: Int) -> Pending? { held[id]?.pending }

    /// Takes the held pair (it is written by the caller, which restarts the interval). |onlyIfDue| is the timer: a timer armed for a pair that an earlier
    /// flush already took finds nothing, or a newer pair that is not due yet, and writes nothing.
    public mutating func take(_ id: Int, now: Date, onlyIfDue: Bool) -> Pending? {
        guard let h = held[id], !onlyIfDue || h.due <= now else { return nil }
        held[id] = nil
        last[id] = now
        return h.pending
    }

    /// Every held pair, for the quit.
    public mutating func drain(now: Date) -> [(id: Int, pending: Pending)] {
        let all = held.map { (id: $0.key, pending: $0.value.pending) }.sorted { $0.id < $1.id }
        for e in all { last[e.id] = now }
        held = [:]
        return all
    }

    public mutating func forget(_ id: Int) { held[id] = nil; last[id] = nil }
}
