import Foundation

public enum AddressInput {
    public static let defaultSearchTemplate = "https://www.google.com/search?q=%s"

    /// Typed text to a navigable URL: explicit scheme as is, host-like text gets a scheme, anything else is a search.
    public static func resolve(_ text: String, searchTemplate: String) -> URL? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("about:") { return URL(string: s) }
        if s.contains("://") {
            if let c = URLComponents(string: s), c.scheme != nil, c.host?.isEmpty == false || c.scheme == "file" {
                return c.url
            }
            return search(s, searchTemplate)
        }
        guard !s.contains(where: \.isWhitespace) else { return search(s, searchTemplate) }
        let authority = s.prefix { !"/?#".contains($0) }
        let isIPv6 = authority.hasPrefix("[")
        let host = isIPv6 ? String(authority.prefix { $0 != "]" }.dropFirst()) : String(authority.prefix { $0 != ":" })
        let isIPv4 = host.split(separator: ".", omittingEmptySubsequences: false).count == 4
            && host.allSatisfy { $0.isNumber || $0 == "." }
        let local = host == "localhost" || isIPv4 || isIPv6
        guard local || host.contains("."),
              let c = URLComponents(string: (local ? "http://" : "https://") + s), c.host != nil
        else { return search(s, searchTemplate) }
        return c.url
    }

    /// Toolbar text: host only, no scheme, no "www.".
    public static func displayHost(_ url: String) -> String {
        guard let host = URLComponents(string: url)?.host, !host.isEmpty else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func search(_ query: String, _ template: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: q))
    }
}
