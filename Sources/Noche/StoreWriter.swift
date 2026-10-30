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
    /// A window that gave items to new windows waits for each of them: a save of it (debounced, a closed tab, its close) would tombstone the
    /// items before the new windows' rows exist. The set holds the windows it still waits for.
    var holds: [UUID: Set<UUID>] = [:]
    private var removing = Set<UUID>()   // closed while held: its rows are dropped once the last window it waits for has saved
#if NOCHE_TESTHOOKS
    var savedHook: ((UUID) -> Void)?     // Test only: called after each `saveNow` write (a check reads the store between two)
#endif
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
#if NOCHE_TESTHOOKS
                let noFix = ProcessInfo.processInfo.environment["NOCHE_TEST_NO_QUIT_CLEAR"] == "1"  // negative control: the old poll
#else
                let noFix = false
#endif
                guard !self.frozen || noFix else { return }
                guard !(self.dirty.isEmpty && self.geometry.isEmpty) else { return }
                if self.debouncer.due() {
                    let ready = self.dirty.filter { self.holds[$0] == nil }
                    self.save(ready, async: true)
                    for id in self.geometry { self.saveFrame(id) }
                    self.dirty.subtract(ready); self.geometry.removeAll(); self.debouncer.fired()
                    if !self.dirty.isEmpty { self.debouncer.event(); self.poll() }
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
        save(Set(windowIDs().filter { holds[$0] == nil }))  // a held window keeps its old rows: they still hold the tab it gave up
        dirty.removeAll(); geometry.removeAll()
        debouncer.fired()
    }

    /// Saves these windows now, one after the other in this order (a move writes the window that receives before the one that gave up: the
    /// group row and the tab rows land in the new window before the old one drops what it no longer holds).
    func saveNow(_ ids: [UUID]) {
        guard !frozen else { return }
        for id in ids where holds[id] == nil {  // a held window saves when its last new window has (`release`), it stays dirty meanwhile
            save([id]); dirty.remove(id); geometry.remove(id)
#if NOCHE_TESTHOOKS
            savedHook?(id)
#endif
        }
    }

    /// |source| gave items to the new window |new| and waits for its first save.
    func hold(_ source: UUID, until new: UUID) { holds[source, default: []].insert(new) }

    /// |new| saved (or closed): true when |source| waits for no other window and is still open, so the caller may save it. A source that was
    /// closed meanwhile is dropped from the store here, after every window it gave to has its rows.
    @discardableResult
    func release(_ source: UUID, after new: UUID) -> Bool {
        if BarHook.on("MOVE_HOLD1") { holds[source] = nil } else { holds[source]?.remove(new) }  // negative control: one wait for all, the first new window frees the source
        guard holds[source]?.isEmpty ?? true else { return false }
        holds[source] = nil
        guard removing.remove(source) != nil else { return true }
        attempt("remove window") { try store.removeWindow(source) }
        return false
    }

    /// Quit: with `close` the windows are dropped (the closed list stays), otherwise every window is written. Nothing is written afterwards.
    func quit() {
        guard !frozen else { return }
        let close = SettingKeys.value("quitBehavior", stored: (try? store.setting("quitBehavior")).flatMap { $0 }) == "close"
        if close {
            // A pending debounced save would write the window again (deletedAt NULL) and bring its tabs back.
#if NOCHE_TESTHOOKS
            if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_QUIT_CLEAR"] != "1" { dirty.removeAll(); geometry.removeAll() }
#else
            dirty.removeAll(); geometry.removeAll()
#endif
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
        let held = holds[window] != nil && !BarHook.on("HOLD_NOCLOSED")  // the hook: a closed tab saves a held window at once
        if !held, let s = snapshot(window) { attempt("save") { try store.save(s) } }
        attempt("record closed tab") { try store.recordClosed(tab, windowID: window, index: index) }
        if held { markDirty(window: window) } else { dirty.remove(window); geometry.remove(window) }  // a held window saves without the tab once it is free
    }

    func windowClosed(_ id: UUID) {
        guard !frozen else { return }
        dirty.remove(id); geometry.remove(id)
        for source in Array(holds.keys) where holds[source]?.contains(id) == true { release(source, after: id) }  // a new window closed before it saved: nothing more to wait for
        if holds[id] != nil, !BarHook.on("HOLD_NOREMOVE") { removing.insert(id); return }  // the hook: closing a held window drops its rows at once
        holds[id] = nil
        attempt("remove window") { try store.removeWindow(id) }
    }

    /// The newest closed tab, still on the list (see `Store.peekLastClosed`); `reopened` takes it off once it is back in a window.
    func peekClosed() -> ClosedTab? {
        var tab: ClosedTab?
        attempt("peek closed tab") { tab = try store.peekLastClosed() }
        return tab
    }

    func reopened(_ id: TabID) { attempt("clear closed tab") { try store.clearClosed(id) } }

    /// Puts a popped closed tab back on the list (kept for callers that pop).
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
