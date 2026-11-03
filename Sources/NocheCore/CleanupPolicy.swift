import Foundation

/// When automatic tab cleanup runs (M1.6 Task 7c, spec row 102). Pure: the clock, the last typing and the presentation state come from the caller.
public enum CleanupPolicy {
    /// The job runs this often (P: the spec says hourly).
    public static let interval: TimeInterval = 3600
    /// A key typed in Noche this recently holds the job back (B: the spec says "the last 10 s").
    public static let typingQuiet: TimeInterval = 10

    /// Whether the job is due: never run yet (the launch run), or a whole interval since the last run.
    public static func isDue(now: Date, lastRun: Date?) -> Bool {
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= interval
    }

    /// Whether the job runs now: due, the Mac not presenting and no typing in the last |typingQuiet| seconds. A job held back stays due.
    public static func shouldRun(now: Date, lastRun: Date?, lastTypedAt: Date?, presenting: Bool) -> Bool {
        guard isDue(now: now, lastRun: lastRun), !presenting else { return false }
        guard let lastTypedAt else { return true }
        return now.timeIntervalSince(lastTypedAt) >= typingQuiet
    }
}
