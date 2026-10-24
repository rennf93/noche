import Foundation

public enum AddressInput {
    public static let defaultSearchTemplate = "https://www.google.com/search?q=%s"

    /// Typed or pasted text only ever opens these schemes, compared lowercase; anything else (javascript:, data:) searches.
    public static let allowedSchemes: Set<String> = ["http", "https", "file", "about", "chrome", "chrome-extension", "view-source"]

    /// Typed text to a navigable URL: explicit scheme as is, host-like text gets a scheme, anything else is a search.
    public static func resolve(_ text: String, searchTemplate: String) -> URL? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        // An explicit scheme (not host:port, whose text after the colon starts with a digit) must be on the allowlist.
        let scheme = s.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
        if let first = scheme.first, first.isLetter, s.dropFirst(scheme.count).hasPrefix(":"),
           s.dropFirst(scheme.count + 1).first?.isNumber != true {
            let name = scheme.lowercased()
            let text = name + String(s.dropFirst(scheme.count))
            guard allowedSchemes.contains(name) else { return search(s, searchTemplate) }
            if name == "about" || name == "view-source" { return URL(string: text) }
            if let c = URLComponents(string: text), text.dropFirst(name.count + 1).hasPrefix("//"),
               c.host?.isEmpty == false || name == "file" {
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
