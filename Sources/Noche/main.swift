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
    // Smoke and self-test runs share the owner's Mac: no Dock icon, never frontmost.
    var hidden = SmokeOptions.parse(CommandLine.arguments) != nil
#if NOCHE_TESTHOOKS
    hidden = hidden || SelfTest.parse(CommandLine.arguments) != nil
#endif
    app.setActivationPolicy(hidden ? .accessory : .regular)
    app.run()
}
