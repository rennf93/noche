import AppKit
import NocheCore

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
}

/// Every color and metric of the window chrome, written once. Coordinates are window points, origin top-left, window
/// 2368x1436 (the reference capture size). Sections are those of noche-private/recon/live-ui.md.
@MainActor
enum ChromeStyle {
    // Section 2: window and card
    static let windowRadius: CGFloat = 12
    static let windowBorder = NSColor(hex: 0x343434)
    static let inset: CGFloat = 6                        // card inset from the top, right and bottom
    static let cardRadius: CGFloat = 10
    static let cardFill = NSColor(hex: 0x1F1F1F)
    static let cardBorder = NSColor(hex: 0x2A2A2A)
    static let toolbarHeight: CGFloat = 42               // card top 6 to the divider's bottom 48
    static let dividerY: CGFloat = 47
    static let dividerColor = NSColor(hex: 0x252525)
    static let webTop: CGFloat = 48
    // Section 2: toolbar buttons (32x32, pitch 35, first button 5 pt inside the card, y 11)
    static let buttonSize: CGFloat = 32
    static let buttonPitch: CGFloat = 35
    static let buttonInset: CGFloat = 5
    static let buttonY: CGFloat = 11
    static let buttonRadius: CGFloat = 8
    static let buttonHover = NSColor(hex: 0x2A2A2A)
    static let iconColor = NSColor(hex: 0x9D9D9D)
    static let iconDisabled = NSColor(hex: 0x555555)
    // Section 4: address text (host only), x is 153 pt inside the card
    static let addressInset: CGFloat = 153
    static let addressY: CGFloat = 12
    static let addressHeight: CGFloat = 30
    static let addressColor = NSColor(hex: 0x909090)
    static let font = NSFont.systemFont(ofSize: 13)
    // Section 3: sidebar
    static let sidebarWidth: CGFloat = 197
    static let trafficX: [CGFloat] = [17, 40, 63]
    static let trafficY: CGFloat = 19
    static let trafficSize: CGFloat = 16
    static let trafficColors = [NSColor(hex: 0xFF5F57), NSColor(hex: 0xFEBC2E), NSColor(hex: 0x28C840)]
    static let rowX: CGFloat = 6
    static let rowWidth: CGFloat = 185
    static let newTabColor = NSColor(hex: 0x8A8A8A)
    static let faviconX: CGFloat = 14
    static let faviconSize: CGFloat = 18
    static let titleX: CGFloat = 37
    static let titleFade: CGFloat = 20
    static let titleColor = NSColor(hex: 0xE0E0E0)
    static let rowSelectedFill = NSColor(hex: 0x1B1D21)
    static let rowSelectedBorder = NSColor(hex: 0x2A2A2A)
    static let rowHover = NSColor.white.withAlphaComponent(0.14)
    static let rowRadius: CGFloat = 10
    // Section 3: bottom row (downloads button, icon 14 #666) and its progress ring (M1.5 builder call: no capture of the ring exists)
    static let sidebarIcon = NSColor(hex: 0x666666)
    static let downloadRingRadius: CGFloat = 11.5
    static let downloadRingWidth: CGFloat = 2
    static let downloadRingTrack = NSColor.white.withAlphaComponent(0.15)
    static let downloadRing = NSColor(hex: 0xE0E0E0)
    static let sidebarBottom: CGFloat = 42               // the bottom row: the scrolling list ends above it
    // M1.6 sidebar (note 1.1 to 1.4; the row geometry is SidebarMetrics in NocheCore). M or T where captured or tokenized, P and B are builder calls
    // (docs/app/README.md "M1.6 sidebar").
    static let sidebarDivider = NSColor.white.withAlphaComponent(0.10)           // M: #383c42 on #22272d, not the token's 15%
    static let tileRadius: CGFloat = 10                                          // M
    static let tileFill = NSColor.white.withAlphaComponent(0.10)                 // T TabDockItemRestingBackground
    static let tileBorder = NSColor.white.withAlphaComponent(0x24 / 255.0)       // T TabDockItemRestingStroke
    static let tileHoverFill = NSColor.white.withAlphaComponent(0x29 / 255.0)    // P (T TabBackgroundHovered)
    static let tileSelectedStroke = NSColor.white.withAlphaComponent(0x73 / 255.0)  // P (T TabDockItemDefaultSelectionStroke)
    static let tileSelectedWidth: CGFloat = 1.5                                  // P
    static let tileFaviconSize: CGFloat = 20                                     // M
    static let tileLoadingGap: CGFloat = 3, tileLoadingWidth: CGFloat = 2        // P: a 180 degree arc around the favicon
    static let dormantAlpha: CGFloat = 0.45                                      // P
    static let resetGlyphSize: CGFloat = 12, resetGlyphInset: CGFloat = 4        // P: the return glyph of a pinned tab off its pinned page, shown on hover
    static let resetGlyphColor = NSColor.white.withAlphaComponent(0.7)           // P
    static let groupFont = NSFont.systemFont(ofSize: 13, weight: .semibold)      // M
    static let groupIconSize: CGFloat = 14                                       // M
    static let groupChevronSize: CGFloat = 8, groupChevronGap: CGFloat = 8       // M gap, P size
    static let groupChevron = NSColor(hex: 0x8A8A8A)                             // P
    static let groupChevronDuration: TimeInterval = 0.120                        // P
    static let groupIndent = SidebarMetrics.groupIndent                          // P: a child row's favicon and title
    static let groupOutline = NSColor.white.withAlphaComponent(0.10)             // T TabGroupSidebarStroke
    static let groupFill = NSColor.white.withAlphaComponent(0.05)                // P: TabGroupNeutralBackground at 50%
    /// The expanded group's outline in its color: white (index 0) keeps the neutral outline, the others take their swatch at |groupTintAlpha|.
    static let groupTintAlpha: CGFloat = 0.55                                    // P
    static func groupOutline(colorIndex index: Int) -> NSColor {
        let i = BarHook.on("GRP_SWAPOUT47") && (index == 4 || index == 7) ? 11 - index : index  // negative control: the outline alone trades amber and orange
        return i <= 0 ? groupOutline : groupColors[min(i, groupColors.count - 1)].withAlphaComponent(groupTintAlpha)
    }
    static let swatchSize: CGFloat = 18, swatchPitch: CGFloat = 24               // M: ~18 px circles, pitch 24
    static let swatchRing = NSColor.white                                        // M: the selected swatch has a white ring
    static let swatchRowInset: CGFloat = 14, swatchRowHeight: CGFloat = 28       // P: the menu row that holds the 8 swatches
    static let iconCell: CGFloat = 30, iconColumns = 8, iconPickerPad: CGFloat = 10  // P: the Change Icon popover
    // Drag and drop (note 2.1, M1.6 Task 5)
    static let dropOutline = NSColor.white.withAlphaComponent(0x2E / 255.0)      // T TabGroupNeutralStroke: the folder a drop joins
    static let dropOutlineWidth: CGFloat = 2                                     // note 2: a 2 pt outline
    static let dropLine = NSColor.white.withAlphaComponent(0.75)                 // P: the insertion line (2 pt, DropResolver.lineHeight)
    static let groupActiveDot: CGFloat = 4                                       // P
    static let groupActiveDotColor = NSColor(hex: 0xE0E0E0)                      // P
    /// The 8 group colors in `colorIndex` order: white, green, blue, purple, amber, pink, red, orange (P: the macOS dark system palette).
    static let groupColors: [NSColor] = {
        var hex = [0xF2F2F7, 0x30D158, 0x0A84FF, 0xBF5AF2, 0xFFB340, 0xFF6482, 0xFF453A, 0xFF9F0A]
        if BarHook.on("GRP_SWAP47") { hex.swapAt(4, 7) }  // negative control: amber and orange trade places
        return hex.map { NSColor(hex: UInt32($0)) }
    }()
    static let spaceDot: CGFloat = 6, bottomIconY: CGFloat = 18                  // M dot size and icon center
    static let spaceDotCenterX: CGFloat = 93, spacesChevronCenterX: CGFloat = 174   // M: dots at x 86 and 98 (hit 14 wide), chevron box x 165, 18 wide; B: the one Space takes the first dot's place
    static let spaceDotActive = NSColor(hex: 0xE8E8E8)                           // M
    // Section 8: motion
    static let showDuration: TimeInterval = 0.110
    static let hideDuration: TimeInterval = 0.125
    static let overshootBack: CGFloat = 0.55             // ease-out-back constant: peak at 1.0103, 1.96 pt on a 191 pt slide

