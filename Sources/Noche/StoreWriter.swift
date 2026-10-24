import Foundation
import NocheCore
import NocheStore

/// Mirrors the windows and tabs into the store. The in-memory `TabList`s stay the truth; this saves snapshots taken on the main actor.
/// Debounce: 250 ms reset per event, 2 s cap (`Debouncer`), polled every 50 ms while something is dirty. `flush()` is synchronous
/// (`DatabasePool.write`) and is what quit and window close use, so nothing pending is lost. Failures are logged, never thrown into the UI.
@MainActor
final class StoreWriter {
    let store: Store
    /// The snapshot of a live window, nil for an unknown id or a window still restoring (a partial snapshot would tombstone tabs).
    var snapshot: (UUID) -> WindowSnapshot? = { _ in nil }
    /// Every live window's id, in z-order.
    var windowIDs: () -> [UUID] = { [] }

    private var debouncer = Debouncer(now: { Date() })
    private var dirty = Set<UUID>()      // tabs or state changed: the whole window is saved
    private var geometry = Set<UUID>()   // only the frame changed: one UPDATE of the window row, tab rows untouched
    private var polling = false
    private var frozen = false
#if NOCHE_TESTHOOKS
    private var killArmed = false
    private static let killAt = ProcessInfo.processInfo.environment["NOCHE_TEST_KILL_AT"]
#endif

    init(store: Store) {
        self.store = store
#if NOCHE_TESTHOOKS
        if Self.killAt == "in-transaction" {
            Store.inTransactionHook = { [weak self] in if self?.killArmed == true { kill(getpid(), SIGKILL) } }
        }
#endif
    }

    func markDirty(window: UUID, geometry onlyGeometry: Bool = false) {
        guard !frozen else { return }
#if NOCHE_TESTHOOKS
        if killArmed, Self.killAt == "pending" { kill(getpid(), SIGKILL) }  // between the event and its write
#endif
        if onlyGeometry { if !dirty.contains(window) { geometry.insert(window) } } else { dirty.insert(window); geometry.remove(window) }
        debouncer.event()
        poll()
    }

    private func poll() {
        guard !polling else { return }
        polling = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.polling = false
                guard !(self.dirty.isEmpty && self.geometry.isEmpty) else { return }
                if self.debouncer.due() {
                    self.save(self.dirty, async: true)
                    for id in self.geometry { self.saveFrame(id) }
                    self.dirty.removeAll(); self.geometry.removeAll(); self.debouncer.fired()
                } else { self.poll() }
            }
        }
    }

    /// Debounced saves go to the writer queue (a 100-tab window measured about 8 ms, over the 4 ms main-thread budget); quit and
    /// window close save synchronously, and GRDB serializes writers, so those still land after any queued save.
    private func save(_ ids: Set<UUID>, async: Bool = false) {
        for id in ids {
            guard let s = snapshot(id) else { continue }
            if async { store.saveAsync(s) { Self.log("save", $0) } } else { attempt("save") { try store.save(s) } }
        }
    }

    private func saveFrame(_ id: UUID) {
        guard let s = snapshot(id) else { return }
        attempt("save frame") { try store.saveFrame(id, frame: s.frame, isFullScreen: s.isFullScreen, isZoomed: s.isZoomed) }
    }

    nonisolated private static func log(_ what: String, _ error: any Error) {
        FileHandle.standardError.write(Data("NOCHE store \(what) failed: \(error)\n".utf8))
    }

    /// Writes every live window now (quit, and the tests' synchronous checkpoint).
    func flush() {
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NOFLUSH"] == "1" { return }  // negative control: the quit flush never happens
#endif
        guard !frozen else { return }
        save(Set(windowIDs()))
        dirty.removeAll(); geometry.removeAll()
        debouncer.fired()
    }

    /// Quit: with `close` the windows are dropped (the closed list stays), otherwise every window is written. Nothing is written afterwards.
    func quit() {
        guard !frozen else { return }
        let close = ((try? store.setting("quitBehavior")) ?? nil) == "close"
        if close {
            for id in windowIDs() { attempt("remove window") { try store.removeWindow(id) } }
        } else {
            flush()
        }
        frozen = true
    }

    /// A tab was closed on its own (not with its window): the window is saved without it, then the tab goes on the closed list.
    func closed(tab: TabItem, window: UUID, index: Int) {
        guard !frozen else { return }
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_CLOSED"] == "1" { return markDirty(window: window) }  // negative control
#endif
        if let s = snapshot(window) { attempt("save") { try store.save(s) } }
        attempt("record closed tab") { try store.recordClosed(tab, windowID: window, index: index) }
        dirty.remove(window); geometry.remove(window)
    }

    func windowClosed(_ id: UUID) {
        guard !frozen else { return }
        dirty.remove(id); geometry.remove(id)
        attempt("remove window") { try store.removeWindow(id) }
    }

    func popClosed() -> ClosedTab? {
        var tab: ClosedTab?
        attempt("pop closed tab") { tab = try store.popLastClosed() }
        return tab
    }

    /// A reopen that could not add its tab: the tab goes back on the closed list.
    func putBack(_ closed: ClosedTab) {
        attempt("restore closed tab") { try store.recordClosed(closed.tab, windowID: closed.windowID, index: closed.index) }
    }

    var hasClosed: Bool { ((try? store.hasClosedTabs()) ?? false) }

    private func attempt(_ what: String, _ body: () throws -> Void) {
        do { try body() } catch { Self.log(what, error) }
    }

#if NOCHE_TESTHOOKS
    /// Test only: from now on NOCHE_TEST_KILL_AT sends SIGKILL to this process (see SelfTestStore.crashMidWrite).
    func armKill() { killArmed = true }
#endif
}
