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
public func urlDisplay(_ url: String) -> String {
    var s = Substring(url)
    if let r = s.range(of: "://") { s = s[r.upperBound...] }
    if s.hasPrefix("www.") { s = s.dropFirst(4) }
    if s.hasSuffix("/") { s = s.dropLast() }
    return String(s)
}
