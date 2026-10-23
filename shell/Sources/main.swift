// Noche shell entry point.
//
// Plain swiftc, no SwiftPM, no xcodeproj: the phase-2 shell links the
// libcef_dll wrapper (static) and loads the CEF framework at runtime out of
// shell/deps/ (vendored by scripts/fetch-cef.sh); build.sh stays a single
// readable script. WebKit is never imported (the browser is CEF, not a
// WKWebView wrapper).

import AppKit

// CEF subprocess gate, before anything else touches AppKit: when this process
// was launched as a helper the shim runs the helper loop and returns an exit
// code; nil means we are the browser process and continue below.
if let helperExitCode = CefBridge.executeProcess() {
    exit(helperExitCode)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
