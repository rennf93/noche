import CryptoKit
import Foundation

public struct FetchResponse: Sendable {
    public var status: Int
    public var body: Data
    public var finalURL: URL
    public var etag: String?
    public var lastModified: String?
    /// Declared body length when known, to detect a cut connection.
    public var expectedLength: Int?
    public init(status: Int, body: Data, finalURL: URL, etag: String?, lastModified: String?, expectedLength: Int?) {
        self.status = status; self.body = body; self.finalURL = finalURL; self.etag = etag; self.lastModified = lastModified; self.expectedLength = expectedLength
    }
}

/// The HTTP layer, injected so tests never touch the network. Throws on a transport error.
public protocol HTTPFetching: Sendable {
    func fetch(url: URL, etag: String?, lastModified: String?) async throws -> FetchResponse
}

public struct ListMeta: Codable, Equatable, Sendable {
    public var url: String
    public var etag: String?
    public var lastModified: String?
    public var sha256: String
    public var fetchedAt: Double
    public var ruleCount: Int
    public var crateVersion: String
}

public enum UpdateOutcome: Equatable, Sendable {
    case updated(ruleCount: Int)
    case notModified
    case failed(UpdateFailure)
}

public enum LoadSource: Equatable, Sendable { case serialized, rebuilt, none }

/// Downloads one list at a time, gates it, writes `<root>/<listid>/{list.txt,meta.json,engine.bin}` and swaps the engine.
/// Any failure keeps the old file and engine.
public actor ListUpdater {
    public static let allowedHosts: Set<String> = ["easylist.to", "secure.fanboy.co.nz"]

    private let root: URL
    private let engines: BlockEngineSet
    private let fetcher: HTTPFetching
    private let gates: [BlockList: ListIntegrity]
    private let now: @Sendable () -> Date

    public init(root: URL, engines: BlockEngineSet, fetcher: HTTPFetching, gates: [BlockList: ListIntegrity] = [:], now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root; self.engines = engines; self.fetcher = fetcher; self.gates = gates; self.now = now
    }

    private func dir(_ l: BlockList) -> URL { root.appendingPathComponent(l.id, isDirectory: true) }
    private func readMeta(_ l: BlockList) -> ListMeta? {
        (try? Data(contentsOf: dir(l).appendingPathComponent("meta.json"))).flatMap { try? JSONDecoder().decode(ListMeta.self, from: $0) }
    }
    private func writeAtomic(_ data: Data, _ name: String, _ l: BlockList) throws {
        try FileManager.default.createDirectory(at: dir(l), withIntermediateDirectories: true)
        try data.write(to: dir(l).appendingPathComponent(name), options: .atomic)
    }

    /// Launch path: engine.bin when its crateVersion matches and it deserializes, else rebuild from list.txt.
    public func loadFromDisk(_ list: BlockList) async -> LoadSource {
        let d = dir(list)
        let meta = readMeta(list)
        if let meta, meta.crateVersion == BlockEngine.crateVersion,
           let bin = try? Data(contentsOf: d.appendingPathComponent("engine.bin")),
           let e = BlockEngine(serialized: bin) {
            engines.set(e, for: list)
            return .serialized
        }
        guard let text = try? String(contentsOf: d.appendingPathComponent("list.txt"), encoding: .utf8) else { return .none }
        guard let e = await Task.detached(priority: .utility, operation: { BlockEngine(lists: [text]) }).value else { return .none }
        engines.set(e, for: list)
        if var meta {
            meta.crateVersion = BlockEngine.crateVersion
            if let enc = try? JSONEncoder().encode(meta), let bin = Optional(e.serialize()) {
                try? writeAtomic(bin, "engine.bin", list)
                try? writeAtomic(enc, "meta.json", list)
            }
        }
        return .rebuilt
    }

    public func update(_ list: BlockList) async -> UpdateOutcome {
        let gate = gates[list] ?? .standard(list)
        let previous = readMeta(list)
        let haveFile = FileManager.default.fileExists(atPath: dir(list).appendingPathComponent("list.txt").path)
        let conditional = haveFile ? previous : nil

        let resp: FetchResponse
        do { resp = try await fetcher.fetch(url: list.url, etag: conditional?.etag, lastModified: conditional?.lastModified) }
        catch { return .failed(.network) }

        guard resp.finalURL.scheme?.lowercased() == "https" else { return .failed(.notHTTPS) }
        let host = resp.finalURL.host?.lowercased() ?? ""
        guard Self.allowedHosts.contains(host) else { return .failed(.hostNotAllowed(host)) }

        if resp.status == 304, var meta = conditional {
            meta.fetchedAt = now().timeIntervalSince1970
            guard let enc = try? JSONEncoder().encode(meta), (try? writeAtomic(enc, "meta.json", list)) != nil else { return .failed(.writeFailed) }
            return .notModified
        }
        guard resp.status == 200 else { return .failed(.httpStatus(resp.status)) }
        if let n = resp.expectedLength, n != resp.body.count { return .failed(.truncated) }

        let stats: ListStats
        switch gate.validate(resp.body, previousRuleCount: haveFile ? previous?.ruleCount : nil) {
        case .failure(let f): return .failed(f)
        case .success(let s): stats = s
        }
        guard let text = String(data: resp.body, encoding: .utf8) else { return .failed(.badHeader) }

        // Parse and serialize off the calling thread; the old engine stays live until the swap.
        let built = await Task.detached(priority: .utility) { () -> (BlockEngine, Data)? in
            guard let e = BlockEngine(lists: [text]) else { return nil }
            return (e, e.serialize())
        }.value
        guard let (engine, bin) = built else { return .failed(.engineBuildFailed) }

        let meta = ListMeta(url: list.url.absoluteString, etag: resp.etag, lastModified: resp.lastModified,
                            sha256: SHA256.hash(data: resp.body).map { String(format: "%02x", $0) }.joined(),
                            fetchedAt: now().timeIntervalSince1970, ruleCount: stats.ruleCount, crateVersion: BlockEngine.crateVersion)
        do {
            // meta last: it is the commit marker (a crash before it leaves the old etag, so the next run refetches).
            try writeAtomic(resp.body, "list.txt", list)
            try writeAtomic(bin, "engine.bin", list)
            try writeAtomic(try JSONEncoder().encode(meta), "meta.json", list)
        } catch { return .failed(.writeFailed) }
        engines.set(engine, for: list)
        return .updated(ruleCount: stats.ruleCount)
    }
}

/// Production fetcher: conditional GET over HTTPS; a redirect off the allowlist is refused.
public final class URLSessionFetcher: NSObject, HTTPFetching, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!
    public override init() {
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    public func fetch(url: URL, etag: String?, lastModified: String?) async throws -> FetchResponse {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { req.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // A compressed transfer reports the encoded length, which would not match the decoded body.
        let encoded = http.value(forHTTPHeaderField: "Content-Encoding") != nil
        return FetchResponse(status: http.statusCode, body: data, finalURL: http.url ?? url,
                             etag: http.value(forHTTPHeaderField: "ETag"), lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                             expectedLength: encoded || http.expectedContentLength < 0 ? nil : Int(http.expectedContentLength))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let ok = request.url?.scheme?.lowercased() == "https" && ListUpdater.allowedHosts.contains(request.url?.host?.lowercased() ?? "")
        completionHandler(ok ? request : nil)
    }
}
