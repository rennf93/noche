import Foundation

public enum UpdateFailure: Error, Equatable, Sendable {
    case notHTTPS
    case hostNotAllowed(String)
    case network
    case httpStatus(Int)
    case truncated
    case badSize(Int)
    case badHeader
    case tooFewRules(found: Int, minimum: Int)
    case ruleCountDropped(previous: Int, found: Int)
    case tooManyParseErrors(errors: Int, rules: Int)
    case engineBuildFailed
    case writeFailed
}

public struct ListStats: Equatable, Sendable { public var ruleCount: Int; public var errorCount: Int }

/// The sanity gate for a downloaded list (note section 6): size, header, rule count floor, no collapse versus the
/// previous version, parse errors under 1 percent. Every number is a parameter so fixtures can pass it.
public struct ListIntegrity: Sendable {
    public var list: BlockList
    public var minBytes: Int
    public var maxBytes: Int
    public var minRules: Int
    public var title: String

    public init(list: BlockList, minBytes: Int, maxBytes: Int, minRules: Int, title: String) {
        self.list = list; self.minBytes = minBytes; self.maxBytes = maxBytes; self.minRules = minRules; self.title = title
    }

    /// Real-list gate. EasyList over 20,000 rules (stated by the note); the other minimums sit well under today's counts.
    public static func standard(_ list: BlockList) -> ListIntegrity {
        let minRules: Int
        switch list {
        case .ads: minRules = 20_001
        case .trackers: minRules = 5_000
        case .cookies: minRules = 1_000
        }
        return ListIntegrity(list: list, minBytes: 100 * 1024, maxBytes: 20 * 1024 * 1024, minRules: minRules, title: list.title)
    }

    public func validate(_ body: Data, previousRuleCount: Int?) -> Result<ListStats, UpdateFailure> {
        guard body.count >= minBytes, body.count <= maxBytes else { return .failure(.badSize(body.count)) }
        guard let text = String(data: body, encoding: .utf8) else { return .failure(.badHeader) }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let want = title.lowercased()
        let headerOK = lines.prefix(50).contains {
            let l = $0.trimmingCharacters(in: .whitespaces).lowercased()
            return l.hasPrefix("! title:") && l.dropFirst(8).trimmingCharacters(in: .whitespaces) == want
        }
        guard headerOK else { return .failure(.badHeader) }
        var rules = 0, errors = 0
        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("!") || l.hasPrefix("[") { continue }
            // shortcut: structural line check only (HTML, control bytes), the FFI reports no per-line parse errors; upgrade if it ever does.
            if l.hasPrefix("<") || l.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" }) { errors += 1 } else { rules += 1 }
        }
        guard rules >= minRules else { return .failure(.tooFewRules(found: rules, minimum: minRules)) }
        if let p = previousRuleCount, rules * 2 < p { return .failure(.ruleCountDropped(previous: p, found: rules)) }
        guard errors * 100 < rules + errors else { return .failure(.tooManyParseErrors(errors: errors, rules: rules)) }
        return .success(ListStats(ruleCount: rules, errorCount: errors))
    }
}
