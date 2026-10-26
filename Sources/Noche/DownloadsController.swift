import AppKit
import CefBridge

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
#endif

    func downloads(_ downloads: NCDownloads, didUpdate item: NCDownloadItem) {
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

    func pause(_ item: NCDownloadItem) { NCDownloads.shared.pause(item.identifier) }
    func resume(_ item: NCDownloadItem) { NCDownloads.shared.resume(item.identifier) }
    func cancel(_ item: NCDownloadItem) { NCDownloads.shared.cancel(item.identifier) }

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
        guard !BarHook.on("DL_NOPAUSE"), NCDownloads.shared.pauseAllForQuit() > 0, items.contains(where: { $0.state == .inProgress }) else { return then() }
        quietWaiter = then
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated { if let waiter = self?.quietWaiter { self?.quietWaiter = nil; waiter() } }
        }
    }
}
