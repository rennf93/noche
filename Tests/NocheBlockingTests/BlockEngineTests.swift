import XCTest
@testable import NocheBlocking

final class BlockEngineTests: XCTestCase {
    private struct Row { let url: String; let source: String; let type: String; let block: Bool; let note: String }

    func testMatchingTable() throws {
        let e = try XCTUnwrap(BlockEngine(lists: [Fixtures.ads]))
        let rows: [Row] = [
            Row(url: "https://ads.fixture.test/x.js", source: "https://site-a.test/", type: "script", block: true, note: "host rule"),
            Row(url: "https://sub.ads.fixture.test/x.png", source: "https://site-a.test/", type: "image", block: true, note: "subdomain"),
            Row(url: "https://ads.fixture.test/allowed/x.js", source: "https://site-a.test/", type: "script", block: false, note: "exception wins"),
            Row(url: "https://clean.fixture.test/x.js", source: "https://site-a.test/", type: "script", block: false, note: "no rule"),
            Row(url: "https://tp.fixture.test/p.gif", source: "https://site-a.test/", type: "image", block: true, note: "third party"),
            Row(url: "https://tp.fixture.test/p.gif", source: "https://tp.fixture.test/", type: "image", block: false, note: "first party"),
            Row(url: "https://js.fixture.test/a.js", source: "https://site-a.test/", type: "script", block: true, note: "script type"),
            Row(url: "https://js.fixture.test/a.png", source: "https://site-a.test/", type: "image", block: false, note: "not script"),
            Row(url: "https://dom.fixture.test/a.js", source: "https://site-a.test/", type: "script", block: true, note: "domain match"),
            Row(url: "https://dom.fixture.test/a.js", source: "https://site-b.test/", type: "script", block: false, note: "domain mismatch"),
            Row(url: "https://both.fixture.test/a.png", source: "https://site-a.test/", type: "image", block: true, note: "typed exception leaves image"),
            Row(url: "https://both.fixture.test/a.js", source: "https://site-a.test/", type: "script", block: false, note: "typed exception allows script"),
            Row(url: "https://bad.fixture.test/a.js", source: "https://site-a.test/", type: "script", block: false, note: "bad option line ignored"),
            Row(url: "not a url", source: "", type: "script", block: false, note: "unparseable url allows"),
        ]
        for r in rows {
            XCTAssertEqual(e.check(url: r.url, sourceURL: r.source, type: r.type), r.block, r.note)
        }
    }

    func testCosmeticSelectorsForFixtureDomain() throws {
        let e = try XCTUnwrap(BlockEngine(lists: [Fixtures.ads]))
        let a = try XCTUnwrap(e.cosmetic(url: "https://site-a.test/page"))
        XCTAssertTrue(a.hide.contains(".only-a"))
        XCTAssertFalse(a.hide.contains(".also-a"), "#@# removes the selector")
        XCTAssertTrue(a.exceptions.contains(".also-a") || !a.hide.contains(".also-a"))
        let b = try XCTUnwrap(e.cosmetic(url: "https://other.test/page"))
        XCTAssertFalse(b.hide.contains(".only-a"))
        XCTAssertFalse(b.hide.contains(".also-a"))
    }

    func testSerializeRoundTripAndGarbage() throws {
        let e = try XCTUnwrap(BlockEngine(lists: [Fixtures.ads]))
        let data = e.serialize()
        XCTAssertGreaterThan(data.count, 0)
        let e2 = try XCTUnwrap(BlockEngine(serialized: data))
        for (u, t) in [("https://ads.fixture.test/x.js", "script"), ("https://clean.fixture.test/x.js", "script"), ("https://ads.fixture.test/allowed/x", "image")] {
            XCTAssertEqual(e.check(url: u, sourceURL: "https://site-a.test/", type: t), e2.check(url: u, sourceURL: "https://site-a.test/", type: t))
        }
        XCTAssertNil(BlockEngine(serialized: Data([1, 2, 3, 4, 5, 6, 7, 8])))
        XCTAssertNil(BlockEngine(serialized: Data()))
    }

    func testSwitchesCombineIndependently() throws {
        let set = BlockEngineSet()
        set.set(try XCTUnwrap(BlockEngine(lists: [Fixtures.ads])), for: .ads)
        set.set(try XCTUnwrap(BlockEngine(lists: [Fixtures.trackers])), for: .trackers)
        set.set(try XCTUnwrap(BlockEngine(lists: [Fixtures.cookies])), for: .cookies)
        let probes: [(BlockList, String)] = [(.ads, "https://ads.fixture.test/a.js"), (.trackers, "https://track.fixture.test/p.gif"), (.cookies, "https://consent.fixture.test/c.js")]
        for mask in 0..<8 {
            let enabled = Set(BlockList.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
            for (list, url) in probes {
                XCTAssertEqual(set.isBlocked(url: url, sourceURL: "https://site-a.test/", type: "script", enabled: enabled), enabled.contains(list), "mask \(mask) \(list)")
            }
            let hide = set.hideSelectors(url: "https://site-a.test/", enabled: enabled)
            XCTAssertEqual(hide.contains("div[data-cookie-banner]"), enabled.contains(.cookies), "mask \(mask) cosmetic")
            XCTAssertEqual(hide.contains(".only-a"), enabled.contains(.ads), "mask \(mask) cosmetic ads")
        }
        XCTAssertFalse(BlockEngineSet().isBlocked(url: "https://ads.fixture.test/a.js", sourceURL: "", type: "script", enabled: Set(BlockList.allCases)), "no engine loaded blocks nothing")
    }

    func testSwapIsAtomicUnderConcurrentChecks() throws {
        let old = try XCTUnwrap(BlockEngine(lists: ["||old.fixture.test^"]))
        let new = try XCTUnwrap(BlockEngine(lists: ["||old.fixture.test^\n||new.fixture.test^"]))
        let set = BlockEngineSet()
        set.set(old, for: .ads)
        let enabled: Set<BlockList> = [.ads]
        let bad = NSLock(); var failures = 0
        let group = DispatchGroup()
        let stop = ManagedFlag()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                while !stop.isSet {
                    let a = set.isBlocked(url: "https://old.fixture.test/x", sourceURL: "", type: "script", enabled: enabled)
                    let b = set.isBlocked(url: "https://new.fixture.test/x", sourceURL: "", type: "script", enabled: enabled)
                    // old: (true,false); new: (true,true). Anything else is a torn read.
                    if !a { bad.lock(); failures += 1; bad.unlock() }
                    _ = b
                }
            }
        }
        for i in 0..<200 { set.set(i % 2 == 0 ? new : old, for: .ads); usleep(200) }
        set.set(new, for: .ads)
        stop.set()
        group.wait()
        XCTAssertEqual(failures, 0)
        XCTAssertTrue(set.isBlocked(url: "https://new.fixture.test/x", sourceURL: "", type: "script", enabled: enabled))
    }
}

final class ManagedFlag: @unchecked Sendable {
    private let l = NSLock(); private var v = false
    var isSet: Bool { l.lock(); defer { l.unlock() }; return v }
    func set() { l.lock(); v = true; l.unlock() }
}
