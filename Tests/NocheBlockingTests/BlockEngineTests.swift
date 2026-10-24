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
        // Each engine blocks "both" always; old blocks only "oldonly", new only "newonly". A check may only ever see
        // the old or the new engine's answer for a URL, so "both" is always true and answers never come from a freed engine.
        func make(_ new: Bool) throws -> BlockEngine {
            try XCTUnwrap(BlockEngine(lists: ["||both.fixture.test^\n" + (new ? "||newonly.fixture.test^" : "||oldonly.fixture.test^")]))
        }
        let set = BlockSetBox()
        set.set.set(try make(false), for: .ads)
        let enabled: Set<BlockList> = [.ads]
        let bad = NSLock(); var failures = 0, checks = 0
        let group = DispatchGroup()
        let stop = ManagedFlag()
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                var n = 0
                while !stop.isSet {
                    let both = set.set.isBlocked(url: "https://both.fixture.test/x", sourceURL: "", type: "script", enabled: enabled)
                    let other = set.set.isBlocked(url: "https://neither.fixture.test/x", sourceURL: "", type: "script", enabled: enabled)
                    if !both || other { bad.lock(); failures += 1; bad.unlock() }
                    n += 1
                }
                bad.lock(); checks += n; bad.unlock()
            }
        }
        // Engines are built inside the loop and the previous one is released at each swap while checks run.
        for i in 0..<100 { set.set.set(try make(i % 2 == 0), for: .ads) }
        let last = try make(true)
        set.set.set(last, for: .ads)
        usleep(20_000)
        stop.set()
        group.wait()
        XCTAssertEqual(failures, 0)
        XCTAssertGreaterThan(checks, 0)
        XCTAssertTrue(set.set.isBlocked(url: "https://newonly.fixture.test/x", sourceURL: "", type: "script", enabled: enabled))
        XCTAssertFalse(set.set.isBlocked(url: "https://oldonly.fixture.test/x", sourceURL: "", type: "script", enabled: enabled))
    }

    func testEmptyListsAndCorruptBytesDoNotCrash() throws {
        let e = try XCTUnwrap(BlockEngine(lists: []))
        XCTAssertFalse(e.check(url: "https://a.test/x", sourceURL: "", type: "script"))
        let full = try XCTUnwrap(BlockEngine(lists: [Fixtures.ads])).serialize()
        for cut in [full.count / 2, full.count - 1, 1, 7] { _ = BlockEngine(serialized: full.prefix(cut)) }
        var flipped = full; for i in stride(from: 0, to: flipped.count, by: 97) { flipped[i] ^= 0xFF }
        _ = BlockEngine(serialized: flipped)?.cosmetic(url: "https://site-a.test/")
    }
}

final class BlockSetBox: @unchecked Sendable { let set = BlockEngineSet() }

final class ManagedFlag: @unchecked Sendable {
    private let l = NSLock(); private var v = false
    var isSet: Bool { l.lock(); defer { l.unlock() }; return v }
    func set() { l.lock(); v = true; l.unlock() }
}
