import AppKit

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
    static let newTabY: CGFloat = 54
    static let newTabHeight: CGFloat = 39
    static let newTabColor = NSColor(hex: 0x8A8A8A)
    static let firstRowY: CGFloat = 93
    static let rowPitch: CGFloat = 37
    static let rowHeight: CGFloat = 37
    static let faviconX: CGFloat = 14
    static let faviconSize: CGFloat = 18
    static let titleX: CGFloat = 37
    static let titleFade: CGFloat = 20
    static let titleColor = NSColor(hex: 0xE0E0E0)
    static let rowSelectedFill = NSColor(hex: 0x1B1D21)
    static let rowSelectedBorder = NSColor(hex: 0x2A2A2A)
    static let rowHover = NSColor.white.withAlphaComponent(0.14)
    static let rowRadius: CGFloat = 10
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

    static func rowY(_ index: Int) -> CGFloat { firstRowY + rowPitch * CGFloat(index) }

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
    static let barMotionDuration: TimeInterval = 0.107

    // M1.4 find pill and zoom pill: builder calls (no capture exists; docs/app/README.md "Builder calls and rulings"), colors from the command bar's.
    static let findWidth: CGFloat = 308, findHeight: CGFloat = 36
    static let findTop: CGFloat = 8, findRight: CGFloat = 12     // inside the card, below the divider, from the card's right edge
    static let zoomWidth: CGFloat = 56, zoomHeight: CGFloat = 26
    static let zoomRight: CGFloat = 12                           // from the toolbar's right edge (the extension area will sit right of it)
}

/// Where everything sits for a window size and a card left edge (6 hidden, 197 shown, up to 199 mid-show).
@MainActor
struct ChromeLayout {
    let size: CGSize
    let cardX: CGFloat

    var card: CGRect {
        CGRect(x: cardX, y: ChromeStyle.inset, width: size.width - ChromeStyle.inset - cardX, height: size.height - 2 * ChromeStyle.inset)
    }
    var toolbar: CGRect { CGRect(x: cardX, y: ChromeStyle.inset, width: card.width, height: ChromeStyle.toolbarHeight) }
    /// The sidebar slides with the card: x -197 when the card is at 6, 0 when it is at 197.
    var sidebar: CGRect {
        let s = (cardX - ChromeStyle.inset) / (ChromeStyle.sidebarWidth - ChromeStyle.inset)
        return CGRect(x: -ChromeStyle.sidebarWidth + ChromeStyle.sidebarWidth * s, y: 0, width: ChromeStyle.sidebarWidth, height: size.height)
    }
    /// The find pill: top right of the card, below the toolbar's divider.
    var findBar: CGRect {
        CGRect(x: card.maxX - ChromeStyle.findRight - ChromeStyle.findWidth, y: ChromeStyle.webTop + ChromeStyle.findTop,
               width: ChromeStyle.findWidth, height: ChromeStyle.findHeight)
    }
    /// The web view sits 1 pt inside the card border, below the divider.
    var webInsets: NSEdgeInsets {
        NSEdgeInsets(top: ChromeStyle.webTop, left: cardX + 1, bottom: ChromeStyle.inset + 1, right: ChromeStyle.inset + 1)
    }
}
