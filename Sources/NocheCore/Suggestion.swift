import Foundation

public struct Suggestion: Equatable, Sendable {
    public enum Kind: Sendable { case page, query, tab, site, remoteQuery, goTo }
    public let kind: Kind
    /// Row text: "Title - host" style, built by the ranker.
    public let title: String
    public let url: String?
    public let tabID: TabID?
    public let frecency: Double

    public init(kind: Kind, title: String, url: String?, tabID: TabID?, frecency: Double) {
        self.kind = kind
        self.title = title
        self.url = url
        self.tabID = tabID
        self.frecency = frecency
    }
}

/// A stored history page, as the store hands it to the ranker.
public struct PageCandidate: Equatable, Sendable {
    public let url: String
    public let host: String
    public let title: String
    public let visitCount: Int
    public let typedCount: Int
    public let lastVisitAt: Date

    public init(url: String, host: String, title: String, visitCount: Int, typedCount: Int, lastVisitAt: Date) {
        self.url = url
        self.host = host
        self.title = title
        self.visitCount = visitCount
        self.typedCount = typedCount
        self.lastVisitAt = lastVisitAt
    }
}

/// A stored bookmark that can be suggested (an address, its title and when it was added).
public struct BookmarkCandidate: Equatable, Sendable {
    public let url: String
    public let title: String
    public let addedAt: Date
    public init(url: String, title: String, addedAt: Date) {
        self.url = url
        self.title = title
        self.addedAt = addedAt
    }
}

/// A built-in site list row.
public struct SiteEntry: Equatable, Sendable {
    public let name: String
    public let host: String
    public init(name: String, host: String) {
        self.name = name
        self.host = host
    }
}

/// URL text for rows and the field: no scheme, no leading "www.", no single trailing "/"; path and query stay.
/// What a typed token is matched by: a leading `http://` or `https://` and `www.` are dropped (an address is stored with them, the bar shows it without).
/// A token that is nothing but those stays as typed.
public func typedWithoutSchemeAndWww(_ typed: String) -> String {
    var r = Substring(typed)
    for p in ["https://", "http://"] where r.lowercased().hasPrefix(p) { r = r.dropFirst(p.count); break }
    if r.lowercased().hasPrefix("www.") { r = r.dropFirst(4) }
    return r.isEmpty ? typed : String(r)
}

public func urlDisplay(_ url: String) -> String {
    var s = Substring(url)
    if let r = s.range(of: "://") { s = s[r.upperBound...] }
    if s.hasPrefix("www.") { s = s.dropFirst(4) }
    if s.hasSuffix("/") { s = s.dropLast() }
    return String(s)
}
