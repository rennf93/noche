// swift-tools-version: 6.1
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let env = ProcessInfo.processInfo.environment
// NocheCore and its tests build with no CEF present. The app and helper need vendor/cef and the wrapper,
// so scripts/build-app.sh opts in with NOCHE_APP=1; the spike targets also need NOCHE_SPIKES=1 and the engine probe NOCHE_PROBES=1.
let withSpikes = env["NOCHE_SPIKES"] == "1"
let withProbes = env["NOCHE_PROBES"] == "1"
let withApp = env["NOCHE_APP"] == "1" || withSpikes || withProbes
// The CEF sandbox is on by default; NOCHE_NO_SANDBOX=1 opts out (no helper sandbox init, no_sandbox=true).
let sandboxFlags = env["NOCHE_NO_SANDBOX"] == "1" ? [] : ["-DNOCHE_SANDBOX=1"]
// NOCHE_TESTHOOKS=1 compiles test-only hooks (forcing the shutdown watchdog) into the app.
// The -Xcc flag makes the bridge header's #ifdef NOCHE_TESTHOOKS declarations visible to Swift, matching the bridge's own build.
let testHookSettings: [SwiftSetting] = env["NOCHE_TESTHOOKS"] == "1" ? [.define("NOCHE_TESTHOOKS"), .unsafeFlags(["-Xcc", "-DNOCHE_TESTHOOKS=1"])] : []
// The bridge's test switches and counters compile only with the same switch.
let bridgeTestFlags = env["NOCHE_TESTHOOKS"] == "1" ? ["-DNOCHE_TESTHOOKS=1"] : []
let cefFlags = sandboxFlags + [
    "-std=c++20", "-fno-exceptions", "-fno-rtti", "-fno-threadsafe-statics", "-fno-strict-aliasing",
    "-fvisibility=hidden", "-fvisibility-inlines-hidden", "-fobjc-call-cxx-cdtors",
    "-fstack-protector", "-funwind-tables", "-arch", "arm64", "-mmacosx-version-min=14.0",
    "-I", "\(root)/vendor/cef",
]
// NOCHE_BLOCKING=1 adds the native filter engine and its tests; scripts/build-adblock.sh builds build/adblock/libnoche_adblock.a first.
let withBlocking = env["NOCHE_BLOCKING"] == "1"
let wrapper = "\(root)/build/cef/libcef_dll_wrapper.a"

var products: [Product] = []
var targets: [Target] = [
    .target(name: "NocheCore"),
    .testTarget(name: "NocheCoreTests", dependencies: ["NocheCore"]),
    // The SQLite store builds with no CEF either, so plain `swift test` runs its tests.
    .target(name: "NocheStore", dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "NocheCore"]),
    .testTarget(name: "NocheStoreTests", dependencies: ["NocheStore", "NocheCore"]),
]

if withBlocking {
    targets += [
        .target(
            name: "CNocheAdblock",
            publicHeadersPath: "include",
            linkerSettings: [.unsafeFlags(["-L", "\(root)/build/adblock"]), .linkedLibrary("noche_adblock")]
        ),
        .target(name: "NocheBlocking", dependencies: ["CNocheAdblock"]),
        .testTarget(name: "NocheBlockingTests", dependencies: ["NocheBlocking"]),
    ]
}

if withApp {
    products += [
        .executable(name: "Noche", targets: ["Noche"]),
        .executable(name: "NocheHelper", targets: ["NocheHelper"]),
    ]
    targets += [
        .target(
            name: "CefBridge",
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(cefFlags + bridgeTestFlags)],
            linkerSettings: [.unsafeFlags([wrapper]), .linkedLibrary("c++"), .linkedFramework("AppKit"), .linkedFramework("QuartzCore")]
        ),
        .executableTarget(name: "Noche", dependencies: ["NocheCore", "CefBridge"], swiftSettings: testHookSettings),
        .executableTarget(
            name: "NocheHelper",
            cxxSettings: [.unsafeFlags(cefFlags)],
            linkerSettings: [.unsafeFlags([wrapper]), .linkedLibrary("c++"), .linkedFramework("AppKit")]
        ),
    ]
}

if withSpikes {
    for (name, path) in [("SpikeChromeStyle", "ChromeStyle"), ("SpikeAlloyCard", "AlloyCard"),
                         ("SpikeAgentCDP", "AgentCDP"), ("SpikeMedia", "Media")] {
        products.append(.executable(name: name, targets: [name]))
        targets.append(.executableTarget(
            name: name,
            dependencies: ["CefBridge"],
            path: "Spikes/\(path)",
            cxxSettings: [.unsafeFlags(cefFlags)],
            linkerSettings: [.unsafeFlags([wrapper]), .linkedLibrary("c++"), .linkedFramework("AppKit")]
        ))
    }
}

if withProbes {
    products.append(.executable(name: "EngineProbe", targets: ["EngineProbe"]))
    targets.append(.executableTarget(
        name: "EngineProbe",
        dependencies: ["CefBridge"],
        path: "Probes/EngineProbe",
        // NOCHE_TABS_API=1 compiles the tab checks, which need the engine with CefBrowserView::AddTab (task B2).
        // NOCHE_ACTIONS_API=1 compiles the extension action checks (task B5), which also use the tab API.
        cxxSettings: [.unsafeFlags(cefFlags + (env["NOCHE_TABS_API"] == "1" || env["NOCHE_ACTIONS_API"] == "1" ? ["-DNOCHE_TABS_API=1"] : [])
                                   + (env["NOCHE_ACTIONS_API"] == "1" ? ["-DNOCHE_ACTIONS_API=1"] : []))],
        linkerSettings: [.unsafeFlags([wrapper]), .linkedLibrary("c++"), .linkedFramework("AppKit")]
    ))
}

let package = Package(
    name: "Noche",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")],
    targets: targets,
    cxxLanguageStandard: .cxx20
)