    /// A tinted SF Symbol.
    static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
        return NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    // M1.3 command bar (noche-private/specs/research/m1-3-command-bar.md section 1; geometry itself is CommandBarLayout)
    static let barFill = NSColor(hex: 0x282828)
    static let barBorder = NSColor(hex: 0x3E4042)              // also while focused: no focus ring
    static let barRadius: CGFloat = 16
    static let barRowSelected = NSColor(hex: 0x464747)         // measured; the token alone would give #424344
    static let barRowRadius: CGFloat = 8
    static let barTitle = NSColor.white
    static let barHost = NSColor(hex: 0x9FA1A8)
    static let barPlaceholder = NSColor(hex: 0x9A9A9A)
    static let barSelectedText = NSColor(hex: 0x787D86, alpha: 0xB2 / 255.0)
    static let barChipText = NSColor(hex: 0xA9A9A9)
    static let barMic = NSColor(hex: 0x656565)
    static let barSendFill = NSColor(hex: 0x3A3A3A)
    static let barGoFill = NSColor(hex: 0xD4D4D4)
    static let barGoText = NSColor(hex: 0x0F182C)
    static let barHintFill = NSColor.white.withAlphaComponent(0.10)
    static let newTabBackground = NSColor(hex: 0x161616)
    static let barInputFontNewTab = NSFont.systemFont(ofSize: 14)
    static let barInputFontOverlay = NSFont.systemFont(ofSize: 13)
    static let barRowFont = NSFont.systemFont(ofSize: 13)
    // M1.6 Search Tabs and Tab Switcher (the command bar's fill, border, radius and row colors above; B = a builder constant, docs/app/README.md "M1.6 Search Tabs and Tab Switcher")
    static let searchWidth: CGFloat = 560, searchTop: CGFloat = 96                // B
    static let searchInputHeight: CGFloat = 52, searchRowHeight: CGFloat = 40     // B input, M row (spec: rows 40)
    static let searchHeaderHeight: CGFloat = 26, searchMaxLines = 9, searchPad: CGFloat = 8  // B: lines are rows and section headers; the card scrolls past 9
    static let searchHeaderFont = NSFont.systemFont(ofSize: 11, weight: .semibold)  // B
    static let switcherTileWidth: CGFloat = 120, switcherTileHeight: CGFloat = 92, switcherGap: CGFloat = 8, switcherPad: CGFloat = 12  // B
    static let switcherIconSize: CGFloat = 32, switcherLimit = 8                  // B size, spec: up to 8 tiles
    static let switcherMinTileWidth: CGFloat = 72                                 // B: the narrowest a tile gets before the strip scrolls
    static let switcherShowDelay: TimeInterval = 0.2                              // spec: a tap shorter than 200 ms switches without the strip
    static let switcherFont = NSFont.systemFont(ofSize: 12)                       // B
    static let barMotionDuration: TimeInterval = 0.107

