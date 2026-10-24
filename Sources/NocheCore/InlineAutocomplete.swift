import Foundation

public enum InlineAutocomplete {
    /// Field text (typed exactly as typed, plus the rest of the top hit's display URL) with the rest selected.
    /// Only for a page top hit whose display URL starts with the typed text, a single token, and not right after a delete.
    public static func completion(typed: String, topHit: Suggestion?, justDeleted: Bool) -> (text: String, selectedRange: NSRange)? {
        guard !justDeleted, let topHit, topHit.kind == .page, let url = topHit.url,
              !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
        let display = urlDisplay(url)
        guard let match = display.range(of: typed, options: [.caseInsensitive, .anchored]), match.upperBound < display.endIndex else { return nil }
        let rest = String(display[match.upperBound...])
        return (typed + rest, NSRange(location: typed.utf16.count, length: rest.utf16.count))
    }
}
