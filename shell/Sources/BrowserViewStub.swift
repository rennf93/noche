import AppKit

/// Stub for the CEF browser view. No WebKit import anywhere in this target:
/// the plan of record is a CEF (Chromium Embedded Framework) browser hosted in
/// this region of the window. This view reserves the space, shows which CEF
/// distribution is vendored (if any), and exposes the mount seam the CEF shim
/// will use once it lands.
final class BrowserViewStub: NSView {
    private let receipt: CefReceipt?

    override init(frame: NSRect) {
        self.receipt = CefReceipt.loadFromBundle()
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.11, alpha: 1).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("BrowserViewStub is created in code only")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layer else { return }
        // Subtle 1px inner border so the browser region is visible against the strip.
        layer.borderWidth = 1
        layer.borderColor = NSColor(calibratedWhite: 0.2, alpha: 1).cgColor

        let lines: [(String, NSFont, NSColor)]
        if let cefVersion = receipt?.cefVersion {
            lines = [
                ("CEF browser view stub", .systemFont(ofSize: 18, weight: .semibold), .labelColor),
                ("Vendored CEF: \(cefVersion)", .monospacedSystemFont(ofSize: 12, weight: .regular), .secondaryLabelColor),
                ("Library at: \(receipt!.libraryPath)", .monospacedSystemFont(ofSize: 11, weight: .regular), .secondaryLabelColor),
            ]
        } else {
            lines = [
                ("CEF browser view stub", .systemFont(ofSize: 18, weight: .semibold), .labelColor),
                ("CEF not vendored yet: run shell/scripts/fetch-cef.sh", .monospacedSystemFont(ofSize: 12, weight: .regular), .secondaryLabelColor),
            ]
        }

        var y = bounds.midY + CGFloat(lines.count) * 12
        for (text, font, color) in lines {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let styled = NSAttributedString(string: text, attributes: attributes)
            let size = styled.size()
            y -= 24
            styled.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: y))
        }
    }

    /// Mount seam for the CEF shim: hosts the NSView CEF creates for the
    /// browser. With window_info.SetAsChild(parent) CEF parents its native
    /// browser view under the view this stub hands to the shim (there is no
    /// GetNativeView accessor on CefBrowserHost in CEF 156); the shim passes
    /// the CEF-created subview back through the OnAfterCreated callback and
    /// the app calls this to formally mount it in the view hierarchy.
    func installBrowserView(_ hosted: NSView) {
        hosted.frame = bounds
        hosted.autoresizingMask = [.width, .height]
        subviews.forEach { $0.removeFromSuperview() }
        addSubview(hosted)
    }
}
