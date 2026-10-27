import Foundation

public enum SettingType: Equatable, Sendable {
    case bool                    // "0" or "1"
    case int(ClosedRange<Int>)
    case choice([String])
    case text
}

/// One key of the `setting` table: its type, default and validation. Values are stored as text.
public struct SettingKey: Equatable, Sendable {
    public let name: String
    public let type: SettingType
    public let defaultValue: String

    public init(name: String, type: SettingType, defaultValue: String) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
    }

    public func isValid(_ value: String) -> Bool {
        switch type {
        case .bool: value == "0" || value == "1"
        case .int(let r): Int(value).map(r.contains) ?? false
        case .choice(let c): c.contains(value)
        case .text: true
        }
    }
}

/// Every setting key the app reads. Later tasks add theirs here; `--selftest-setting` accepts exactly these.
public enum SettingKeys {
    public static let all: [SettingKey] = [
        SettingKey(name: "quitBehavior", type: .choice(["preserve", "close"]), defaultValue: "preserve"),
        SettingKey(name: "suggestRemote", type: .bool, defaultValue: "0"),
        SettingKey(name: BookmarksBarMode.settingKey, type: .choice(BookmarksBarMode.allCases.map(\.rawValue)), defaultValue: BookmarksBarMode.newTabOnly.rawValue),
    ]

    public static func key(_ name: String) -> SettingKey? { all.first { $0.name == name } }

    public static func isValid(_ name: String, _ value: String) -> Bool { key(name)?.isValid(value) ?? false }

    /// The `key=value` pairs of every `--selftest-setting` flag in |args|, in order; a flag with no `=`, an unknown key or an invalid value is dropped.
    public static func flagSettings(_ args: [String]) -> [(String, String)] {
        var out: [(String, String)] = []
        for (i, a) in args.enumerated() where a == "--selftest-setting" && i + 1 < args.count {
            guard let eq = args[i + 1].firstIndex(of: "=") else { continue }
            let k = String(args[i + 1][..<eq]), v = String(args[i + 1][args[i + 1].index(after: eq)...])
            if isValid(k, v) { out.append((k, v)) }
        }
        return out
    }
}
