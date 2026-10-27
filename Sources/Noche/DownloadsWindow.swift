import AppKit
import CefBridge

/// One download row: name, a size and progress line, a progress bar while it runs, and the buttons that fit its state
/// (Pause or Resume and Cancel while unfinished, Open and Show in Finder when complete, and Remove once it ended).
final class DownloadRowView: NSView {
    static let height: CGFloat = 68
    override var isFlipped: Bool { true }
    let nameField = NSTextField(labelWithString: "")
    let detailField = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    private let buttons: [NSButton] = ["Pause", "Resume", "Cancel", "Open", "Show in Finder", "Remove"].map {
        let b = NSButton(title: $0, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.setAccessibilityIdentifier("downloads.\($0.lowercased().replacingOccurrences(of: " ", with: ""))")
        return b
    }
    private(set) var item: NCDownloadItem?
#if NOCHE_TESTHOOKS
    /// How many times this row was configured, and all rows together (the check that an update touches only the rows that changed).
    private(set) var configured = 0
    static var configuredTotal = 0
#endif
    /// A complete download whose file is gone (moved, renamed or deleted): Open and Show in Finder would do nothing, so the row says so and offers Remove only.
    private(set) var fileMissing = false
    var onAction: ((String, NCDownloadItem) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameField.font = ChromeStyle.font
        nameField.textColor = ChromeStyle.titleColor
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.setAccessibilityIdentifier("downloads.name")
        detailField.font = NSFont.systemFont(ofSize: 12)
        detailField.textColor = ChromeStyle.barHost
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setAccessibilityIdentifier("downloads.detail")
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        progress.controlSize = .small
        progress.setAccessibilityIdentifier("downloads.progress")
        for v in [nameField, detailField, progress] as [NSView] { addSubview(v) }
        for b in buttons { b.target = self; b.action = #selector(pressed(_:)); addSubview(b) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The visible button titled |title| (a hidden one does not apply to the row's state).
    func button(_ title: String) -> NSButton? { buttons.first { $0.title == title && !$0.isHidden } }
    var visibleButtons: [String] { buttons.filter { !$0.isHidden }.map(\.title) }

    @objc private func pressed(_ b: NSButton) { if let item { onAction?(b.title, item) } }

    func configure(_ item: NCDownloadItem) {
#if NOCHE_TESTHOOKS
        configured += 1
        Self.configuredTotal += 1
#endif
        self.item = item
        fileMissing = item.state == .complete && !BarHook.on("DL_NOFILECHECK") && !FileManager.default.fileExists(atPath: item.fullPath)
        nameField.stringValue = item.suggestedName
        detailField.stringValue = fileMissing ? "File not found" : Self.detail(item)
        let live = item.state == .inProgress || item.state == .paused
        progress.isHidden = !live
        progress.doubleValue = Double(max(0, item.percent))
        progress.isIndeterminate = live && item.percent < 0
        if progress.isIndeterminate { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        let shown: Set<String> = switch item.state {
        case .inProgress: ["Pause", "Cancel"]
        case .paused, .interrupted: ["Resume", "Cancel"]
        case .complete: fileMissing ? ["Remove"] : ["Open", "Show in Finder", "Remove"]
        case .canceled: ["Remove"]
        @unknown default: []
        }
        for b in buttons { b.isHidden = !shown.contains(b.title) }
        needsLayout = true
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static func detail(_ d: NCDownloadItem) -> String {
        let of = d.totalBytes > 0 ? "\(size(d.receivedBytes)) of \(size(d.totalBytes))" : size(d.receivedBytes)
        switch d.state {
        case .inProgress: return d.percent >= 0 ? "\(of) (\(d.percent)%)" + (d.speed > 0 ? " - \(size(d.speed))/s" : "") : of
        case .paused: return "Paused - \(of)"
        case .complete: return "Complete - \(size(d.receivedBytes))"
        case .canceled: return "Canceled"
        case .interrupted: return "Interrupted - \(of)"
        @unknown default: return of
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width, actions = buttons.filter { !$0.isHidden }
        var x = w - 12
        for b in actions.reversed() {
            b.sizeToFit()
            x -= b.frame.width
            b.frame.origin = NSPoint(x: x, y: 10)
            x -= 6
        }
        let text = max(80, (actions.isEmpty ? w : x) - 28)
        nameField.frame = NSRect(x: 16, y: 10, width: text, height: 18)
        detailField.frame = NSRect(x: 16, y: 30, width: text, height: 16)
        progress.frame = NSRect(x: 16, y: 52, width: w - 32, height: 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        ChromeStyle.cardBorder.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// The Downloads window (Window > Downloads, the sidebar button): a native window over `DownloadsController`, one row per download, newest first.
@MainActor
final class DownloadsWindowController: NSObject {
    unowned let owner: DownloadsController
    let window: NSWindow
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let empty = NSTextField(labelWithString: "No downloads")
    /// Removes every row that is not in progress or paused.
    let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private(set) var rows: [DownloadRowView] = []
    private var observer: NSObjectProtocol?
    /// `changed` can come ten times a second per live download (and once per history row at launch): the list reloads at most once per `reloadInterval`,
    /// the first change at once and the rest together at the end of the interval.
    static let reloadInterval = 0.1
    private var lastReload = Date.distantPast
    private var reloadPending = false
#if NOCHE_TESTHOOKS
    private(set) var reloads = 0
#endif

    init(owner: DownloadsController) {
        self.owner = owner
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Downloads"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 200)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = ChromeStyle.cardFill
        window.setAccessibilityIdentifier("downloads.window")
        if let app = NSApp.delegate as? AppDelegate, app.hidden { window.level = .floating }
        let content = window.contentView!, strip: CGFloat = 36
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.toolTip = "Remove every download that is not in progress or paused from the list (the files stay)"
        clearButton.target = self
        clearButton.action = #selector(clearFinished)
        clearButton.setAccessibilityIdentifier("downloads.clear")
        clearButton.sizeToFit()
        clearButton.frame.origin = NSPoint(x: content.bounds.width - clearButton.frame.width - 12, y: content.bounds.height - strip + (strip - clearButton.frame.height) / 2)
        clearButton.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(clearButton)
        scroll.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - strip)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = document
        scroll.setAccessibilityIdentifier("downloads.list")
        empty.textColor = ChromeStyle.barHost
        empty.font = ChromeStyle.font
        empty.setAccessibilityIdentifier("downloads.empty")
        document.addSubview(empty)
        window.contentView!.addSubview(scroll)
        window.center()
        observer = NotificationCenter.default.addObserver(forName: DownloadsController.changed, object: owner, queue: .main) { [weak self] note in
            let now = note.userInfo?[DownloadsController.nowKey] != nil
            MainActor.assumeIsolated { self?.changed(immediately: now) }
        }
        // A file moved or deleted since the row was drawn shows when the person comes back to the window.
        NotificationCenter.default.addObserver(self, selector: #selector(becameKey), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: scroll)
        reload()
    }

    @objc private func resized() { layoutRows() }
    @objc private func clearFinished() { owner.clearFinished(); reload() }
    @objc private func becameKey() { reload(refreshFiles: true) }

    func show() {
        reload(refreshFiles: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func changed(immediately: Bool) {
        if immediately || BarHook.on("DL_NOCOALESCE") { reload(); return }  // negative control: every change reloads at once
        guard !reloadPending else { return }
        let wait = Self.reloadInterval - Date().timeIntervalSince(lastReload)
        if wait <= 0 { reload(); return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated { self?.reloadPending = false; self?.reload() }
        }
    }

    /// Rebuilds the list from the controller: a row keeps its view while its download is listed and is configured only when the item changed (the engine
    /// makes a new item object for every update). |refreshFiles| also re-checks the file of each complete row.
    private func reload(refreshFiles: Bool = false) {
        lastReload = Date()
#if NOCHE_TESTHOOKS
        reloads += 1
#endif
        let items = owner.items
        var pool = Dictionary(rows.compactMap { r in r.item.map { ($0.identifier, r) } }, uniquingKeysWith: { a, _ in a })
        let next = items.map { pool.removeValue(forKey: $0.identifier) ?? DownloadRowView(frame: .zero) }
        for r in pool.values { r.removeFromSuperview() }
        for (i, (row, item)) in zip(next, items).enumerated() {
            if row.superview == nil {
                row.onAction = { [weak self] title, item in self?.perform(title, item) }
                document.addSubview(row)
            }
            if row.item !== item || BarHook.on("DL_RELOADALL") || (refreshFiles && item.state == .complete) { row.configure(item) }  // negative control: every row, every time
            row.setAccessibilityIdentifier("downloads.row.\(i)")
        }
        rows = next
        empty.isHidden = !items.isEmpty
        clearButton.isEnabled = items.contains(where: DownloadsController.isFinished)
        layoutRows()
    }

    private func layoutRows() {
        let w = scroll.contentSize.width
        for (i, row) in rows.enumerated() { row.frame = NSRect(x: 0, y: CGFloat(i) * DownloadRowView.height, width: w, height: DownloadRowView.height) }
        empty.sizeToFit()
        empty.frame.origin = NSPoint(x: 16, y: 16)
        document.frame = NSRect(x: 0, y: 0, width: w, height: max(scroll.contentSize.height, CGFloat(rows.count) * DownloadRowView.height))
    }

    private func perform(_ title: String, _ item: NCDownloadItem) {
        switch title {
        case "Pause": owner.pause(item)
        case "Resume": owner.resume(item)
        case "Cancel": if !BarHook.on("DL_NOCANCEL") { owner.cancel(item) }
        case "Open", "Show in Finder":
            // The file may have gone since the row was drawn: the row says so instead of doing nothing.
            if !FileManager.default.fileExists(atPath: item.fullPath), !BarHook.on("DL_NOFILECHECK") { reload(refreshFiles: true); return }
            if title == "Open" { owner.open(item) } else { owner.reveal(item) }
        case "Remove": owner.remove(item); reload()
        default: break
        }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }
