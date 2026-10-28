import Foundation
import CoreGraphics

/// What a sidebar drag carries: a tab or a group, by id.
public enum DragItem: Hashable, Sendable {
    case tab(TabID)
    case group(GroupID)
}

/// The pasteboard payload of a sidebar drag (note 4.1): the kind, the id and the window it started in. Same window only (M1.6): a
/// payload that names another window is refused, whatever it holds.
public struct DragPayload: Codable, Equatable, Sendable {
    public static let pasteboardType = "app.noche.sidebar-item"
    public var kind: String
    public var id: UUID
    public var window: UUID

    public init(_ item: DragItem, window: UUID) {
        switch item {
        case .tab(let t): kind = "tab"; id = t.raw
        case .group(let g): kind = "group"; id = g.raw
        }
        self.window = window
    }

    public init?(data: Data) {
        guard let p = try? JSONDecoder().decode(DragPayload.self, from: data), p.item != nil else { return nil }
        self = p
    }

    public var data: Data? { try? JSONEncoder().encode(self) }

    public var item: DragItem? {
        switch kind {
        case "tab": .tab(TabID(raw: id))
        case "group": .group(GroupID(raw: id))
        default: nil
        }
    }

    /// The dragged item when the drag started in |window|; nil for another window's drag.
    public func item(in window: UUID) -> DragItem? { self.window == window ? item : nil }
}

/// What the sidebar draws for the slot a drag would drop into, in layout coordinates (window points, scrolled to the top).
public enum DropIndicator: Equatable, Sendable {
    case line(CGRect)      // the insertion line between rows
    case folder(CGRect)    // the outline of the folder the drop joins (its header, and its children when it is open)
    case ghost(CGRect)     // the 41 x 41 preview of the grid slot

    public var frame: CGRect {
        switch self {
        case .line(let f), .folder(let f), .ghost(let f): f
        }
    }
}

public struct DropResolution: Equatable, Sendable {
    /// Where the drop lands; nil when the drop is refused (it snaps back).
    public var target: DropTarget?
    public var indicator: DropIndicator?
    /// A collapsed folder under the middle of the pointer: it opens after |DropResolver.autoExpandDelay|.
    public var openFolder: GroupID?
}

/// Where the sidebar list scrolls while a drag is near its top or bottom edge (note 2.1: a 24 pt band).
public enum AutoScroll {
    public static let band: CGFloat = 24
    public static let maxStep: CGFloat = 14

    /// Points to scroll for a pointer |y| points below the top of a |height| tall visible area: negative scrolls up, 0 away from both
    /// edges. The step grows with the depth into the band.
    public static func step(y: CGFloat, height: CGFloat) -> CGFloat {
        func ramp(_ depth: CGFloat) -> CGFloat { 2 + min(max(depth, 0), band) / band * (maxStep - 2) }
        if y < band { return -ramp(band - y) }
        if y > height - band { return ramp(y - (height - band)) }
        return 0
    }
}

/// The drop rules of note 2.1, pure: a pointer position over a sidebar layout and the dragged item give the `DropTarget` the existing
/// `TabList` mutations take, with the indicator to draw. Indexes count the container without the dragged item (the meaning of
/// `TabList.move(_:to:)`), and the dragged item's own row is skipped, so a drop where it already is changes nothing.
///
/// - The grid area: a tab pins as a tile in the slot nearest the pointer (a group is refused).
/// - The persistent area and the day list (below the divider): a loose row takes the pointer's half (above the middle before it, else after).
///   A folder row takes its quarters: the top one before the folder, the middle half joins it at its end, the bottom one after it (an open
///   folder's bottom quarter joins it at the top instead: its line would sit inside the box). Below the middle of the header of an open
///   folder, the pointer is on its children: a drop joins at that position. A group dragged takes the same quarters and is refused
///   in the middle of a folder and over its children (a folder cannot be dropped into a folder).
public enum DropResolver {
    public static let autoExpandDelay: TimeInterval = 0.6
    public static let lineHeight: CGFloat = 2
    private static let refused = DropResolution(target: nil, indicator: nil, openFolder: nil)

    private struct Unit {
        var ref: TopRef
        var frame: CGRect
        var collapsed = false
        var kids: [CGRect] = []  // every child row of an open folder, the dragged one included: it still fills its box
        var own: Int?            // the dragged child's place in |kids|: indexes do not count it
        var box: CGRect { kids.last.map { frame.union($0) } ?? frame }
        var group: GroupID? { if case .group(let g) = ref { g } else { nil } }
    }

    public static func resolve(_ point: CGPoint, layout: SidebarLayout, dragged: DragItem, isCollapsed: (GroupID) -> Bool) -> DropResolution {
        typealias M = SidebarMetrics
        var grid = 0
        var gridBottom: CGFloat?
        var persistent: [Unit] = [], day: [Unit] = []
        var dividerY = CGFloat.infinity
        var newTabBottom: CGFloat?
        var inDay = false, skipping = false
        for p in layout.placements {
            switch p.entry {
            case .gridTile(let t):
                gridBottom = max(gridBottom ?? 0, p.frame.maxY)  // the dragged tile keeps its place in the layout
                if dragged != .tab(t) { grid += 1 }
            case .divider:
                dividerY = p.frame.minY
                inDay = true
            case .newTab:
                newTabBottom = p.frame.maxY
            case .group(let g):
                skipping = dragged == .group(g)
                if skipping { continue }
                let u = Unit(ref: .group(g), frame: p.frame, collapsed: isCollapsed(g))
                if inDay { day.append(u) } else { persistent.append(u) }
            case .tab(let t, let level):
                if level > 0 {
                    // A child: it belongs to the last unit, which is a group (the layout puts children right after their header).
                    func add(_ units: inout [Unit]) {
                        guard !skipping, !units.isEmpty else { return }
                        units[units.count - 1].kids.append(p.frame)
                        if dragged == .tab(t) { units[units.count - 1].own = units[units.count - 1].kids.count - 1 }
                    }
                    if inDay { add(&day) } else { add(&persistent) }
                    continue
                }
                skipping = false
                if dragged == .tab(t) { continue }
                let u = Unit(ref: .tab(t), frame: p.frame)
                if inDay { day.append(u) } else { persistent.append(u) }
            }
        }

        // The grid area: down to the gap under the last row of tiles.
        if let gridBottom, point.y < gridBottom + M.gridGap {
            guard case .tab = dragged else { return refused }
            let slot = PinnedGrid.slot(at: CGPoint(x: point.x, y: point.y - M.listTop), count: grid, width: layout.width)
            let ghost = PinnedGrid.frame(index: slot, width: layout.width).offsetBy(dx: 0, dy: M.listTop)
            return DropResolution(target: .grid(slot), indicator: .ghost(ghost), openFolder: nil)
        }

        let below = point.y >= dividerY
        let units = below ? day : persistent
        let rowW = layout.width - M.rowInset
        let top = below ? (newTabBottom ?? dividerY) : (gridBottom.map { $0 + M.gridGap } ?? M.listTop)
        func line(_ y: CGFloat, indent: CGFloat = 0) -> DropIndicator {
            .line(CGRect(x: M.rowX + indent, y: y - lineHeight / 2, width: rowW - indent, height: lineHeight))
        }
        func edge(_ i: Int) -> CGFloat {  // the line before unit |i| (i == count: after the last one)
            if units.isEmpty { return top }
            if i <= 0 { return units[0].box.minY }
            if i >= units.count { return units[units.count - 1].box.maxY }
            return (units[i - 1].box.maxY + units[i].box.minY) / 2
        }
        func at(_ i: Int) -> DropResolution {
            DropResolution(target: below ? .day(i) : .persistent(i), indicator: line(edge(i)), openFolder: nil)
        }

        guard !units.isEmpty else { return at(0) }
        var i = 0
        while i < units.count - 1, point.y >= (units[i].box.maxY + units[i + 1].box.minY) / 2 { i += 1 }
        let u = units[i], y = point.y
        if y > u.box.maxY { return at(i + 1) }
        guard let g = u.group else { return y < u.frame.midY ? at(i) : at(i + 1) }

        let q = u.frame.height / 4
        if case .group = dragged {
            if y < u.frame.minY + q { return at(i) }
            if y >= u.box.maxY - q { return at(i + 1) }
            return refused
        }
        if y < u.frame.minY + q { return at(i) }
        if y < u.frame.maxY - q {
            return DropResolution(target: .group(g, Int.max), indicator: .folder(u.box), openFolder: u.collapsed ? g : nil)
        }
        if u.collapsed { return at(i + 1) }
        var k = 0
        while k < u.kids.count, y >= u.kids[k].midY { k += 1 }
        let edgeY = k == 0 ? (u.kids.first?.minY ?? u.frame.maxY) : u.kids[k - 1].maxY
        return DropResolution(target: .group(g, k - (u.own.map { $0 < k ? 1 : 0 } ?? 0)), indicator: line(edgeY, indent: M.groupIndent), openFolder: nil)
    }
}
