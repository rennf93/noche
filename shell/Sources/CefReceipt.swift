import Foundation

/// Reads the CEF-VERSION.txt receipt that scripts/fetch-cef.sh writes into
/// shell/deps/ and build.sh copies into the app bundle Resources.
struct CefReceipt {
    let cefVersion: String
    let platform: String
    let distribution: String
    let sha1: String
    let libraryPath: String

    static func loadFromBundle() -> CefReceipt? {
        guard
            let url = Bundle.main.url(forResource: "CEF-VERSION", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }

        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1])
        }
        guard let version = fields["cef_version"] else { return nil }

        let cefRoot = Bundle.main.resourcePath.map {
            URL(fileURLWithPath: $0).appendingPathComponent("Frameworks/Chromium Embedded Framework.framework")
        }
        return CefReceipt(
            cefVersion: version,
            platform: fields["platform"] ?? "unknown",
            distribution: fields["distribution"] ?? "unknown",
            sha1: fields["sha1"] ?? "unknown",
            libraryPath: cefRoot?.path ?? "unknown"
        )
    }
}
