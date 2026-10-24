import XCTest
@testable import NocheBlocking

final class ListUpdaterTests: XCTestCase {
    private var dir: URL!
    private var fetcher: FakeFetcher!
    private var engines: BlockEngineSet!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() { dir = Fixtures.tempDir(); fetcher = FakeFetcher(); engines = BlockEngineSet() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func updater(minRules: Int = 3, _ clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }) -> ListUpdater {
        ListUpdater(root: dir, engines: engines, fetcher: fetcher, gates: [.ads: Fixtures.gate(.ads, minRules: minRules)], now: clock)
    }
    private func blocksOld(_ host: String) -> Bool {
        engines.isBlocked(url: "https://\(host).fixture.test/x.js", sourceURL: "https://site-a.test/", type: "script", enabled: [.ads])
    }
    private func seed(_ u: ListUpdater, rules: Int = 10) async {
        fetcher.enqueue(ok(Fixtures.generated(rules: rules)))
        let r = await u.update(.ads)
        XCTAssertEqual(r, .updated(ruleCount: rules))
    }
    private func assertKept(_ u: ListUpdater, _ failure: UpdateFailure, file: StaticString = #filePath, line: UInt = #line) async {
        let before = try? Data(contentsOf: dir.appendingPathComponent("ads/list.txt"))
        let r = await u.update(.ads)
        XCTAssertEqual(r, .failed(failure), file: file, line: line)
        XCTAssertEqual(try? Data(contentsOf: dir.appendingPathComponent("ads/list.txt")), before, "old file kept", file: file, line: line)
        XCTAssertTrue(blocksOld("h0"), "old engine kept", file: file, line: line)
        XCTAssertFalse(blocksOld("zz"), file: file, line: line)
    }

