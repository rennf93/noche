import XCTest
@testable import NocheCore

final class SuggestionRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func page(_ url: String, host: String, title: String, visits: Int = 1, typed: Int = 0, ageDays: Double = 0) -> PageCandidate {
        PageCandidate(url: url, host: host, title: title, visitCount: visits, typedCount: typed,
                      lastVisitAt: now.addingTimeInterval(-ageDays * 86400))
    }
    private func tab(_ url: String, _ title: String) -> TabItem {
        TabItem(id: TabID(), engineID: 1, url: url, title: title, isLoading: false)
    }
    private func rank(_ q: String, pages: [PageCandidate] = [], tabs: [TabItem] = [], sites: [SiteEntry] = [],
                      remote: [String] = [], active: TabID? = nil) -> [Suggestion] {
        SuggestionRanker.rank(query: q, pages: pages, tabs: tabs, sites: sites, remote: remote, activeTabID: active, now: now)
    }

    func testWeatherCapture() {
        let sunday = "https://weathercrave.com/weather-forecast-italy/country-89/weather-forecast-italy-next-sunday"
        let friday = "https://weathercrave.com/weather-forecast-italy/country-89/weather-forecast-italy-next-friday"
        let pages = [
            page(friday, host: "weathercrave.com", title: "Italy Weather Forecast : free 15 day weather forecasts - Weather Crave", ageDays: 2),
            page(sunday, host: "weathercrave.com", title: "Italy Weather Forecast : free 15 day weather forecasts - Weather Crave", ageDays: 1),
        ]
        let sites = [SiteEntry(name: "Weather.com", host: "weather.com"),
                     SiteEntry(name: "National Weather Service", host: "weather.gov")]
        let rows = rank("weather", pages: pages, sites: sites)
        XCTAssertEqual(rows.map(\.kind), [.page, .query, .site, .site, .site, .page])
        XCTAssertEqual(rows.map(\.url), [sunday, nil, "https://weather.com", "https://weather.gov", "https://weathercrave.com", friday])
        XCTAssertEqual(rows[1].title, "weather")
        XCTAssertEqual(rows[2].title, "Weather.com - weather.com")
        XCTAssertEqual(rows[4].title, "weathercrave.com - weathercrave.com")
        let inline = InlineAutocomplete.completion(typed: "weather", topHit: rows[0], justDeleted: false)
        XCTAssertEqual(inline?.text, "weathercrave.com/weather-forecast-italy/country-89/weather-forecast-italy-next-sunday")
        XCTAssertEqual(inline?.selectedRange, NSRange(location: 7, length: inline!.text.utf16.count - 7))
    }

    func testTypedSchemeAndWwwStillMatchHistory() {
        let gh = page("https://github.com/", host: "github.com", title: "GitHub")
        for typed in ["https://git", "http://git", "www.git", "https://www.git"] {
            let rows = rank(typed, pages: [gh])
            XCTAssertEqual(rows.first?.kind, .page, typed)
            XCTAssertEqual(rows.first?.url, "https://github.com/", typed)
        }
        XCTAssertNotEqual(rank("https://zzz", pages: [gh]).first?.kind, .page)
    }

    func testEmptyQueryHasNoRows() { XCTAssertTrue(rank("  ").isEmpty) }

    func testNoHistoryQueryIsRowOne() {
        let rows = rank("hello world")
        XCTAssertEqual(rows.map(\.kind), [.query])
        XCTAssertEqual(rows[0].title, "hello world")
    }

    func testUrlLikeTextGivesGoToRowFirst() {
        let rows = rank("example.com")
        XCTAssertEqual(rows.map(\.kind), [.goTo, .query])
        XCTAssertEqual(rows[0].url, "https://example.com")
        XCTAssertEqual(rows[0].title, "example.com")
    }

    func testRemoteRowsFollowQueryRow() {
        let rows = rank("wea", remote: ["weather", "weather tomorrow"])
        XCTAssertEqual(rows.map(\.kind), [.query, .remoteQuery, .remoteQuery])
    }

    func testCapWithoutTopHitKeepsOneHistoryPage() {
        let tabs = [tab("https://one.example/a", "Zed one"), tab("https://two.example/b", "Zed two")]
        let sites = ["a", "b", "c"].map { SiteEntry(name: "Zed \($0)", host: "zed-\($0).com") }
        let pages = [page("https://q.org/x", host: "q.org", title: "Zed x"), page("https://q.org/y", host: "q.org", title: "Zed y")]
        let rows = rank("zed", pages: pages, tabs: tabs, sites: sites)
        XCTAssertEqual(rows.map(\.kind), [.query, .tab, .tab, .site, .site, .page])
    }

    func testCapWithTopHitReservesHistoryPage() {
        let tabs = [tab("https://one.example/a", "Zed one"), tab("https://two.example/b", "Zed two")]
        let sites = ["a", "b", "c"].map { SiteEntry(name: "Zed \($0)", host: "zed-\($0).com") }
        let pages = [page("https://zed.org/x", host: "zed.org", title: "t", visits: 5), page("https://other.org/y", host: "other.org", title: "Zed y")]
        let rows = rank("zed", pages: pages, tabs: tabs, sites: sites)
        XCTAssertEqual(rows.map(\.kind), [.page, .query, .tab, .tab, .site, .page])
    }

    func testTieBreakAndDedupe() {
        let pages = [
            page("https://b.com/", host: "b.com", title: "Q", ageDays: 1),
            page("https://a.com/", host: "a.com", title: "Q", ageDays: 1),
            page("https://c.com/", host: "c.com", title: "Q", ageDays: 0),
            page("https://c.com/", host: "c.com", title: "Q", ageDays: 0),
        ]
        let rows = rank("q", pages: pages)
        XCTAssertEqual(rows.filter { $0.kind == .page }.compactMap(\.url), ["https://c.com/", "https://a.com/"])
        XCTAssertEqual(rows.filter { $0.kind == .site }.compactMap(\.url), ["https://c.com", "https://a.com", "https://b.com"])
    }

    func testFrecencyWeightsAgeAndTyped() {
        let old = page("https://old.com/", host: "old.com", title: "Q", visits: 3, ageDays: 100)
        let fresh = page("https://fresh.com/", host: "fresh.com", title: "Q", visits: 1, ageDays: 1)
        let urls = rank("q", pages: [old, fresh]).filter { $0.kind == .page }.compactMap(\.url)
        XCTAssertEqual(urls.first, "https://fresh.com/")
        let typed = page("https://typed.com/", host: "typed.com", title: "Q", visits: 1, typed: 3, ageDays: 1)
        XCTAssertEqual(rank("q", pages: [fresh, typed]).first(where: { $0.kind == .page })?.url, "https://typed.com/")
    }

    func testOpenTabHidesSameUrlHistoryPage() {
        let a = tab("https://alpha.org/x", "Alpha")
        let rows = rank("alp", pages: [page("https://alpha.org/x", host: "alpha.org", title: "Alpha"), page("https://alpha.org/y", host: "alpha.org", title: "Alpha y")], tabs: [a])
        XCTAssertEqual(rows.filter { $0.url == "https://alpha.org/x" }.count, 1)
    }

    func testPageForOpenTabIsTopHitWithInlineAndSwitches() {
        let a = tab("https://alpha.org/x", "Alpha"), b = tab("https://alpine.org", "Alp two")
        let rows = rank("alp", pages: [page("https://alpha.org/x", host: "alpha.org", title: "Alpha")], tabs: [a, b])
        XCTAssertEqual(rows[0].kind, .page)
        XCTAssertEqual(rows[0].tabID, a.id)
        XCTAssertEqual(rows.filter { $0.url == "https://alpha.org/x" }.count, 1)
        XCTAssertEqual(rows.filter { $0.kind == .tab }.map(\.tabID), [b.id], "the tab slot goes to the next tab")
        XCTAssertEqual(InlineAutocomplete.completion(typed: "alp", topHit: rows[0], justDeleted: false)?.text, "alpha.org/x")
        XCTAssertEqual(CommandRouter.route(rows[0], typed: "alp", searchTemplate: AddressInput.defaultSearchTemplate), .switchTo(a.id))
    }

    func testTabCarryingPagesKeepTwoTabSlots() {
        let tabs = (1...3).map { tab("https://zed.org/\($0)", "Zed \($0)") }
        let pages = tabs.map { page($0.url, host: "zed.org", title: "Zed", visits: 1) }
            + [page("https://other.org/p", host: "other.org", title: "Zed plain")]
        let sites = ["a", "b", "c"].map { SiteEntry(name: "Zed \($0)", host: "zed-\($0).com") }
        let rows = rank("zed", pages: pages, tabs: tabs, sites: sites)
        let switchable = rows.filter { $0.tabID != nil }
        XCTAssertEqual(switchable.count, 3, "top hit plus two tab slots")
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.filter { $0.kind == .site }.count, 1, "sites shrink")
        XCTAssertEqual(rows.last?.url, "https://other.org/p", "history reserve")
    }

    func testOverflowTabCarryingPageFallsBackToHistoryRows() {
        let tabs = (1...3).map { tab("https://t\($0).example/p", "Zed \($0)") }
        let pages = [page("https://zed.org/top", host: "zed.org", title: "t", visits: 9)]
            + tabs.map { page($0.url, host: "\(URL(string: $0.url)!.host!)", title: "Zed", visits: 2) }
            + [page("https://other.org/p", host: "other.org", title: "Zed plain")]
        let rows = rank("zed", pages: pages, tabs: tabs)
        XCTAssertEqual(rows.map(\.kind), [.page, .query, .page, .page, .page, .page])
        XCTAssertEqual(rows.compactMap(\.tabID), tabs.map(\.id))
        XCTAssertEqual(rows.last?.url, "https://other.org/p")
        XCTAssertEqual(CommandRouter.route(rows[4], typed: "zed", searchTemplate: AddressInput.defaultSearchTemplate), .switchTo(tabs[2].id))
    }

    func testPlainTabAndTabCarryingPageShareTabGroup() {
        let a = tab("https://zed.org/a", "Zed a"), b = tab("https://two.example", "Zed b")
        let rows = rank("zed", pages: [page("https://zed.org/a", host: "zed.org", title: "Zed a")], tabs: [b, a])
        XCTAssertEqual(rows.dropFirst(2).compactMap(\.tabID), [b.id], "a is the top hit; b fills a tab slot")
        let rows2 = rank("zed", pages: [page("https://zed.org/a", host: "zed.org", title: "Zed a"), page("https://zed.org/c", host: "zed.org", title: "Zed c", visits: 9)], tabs: [b, a])
        XCTAssertEqual(rows2.compactMap(\.tabID), [b.id, a.id], "tab order b then a, the tab-carrying page among the tab rows")
    }

    func testActiveTabUrlStaysOrdinaryPage() {
        let a = tab("https://alpha.org/x", "Alpha")
        let rows = rank("alp", pages: [page("https://alpha.org/x", host: "alpha.org", title: "Alpha")], tabs: [a], active: a.id)
        XCTAssertNil(rows[0].tabID)
        XCTAssertEqual(CommandRouter.route(rows[0], typed: "alp", searchTemplate: AddressInput.defaultSearchTemplate), .navigate(URL(string: "https://alpha.org/x")!))
    }

    func testTabsExcludeActiveAndBlank() {
        let active = tab("https://foo.com", "Foo active"), blank = tab("about:blank", "Foo blank"), ok = tab("https://foo.org", "Foo ok")
        let rows = rank("foo", tabs: [active, blank, ok], active: active.id)
        XCTAssertEqual(rows.filter { $0.kind == .tab }.map(\.tabID), [ok.id])
    }

    func testTitleWordMatchAndMultiToken() {
        let p = page("https://x.com/a", host: "x.com", title: "The Great Gatsby")
        XCTAssertEqual(rank("gat", pages: [p]).map(\.kind), [.query, .site, .page])
        XCTAssertEqual(rank("great gat", pages: [p]).map(\.kind), [.query, .site, .page])
        XCTAssertEqual(rank("great zzz", pages: [p]).map(\.kind), [.query])
    }

    func testSiteMatchesFirstLabelOrNameWord() {
        let sites = [SiteEntry(name: "Stack Overflow", host: "stackoverflow.com"), SiteEntry(name: "Github", host: "github.com")]
        XCTAssertEqual(rank("over", sites: sites).filter { $0.kind == .site }.count, 1)
        XCTAssertEqual(rank("git", sites: sites).filter { $0.kind == .site }.map(\.url), ["https://github.com"])
    }

    func testTypedSchemeAndWwwStillMatchSites() {
        let sites = [SiteEntry(name: "GitHub", host: "github.com"), SiteEntry(name: "Weather.com", host: "weather.com")]
        for typed in ["www.git", "https://git", "http://www.git", "https://www.git"] {
            XCTAssertTrue(rank(typed, sites: sites).contains { $0.kind == .site && $0.url == "https://github.com" }, typed)
        }
        XCTAssertFalse(rank("www.git", sites: sites).contains { $0.url == "https://weather.com" })
    }

    func testBookmarkOnlyPageIsARow() {
        let b = BookmarkCandidate(url: "https://docs.example.org/guide", title: "Team Guide", addedAt: now)
        let rows = SuggestionRanker.rank(query: "team", pages: [], tabs: [], sites: [], remote: [], activeTabID: nil, now: now, bookmarks: [b])
        XCTAssertTrue(rows.contains { $0.kind == .page && $0.url == "https://docs.example.org/guide" && $0.title.hasPrefix("Team Guide") })
        let none = SuggestionRanker.rank(query: "team", pages: [], tabs: [], sites: [], remote: [], activeTabID: nil, now: now, bookmarks: [])
        XCTAssertFalse(none.contains { $0.kind == .page })
    }

    func testBookmarkAndHistoryPageWithTrailingSlashGiveOneRow() {
        let p = page("https://x.com/", host: "x.com", title: "X Home", visits: 3)
        let rows = SuggestionRanker.rank(query: "x", pages: [p], tabs: [], sites: [], remote: [], activeTabID: nil, now: now,
                                         bookmarks: [BookmarkCandidate(url: "https://x.com", title: "X", addedAt: now), BookmarkCandidate(url: "http://www.x.com/", title: "X again", addedAt: now)])
        let pages = rows.filter { $0.kind == .page }
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.url, "https://x.com/")
        XCTAssertEqual(pages.first?.frecency, 6)
    }

    /// Ruling M45: the dedupe key drops the scheme, a leading www. and one trailing slash and lowercases the host only.
    func testDedupeKeyKeepsPathCaseAndMergesHostCase() {
        let rows = SuggestionRanker.rank(query: "x", pages: [page("https://x.com/Foo", host: "x.com", title: "Upper", visits: 2)], tabs: [], sites: [], remote: [], activeTabID: nil, now: now,
                                         bookmarks: [BookmarkCandidate(url: "https://x.com/foo", title: "Lower", addedAt: now), BookmarkCandidate(url: "https://X.com/Foo", title: "Host case", addedAt: now)])
        XCTAssertEqual(Set(rows.filter { $0.kind == .page }.compactMap(\.url)), ["https://x.com/Foo", "https://x.com/foo"])
        XCTAssertEqual(rows.filter { $0.kind == .page }.count, 2)
        XCTAssertEqual(pageKey("https://WWW.X.com/Foo/"), "x.com/Foo")
        XCTAssertEqual(pageKey("http://x.com/a?Q=1#F"), "x.com/a?Q=1#F")
        XCTAssertNotEqual(pageKey("http://x.com/?a=B"), pageKey("http://x.com/?a=b"))
    }

    /// When pages merge the row opens the https address if any merged address is https.
    func testMergedPagesOpenHttps() {
        func rows(history: String?, marks: [String]) -> [String?] {
            SuggestionRanker.rank(query: "x", pages: history.map { [page($0, host: "x.com", title: "X", visits: 3)] } ?? [], tabs: [], sites: [], remote: [], activeTabID: nil, now: now,
                                  bookmarks: marks.map { BookmarkCandidate(url: $0, title: "X", addedAt: now) }).filter { $0.kind == .page }.map(\.url)
        }
        XCTAssertEqual(rows(history: "http://x.com/a", marks: ["https://x.com/a"]), ["https://x.com/a"])
        XCTAssertEqual(rows(history: "https://x.com/a", marks: ["http://x.com/a"]), ["https://x.com/a"])
        XCTAssertEqual(rows(history: nil, marks: ["http://www.x.com/a", "https://x.com/a/"]), ["https://x.com/a/"])
        XCTAssertEqual(rows(history: "http://x.com/a", marks: ["http://x.com/a/"]), ["http://x.com/a"])
    }

    func testBookmarkedPageGainsDoubleFrecency() {
        let a = page("https://a.example/x", host: "a.example", title: "Note one", visits: 3)
        let b = page("https://b.example/x", host: "b.example", title: "Note two", visits: 4)
        let plain = SuggestionRanker.rank(query: "note", pages: [a, b], tabs: [], sites: [], remote: [], activeTabID: nil, now: now)
        XCTAssertEqual(plain.filter { $0.kind == .page }.first?.url, "https://b.example/x")
        let marked = SuggestionRanker.rank(query: "note", pages: [a, b], tabs: [], sites: [], remote: [], activeTabID: nil, now: now,
                                           bookmarks: [BookmarkCandidate(url: "https://a.example/x", title: "Note one", addedAt: now)])
        let pages = marked.filter { $0.kind == .page }
        XCTAssertEqual(pages.first?.url, "https://a.example/x")
        XCTAssertEqual(pages.first?.frecency, 6)  // 3 visits at 1.0, doubled
    }

    func testUrlDisplay() {
        XCTAssertEqual(urlDisplay("https://www.example.com/"), "example.com")
        XCTAssertEqual(urlDisplay("http://a.com/p?q=1"), "a.com/p?q=1")
        XCTAssertEqual(urlDisplay("about:blank"), "about:blank")
    }
}
