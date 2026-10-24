import Foundation

/// A key chord. |key| is the lowercased characters-ignoring-modifiers value or a special key name
/// (return, tab, left, right, up, down, f1..f12, space, delete, esc). |mods| is a bit set: cmd 1, shift 2, opt 4, ctrl 8.
public struct Chord: Codable, Hashable, Sendable {
    public static let cmd: UInt8 = 1, shift: UInt8 = 2, opt: UInt8 = 4, ctrl: UInt8 = 8
    public static let invalidReason = "Include Command, Control or Option"

    public let key: String
    public let mods: UInt8
    /// Canonical form: a shifted US symbol becomes its base key plus the shift bit, so a real event (Cmd+Shift+= or
    /// Cmd+Shift+"+") and a recorded chord compare equal.
    public init(_ key: String, _ mods: UInt8 = 0) {
        let k = key.lowercased()
        if let base = Chord.shiftedBase[k] { self.key = base; self.mods = mods | Chord.shift } else { self.key = k; self.mods = mods }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decode(String.self, forKey: .key), try c.decode(UInt8.self, forKey: .mods))
    }

    private static let shiftedBase: [String: String] = {
        var m = ["+": "=", "\"": "'", ":": ";", "<": ",", ">": ".", "?": "/", "{": "[", "}": "]", "|": "\\", "_": "-", "~": "`"]
        for (s, d) in zip("!@#$%^&*()", "1234567890") { m[String(s)] = String(d) }
        return m
    }()

    private static let arrows: Set<String> = ["left", "right", "up", "down"]
    private static let keyGlyphs = ["return": "↩", "tab": "⇥", "left": "←", "right": "→", "up": "↑", "down": "↓",
                                    "space": "Space", "delete": "⌫", "esc": "⎋"]

    private var isFunctionKey: Bool { key.count >= 2 && key.hasPrefix("f") && Int(key.dropFirst()) != nil }

    /// Note 3.3 step 3: a Cmd, Ctrl or Opt modifier, or a function/arrow key with any modifier.
    public var isValid: Bool {
        if mods & (Chord.cmd | Chord.ctrl | Chord.opt) != 0 { return true }
        return mods != 0 && (isFunctionKey || Chord.arrows.contains(key))
    }

    /// Standard macOS order: Ctrl, Opt, Shift, Cmd, then the key.
    /// Shift+"=" is shown as the user-facing "+" with no shift glyph ("⌘+"); every other shifted key keeps "⇧" and the base key.
    private var isPlus: Bool { key == "=" && mods & Chord.shift != 0 }

    public var glyphs: String {
        var s = ""
        if mods & Chord.ctrl != 0 { s += "⌃" }
        if mods & Chord.opt != 0 { s += "⌥" }
        if mods & Chord.shift != 0 && !isPlus { s += "⇧" }
        if mods & Chord.cmd != 0 { s += "⌘" }
        return s + (isPlus ? "+" : Chord.keyGlyphs[key] ?? key.uppercased())
    }


    public var spoken: String {
        var p: [String] = []
        if mods & Chord.ctrl != 0 { p.append("ctrl") }
        if mods & Chord.opt != 0 { p.append("opt") }
        if mods & Chord.shift != 0 && !isPlus { p.append("shift") }
        if mods & Chord.cmd != 0 { p.append("cmd") }
        return (p + [isPlus ? "+" : key]).joined(separator: " ")
    }
}

/// AppKit-free description of one action. The menu or command route lives app-side, keyed by |id|.
public struct ShortcutAction: Hashable, Sendable {
    public let id: String
    public let section: String
    public let title: String
    public let defaultChord: Chord?
    public let milestone: String?
    public let referenceOnly: Bool
}

public enum ShortcutDefaults {
    static func action(_ section: String, _ id: String, _ title: String, _ chord: Chord?, milestone: String? = nil) -> ShortcutAction {
        ShortcutAction(id: id, section: section, title: title, defaultChord: chord, milestone: milestone, referenceOnly: milestone != nil)
    }
}

