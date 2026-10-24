#if NOCHE_TESTHOOKS
import AppKit
import CefBridge

/// Persistence checks. Names ending in `-relaunch` run twice on one profile (scripts/app-test.sh: phase 1 on a wiped profile,
/// phase 2 on the same one); each phase prints its own `pass` line and the check passes only if both did.
extension SelfTest {
    /// Phase 1 opens 3 tabs; chromium-restore-relaunch then quits normally, chromium-restore-crash-relaunch prints phase1-ready
    /// and waits for scripts/app-test.sh to SIGKILL it. Phase 2 counts what the engine brought back by itself, before Noche
    /// restores anything. NOCHE_TEST_RESTORE_EXPECT=N (negative control) makes phase 2 expect N tabs instead of 1.
    func chromiumRestoreRelaunch() async {
        guard await ready() else { return }
        if phase == 1 {
            guard await openTabs(3) else { return finish(false, "phase 1: 3 tabs did not load (rows=\(rowCount))") }
            try? await Task.sleep(for: .seconds(2))  // let the engine's session writer see them
            if check.hasSuffix("-crash-relaunch") { return line("info", "phase1-ready: 3 tabs loaded, waiting to be killed") }
            return finish(violations.isEmpty, "phase 1: 3 tabs open, quitting normally \(violations)")
        }
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Noche Test/Cache")
        // The profile phase 1 left: phase 2 on a wiped profile would pass for the wrong reason.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        guard left.contains("Default") || left.contains("Local State") else { return finish(false, "phase 2: no profile left by phase 1 (\(left))") }
        // Restored tabs and windows arrive after the first load: wait until the counts hold still for 3 s (cap 15 s).
        func counts() -> (Int, Int) { (app.windows.reduce(0) { $0 + $1.tabs.count }, ownWindows()) }
        var last = counts(), since = Date()
        let end = Date().addingTimeInterval(15)
        while Date() < end, Date().timeIntervalSince(since) < 3 {
            try? await Task.sleep(for: .milliseconds(100))
            let now = counts()
            if now != last { last = now; since = Date() }
        }
        let want = Int(ProcessInfo.processInfo.environment["NOCHE_TEST_RESTORE_EXPECT"] ?? "") ?? 1
        let (tabs, windows) = last
        let detail = "phase 2: engine tabs=\(tabs) NSWindows=\(windows) controllers=\(app.controllers.count) profile=\(left.count) entries"
        guard tabs == want, windows == 1, app.controllers.count == 1 else { return finish(false, "\(detail), want \(want) tab, 1, 1") }
        finish(violations.isEmpty, "\(detail) \(violations)")
    }
}
#endif