    // M1.4 find pill and zoom pill: builder calls (no capture exists; docs/app/README.md "Builder calls and rulings"), colors from the command bar's.
    static let findWidth: CGFloat = 308, findMinWidth: CGFloat = 260, findHeight: CGFloat = 36
    static let findTop: CGFloat = 8, findRight: CGFloat = 12     // inside the card, below the divider, from the card's right edge
    static let zoomWidth: CGFloat = 56, zoomHeight: CGFloat = 26
    static let permissionWidth: CGFloat = 340, permissionHeight: CGFloat = 96
    /// The narrowest window (M27): the sidebar, a card as wide as the find pill's floor with its two margins, and the right inset.
    static let minimumWindowWidth: CGFloat = sidebarWidth + findMinWidth + 2 * findRight + inset
    static let permissionTop: CGFloat = 8, permissionLeft: CGFloat = 12   // inside the card, below the divider, from the card's left edge
    static let zoomRight: CGFloat = 12                           // from the toolbar's right edge (the extension area will sit right of it)

    // Section 2: bookmarks bar (row 48, 42 high) and its folder chip (x 12 inside the card, y 54, 30 high, 12 px #d2d2d2 text, folder icon 14, chevron).
    static let bookmarksBarHeight: CGFloat = 42
    static let chipX: CGFloat = 12
    static let chipY: CGFloat = 6                                // 54 - 48
    static let chipHeight: CGFloat = 30
    static let chipRadius: CGFloat = 8
    static let chipHover = NSColor(hex: 0x2C2C2C)
    static let chipText = NSColor(hex: 0xD2D2D2)
    static let chipFont = NSFont.systemFont(ofSize: 12)
    static let chipIcon: CGFloat = 14
    static let chipPitch: CGFloat = 4                            // builder call: the gap between chips (the capture shows one chip)
    static let chipMaxWidth: CGFloat = 180                       // builder call: a long title is cut here
    // M1.5 builder call: the Cmd+D card (title, folder popup, Done and Remove), a card under the toolbar at the card's top right.
    static let bookmarkEditWidth: CGFloat = 340, bookmarkEditHeight: CGFloat = 156
    static let bookmarkEditTop: CGFloat = 8, bookmarkEditRight: CGFloat = 12
}

