import Foundation
import CoreGraphics

/// Where every sidebar row sits (note 1.1), in window points with the top-left origin, scrolled to the top. Row pitches are the capture's:
/// tab rows 37, group rows 40 (39 high), grid rows 47. The persistent area ends 6 pt above the divider; New Tab sits 4 pt below it.
public enum SidebarMetrics {
    public static let listTop: CGFloat = 54
    public static let gridGap: CGFloat = 3          // between the grid and the list
    public static let tabPitch: CGFloat = 37
    public static let tabHeight: CGFloat = 37
    public static let groupPitch: CGFloat = 40
    public static let groupHeight: CGFloat = 39
    public static let groupGap: CGFloat = 3         // before a group that follows a tab row
    public static let dividerGap: CGFloat = 6       // from the last persistent row to the divider
    public static let dividerInset: CGFloat = 12       // from the left; the right margin is 10 (x 12 to 187 at 197)
    public static let dividerHeight: CGFloat = 1
    public static let newTabGap: CGFloat = 4        // from the divider to the New Tab row
    public static let newTabHeight: CGFloat = 39
    public static let rowX: CGFloat = 6
    public static let rowInset: CGFloat = 12        // rows are the sidebar's width minus this
    public static let groupIndent: CGFloat = 14     // a child row's favicon and title (note 1.3)
    public static let bottomPad: CGFloat = 12       // the list's content ends this far above the bottom bar
    /// Realized rows: the visible ones plus |overscan| on each side, so that at most |realizedBudget| are alive when a window shows
    /// 36 to 38 rows (the 1436 pt test height).
    public static let realizedBudget = 40

    public static func overscan(visible: Int) -> Int { max(1, (realizedBudget - visible) / 2) }
}

public struct SidebarPlacement: Equatable, Sendable {
    public let entry: SidebarEntry
    public let frame: CGRect
    /// The entry's number among its kind (grid tiles, group rows, tab rows), in layout order.
    public let ordinal: Int
}

public struct GroupBox: Equatable, Sendable {
    public let group: GroupID
    public let frame: CGRect
}

/// The layout of |entries| (from `TabList.layout()`) at a sidebar |width|.
public struct SidebarLayout: Equatable, Sendable {
    public private(set) var placements: [SidebarPlacement] = []
    /// The box around each expanded group's header and children.
    public private(set) var boxes: [GroupBox] = []
    /// Where the list ends (window points, without the bottom padding).
    public private(set) var contentBottom: CGFloat = SidebarMetrics.listTop
    /// The sidebar width the layout was made for.
    public private(set) var width: CGFloat = 0

    public init() {}

    public init(entries: [SidebarEntry], width: CGFloat) {
        typealias M = SidebarMetrics
        self.width = width
        let rowW = width - M.rowInset
        var y = M.listTop
        let tiles = entries.filter { if case .gridTile = $0 { true } else { false } }.count
        if tiles > 0 { y += PinnedGrid.rowPitch * CGFloat(PinnedGrid.rows(count: tiles, width: width) - 1) + PinnedGrid.tile + M.gridGap }
        var kinds = [0, 0, 0]  // tiles, groups, tab rows
        var afterTab = false
        var open: (group: GroupID, top: CGFloat, bottom: CGFloat)?
        func closeBox() {
            if let o = open, o.bottom > o.top + M.groupHeight { boxes.append(GroupBox(group: o.group, frame: CGRect(x: M.rowX, y: o.top, width: rowW, height: o.bottom - o.top))) }
            open = nil
        }
        func place(_ e: SidebarEntry, _ f: CGRect, kind: Int?) {
            placements.append(SidebarPlacement(entry: e, frame: f, ordinal: kind.map { kinds[$0] } ?? 0))
            if let kind { kinds[kind] += 1 }
        }
        for e in entries {
            switch e {
            case .gridTile:
                var f = PinnedGrid.frame(index: kinds[0], width: width)
                f.origin.y += M.listTop
                place(e, f, kind: 0)
            case .tab(_, let level):
                if level == 0 { closeBox() }
                let f = CGRect(x: M.rowX, y: y, width: rowW, height: M.tabHeight)
                place(e, f, kind: 2)
                y += M.tabPitch
                afterTab = true
                if level > 0 { open?.bottom = f.maxY }
            case .group(let g):
                closeBox()
                if afterTab { y += M.groupGap }
                let f = CGRect(x: M.rowX, y: y, width: rowW, height: M.groupHeight)
                place(e, f, kind: 1)
                open = (g, f.minY, f.maxY)
                y += M.groupPitch
                afterTab = false
            case .divider:
                closeBox()
                y += M.dividerGap
                place(e, CGRect(x: M.dividerInset, y: y, width: width - M.dividerInset - 10, height: M.dividerHeight), kind: nil)
                y += M.dividerHeight + M.newTabGap
                afterTab = false
            case .newTab:
                place(e, CGRect(x: M.rowX, y: y, width: rowW, height: M.newTabHeight), kind: nil)
                y += M.newTabHeight
                afterTab = false
            }
        }
        closeBox()
        contentBottom = y
    }

    /// The placements to keep alive for a window of the list showing y in |minY|..|maxY| (window points): the visible rows plus the
    /// overscan on each side. Grid tiles, group rows and tab rows only; the divider and the New Tab row are always there.
    public func realized(minY: CGFloat, maxY: CGFloat) -> [Int] {
        guard !placements.isEmpty else { return [] }
        // placements are in nondecreasing y: the first whose bottom passes minY, then the first whose top reaches maxY.
        var lo = 0, hi = placements.count
        while lo < hi { let m = (lo + hi) / 2; if placements[m].frame.maxY > minY { hi = m } else { lo = m + 1 } }
        let first = lo
        lo = first; hi = placements.count
        while lo < hi { let m = (lo + hi) / 2; if placements[m].frame.minY >= maxY { hi = m } else { lo = m + 1 } }
        let end = lo
        let n = SidebarMetrics.overscan(visible: end - first)
        let from = max(0, first - n), to = min(placements.count, end + n)
        return (from..<to).filter { i in
            switch placements[i].entry {
            case .divider, .newTab: false
            default: true
            }
        }
    }
}
