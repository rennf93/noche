import AppKit
import NocheCore
import NocheStore

/// One row of the Bookmarks window: a bookmark with the rows under it (a root or a folder).
final class BookmarkNode: NSObject {
    let bookmark: Bookmark
    let isRoot: Bool
    var children: [BookmarkNode] = []
    init(_ bookmark: Bookmark, isRoot: Bool) { self.bookmark = bookmark; self.isRoot = isRoot }
    var isFolder: Bool { bookmark.kind == .folder }
}

final class BookmarksOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?
    var onRename: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 51 || event.keyCode == 117) && !BarHook.on("BM_NOKEY") { onDelete?() }  // Delete and Forward Delete
        else if event.keyCode == 36 || event.keyCode == 76 { onRename?() }                            // Return and Enter start renaming the selected title
        else { super.keyDown(with: event) }
    }
}

/// The Bookmarks window (Bookmarks > Manage Bookmarks, Opt+Cmd+B): a native window over the store's bookmark tree, the two roots at the top level.
/// A title edits in place (Return renames), Delete removes the row and everything under it, New Folder adds one under the selected folder,
/// a double click opens a page in a new tab. Every change goes through the app, so the bar, the menu and the command bar follow at once.
@MainActor
final class BookmarksWindowController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    unowned let app: AppDelegate
    let window: NSWindow
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    let folderButton = NSButton(title: "New Folder", target: nil, action: nil)
    let outline = BookmarksOutlineView()
    private(set) var roots: [BookmarkNode] = []

    init(app: AppDelegate) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Bookmarks"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 240)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = ChromeStyle.cardFill
        window.setAccessibilityIdentifier("bookmarks.window")
        if app.hidden && !BarHook.on("BM_NOFLOAT") { window.level = .floating }

        deleteButton.bezelStyle = .rounded
        deleteButton.toolTip = "Delete the selected bookmark or folder, and everything in it"
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        deleteButton.setAccessibilityIdentifier("bookmarks.delete")
        folderButton.bezelStyle = .rounded
        folderButton.toolTip = "Add a folder inside the selected folder"
        folderButton.target = self
        folderButton.action = #selector(newFolder)
        folderButton.setAccessibilityIdentifier("bookmarks.newFolder")
        for (id, title, width) in [("title", "Title", 320), ("address", "Address", 360)] as [(String, String, CGFloat)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = 80
            outline.addTableColumn(c)
        }
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = false
        outline.target = self
        outline.doubleAction = #selector(openSelected)
        outline.onDelete = { [weak self] in self?.deleteSelected() }
        outline.onRename = { [weak self] in self?.beginRename() }
        outline.setAccessibilityIdentifier("bookmarks.list")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.setAccessibilityIdentifier("bookmarks.scroll")

        let content = window.contentView!
        for v in [folderButton, deleteButton, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            deleteButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            deleteButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            folderButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            folderButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: deleteButton.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.center()
        reload()
    }

    func show() {
        BrowserWindowController.note("showBookmarks")
        reload()
        window.makeKeyAndOrderFront(nil)
    }

    /// Folders the person collapsed: every other folder shows open.
    private var collapsed = Set<String>()
    private var reloading = false

    /// Rebuilds the tree from the store.
    @objc func reload() {
        guard let store = app.writer?.store else { return }
        reloading = true
        defer { reloading = false }
        func node(_ b: Bookmark, root: Bool) -> BookmarkNode {
            let n = BookmarkNode(b, isRoot: root)
            if b.kind == .folder { n.children = ((try? store.bookmarkChildren(of: b.id)) ?? []).map { node($0, root: false) } }
            return n
        }
        roots = ((try? store.bookmarkRoots()) ?? []).map { node($0, root: true) }
        outline.reloadData()
        func expand(_ n: BookmarkNode) {
            if n.isFolder, !collapsed.contains(n.bookmark.id) { outline.expandItem(n) }
            n.children.forEach(expand)
        }
        roots.forEach(expand)
    }

    /// The rows now shown, as "indent title" (test support).
    var visibleTitles: [String] { (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? BookmarkNode).map { String(repeating: "  ", count: outline.level(forItem: $0)) + $0.bookmark.title } } }

    func node(titled title: String) -> BookmarkNode? {
        func find(_ n: BookmarkNode) -> BookmarkNode? { n.bookmark.title == title ? n : n.children.lazy.compactMap(find).first }
        return roots.lazy.compactMap(find).first
    }

    func select(_ n: BookmarkNode) {
        let r = outline.row(forItem: n)
        if r >= 0 { outline.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false) }
    }

    private var selected: BookmarkNode? { outline.item(atRow: outline.selectedRow) as? BookmarkNode }

    @objc func openSelected() {
        let r = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard r >= 0, let n = outline.item(atRow: r) as? BookmarkNode, !n.isFolder, !BarHook.on("BM_NOOPEN") else { return }
        app.openBookmark(n.bookmark, newTab: true)
    }

    @objc func deleteSelected() {
        guard let n = selected, !n.isRoot else { return }
        if !BarHook.on("BM_NODELETE") { app.deleteBookmark(n.bookmark.id) }
        reload()
    }

    /// Under the selected folder, beside the selected page, or (nothing selected) in Bookmarks Bar.
    @objc func newFolder() {
        guard let first = roots.first else { return }
        var parentId = first.bookmark.id
        if let n = selected { parentId = n.isFolder ? n.bookmark.id : (n.bookmark.parentId ?? parentId) }
        app.addBookmarkFolder(title: "New Folder", parentId: parentId)
        reload()
    }

    /// A title is only editable once Return asked for it, so a double click opens a row and never starts editing.
    func beginRename() {
        let r = outline.selectedRow
        guard r >= 0, let n = outline.item(atRow: r) as? BookmarkNode, !n.isRoot, let field = outline.view(atColumn: 0, row: r, makeIfNecessary: true) as? NSTextField else { return }
        field.isEditable = true
        outline.editColumn(0, row: r, with: nil, select: true)
    }

    @objc func titleEdited(_ field: NSTextField) {
        let r = outline.row(for: field)
        guard r >= 0, let n = outline.item(atRow: r) as? BookmarkNode, !n.isRoot else { return }
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, !BarHook.on("BM_NORENAME") { app.renameBookmark(n.bookmark.id, to: t) }
        reload()
    }

    /// Leaving the field (Escape, a click elsewhere) ends the rename: the rows are rebuilt, uneditable again.
    func controlTextDidEndEditing(_ obj: Notification) { DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.reload() } } }

    // MARK: outline

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if !reloading, let n = notification.userInfo?["NSObject"] as? BookmarkNode { collapsed.insert(n.bookmark.id) }
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        if !reloading, let n = notification.userInfo?["NSObject"] as? BookmarkNode { collapsed.remove(n.bookmark.id) }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? BookmarkNode)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? BookmarkNode)?.children[index] ?? roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? BookmarkNode)?.isFolder == true }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? BookmarkNode else { return nil }
        let isTitle = tableColumn?.identifier.rawValue == "title"
        let field = NSTextField(string: isTitle ? n.bookmark.title : (n.bookmark.url ?? ""))
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = false
        field.font = ChromeStyle.font
        field.textColor = ChromeStyle.titleColor
        field.lineBreakMode = .byTruncatingTail
        if isTitle { field.target = self; field.action = #selector(titleEdited(_:)); field.delegate = self }
        return field
    }
}
