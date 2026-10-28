import AppKit

/// The inline name field of a row being renamed (a tab or a group): Return and a click elsewhere commit, Escape cancels. The row that owns
/// it sets |onCommit| and |onCancel| and calls |begin|; it ends on its own, once, whichever way it ends. Focus goes back to the page when
/// it ended on a key (Return, Escape) or the row scrolled out while the field had it, never when a click moved it to another control.
final class RenameField: NSTextField, NSTextFieldDelegate {
    private static let escStays = BarHook.on("RENAME_ESCNOFOCUS"), recycleStays = BarHook.on("RENAME_RECYCLENOFOCUS")  // negative controls: Escape, or a scroll cancel, leaves focus nowhere
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// Gives focus back to the page; |onlyIfFree|: only when no other control has taken it by the time the click that ended the edit is handled.
    var returnFocus: ((_ onlyIfFree: Bool) -> Void)?
    private(set) var isEditing = false

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        cell?.isScrollable = true
        textColor = .white
        delegate = self
        setAccessibilityIdentifier("sidebar.rename")
    }
    required init?(coder: NSCoder) { fatalError() }

    func begin(_ text: String, font: NSFont, frame: NSRect, in parent: NSView) {
        self.font = font
        self.frame = frame
        stringValue = text
        isEditing = true
        parent.addSubview(self)
        parent.window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    /// |clicked|: the edit ended because focus moved (a click elsewhere), not on a key.
    func commit(clicked: Bool = false) {
        guard isEditing else { return }
        isEditing = false
        let text = stringValue
        removeFromSuperview()
        onCommit?(text)
        returnFocus?(clicked)
    }

    func cancel(recycled: Bool = false) {
        guard isEditing else { return }
        isEditing = false
        let hadFocus = currentEditor().map { window?.firstResponder === $0 } ?? false
        removeFromSuperview()
        onCancel?()
        if hadFocus, !(recycled ? Self.recycleStays : Self.escStays) { returnFocus?(false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commit(); return true
        case #selector(NSResponder.cancelOperation(_:)): cancel(); return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) { commit(clicked: true) }
}

/// A pinned tile has no title on screen to edit in place: its rename is a small popover holding the same field.
/// Test builds keep the field here instead of opening it (a hidden window is never key).
@MainActor
enum RenamePopover {
#if NOCHE_TESTHOOKS
    static var pending: RenameField?
#endif

    static func present(from anchor: NSView, text: String, returnFocus: @escaping (Bool) -> Void, commit: @escaping (String) -> Void) {
        let field = RenameField()
        field.returnFocus = returnFocus
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 34))
        field.onCommit = commit
#if NOCHE_TESTHOOKS
        field.begin(text, font: ChromeStyle.font, frame: NSRect(x: 8, y: 6, width: 184, height: 22), in: box)
        pending = field
#else
        let popover = NSPopover()
        popover.behavior = .transient
        let controller = NSViewController()
        controller.view = box
        popover.contentViewController = controller
        field.onCommit = { [weak popover] text in popover?.close(); commit(text) }
        field.onCancel = { [weak popover] in popover?.close() }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        field.begin(text, font: ChromeStyle.font, frame: NSRect(x: 8, y: 6, width: 184, height: 22), in: box)
#endif
    }
}
