import AppKit

/// The shared toast (M1.6 Task 7c, T7.7): a short message with an Undo button, at the bottom of the page card. Tab cleanup and the Cmd+D card's
/// Remove use it. It is an overlay view of the window (never a window of its own), so a hidden run tests it through direct calls.
final class ToastView: NSView {
    override var isFlipped: Bool { true }
    /// How long a toast stays before it hides itself (B: README builder calls).
    static let lifetime: TimeInterval = 8

    let label = NSTextField(labelWithString: "")
    let undo = PromptButton(title: "Undo", identifier: "toast.undo", primary: true)
    /// The lifetime timer of the toast on screen (nil when hidden); test support fires it.
    private(set) var timer: Timer?
    private var onUndo: (() -> Void)?
    /// False once the thing the toast would undo changed under it; the window hides the toast then (`BrowserWindowController.syncToast`).
    private(set) var isValid: () -> Bool = { true }
    /// How many toasts were shown (test support).
    private(set) var shownCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("toast")
        label.font = ChromeStyle.barRowFont
        label.textColor = ChromeStyle.barTitle
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityIdentifier("toast.text")
        undo.target = self
        undo.action = #selector(undoClicked)
        addSubview(label)
        addSubview(undo)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Shows |message| with Undo. |valid| says whether Undo still applies (checked on every click); a new toast replaces the one on screen.
    func show(_ message: String, valid: @escaping () -> Bool = { true }, undo action: @escaping () -> Void) {
        label.stringValue = message
        onUndo = action
        isValid = valid
        isHidden = false
        shownCount += 1
        needsLayout = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.lifetime, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        onUndo = nil
        isHidden = true
    }

    /// Undo runs once, and only while it still applies; the toast goes either way.
    @objc func undoClicked() {
        let action = onUndo, valid = isValid()
        hide()
        if valid { action?() }
    }

    override func layout() {
        super.layout()
        let button = NSSize(width: 64, height: 28)
        undo.frame = NSRect(x: bounds.width - 8 - button.width, y: (bounds.height - button.height) / 2, width: button.width, height: button.height)
        label.frame = NSRect(x: 16, y: (bounds.height - 18) / 2, width: max(0, undo.frame.minX - 24), height: 18)
    }

    override func mouseDown(with event: NSEvent) {}  // the page behind must not take the press

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ChromeStyle.barRadius, yRadius: ChromeStyle.barRadius)
        ChromeStyle.barFill.setFill()
        path.fill()
        ChromeStyle.barBorder.setStroke()
        path.stroke()
    }
}
