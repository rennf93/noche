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
        // Minutes a background tab may sit unused before the app discards its page (B: README builder calls).
        SettingKey(name: "discardAfterMinutes", type: .int(1...525_600), defaultValue: "120"),
        // "Add emoji to new tab groups" (M83, B): a new group takes an emoji from `GroupEmoji.list`. Off by default.
        SettingKey(name: "emojiForNewGroups", type: .bool, defaultValue: "0"),
        // "Haptic feedback when reordering tabs" (spec note section 2, default on): a tap each time a sidebar drag's insertion slot changes.
        SettingKey(name: "hapticReorder", type: .bool, defaultValue: "1"),
        // "Add new tabs to the top" (M1.6 Task 7, default on): a new tab opens at the top of the day list; off, at the end (after its opener).
        SettingKey(name: "addNewTabsToTop", type: .bool, defaultValue: "1"),
        // "Warn before closing last tab" (default on): Cmd+W on the last tab of the profile asks first.
        SettingKey(name: "warnBeforeClosingLastTab", type: .bool, defaultValue: "1"),
        // "Automatically group tabs for meetings" (G4): the key only, nothing reads it until M1.8 (Settings) and M3 (calendar access).
        SettingKey(name: "autoGroupMeetings", type: .bool, defaultValue: "0"),
        // Finished downloads the person removed from the list, one "engine id|address" per line (DownloadsController).
        SettingKey(name: downloadsRemoved, type: .text, defaultValue: ""),
        // The profile "New windows open with" (ProfileStore): a profile id; empty means the first live profile.
        SettingKey(name: newWindowProfile, type: .text, defaultValue: ""),
    ]

    public static let downloadsRemoved = "downloadsRemoved"
    public static let newWindowProfile = "newWindowProfileId"

    /// A bool key: the stored value when it is valid, else the table's default.
    public static func bool(_ name: String, stored: String?) -> Bool {
        let k = key(name)!
        return (stored.flatMap { k.isValid($0) ? $0 : nil } ?? k.defaultValue) == "1"
    }

    /// A text key: the stored value, else the table's default.
    public static func text(_ name: String, stored: String?) -> String { stored ?? key(name)!.defaultValue }

    /// Whether a drag taps the trackpad: the stored value when it is valid, else the default (on).
    public static func hapticReorder(stored: String?) -> Bool { bool("hapticReorder", stored: stored) }

    /// The discard threshold in minutes: the stored value when it is valid for the key's range, else the default (120).
    public static func discardAfterMinutes(stored: String?) -> Int {
        let k = key("discardAfterMinutes")!
        if let stored, k.isValid(stored), let n = Int(stored) { return n }
        return Int(k.defaultValue)!
    }

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
