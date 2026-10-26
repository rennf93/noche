import Foundation

public enum InlineAutocomplete {
    /// Field text (typed exactly as typed, plus the rest of the top hit's display URL) with the rest selected.
    /// Only for a page top hit whose display URL (the whole address when the typed text starts with a scheme) starts with the typed text, a single token, and not right after a delete.
    public static func completion(typed: String, topHit: Suggestion?, justDeleted: Bool) -> (text: String, selectedRange: NSRange)? {
        guard !justDeleted, let topHit, topHit.kind == .page, let url = topHit.url,
              !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
        // What was typed decides what it is completed against: with a scheme the whole address, with "www." the address without its scheme, else the shown address.
        let lower = typed.lowercased()
        let display = lower.hasPrefix("https://") || lower.hasPrefix("http://") ? url
            : lower.hasPrefix("www.") ? url.range(of: "://").map { String(url[$0.upperBound...]) } ?? url
            : urlDisplay(url)
        guard let match = display.range(of: typed, options: [.caseInsensitive, .anchored]), match.upperBound < display.endIndex else { return nil }
        let rest = String(display[match.upperBound...])
        return (typed + rest, NSRange(location: typed.utf16.count, length: rest.utf16.count))
    }
}
