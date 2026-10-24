import Foundation

public enum ProfileNameError: Error, Equatable, Sendable { case empty, tooLong, duplicate }

public struct ProfileColor: Equatable, Sendable {
    public let r: Double, g: Double, b: Double
    init(_ r: Int, _ g: Int, _ b: Int) { self.r = Double(r) / 255; self.g = Double(g) / 255; self.b = Double(b) / 255 }
}

/// Swatch fills sampled from the owner capture 09-owner-settings-edit-profile.png (788x517 px, 1x). Each value is the median
/// of the 5x5 block around the swatch center (x = 559 + 26 * i, y = 141); white is the selected swatch, so its center is the
/// fill inside the ring. sRGB components.
public enum ProfilePalette {
    public static let names = ["white", "green", "blue", "purple", "amber", "pink", "red", "orange"]
    public static let colors: [ProfileColor] = [
        ProfileColor(0xFC, 0xFC, 0xFC),  // white  (559, 141)
        ProfileColor(0x00, 0x8E, 0x59),  // green  (585, 141)
        ProfileColor(0x00, 0x81, 0xC2),  // blue   (611, 141)
        ProfileColor(0x63, 0x5D, 0xAA),  // purple (637, 141)
        ProfileColor(0xD5, 0x80, 0x00),  // amber  (663, 141)
        ProfileColor(0xCC, 0x4C, 0x6A),  // pink   (689, 141)
        ProfileColor(0xDD, 0x3D, 0x51),  // red    (715, 141)
        ProfileColor(0xDA, 0x45, 0x0A),  // orange (741, 141)
    ]
}

public enum ProfileRules {
    public static let maxNameLength = 40

    /// Returns the trimmed name. |existing| holds the names of the other live profiles.
    public static func validName(_ raw: String, existing: [String]) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw ProfileNameError.empty }
        if name.count > maxNameLength { throw ProfileNameError.tooLong }
        if existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { throw ProfileNameError.duplicate }
        return name
    }

    /// First palette index no live profile uses, else the least used (ties to the lowest index).
    public static func nextColor(used: [Int]) -> Int {
        let n = ProfilePalette.colors.count
        let counts = (0..<n).map { i in used.filter { $0 == i }.count }
        return counts.firstIndex(of: counts.min() ?? 0) ?? 0
    }

    private static func profileNumber(_ dir: String) -> Int? {
        guard dir.hasPrefix("Profile "), let n = Int(dir.dropFirst(8)), n > 0, String(n) == dir.dropFirst(8) else { return nil }
        return n
    }

    /// |existing| is every directory name ever assigned, tombstoned profiles included, so a number is never reused.
    public static func nextDirName(existing: [String]) -> String {
        if existing.isEmpty { return "Default" }
        return "Profile \((existing.compactMap(profileNumber).max() ?? 0) + 1)"
    }

    /// Next or previous id in |order| with wrap; an unknown |current| lands on the first (forward) or last (backward).
    public static func switched(from current: String, in order: [String], forward: Bool) -> String? {
        guard !order.isEmpty else { return nil }
        guard let i = order.firstIndex(of: current) else { return forward ? order.first : order.last }
        return order[(i + (forward ? 1 : order.count - 1)) % order.count]
    }

    /// Windows to close when |deleting| is removed: only its own. Sharers keep the same Chromium directory (one of them takes it over).
    public static func windowsClosed(deleting: String, windows: [(id: String, profileId: String)]) -> [String] {
        windows.filter { $0.profileId == deleting }.map(\.id)
    }

    /// Tombstoned `Profile <n>` directories no live profile uses or shares; never `Default` or anything else.
    public static func sweepCandidates(tombstonedDirs: [String], liveDirs: [String]) -> [String] {
        var seen = Set<String>()
        return tombstonedDirs.filter { profileNumber($0) != nil && !liveDirs.contains($0) && seen.insert($0).inserted }
    }
}
