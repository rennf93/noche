import Foundation

public enum SuggestionRanker {
    static let maxRows = 6

    /// Tiered, not scored across kinds: top hit, literal query, remote, tabs, sites, history. Row 0 is the selected one.
    public static func rank(query: String, pages: [PageCandidate], tabs: [TabItem], sites: [SiteEntry],
                            remote: [String], activeTabID: TabID?, now: Date = Date(), bookmarks: [BookmarkCandidate] = []) -> [Suggestion] {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = typed.lowercased()
        guard !q.isEmpty else { return [] }
        let tokens = q.split(whereSeparator: \.isWhitespace).map { typedWithoutSchemeAndWww(String($0)) }

        // A bookmark joins the history pages (one that was never visited is a page of its own) and its page's frecency counts bookmarkBonus times.
        // The key is `pageKey` (ruling M45), so https://x.com and https://x.com/ are one page and /Foo and /foo are two. A merged page opens its https address if any merged address is https.
        func key(_ url: String) -> String { pageKey(url) }
        func isHttps(_ url: String) -> Bool { url.lowercased().hasPrefix("https://") }
        var httpsOf: [String: String] = [:]
        for b in bookmarks where b.isHttps && httpsOf[b.key] == nil { httpsOf[b.key] = b.url }
        let marked = Set(bookmarks.map(\.key))
        var wasURL: [String: [String]] = [:]  // a page rewritten to its https address: every address an open tab may still be at
        let pages = pages.map { p -> PageCandidate in
            guard !isHttps(p.url), let https = httpsOf[key(p.url)] else { return p }
            wasURL[https, default: []].append(p.url)
            return PageCandidate(url: https, host: p.host, title: p.title, visitCount: p.visitCount, typedCount: p.typedCount, lastVisitAt: p.lastVisitAt)
        }
        let known = Set(pages.map { key($0.url) })
        // Only a bookmark that matches the typed text becomes a page (the test is on the precomputed fields); one address once.
        var listedMarks = Set<String>()
        let bookmarkPages = bookmarks.filter { b in
            b.host != nil && !known.contains(b.key) && matches(tokens, display: b.display, host: b.host ?? "", words: b.titleWords) && listedMarks.insert(b.key).inserted
        }.map { b in
            PageCandidate(url: httpsOf[b.key] ?? b.url, host: b.host ?? "", title: b.title, visitCount: 0, typedCount: 0, lastVisitAt: b.addedAt)
        }
        var seen = Set<String>()
        let matches = (pages + bookmarkPages)
            .filter { pageMatches(tokens, display: urlDisplay($0.url).lowercased(), host: $0.host.lowercased(), title: $0.title) }
            .map { ($0, frecency($0, now: now) * (marked.contains(key($0.url)) ? bookmarkBonus : 1)) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.lastVisitAt != b.0.lastVisitAt { return a.0.lastVisitAt > b.0.lastVisitAt }
                return a.0.url < b.0.url
            }
            .filter { seen.insert($0.0.url).inserted }

        // A history page for an open (non-active) tab's URL carries that tab's id and replaces the tab row.
        let others = tabs.filter { $0.id != activeTabID && $0.url != "about:blank" }
        var tabByURL: [String: TabID] = [:]
        for t in others where tabByURL[t.url] == nil { tabByURL[t.url] = t.id }
        let tabIndex = Dictionary(others.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The row's own address first, else the first open tab (in tab order) at any address merged into it.
        func tabOf(_ url: String) -> TabID? { tabByURL[url] ?? (wasURL[url] ?? []).compactMap { tabByURL[$0] }.min { (tabIndex[$0] ?? 0) < (tabIndex[$1] ?? 0) } }
        let matchedURLs = Set(matches.flatMap { [$0.0.url] + (wasURL[$0.0.url] ?? []) })
        let tabRows = others.filter { !matchedURLs.contains($0.url)
            && pageMatches(tokens, display: urlDisplay($0.url).lowercased(), host: AddressInput.displayHost($0.url).lowercased(), title: $0.title) }
            .map { Suggestion(kind: .tab, title: "\($0.title) - \(AddressInput.displayHost($0.url))", url: $0.url, tabID: $0.id, frecency: 0) }

        var head: [Suggestion] = []
        var topURL: String?
        if tokens.count == 1, let top = matches.first(where: { urlDisplay($0.0.url).lowercased().hasPrefix(tokens[0]) }) {
            head.append(pageRow(top.0, top.1, tabOf(top.0.url)))
            topURL = top.0.url
        } else if let url = AddressInput.resolve(typed, searchTemplate: probeTemplate), url.scheme != "noche-probe" {
            head.append(Suggestion(kind: .goTo, title: urlDisplay(url.absoluteString), url: url.absoluteString, tabID: nil, frecency: 0))
        }
        head.append(Suggestion(kind: .query, title: typed, url: nil, tabID: nil, frecency: 0))
        head += remote.prefix(3).map { Suggestion(kind: .remoteQuery, title: $0, url: nil, tabID: nil, frecency: 0) }
        head = Array(head.prefix(maxRows - 1))

        var siteRows = sites.filter { siteMatches(q, $0) }
            .map { Suggestion(kind: .site, title: "\($0.name) - \($0.host)", url: "https://\($0.host)", tabID: nil, frecency: 0) }
        var hostScore: [String: Double] = [:], order: [String] = []
        for (p, f) in matches {
            let h = p.host.lowercased()
            if hostScore[h] == nil { order.append(h) }
            hostScore[h, default: 0] += f
        }
        let listed = Set(siteRows.compactMap { $0.url })
        siteRows += order.enumerated().sorted { a, b in
                let (x, y) = (hostScore[a.element] ?? 0, hostScore[b.element] ?? 0)
                return x != y ? x > y : a.offset < b.offset
            }.map(\.element)
            .filter { !listed.contains("https://\($0)") }
            .map { Suggestion(kind: .site, title: "\($0) - \($0)", url: "https://\($0)", tabID: nil, frecency: hostScore[$0] ?? 0) }

        // Pages that stand in for an open tab join the tab group, ordered with the tab rows by tab order.
        let rest = matches.filter { $0.0.url != topURL }
        let pageRows = rest.filter { tabOf($0.0.url) == nil }.map { pageRow($0.0, $0.1, nil) }
        let tabGroup = (tabRows + rest.filter { tabOf($0.0.url) != nil }.map { pageRow($0.0, $0.1, tabOf($0.0.url)) })
            .sorted { (tabIndex[$0.tabID!] ?? 0) < (tabIndex[$1.tabID!] ?? 0) }

        // One slot stays for a history page, so sites shrink first, then tabs.
        // A tab-carrying page past the two tab slots falls back to the history rows (keeping its tab id) and counts toward the reserve.
        let slots = maxRows - head.count
        let overflow = tabGroup.dropFirst(2).filter { $0.kind == .page }
        let reserve = min(slots, (pageRows.isEmpty ? 0 : 1) + (overflow.isEmpty ? 0 : 1))
        let tabTake = min(tabGroup.count, 2, slots - reserve)
        let fallback = tabGroup.dropFirst(tabTake).filter { $0.kind == .page }
        let allPages = (pageRows + fallback).sorted { $0.frecency > $1.frecency }
        let siteTake = min(siteRows.count, 3, slots - reserve - tabTake)
        let pageTake = slots - tabTake - siteTake
        return head + tabGroup.prefix(tabTake) + siteRows.prefix(siteTake) + allPages.prefix(pageTake)
    }

    /// Never a real URL, so a resolve that does not search is told apart by its scheme.
    private static let probeTemplate = "noche-probe://q/?q=%s"

    private static func pageRow(_ p: PageCandidate, _ f: Double, _ tab: TabID?) -> Suggestion {
        Suggestion(kind: .page, title: "\(p.title.isEmpty ? p.host : p.title) - \(urlDisplay(p.url))", url: p.url, tabID: tab, frecency: f)
    }

    /// A bookmarked page counts double (builder value). A bookmark never visited counts as one visit.
    static let bookmarkBonus = 2.0

    /// Age weights are builder numbers: 1.0 up to 4 days, 0.7 (14), 0.5 (31), 0.3 (90), 0.1 older; typed visits count double.
    static func frecency(_ p: PageCandidate, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(p.lastVisitAt)) / 86400
        let w = days <= 4 ? 1.0 : days <= 14 ? 0.7 : days <= 31 ? 0.5 : days <= 90 ? 0.3 : 0.1
        return Double(max(1, p.visitCount + p.typedCount)) * w
    }

    private static func words(_ s: String) -> [String] { suggestionWords(s) }

    private static func pageMatches(_ tokens: [String], display: String, host: String, title: String) -> Bool {
        matches(tokens, display: display, host: host, words: words(title))
    }

    private static func matches(_ tokens: [String], display: String, host: String, words: [String]) -> Bool {
        tokens.allSatisfy { t in display.hasPrefix(t) || host.hasPrefix(t) || words.contains { $0.hasPrefix(t) } }
    }

    private static func siteMatches(_ typed: String, _ s: SiteEntry) -> Bool {
        let q = typedWithoutSchemeAndWww(typed)  // the host list is matched without a typed scheme or www., as the pages are
        let label = s.host.lowercased().split(separator: ".").first.map(String.init) ?? ""
        return label.hasPrefix(q) || words(s.name).contains { $0.hasPrefix(q) }
    }
}
