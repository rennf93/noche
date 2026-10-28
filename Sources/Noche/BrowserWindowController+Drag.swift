import AppKit
import NocheCore
import NocheStore

/// Sidebar drag and drop (M1.6 Task 5): the sidebar resolves the pointer to a `DropTarget` (`DropResolver`); these are the list changes a
/// drop makes and what the drag does around it. Same window only: the sidebar refuses a drop whose payload names another window.
extension BrowserWindowController {
    func wireDrag() {
        sidebar.windowID = id
        sidebar.isGroupCollapsed = { [weak self] g in self?.group(withID: g)?.isCollapsed ?? false }
        sidebar.isKnown = { [weak self] item in
            switch item {
            case .tab(let t): self?.item(withID: t) != nil
            case .group(let g): self?.group(withID: g) != nil
            }
        }
        sidebar.onDrop = { [weak self] item, target in self?.performDrop(item, to: target) ?? false }
        sidebar.onOpenFolder = { [weak self] g in
            self?.list.collapse(g, false)
            self?.refreshNow()  // the layout changes under the pointer at once
        }
        sidebar.onDragEnd = { [weak self] item, opened in self?.dragFinished(item, opened: opened) }
        sidebar.hapticOn = { [weak self] in
            SettingKeys.hapticReorder(stored: (try? self?.app.writer?.store.setting("hapticReorder")).flatMap { $0 })
        }
    }

    /// The one list change of a drop: a tab moves to |target| (pinned, unpinned or grouped as the container says; a folder it joins opens),
    /// a group moves with its tabs between the persistent area and the day list. False when the item or the group is gone, or the target
    /// is not one a group can take.
    @discardableResult
    func performDrop(_ item: DragItem, to target: DropTarget) -> Bool {
        note("dropSidebarItem")
        if BarHook.on("DRAG_NODROP") { return false }  // negative control: a drop changes nothing
        switch item {
        case .tab(let id):
            guard self.item(withID: id) != nil else { return false }
            var to = target
            if BarHook.on("DRAG_NOJOIN"), case .group = target { to = .day(0) }  // negative control: the middle of a folder is not a join
            if BarHook.on("DRAG_OFFBYONE"), case .day(let i) = target { to = .day(i + 1) }  // negative control: the day list's index is one off
            if case .group(let g, _) = to {
                guard group(withID: g) != nil else { return false }
                list.collapse(g, false)
            }
            list.move(id, to: to)
        case .group(let g):
            guard group(withID: g) != nil, list.moveGroup(g, to: target) else { return false }
        }
        refresh()
        if !BarHook.on("DRAG_NOSAVE") { changed() }  // negative control: a drop is not saved
        return true
    }

    /// The drag is over: a folder it opened closes again unless the tab went into it (saved: a save in between may have kept it open).
    func dragFinished(_ item: DragItem, opened: [GroupID]) {
        if BarHook.on("DRAG_NOCOLLAPSE") { return }  // negative control: the folders stay open
        var any = false
        for g in opened where group(withID: g) != nil {
            if case .tab(let t) = item, self.item(withID: t)?.groupID == g { continue }
            list.collapse(g, true)
            any = true
        }
        if any {
            refreshNow()
            if !BarHook.on("DRAG_NOSAVECLOSE") { changed() }  // negative control: the close of a folder the hover opened is not saved
        }
    }
}
