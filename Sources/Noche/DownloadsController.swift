import AppKit
import CefBridge
import NocheStore

/// The profile's downloads as the UI sees them: the observer of `NCDownloads` (installed once at startup, before any window is restored, so
/// downloads whose tab closed and downloads restored from the last session report here too). Newest first. Every change posts `changed`;
/// the Downloads window and each window's sidebar button listen.
@MainActor
final class DownloadsController: NSObject, NCDownloadsObserver {
    static let changed = Notification.Name("NocheDownloadsChanged")
    private(set) var items: [NCDownloadItem] = []
    private var made: DownloadsWindowController?
    /// Called once when nothing is in progress any more (the quit waits for its pauses to land), or at the timeout.
    private var quietWaiter: (() -> Void)?
#if NOCHE_TESTHOOKS
    /// What Open and Show in Finder asked of NSWorkspace; a test build records the call and never makes it.
    static var workspaceLog: [(call: String, path: String)] = []
    var holdCancel = false
#endif

    /// The profile's store, set once it is open (before the engine announces its restored downloads).
    var store: Store? { didSet { removed = Set(removedOrder) } }
    private static let removedKey = "downloadsRemoved"
    /// Finished downloads the person removed from the list, as "engine id|address", oldest first. The engine has no call that forgets a download: it
    /// announces every download of the profile's history again at each launch (ids and names are the same as before), so the removal is kept here, in the
    /// store's `setting` table, and those announcements are dropped. The address is part of the key so that an id reused after the engine's history was
    /// cleared does not hide a new download. Only the newest `removedLimit` are kept.
    private var removedOrder: [String] {
        get { ((try? store?.setting(Self.removedKey)) ?? nil).map { $0.split(separator: "\n").map(String.init) } ?? [] }
        set { try? store?.setSetting(Self.removedKey, newValue.suffix(Self.removedLimit).joined(separator: "\n")) }
    }
    private static let removedLimit = 2000
    private var removed = Set<String>()
    private static func key(_ item: NCDownloadItem) -> String { "\(item.identifier)|\(item.url)" }

    func downloads(_ downloads: NCDownloads, didUpdate item: NCDownloadItem) {
        if removed.contains(Self.key(item)), item.state != .inProgress {
            // The row that was listed (an update that came in progress after the give-up) goes too: its end is dropped, so it would freeze at its last progress.
            if !BarHook.on("DL_KEEPSTALE"), items.contains(where: { $0.identifier == item.identifier }) {
                items.removeAll { $0.identifier == item.identifier }
                NotificationCenter.default.post(name: Self.changed, object: self)
            }
            return
        }
        items.removeAll { $0.identifier == item.identifier }
        items.append(item)
        items.sort { $0.identifier > $1.identifier }  // the engine's ids grow with time
        NotificationCenter.default.post(name: Self.changed, object: self)
        if let waiter = quietWaiter, !items.contains(where: { $0.state == .inProgress }) { quietWaiter = nil; waiter() }
    }

    /// Unfinished downloads (running or paused): the sidebar button shows a ring while any exists.
    var unfinished: [NCDownloadItem] { items.filter { $0.state == .inProgress || $0.state == .paused } }

    /// Progress of the unfinished downloads together (0 to 1, bytes over the known totals); nil when idle.
    var ring: Double? {
        let live = unfinished
        guard !live.isEmpty else { return nil }
        let known = live.filter { $0.totalBytes > 0 }
        let total = known.reduce(Int64(0)) { $0 + $1.totalBytes }
        return total > 0 ? min(1, Double(known.reduce(Int64(0)) { $0 + $1.receivedBytes }) / Double(total)) : 0
    }

    /// Window > Downloads and the sidebar button.
    func show() {
        BrowserWindowController.note("showDownloads")
        windowController.show()
    }

    var windowController: DownloadsWindowController {
        if let made { return made }
        let c = DownloadsWindowController(owner: self)
        made = c
        return c
    }

    /// Whether a row can be removed: the download ended (complete or canceled). A running or paused one is canceled first, an interrupted one can still resume.
    static func isFinished(_ item: NCDownloadItem) -> Bool { item.state == .complete || item.state == .canceled }

