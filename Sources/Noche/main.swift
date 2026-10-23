import AppKit
import CefBridge

// No state restoration: after a crash AppKit would otherwise block launch on a modal prompt.
UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])

MainActor.assumeIsolated {
    let app = NCApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