public enum ShortcutFilter: Sendable { case all, customized, conflicts, noShortcut, referenceOnly }

public enum SetResult: Equatable, Sendable { case ok, invalid(String), reserved, conflict(String) }

public struct ShortcutOverrides: Codable, Equatable, Sendable {
    /// |chord| nil means explicitly none; |reset| is a tombstone meaning "back to default" so merges can see the reset.
    public struct Entry: Codable, Equatable, Sendable {
        public var chord: Chord?
        public var updatedAt: Double
        public var reset: Bool = false
    }
    public private(set) var entries: [String: Entry] = [:]
    public init() {}

    public mutating func set(_ id: String, _ chord: Chord?, at: Double) { entries[id] = Entry(chord: chord, updatedAt: at) }
    public mutating func reset(_ id: String, at: Double) { entries[id] = Entry(chord: nil, updatedAt: at, reset: true) }
    mutating func put(_ id: String, _ e: Entry) { entries[id] = e }

    /// Last write wins per action id; ties keep the local entry.
    public mutating func merge(_ other: ShortcutOverrides) {
        for (id, e) in other.entries where e.updatedAt > (entries[id]?.updatedAt ?? -Double.infinity) { entries[id] = e }
    }
}

public struct ShortcutRegistry: Sendable {
    public static let reserved: Set<Chord> = [
        Chord("q", Chord.cmd), Chord("h", Chord.cmd), Chord("h", Chord.cmd | Chord.opt), Chord("m", Chord.cmd),
        Chord("z", Chord.cmd), Chord("x", Chord.cmd), Chord("c", Chord.cmd), Chord("v", Chord.cmd), Chord("a", Chord.cmd),
    ]
    /// Always-handled macOS chords, warned about even when the app's injected system set lacks them.
    public static let knownSystem: Set<Chord> = [
        Chord("space", Chord.cmd), Chord("tab", Chord.cmd), Chord("`", Chord.cmd),
        Chord("left", Chord.ctrl), Chord("right", Chord.ctrl), Chord("up", Chord.ctrl), Chord("down", Chord.ctrl),
    ]

    public let table: [ShortcutAction]
    public private(set) var overrides: ShortcutOverrides
    /// Bumped on every change, so the app can observe without NotificationCenter in this module.
    public private(set) var changeCount = 0

    public init(table: [ShortcutAction] = ShortcutDefaults.table, overrides: ShortcutOverrides = ShortcutOverrides()) {
        self.table = table; self.overrides = overrides
    }

    private func defaultChord(_ id: String) -> Chord? { table.first { $0.id == id }?.defaultChord }

    public func effective(_ id: String) -> Chord? {
        if let e = overrides.entries[id], !e.reset { return e.chord }
        return defaultChord(id)
    }

    private func isCustomized(_ a: ShortcutAction) -> Bool {
        guard let e = overrides.entries[a.id], !e.reset else { return false }
        return e.chord != a.defaultChord
    }

    private func now() -> Double { Date().timeIntervalSince1970 }

    private func check(_ id: String, _ chord: Chord) -> SetResult? {
        if !chord.isValid { return .invalid(Chord.invalidReason) }
        if ShortcutRegistry.reserved.contains(chord) { return .reserved }
        return nil
    }

    private func owner(of chord: Chord, except id: String) -> String? {
        table.first { $0.id != id && effective($0.id) == chord }?.id
    }

    /// Reports `.conflict` for any other holder of the chord, reference-only actions included.
    public mutating func set(_ id: String, _ chord: Chord, at: Double? = nil) -> SetResult {
        if let bad = check(id, chord) { return bad }
        if let other = owner(of: chord, except: id) { return .conflict(other) }
        write(id, chord, at: at)
        return .ok
    }

