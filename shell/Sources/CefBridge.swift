import AppKit
import Foundation

/// Swift-facing wrapper around the noche_* C API declared in
/// Sources/shim/cef_bridge.h. The implementation behind those symbols is
/// chosen by build.sh: Sources/shim/cef_bridge.mm when the CEF distribution
/// is vendored, Sources/shim/cef_bridge_stub.mm otherwise. Both present the
/// same behavior to this file.
enum CefBridge {
    /// Subprocess gate. Returns the exit code when this process was launched
    /// as a CEF helper (main.swift must exit immediately); nil to continue as
    /// the browser process.
    static func executeProcess() -> Int32? {
        let code = noche_cef_execute_process()
        return code < 0 ? nil : code
    }

    /// CefInitialize. `cacheRoot` and `logFile` are created if missing.
    /// Returns false in stub mode (no CEF vendored).
    static func initialize(cacheRoot: String, logFile: String) -> Bool {
        noche_cef_initialize(cacheRoot, logFile) != 0
    }

    /// Registers the mount-seam callback: fires once from
    /// CefLifeSpanHandler::OnAfterCreated with the browser's native NSView.
    static func onBrowserCreated(
        _ block: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void
    ) {
        noche_cef_set_on_browser_created(block)
    }

    /// Creates a windowed browser parented to `parent` loading `url`.
    @discardableResult
    static func createBrowser(parent: NSView, url: String) -> Bool {
        noche_cef_create_browser(Unmanaged.passUnretained(parent).toOpaque(), url) != 0
    }

    /// Smoke-test hook: on OnLoadEnd the shim writes "title\turl" to `path`.
    static func setLoadHook(path: String?) {
        noche_cef_set_load_hook(path)
    }

    /// CefShutdown on termination.
    static func shutdown() {
        noche_cef_shutdown()
    }

    // MARK: - Smoke-run conventions

    /// URL to load: $NOCHE_URL overrides, otherwise the fixture.html bundled
    /// in Resources (build.sh writes it).
    static var startupURL: String {
        if let custom = ProcessInfo.processInfo.environment["NOCHE_URL"], !custom.isEmpty {
            return custom
        }
        if let fixture = Bundle.main.url(forResource: "fixture", withExtension: "html") {
            return fixture.absoluteString
        }
        return "https://example.com/"
    }

    /// Where the smoke hook is written: $NOCHE_SMOKE_HOOK, or nil.
    static var smokeHookPath: String? {
        ProcessInfo.processInfo.environment["NOCHE_SMOKE_HOOK"]
    }
}
