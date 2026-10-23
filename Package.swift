// swift-tools-version: 6.0
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
// NOCHE_SANDBOX=1 turns the CEF sandbox on (helper init, no_sandbox=false).
let sandboxFlags = ProcessInfo.processInfo.environment["NOCHE_SANDBOX"] == "1" ? ["-DNOCHE_SANDBOX=1"] : []
let cefFlags = sandboxFlags + [
    "-std=c++20", "-fno-exceptions", "-fno-rtti", "-fno-threadsafe-statics", "-fno-strict-aliasing",
    "-fvisibility=hidden", "-fvisibility-inlines-hidden", "-fobjc-call-cxx-cdtors",
    "-fstack-protector", "-funwind-tables", "-arch", "arm64", "-mmacosx-version-min=14.0",
    "-I", "\(root)/vendor/cef",
]
let wrapper = "\(root)/build/cef/libcef_dll_wrapper.a"

let package = Package(
    name: "Noche",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Noche", targets: ["Noche"]),
        .executable(name: "NocheHelper", targets: ["NocheHelper"]),
        .executable(name: "SpikeChromeStyle", targets: ["SpikeChromeStyle"]),
    ],
    targets: [
        .target(name: "NocheCore"),
        .testTarget(name: "NocheCoreTests", dependencies: ["NocheCore"]),
        .target(
            name: "CefBridge",
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(cefFlags)],
            linkerSettings: [.unsafeFlags([wrapper]), .linkedLibrary("c++"), .linkedFramework("AppKit"), .linkedFramework("QuartzCore")]
        ),
        .executableTarget(name: "Noche", dependencies: ["NocheCore", "CefBridge"]),
        .executableTarget(
            name: "NocheHelper",
            cxxSettings: [.unsafeFlags(cefFlags)],
            linkerSettings: [.unsafeFlags([wrapper]), .linkedLibrary("c++"), .linkedFramework("AppKit")]
        ),
        .executableTarget(
            name: "SpikeChromeStyle",
            dependencies: ["CefBridge"],
            path: "Spikes/ChromeStyle",
            cxxSettings: [.unsafeFlags(cefFlags)],
            linkerSettings: [.unsafeFlags([wrapper]), .linkedLibrary("c++"), .linkedFramework("AppKit")]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