/// Where everything sits for a window size and a card left edge (6 hidden, 197 shown, up to 199 mid-show).
@MainActor
struct ChromeLayout {
    let size: CGSize
    let cardX: CGFloat
    /// The bookmarks bar's height when it pushes the page down (0 when hidden, and on the New Tab surface, where it sits over the surface).
    var barHeight: CGFloat = 0
    var barShown = false

    var card: CGRect {
        CGRect(x: cardX, y: ChromeStyle.inset, width: size.width - ChromeStyle.inset - cardX, height: size.height - 2 * ChromeStyle.inset)
    }
    var toolbar: CGRect { CGRect(x: cardX, y: ChromeStyle.inset, width: card.width, height: ChromeStyle.toolbarHeight) }
    /// The sidebar slides with the card: x -197 when the card is at 6, 0 when it is at 197.
    var sidebar: CGRect {
        let s = (cardX - ChromeStyle.inset) / (ChromeStyle.sidebarWidth - ChromeStyle.inset)
        return CGRect(x: -ChromeStyle.sidebarWidth + ChromeStyle.sidebarWidth * s, y: 0, width: ChromeStyle.sidebarWidth, height: size.height)
    }
    /// What the bar takes at the top of the card on every surface it shows on (over the New Tab surface too, where it pushes nothing).
    private var barOffset: CGFloat { barShown && !BarHook.on("BM_NOBARSHIFT") ? ChromeStyle.bookmarksBarHeight : 0 }  // the hook is a negative control
    /// The bookmarks bar: the row under the toolbar's divider, the card's full width.
    var bookmarksBar: CGRect { CGRect(x: cardX, y: ChromeStyle.webTop, width: card.width, height: ChromeStyle.bookmarksBarHeight) }
    /// The Cmd+D card: top right of the card, below the divider (and below the bar when the bar is shown).
    var bookmarkEditor: CGRect {
        let w = min(ChromeStyle.bookmarkEditWidth, max(0, card.width - 2 * ChromeStyle.bookmarkEditRight))
        return CGRect(x: card.maxX - ChromeStyle.bookmarkEditRight - w, y: ChromeStyle.webTop + (barShown ? ChromeStyle.bookmarksBarHeight : 0) + ChromeStyle.bookmarkEditTop,
                      width: w, height: ChromeStyle.bookmarkEditHeight)
    }
    /// The find pill: top right of the card, below the toolbar's divider.
    /// It shrinks with a narrow card (12 pt from each edge) down to `findMinWidth`, then keeps its right edge.
    var findBar: CGRect {
        let w = BarHook.on("FIND_FIXEDWIDTH") ? ChromeStyle.findWidth : min(ChromeStyle.findWidth, max(ChromeStyle.findMinWidth, card.width - 2 * ChromeStyle.findRight))  // negative control: fixed width
        return CGRect(x: card.maxX - ChromeStyle.findRight - w, y: ChromeStyle.webTop + barOffset + ChromeStyle.findTop, width: w, height: ChromeStyle.findHeight)
    }
    /// The permission prompt: top left of the card, below the divider; it narrows with a narrow card (12 pt from each edge).
    var permissionPrompt: CGRect {
        let w = min(ChromeStyle.permissionWidth, max(0, card.width - 2 * ChromeStyle.permissionLeft))
        return CGRect(x: card.minX + ChromeStyle.permissionLeft, y: ChromeStyle.webTop + barOffset + ChromeStyle.permissionTop, width: w, height: ChromeStyle.permissionHeight)
    }
    /// The web view sits 1 pt inside the card border, below the divider.
    var webInsets: NSEdgeInsets {
        NSEdgeInsets(top: ChromeStyle.webTop + barHeight, left: cardX + 1, bottom: ChromeStyle.inset + 1, right: ChromeStyle.inset + 1)
    }
}
