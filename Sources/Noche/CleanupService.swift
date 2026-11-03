import AppKit
import IOKit.pwr_mgt
import NocheCore

/// Automatic tab cleanup (M1.6 Task 7c, spec row 102): once at launch after the restore, then hourly, over every window of the app. The decision
/// (due, presenting, typing) is `CleanupPolicy`; this class owns the clock, the typing record and the timer. The clock and the presentation state are
/// injected so a check drives them.
@MainActor
final class CleanupService {
    unowned let app: AppDelegate
    var now: () -> Date = { Date() }
    var presenting: () -> Bool = { SystemPresentation.isPresenting() }
    /// How often the timer asks whether the job is due (B: README builder calls). The launch run waits for the restore, and a run held back by typing
    /// or a presentation starts within one period of the hold ending.
    static let checkInterval: TimeInterval = 5
    /// The launch run also waits until no tab is loading (a restore loads every tab at once, and a loading tab is never archived), at most this long after
    /// launch (B: README builder calls).
    static let launchSettleLimit: TimeInterval = 60
    /// False: the timer does nothing (a check that drives `tick` itself).
    var timerEnabled = true
    private(set) var lastRun: Date?
    private(set) var lastTypedAt: Date?
    /// How many runs happened, and whether every window had finished its restore at the last one (test support).
    private(set) var runCount = 0
    private(set) var lastRunAfterRestore = false
    private var running = false
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var typing: Any?

    init(app: AppDelegate) { self.app = app }

    func start() {
        // Any key pressed in Noche, to the page or to its own fields, counts as typing.
        typing = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.lastTypedAt = self?.now() }
            return e
        }
        startedAt = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, self.timerEnabled else { return }; Task { await self.tick() } }
        }
        Task { await tick() }
    }

    /// Runs the job when it is due and allowed; true when it ran. Windows still restoring hold the launch run back (a partial list would archive wrongly).
    @discardableResult
    func tick() async -> Bool {
        guard !running, !app.closing, !app.controllers.isEmpty else { return false }
        let restored = app.controllers.allSatisfy { $0.installed && !$0.restoring }
        guard restored || BarHook.on("CLEANUP_NOWAIT") else { return false }  // the hook: the launch run does not wait for the restore
        let settled = app.controllers.allSatisfy { $0.list.items.allSatisfy { !$0.isLoading } }
        if runCount == 0, !settled, !BarHook.on("CLEANUP_NOWAIT"), ProcessInfo.processInfo.systemUptime - startedAt < Self.launchSettleLimit { return false }
        let at = now()
        guard CleanupPolicy.shouldRun(now: at, lastRun: BarHook.on("CLEANUP_EVERYTICK") ? nil : lastRun, lastTypedAt: BarHook.on("CLEANUP_NOTYPING") ? nil : lastTypedAt,
                                      presenting: BarHook.on("CLEANUP_NOPRESENT") ? false : presenting()) else { return false }  // the hooks: typing or a presentation holds nothing back
        running = true
        defer { running = false }
        lastRun = at
        lastRunAfterRestore = restored
        if !(runCount == 0 && BarHook.on("CLEANUP_NOLAUNCH")) {  // the hook: the launch run does nothing
            for c in app.controllers { await c.cleanUpTabs(now: at, toast: false) }
        }
        // Whatever the threshold (Never included), an archived tab past its retention goes.
        if !BarHook.on("CLEANUP_NORETENTION") { _ = try? app.writer?.store.tombstoneExpiredArchive(asOf: at) }
        runCount += 1  // counted when the job is done, so a reader that sees it also sees what the job did
        return true
    }
}

/// Whether the Mac is presenting (a slideshow, a video, a call on the big screen): the question automatic cleanup asks so it never moves tabs in front of
/// an audience. macOS has no "presenting" flag, so this reads two signals: a display that is mirrored (a projector or a second screen showing the same
/// picture), and another process holding a "prevent display sleep" assertion (what Keynote, PowerPoint, video players and call apps take while
/// they present). It can be wrong both ways: any other app that keeps the display awake (a video in a browser, `caffeinate -d`) counts as presenting
/// and holds cleanup back for as long as it does, and a presentation that takes neither signal is missed. The cost of a wrong answer is
/// small: a cleanup that comes late, or one that archives tabs (kept in the archive, found by Search Tabs) while presenting.
enum SystemPresentation {
    static func isPresenting() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        if CGGetActiveDisplayList(UInt32(ids.count), &ids, &n) == .success, ids.prefix(Int(n)).contains(where: { CGDisplayIsInMirrorSet($0) != 0 }) { return true }
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess, let byPID = raw?.takeRetainedValue() as NSDictionary? else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        for (pid, list) in byPID where (pid as? NSNumber)?.int32Value != me {
            for case let a as [String: Any] in (list as? [Any]) ?? [] where (a["AssertType"] as? String) == "PreventUserIdleDisplaySleep" { return true }
        }
        return false
    }
}
