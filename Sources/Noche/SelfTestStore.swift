#if NOCHE_TESTHOOKS
import AppKit
import CefBridge

/// Persistence checks. Names ending in `-relaunch` run twice on one profile (scripts/app-test.sh: phase 1 on a wiped profile,
/// phase 2 on the same one); each phase prints its own `pass` line and the check passes only if both did.
extension SelfTest {
    /// Phase 1 opens 3 tabs and quits normally. Phase 2 counts what the engine brought back by itself, before Noche restores anything.
    func chromiumRestoreRelaunch() async {
        guard await ready() else { return }
        if phase == 1 {
            guard await openTabs(3) else { return finish(false, "phase 1: 3 tabs did not load (rows=\(rowCount))") }
            try? await Task.sleep(for: .seconds(2))  // let the engine's session writer see them
            return finish(violations.isEmpty, "phase 1: 3 tabs open, quitting normally \(violations)")
        }
        try? await Task.sleep(for: .seconds(5))  // restored tabs and windows arrive after the first load
        let tabs = app.windows.reduce(0) { $0 + $1.tabs.count }
        let windows = ownWindows()
        guard tabs == 1, windows == 1, app.controllers.count == 1 else {
            return finish(false, "phase 2: engine tabs=\(tabs) NSWindows=\(windows) controllers=\(app.controllers.count), want 1, 1, 1")
        }
        finish(violations.isEmpty, "phase 2: engine tabs=\(tabs) NSWindows=\(windows) controllers=\(app.controllers.count) \(violations)")
    }
}
#endif