    func testSuccessWritesFilesAndSwapsEngine() async throws {
        let u = updater()
        await seed(u)
        XCTAssertTrue(blocksOld("h9"))
        let d = dir.appendingPathComponent("ads")
        for f in ["list.txt", "meta.json", "engine.bin"] { XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent(f).path), f) }
        let meta = try JSONDecoder().decode(ListMeta.self, from: Data(contentsOf: d.appendingPathComponent("meta.json")))
        XCTAssertEqual(meta.url, BlockList.ads.url.absoluteString)
        XCTAssertEqual(meta.etag, "\"e1\"")
        XCTAssertEqual(meta.lastModified, "Mon, 01 Jan 2026 00:00:00 GMT")
        XCTAssertEqual(meta.ruleCount, 10)
        XCTAssertEqual(meta.crateVersion, BlockEngine.crateVersion)
        XCTAssertEqual(meta.sha256.count, 64)
        XCTAssertEqual(meta.fetchedAt, now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testConditionalGetSendsValidatorsAnd304KeepsFileAndUpdatesFetchedAt() async throws {
        let box = ClockBox(now)
        let u = updater({ box.value })
        await seed(u)
        box.value = now.addingTimeInterval(86_400)
        fetcher.enqueue(.success(FetchResponse(status: 304, body: Data(), finalURL: BlockList.ads.url, etag: nil, lastModified: nil, expectedLength: 0)))
        let before = try Data(contentsOf: dir.appendingPathComponent("ads/list.txt"))
        let r = await u.update(.ads)
        XCTAssertEqual(r, .notModified)
        XCTAssertEqual(fetcher.requests.last?.etag, "\"e1\"")
        XCTAssertEqual(fetcher.requests.last?.lastModified, "Mon, 01 Jan 2026 00:00:00 GMT")
        XCTAssertNil(fetcher.requests.first?.etag, "first fetch is unconditional")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("ads/list.txt")), before)
        let meta = try JSONDecoder().decode(ListMeta.self, from: Data(contentsOf: dir.appendingPathComponent("ads/meta.json")))
        XCTAssertEqual(meta.fetchedAt, box.value.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(meta.etag, "\"e1\"")
        XCTAssertTrue(blocksOld("h0"))
    }

    func testKeepsPreviousOn404() async { let u = updater(); await seed(u)
        fetcher.enqueue(.success(FetchResponse(status: 404, body: Data("nope".utf8), finalURL: BlockList.ads.url, etag: nil, lastModified: nil, expectedLength: 4)))
        await assertKept(u, .httpStatus(404)) }

    func testKeepsPreviousOnTruncatedBody() async { let u = updater(); await seed(u)
        fetcher.enqueue(ok(Fixtures.generated(rules: 10), expected: 5_000))
        await assertKept(u, .truncated) }

    func testKeepsPreviousOnTruncatedFileByRuleDrop() async { let u = updater(); await seed(u, rules: 10)
        fetcher.enqueue(ok(String(Fixtures.generated(rules: 10).prefix(70))))
        let r = await u.update(.ads)
        guard case .failed = r else { return XCTFail("\(r)") }
        XCTAssertTrue(blocksOld("h0")) }

    func testKeepsPreviousOnHTMLErrorBody() async { let u = updater(); await seed(u)
        fetcher.enqueue(ok("<!DOCTYPE html>\n<html><head><title>502</title></head><body>Bad gateway</body></html>\n"))
        await assertKept(u, .badHeader) }

    func testKeepsPreviousOnWrongTitle() async { let u = updater(); await seed(u)
        fetcher.enqueue(ok(Fixtures.generated(title: "Some Other List", rules: 10)))
        await assertKept(u, .badHeader) }

    func testKeepsPreviousOnZeroRules() async { let u = updater(); await seed(u)
        fetcher.enqueue(ok("[Adblock Plus 2.0]\n! Title: Fixture Ads\n! only comments\n"))
        await assertKept(u, .tooFewRules(found: 0, minimum: 3)) }

    func testKeepsPreviousWhenRuleCountHalves() async { let u = updater(); await seed(u, rules: 10)
        fetcher.enqueue(ok(Fixtures.generated(rules: 4)))
        await assertKept(u, .ruleCountDropped(previous: 10, found: 4)) }

    func testAcceptsExactlyHalf() async { let u = updater(); await seed(u, rules: 10)
        fetcher.enqueue(ok(Fixtures.generated(rules: 5)))
        let r = await u.update(.ads)
        XCTAssertEqual(r, .updated(ruleCount: 5)) }

    func testKeepsPreviousOnParseErrors() async { let u = updater(); await seed(u, rules: 10)
        let bad = Fixtures.generated(rules: 10) + (0..<5).map { _ in "<div>broken\u{1}" }.joined(separator: "\n") + "\n"
        fetcher.enqueue(ok(bad))
        let r = await u.update(.ads)
        guard case .failed(.tooManyParseErrors) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(blocksOld("h0")) }

    func testSizeBounds() async {
        let strict = ListUpdater(root: dir, engines: engines, fetcher: fetcher,
                                 gates: [.ads: ListIntegrity(list: .ads, minBytes: 1_000, maxBytes: 5_000, minRules: 3, titleToken: "Fixture")], now: { Date() })
        fetcher.enqueue(ok(Fixtures.generated(rules: 3)))
        let small = await strict.update(.ads)
        guard case .failed(.badSize) = small else { return XCTFail("\(small)") }
        fetcher.enqueue(ok(Fixtures.generated(rules: 2_000)))
        let big = await strict.update(.ads)
        guard case .failed(.badSize) = big else { return XCTFail("\(big)") }
    }

    func testRedirectToOtherHostFails() async { let u = updater(); await seed(u)
        fetcher.enqueue(ok(Fixtures.generated(rules: 10), url: "https://evil.example/easylist.txt"))
        await assertKept(u, .hostNotAllowed("evil.example")) }

    func testHTTPDowngradeFails() async { let u = updater(); await seed(u)
        fetcher.enqueue(ok(Fixtures.generated(rules: 10), url: "http://easylist.to/easylist/easylist.txt"))
        await assertKept(u, .notHTTPS) }

    func testNetworkDownKeepsPrevious() async { let u = updater(); await seed(u)
        await assertKept(u, .network) }

    func testAllowlistedHosts() {
        for l in BlockList.allCases { XCTAssertEqual(l.url.scheme, "https"); XCTAssertTrue(ListUpdater.allowedHosts.contains(l.url.host!)) }
        XCTAssertEqual(ListUpdater.allowedHosts, ["easylist.to", "secure.fanboy.co.nz"])
    }

    func testLaunchLoadReusesEngineBinWhenCrateMatchesElseRebuilds() async throws {
        let u = updater()
        await seed(u)
        // Fresh set, same disk: loads from engine.bin.
        let e2 = BlockEngineSet()
        let u2 = ListUpdater(root: dir, engines: e2, fetcher: fetcher, gates: [.ads: Fixtures.gate()], now: { Date() })
        var how = await u2.loadFromDisk(.ads)
        XCTAssertEqual(how, .serialized)
        XCTAssertTrue(e2.isBlocked(url: "https://h1.fixture.test/x", sourceURL: "", type: "script", enabled: [.ads]))
        // Crate version mismatch: rebuild from list.txt.
        let metaURL = dir.appendingPathComponent("ads/meta.json")
        var meta = try JSONDecoder().decode(ListMeta.self, from: Data(contentsOf: metaURL))
        meta.crateVersion = "other-0.0.0"
        try JSONEncoder().encode(meta).write(to: metaURL)
        let e3 = BlockEngineSet()
        how = await ListUpdater(root: dir, engines: e3, fetcher: fetcher, gates: [.ads: Fixtures.gate()], now: { Date() }).loadFromDisk(.ads)
        XCTAssertEqual(how, .rebuilt)
        XCTAssertTrue(e3.isBlocked(url: "https://h1.fixture.test/x", sourceURL: "", type: "script", enabled: [.ads]))
        // Corrupt engine.bin (deserialize NULL): rebuild too.
        meta.crateVersion = BlockEngine.crateVersion
        try JSONEncoder().encode(meta).write(to: metaURL)
        try Data([9, 9, 9, 9, 9, 9, 9, 9]).write(to: dir.appendingPathComponent("ads/engine.bin"))
        let e4 = BlockEngineSet()
        how = await ListUpdater(root: dir, engines: e4, fetcher: fetcher, gates: [.ads: Fixtures.gate()], now: { Date() }).loadFromDisk(.ads)
        XCTAssertEqual(how, .rebuilt)
        XCTAssertTrue(e4.isBlocked(url: "https://h1.fixture.test/x", sourceURL: "", type: "script", enabled: [.ads]))
        // Nothing on disk.
        let e5 = BlockEngineSet()
        how = await ListUpdater(root: Fixtures.tempDir(), engines: e5, fetcher: fetcher, gates: [:], now: { Date() }).loadFromDisk(.ads)
        XCTAssertEqual(how, .none)
    }

    func testIntegrityGateDefaultsMatchTheNote() {
        let g = ListIntegrity.standard(.ads)
        XCTAssertEqual(g.minBytes, 100 * 1024)
        XCTAssertEqual(g.maxBytes, 20 * 1024 * 1024)
        XCTAssertGreaterThan(g.minRules, 20_000)
        XCTAssertGreaterThan(ListIntegrity.standard(.trackers).minRules, 0)
        XCTAssertGreaterThan(ListIntegrity.standard(.cookies).minRules, 0)
    }
}

final class ClockBox: @unchecked Sendable {
    private let l = NSLock(); private var d: Date
    init(_ d: Date) { self.d = d }
    var value: Date { get { l.lock(); defer { l.unlock() }; return d } set { l.lock(); d = newValue; l.unlock() } }
}
