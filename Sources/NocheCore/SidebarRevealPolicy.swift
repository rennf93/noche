import Foundation

/// When the hidden sidebar slides in over the page and when it slides out again (M1.6 Task 8, spec row 107). Pure: the caller passes the clock and the
/// pointer, asks again at |deadline| (a pointer at rest sends no event), and does the sliding itself.
public struct SidebarRevealPolicy {
    public enum Action: Equatable { case none, reveal, hide }
    /// The strip at the window's left edge (x 0 up to |strip|), how long the pointer rests in it, the sidebar's width, the margin around it that still
    /// counts as "on the sidebar", how long the pointer is away before it hides, and how often a held-back state is asked again (a menu, a drag, a button).
    public var strip: Double = 6, dwell: TimeInterval = 0.150, sidebarWidth: Double = 197, margin: Double = 8, hideDelay: TimeInterval = 0.400
    public static let recheck: TimeInterval = 0.25
    public private(set) var revealed = false
    private var enteredAt: TimeInterval?, leftAt: TimeInterval?, lastNow: TimeInterval = 0, waiting = false, editBlocked = false
    public init() {}

    /// |x| is the pointer in window points (nil: outside the window). |held|: a menu is open, a drag runs, a button is down; it neither reveals nor hides and
    /// restarts both timers. |editing|: the page has a text field focused; it blocks the reveal at the end of the dwell, never the hide.
    public mutating func update(now: TimeInterval, x: Double?, held: Bool, editing: Bool) -> Action {
        lastNow = now
        let inStrip = x.map { $0 >= 0 && $0 < strip } ?? false
        let onSidebar = x.map { $0 >= 0 && $0 < sidebarWidth + margin } ?? false
        waiting = false; editBlocked = false
        if held { enteredAt = nil; leftAt = nil; waiting = revealed || inStrip; return .none }
        if revealed {
            if onSidebar { leftAt = nil; return .none }
            let since = leftAt ?? now
            leftAt = since
            if now >= since + hideDelay { revealed = false; leftAt = nil; return .hide }
            return .none
        }
        guard inStrip else { enteredAt = nil; return .none }
        let since = enteredAt ?? now
        enteredAt = since
        if now >= since + dwell { if editing { editBlocked = true; return .none }; revealed = true; enteredAt = nil; return .reveal }
        return .none
    }

    /// The next time `update` must run for a change that needs no pointer event, nil when only an event can change anything.
    public var deadline: TimeInterval? {
        if waiting { return lastNow + Self.recheck }
        if editBlocked { return nil }
        if revealed { return leftAt.map { $0 + hideDelay } }
        return enteredAt.map { $0 + dwell }
    }

    /// The sidebar is permanent now (Cmd+S or the toggle while revealed): nothing is pending.
    public mutating func end() { revealed = false; enteredAt = nil; leftAt = nil; waiting = false; editBlocked = false }
}
