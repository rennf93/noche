import Foundation
@testable import NocheBlocking

// Hand-written lists only: never real list text.
enum Fixtures {
    static let ads = """
    [Adblock Plus 2.0]
    ! Title: Fixture Ads
    ! this line is a comment
    ||ads.fixture.test^
    ||tp.fixture.test^$third-party
    ||js.fixture.test^$script
    ||dom.fixture.test^$domain=site-a.test
    @@||ads.fixture.test/allowed^
    ||both.fixture.test^
    @@||both.fixture.test^$script
    site-a.test##.only-a
    site-a.test##.also-a
    site-a.test#@#.also-a
    ##a[href^="https://generic.fixture.test/"]
    ||bad.fixture.test^$nosuchoption
    ((( not a rule
    """

    static let trackers = """
    [Adblock Plus 2.0]
    ! Title: Fixture Trackers
    ||track.fixture.test^
    """

    static let cookies = """
    [Adblock Plus 2.0]
    ! Title: Fixture Cookies
    ||consent.fixture.test^
    ##div[data-cookie-banner]
    """

    static func generated(title: String = "Fixture Ads", rules: Int, prefix: String = "h") -> String {
        "[Adblock Plus 2.0]\n! Title: \(title)\n" + (0..<rules).map { "||\(prefix)\($0).fixture.test^" }.joined(separator: "\n") + "\n"
    }

    static func gate(_ list: BlockList = .ads, minRules: Int = 3, title: String? = nil) -> ListIntegrity {
        ListIntegrity(list: list, minBytes: 0, maxBytes: 20_000_000, minRules: minRules, title: title ?? "Fixture Ads")
    }

    static func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("noche-blocking-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

final class FakeFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<FetchResponse, Error>] = []
    private(set) var requests: [(url: URL, etag: String?, lastModified: String?)] = []
    func enqueue(_ r: Result<FetchResponse, Error>) { lock.lock(); queue.append(r); lock.unlock() }
    private func take(_ url: URL, _ etag: String?, _ lm: String?) -> Result<FetchResponse, Error>? {
        lock.lock(); defer { lock.unlock() }
        requests.append((url, etag, lm))
        return queue.isEmpty ? nil : queue.removeFirst()
    }
    func fetch(url: URL, etag: String?, lastModified: String?) async throws -> FetchResponse {
        guard let r = take(url, etag, lastModified) else { throw URLError(.notConnectedToInternet) }
        return try r.get()
    }
}

func ok(_ body: String, url: String = BlockList.ads.url.absoluteString, etag: String? = "\"e1\"", lastModified: String? = "Mon, 01 Jan 2026 00:00:00 GMT", expected: Int? = nil) -> Result<FetchResponse, Error> {
    let d = Data(body.utf8)
    return .success(FetchResponse(status: 200, body: d, finalURL: URL(string: url)!, etag: etag, lastModified: lastModified, expectedLength: expected ?? d.count))
}
