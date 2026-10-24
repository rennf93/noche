import Foundation

public enum SuggestionRanker {
    static let maxRows = 6

    /// Tiered, not scored across kinds: top hit, literal query, remote, tabs, sites, history. Row 0 is the selected one.
    public static func rank(query: String, pages: [PageCandidate], tabs: [TabItem], sites: [SiteEntry],
                            remote: [String], activeTabID: TabID?, now: Date = Date()) -> [Suggestion] {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = typed.lowercased()
        guard !q.isEmpty else { return [] }
        let tokens = q.split(whereSeparator: \.isWhitespace).map(String.init)

        var seen = Set<String>()
        let matches = pages
            .filter { pageMatches(tokens, display: urlDisplay($0.url).lowercased(), host: $0.host.lowercased(), title: $0.title) }
            .map { ($0, frecency($0, now: now)) }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.lastVisitAt != b.0.lastVisitAt { return a.0.lastVisitAt > b.0.lastVisitAt }
                return a.0.url < b.0.url
            }
            .filter { seen.insert($0.0.url).inserted }

        var head: [Suggestion] = []
        var topURL: String?
        if tokens.count == 1, let top = matches.first(where: { urlDisplay($0.0.url).lowercased().hasPrefix(q) }) {
            head.append(pageRow(top.0, top.1))
            topURL = top.0.url
        } else if let url = AddressInput.resolve(typed, searchTemplate: probeTemplate), url.scheme != "noche-probe" {
            head.append(Suggestion(kind: .goTo, title: urlDisplay(url.absoluteString), url: url.absoluteString, tabID: nil, frecency: 0))
        }
        head.append(Suggestion(kind: .query, title: typed, url: nil, tabID: nil, frecency: 0))
        head += remote.prefix(3).map { Suggestion(kind: .remoteQuery, title: $0, url: nil, tabID: nil, frecency: 0) }
        head = Array(head.prefix(maxRows - 1))

        let tabRows = tabs.filter { $0.id != activeTabID && $0.url != "about:blank"
            && pageMatches(tokens, display: urlDisplay($0.url).lowercased(), host: AddressInput.displayHost($0.url).lowercased(), title: $0.title) }
            .map { Suggestion(kind: .tab, title: "\($0.title) - \(AddressInput.displayHost($0.url))", url: $0.url, tabID: $0.id, frecency: 0) }

        var siteRows = sites.filter { siteMatches(q, $0) }
            .map { Suggestion(kind: .site, title: "\($0.name) - \($0.host)", url: "https://\($0.host)", tabID: nil, frecency: 0) }
        var hostScore: [String: Double] = [:], order: [String] = []
        for (p, f) in matches {
            let h = p.host.lowercased()
            if hostScore[h] == nil { order.append(h) }
            hostScore[h, default: 0] += f
        }
        let listed = Set(siteRows.compactMap { $0.url })
        siteRows += order.sorted { (hostScore[$0] ?? 0) > (hostScore[$1] ?? 0) }
            .filter { !listed.contains("https://\($0)") }
            .map { Suggestion(kind: .site, title: "\($0) - \($0)", url: "https://\($0)", tabID: nil, frecency: hostScore[$0] ?? 0) }

        let pageRows = matches.filter { $0.0.url != topURL }.map { pageRow($0.0, $0.1) }

        // One slot stays for a history page, so sites shrink first, then tabs.
        let slots = maxRows - head.count
        let reserve = pageRows.isEmpty ? 0 : 1
        let tabTake = min(tabRows.count, 2, slots - reserve)
        let siteTake = min(siteRows.count, 3, slots - reserve - tabTake)
        let pageTake = slots - tabTake - siteTake
        return head + tabRows.prefix(tabTake) + siteRows.prefix(siteTake) + pageRows.prefix(pageTake)
    }

    /// Never a real URL, so a resolve that does not search is told apart by its scheme.
    private static let probeTemplate = "noche-probe://q/?q=%s"

    private static func pageRow(_ p: PageCandidate, _ f: Double) -> Suggestion {
        Suggestion(kind: .page, title: "\(p.title.isEmpty ? p.host : p.title) - \(urlDisplay(p.url))", url: p.url, tabID: nil, frecency: f)
    }

    /// Age weights are builder numbers: 1.0 up to 4 days, 0.7 (14), 0.5 (31), 0.3 (90), 0.1 older; typed visits count double.
    static func frecency(_ p: PageCandidate, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(p.lastVisitAt)) / 86400
        let w = days <= 4 ? 1.0 : days <= 14 ? 0.7 : days <= 31 ? 0.5 : days <= 90 ? 0.3 : 0.1
        return Double(p.visitCount + p.typedCount) * w
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func pageMatches(_ tokens: [String], display: String, host: String, title: String) -> Bool {
        let titleWords = words(title)
        return tokens.allSatisfy { t in
            display.hasPrefix(t) || host.hasPrefix(t) || titleWords.contains { $0.hasPrefix(t) }
        }
    }

    private static func siteMatches(_ q: String, _ s: SiteEntry) -> Bool {
        let label = s.host.lowercased().split(separator: ".").first.map(String.init) ?? ""
        return label.hasPrefix(q) || words(s.name).contains { $0.hasPrefix(q) }
    }
}
