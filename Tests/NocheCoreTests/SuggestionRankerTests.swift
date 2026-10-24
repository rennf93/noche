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

    func testUrlDisplay() {
        XCTAssertEqual(urlDisplay("https://www.example.com/"), "example.com")
        XCTAssertEqual(urlDisplay("http://a.com/p?q=1"), "a.com/p?q=1")
        XCTAssertEqual(urlDisplay("about:blank"), "about:blank")
    }
}
