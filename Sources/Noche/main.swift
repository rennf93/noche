import AppKit
import CefBridge
import NocheCore

// No state restoration: after a crash AppKit would otherwise block launch on a modal prompt.
UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])

MainActor.assumeIsolated {
    let app = NCApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.mainMenu = MainMenu.build()
    // Smoke runs share the owner's Mac: no Dock icon, never frontmost.
    app.setActivationPolicy(SmokeOptions.parse(CommandLine.arguments) == nil ? .regular : .accessory)
    app.run()
}
