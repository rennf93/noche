import AppKit

/// Owns the main window: tab-strip placeholder on top, CEF browser below.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var browserStub: BrowserViewStub?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 780))

        let tabStrip = TabStripView(frame: NSRect(x: 0, y: 732, width: 1200, height: 48))
        tabStrip.autoresizingMask = [.width]
        content.addSubview(tabStrip)

        let browser = BrowserViewStub(frame: NSRect(x: 0, y: 0, width: 1200, height: 732))
        browser.autoresizingMask = [.width, .height]
        content.addSubview(browser)
        browserStub = browser

        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Noche"
        window.contentView = content
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)

        startCef(stub: browser)
    }

    /// CEF bootstrap. Cache and log live under ~/Library/Application Support
    /// so reruns reuse the profile. When CEF is not vendored (stub build) the
    /// shim fails initialize() and the BrowserViewStub placeholder stays.
    private func startCef(stub: BrowserViewStub) {
        let supportRoot = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Noche", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: supportRoot.appendingPathComponent("CEF/Cache", isDirectory: false),
            withIntermediateDirectories: true
        )

        let cacheRoot = supportRoot.appendingPathComponent("CEF").path
        let logFile = supportRoot.appendingPathComponent("cef.log").path
        guard CefBridge.initialize(cacheRoot: cacheRoot, logFile: logFile) else {
            NSLog("[noche] CEF unavailable; running with placeholder browser region")
            return
        }

        // Mount seam: CEF reports the native browser view on creation; route
        // it into the stub's hierarchy. C function pointers cannot capture
        // context, so this reaches the delegate through NSApp.
        CefBridge.onBrowserCreated { nativeView in
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.mountBrowserView(nativeView)
            }
        }

        CefBridge.setLoadHook(path: CefBridge.smokeHookPath)
        CefBridge.createBrowser(parent: stub, url: CefBridge.startupURL)
    }

    /// Mount seam landing: takes the NSView CEF created for the browser and
    /// hands it to the stub's installBrowserView(_:).
    private func mountBrowserView(_ nativeView: UnsafeMutableRawPointer?) {
        guard let nativeView else { return }
        let view = Unmanaged<NSView>.fromOpaque(nativeView).takeUnretainedValue()
        browserStub?.installBrowserView(view)
        NSLog("[noche] CEF browser view mounted")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        CefBridge.shutdown()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.buildMainMenu()
    }

    /// Minimal menu so Cmd-Q and clipboard basics work before real chrome lands.
    private static func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Noche", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        return main
    }
}
