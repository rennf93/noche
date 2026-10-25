import Foundation

/// Edit > Copy URL as Markdown: `[title](url)`.
public enum MarkdownLink {
    /// The title has backslash, "[" and "]" escaped (backslash first) and every run of whitespace, newlines included, collapsed to one space;
    /// the address has space, "(" and ")" percent-encoded so the link cannot end early. An empty title is the address itself.
    public static func make(title: String, url: String) -> String {
        let shown = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let text = (shown.isEmpty ? url : shown)
            .replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        let target = url.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "[\(text)](\(target))"
    }
}
