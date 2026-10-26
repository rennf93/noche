import AppKit
import NocheStore

/// The Cmd+D card (M1.5 builder call, docs/app/README.md "Builder calls and rulings"): a card under the toolbar at the card's top right.
/// Bookmark mode edits a stored bookmark (title, folder; Done saves, Remove deletes). Folder mode (Bookmark All Tabs) names a new folder and
/// picks its parent; Save adds it, Cancel adds nothing. It is a view of the window, never a window of its own.
final class BookmarkEditView: NSView {
    override var isFlipped: Bool { true }
    enum Mode: Equatable { case added(String), edit(String), folder }   // the bookmark's id for the first two
    private(set) var mode: Mode = .folder
    let heading = NSTextField(labelWithString: "")
    let name = NSTextField(string: "")
    let folders = NSPopUpButton(frame: .zero, pullsDown: false)
    let remove = PromptButton(title: "Remove", identifier: "bookmark.remove", primary: false)
    let done = PromptButton(title: "Done", identifier: "bookmark.done", primary: true)
    /// Done or Save: the name and the chosen parent folder's id.
    var onDone: ((String, String) -> Void)?
    var onRemove: (() -> Void)?
    var onCancel: (() -> Void)?
    private var folderIDs: [String] = []
    private(set) var shownCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("bookmark.edit")
        heading.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = ChromeStyle.barTitle
        heading.setAccessibilityIdentifier("bookmark.heading")
        name.font = ChromeStyle.barRowFont
        name.setAccessibilityIdentifier("bookmark.name")
        name.setAccessibilityLabel("Name")
        name.target = self
        name.action = #selector(doneClicked)   // Return saves
        (name.cell as? NSTextFieldCell)?.sendsActionOnEndEditing = false   // leaving the field (Cancel, another tab) must not save
        folders.setAccessibilityIdentifier("bookmark.folder")
        folders.setAccessibilityLabel("Folder")
        remove.target = self
        remove.action = #selector(removeClicked)
        done.target = self
        done.action = #selector(doneClicked)
        for v in [heading, name, folders, remove, done] as [NSView] { addSubview(v) }
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    var isFolderMode: Bool { mode == .folder }
    var selectedFolderID: String? { folders.indexOfSelectedItem >= 0 && folders.indexOfSelectedItem < folderIDs.count ? folderIDs[folders.indexOfSelectedItem] : nil }

    /// |folderList| is every folder with its depth, in tree order; |parentId| is the one the popup starts on.
    func show(_ mode: Mode, title: String, folderList: [(id: String, title: String, depth: Int)], parentId: String) {
        self.mode = mode
        if isHidden { shownCount += 1 }
        switch mode {
        case .added: heading.stringValue = "Bookmark added"
        case .edit: heading.stringValue = "Edit bookmark"
        case .folder: heading.stringValue = "New folder"
        }
        remove.title = mode == .folder ? "Cancel" : "Remove"
        remove.attributedTitle = NSAttributedString(string: remove.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ChromeStyle.barTitle])
        remove.setAccessibilityIdentifier(mode == .folder ? "bookmark.cancel" : "bookmark.remove")
        remove.setAccessibilityLabel(remove.title)
        done.title = mode == .folder ? "Save" : "Done"
        done.attributedTitle = NSAttributedString(string: done.title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ChromeStyle.barGoText])
        done.setAccessibilityIdentifier(mode == .folder ? "bookmark.save" : "bookmark.done")
        done.setAccessibilityLabel(done.title)
        name.stringValue = title
        folders.removeAllItems()
        folderIDs = folderList.map(\.id)
        for f in folderList { folders.addItem(withTitle: String(repeating: "    ", count: f.depth) + f.title) }
        if let i = folderIDs.firstIndex(of: parentId) { folders.selectItem(at: i) }
        isHidden = false
        needsLayout = true
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        if let w = window, (w.firstResponder as? NSTextView)?.delegate === name { w.makeFirstResponder(nil) }
    }

    /// The name is selected for typing over (a new folder's "New Folder" is the point of it).
    func focusName() {
        name.selectText(nil)
    }

    @objc private func doneClicked() { onDone?(name.stringValue, selectedFolderID ?? "") }
    @objc private func removeClicked() { if mode == .folder { onCancel?() } else { onRemove?() } }

    override func layout() {
        super.layout()
        let w = bounds.width
        heading.frame = NSRect(x: 16, y: 12, width: max(0, w - 32), height: 18)
        name.frame = NSRect(x: 16, y: 38, width: max(0, w - 32), height: 24)
        folders.frame = NSRect(x: 16, y: 70, width: max(0, w - 32), height: 24)
        done.frame = NSRect(x: w - 16 - 84, y: bounds.height - 12 - 30, width: 84, height: 30)
        remove.frame = NSRect(x: done.frame.minX - 8 - 84, y: done.frame.minY, width: 84, height: 30)
    }

    override func mouseDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: ChromeStyle.barRadius, yRadius: ChromeStyle.barRadius)
        ChromeStyle.barFill.setFill()
        path.fill()
        ChromeStyle.barBorder.setStroke()
        path.stroke()
    }
}