    /// Removes the row of a finished download from the list, for good (the file stays where it is, and the removal outlives a relaunch: see `removed`).
    func remove(_ item: NCDownloadItem) {
        guard Self.isFinished(item), !BarHook.on("DL_NOREMOVE") else { return }
        if removed.insert(Self.key(item)).inserted && !BarHook.on("DL_NOKEEP") { removedOrder += [Self.key(item)] }
        items.removeAll { $0.identifier == item.identifier }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// Removes every row that is not in progress or paused (what the window's Clear does). An interrupted download is not finished: it can resume.
    func clearFinished() {
        if BarHook.on("DL_CLEARALL") { items.removeAll(); NotificationCenter.default.post(name: Self.changed, object: self); return }  // negative control: running rows go too
        for item in items.filter(Self.isFinished) { remove(item) }
    }

    func pause(_ item: NCDownloadItem) { NCDownloads.shared.pause(item.identifier) }
    func resume(_ item: NCDownloadItem) { NCDownloads.shared.resume(item.identifier) }
    /// The engine cancels what it is transferring. A download restored from the last session (paused or interrupted) has nothing live to cancel: the engine
    /// then stays silent (CEF's DoCancel acts on in-progress items only) and the row would stay for good, so after `cancelGrace` that row is given up like a
    /// removed one. A row in progress is never given up: a slow cancel is still a live transfer.
    static let cancelGrace = 2.0
    func cancel(_ item: NCDownloadItem) {
#if NOCHE_TESTHOOKS
        if !holdCancel { NCDownloads.shared.cancel(item.identifier) }  // a test holds the cancel: the engine has not landed it yet
#else
        NCDownloads.shared.cancel(item.identifier)
#endif
        let id = item.identifier
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cancelGrace) { [weak self] in MainActor.assumeIsolated { self?.giveUpIfRestored(id) } }
    }

    private func giveUpIfRestored(_ id: UInt32) {
        guard let now = items.first(where: { $0.identifier == id }), !BarHook.on("DL_NOGIVEUP") else { return }
        guard now.state == .paused || now.state == .interrupted || BarHook.on("DL_GIVEUPLIVE") else { return }
        giveUp(now)
    }

    /// Hides the row for good (stored like a removal) without the engine's word.
    func giveUp(_ item: NCDownloadItem) {
        if removed.insert(Self.key(item)).inserted && !BarHook.on("DL_NOKEEP") { removedOrder += [Self.key(item)] }
        items.removeAll { $0.identifier == item.identifier }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func open(_ item: NCDownloadItem) {
        let url = URL(fileURLWithPath: item.fullPath)
#if NOCHE_TESTHOOKS
        if !BarHook.on("DL_NOOPEN") { Self.workspaceLog.append(("open", url.path)) }
#else
        NSWorkspace.shared.open(url)
#endif
    }

    func reveal(_ item: NCDownloadItem) {
        let url = URL(fileURLWithPath: item.fullPath)
#if NOCHE_TESTHOOKS
        if !BarHook.on("DL_NOOPEN") { Self.workspaceLog.append(("reveal", url.path)) }
#else
        NSWorkspace.shared.activateFileViewerSelecting([url])
#endif
    }

    /// The quit path: asks the engine to pause what runs, and calls |then| once every pause landed (an update with nothing in progress), or after |timeout| seconds.
    func pauseAllForQuit(timeout: TimeInterval, then: @escaping () -> Void) {
#if NOCHE_TESTHOOKS
        // Test: the pause lands this many milliseconds late, so the windows are open and interactive for that long (the quit's gap).
        if let ms = Double(ProcessInfo.processInfo.environment["NOCHE_TEST_PAUSE_DELAY_MS"] ?? ""), items.contains(where: { $0.state == .inProgress }) {
            quietWaiter = then
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) { _ = NCDownloads.shared.pauseAllForQuit() }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated { if let waiter = self?.quietWaiter { self?.quietWaiter = nil; waiter() } }
            }
            return
        }
#endif
        guard !BarHook.on("DL_NOPAUSE"), NCDownloads.shared.pauseAllForQuit() > 0, items.contains(where: { $0.state == .inProgress }) else { return then() }
        quietWaiter = then
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated { if let waiter = self?.quietWaiter { self?.quietWaiter = nil; waiter() } }
        }
    }
}