    /// Assigns |chord| and clears the action that held it.
    public mutating func replace(_ id: String, _ chord: Chord, at: Double? = nil) -> SetResult {
        if let bad = check(id, chord) { return bad }
        if let other = owner(of: chord, except: id) { write(other, nil, at: at) }
        write(id, chord, at: at)
        return .ok
    }

    public mutating func keepBoth(_ id: String, _ chord: Chord, at: Double? = nil) -> SetResult {
        if let bad = check(id, chord) { return bad }
        write(id, chord, at: at)
        return .ok
    }

    public mutating func clear(_ id: String, at: Double? = nil) { write(id, nil, at: at) }

    public mutating func reset(_ id: String, at: Double? = nil) {
        guard overrides.entries[id] != nil else { return }  // no entry, nothing to propagate
        overrides.reset(id, at: at ?? now()); changeCount += 1
    }

    public mutating func resetAll(at: Double? = nil) {
        let t = at ?? now()
        for id in overrides.entries.keys { overrides.reset(id, at: t) }
        changeCount += 1
    }

    private mutating func write(_ id: String, _ chord: Chord?, at: Double?) {
        overrides.set(id, chord, at: at ?? now()); changeCount += 1
    }

    public struct ImportReport: Equatable, Sendable {
        public var unknown: [String] = [], rejected: [String] = [], conflicts: [[String]] = []
    }

    /// Merges imported overrides through the same validity and reserved checks as `set`. Unknown ids are ignored,
    /// invalid or reserved chords are rejected, and chords clashing with another action are applied (first in table
    /// order wins at dispatch) and reported as conflict groups.
    public mutating func importOverrides(_ other: ShortcutOverrides) -> ImportReport {
        let known = Set(table.map(\.id))
        var report = ImportReport(), accepted = ShortcutOverrides()
        for (id, e) in other.entries.sorted(by: { $0.key < $1.key }) {
            if !known.contains(id) { report.unknown.append(id); continue }
            if !e.reset, let c = e.chord, check(id, c) != nil { report.rejected.append(id); continue }
            accepted.put(id, e)
        }
        overrides.merge(accepted); changeCount += 1
        let touched = Set(accepted.entries.keys)
        report.conflicts = conflicts().filter { !touched.isDisjoint(with: $0) }
        return report
    }

    /// Groups of ids sharing an effective chord, in table order.
    public func conflicts() -> [[String]] {
        var order: [Chord] = [], groups: [Chord: [String]] = [:]
        for a in table { if let c = effective(a.id) { if groups[c] == nil { order.append(c) }; groups[c, default: []].append(a.id) } }
        return order.compactMap { groups[$0].flatMap { $0.count > 1 ? $0 : nil } }
    }

    /// First action in table order with this effective chord; actions set to none are skipped.
    public func action(matching chord: Chord) -> String? { table.first { effective($0.id) == chord }?.id }

    /// Warn-only: true when macOS (the injected set or the always-handled list) uses the chord.
    public func systemConflict(_ chord: Chord, system: Set<Chord>) -> Bool {
        system.contains(chord) || ShortcutRegistry.knownSystem.contains(chord)
    }

    private static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

    public func search(_ text: String, filter: ShortcutFilter = .all) -> [ShortcutAction] {
        let tokens = ShortcutRegistry.fold(text).split(whereSeparator: \.isWhitespace).map(String.init)
        let conflicted = Set(conflicts().joined())
        return table.filter { a in
            switch filter {
            case .all: break
            case .customized: if !isCustomized(a) { return false }
            case .conflicts: if !conflicted.contains(a.id) { return false }
            case .noShortcut: if effective(a.id) != nil { return false }
            case .referenceOnly: if !a.referenceOnly { return false }
            }
            let c = effective(a.id)
            let hay = ShortcutRegistry.fold([a.title, a.section, c?.spoken ?? "", c?.glyphs ?? ""].joined(separator: "\n"))
            return tokens.allSatisfy { hay.contains($0) }
        }
    }
}
