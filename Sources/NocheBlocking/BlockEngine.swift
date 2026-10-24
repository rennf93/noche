import CNocheAdblock
import Foundation

public struct CosmeticResources: Decodable, Sendable, Equatable {
    public var hide: [String]
    public var exceptions: [String]
    public var script: String
    public var generichide: Bool
}

/// One immutable filter engine (adblock-rust) behind the C ABI. Safe to call from any thread; never mutated after init.
public final class BlockEngine: @unchecked Sendable {
    /// Serialized engines are tied to the crate version; bump together with Native/noche_adblock/Cargo.toml.
    public static let crateVersion = "adblock-0.13.3"

    private let ptr: UnsafeMutableRawPointer

    private init(ptr: UnsafeMutableRawPointer) { self.ptr = ptr }
    deinit { nab_engine_free(ptr) }

    /// Parses filter list texts (ABP syntax). Expensive: call off the main thread.
    public convenience init?(lists: [String]) {
        var cs: [UnsafeMutablePointer<CChar>?] = lists.map { strdup($0) }
        defer { cs.forEach { free($0) } }
        let p = cs.withUnsafeMutableBufferPointer { b -> UnsafeMutableRawPointer? in
            b.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: b.count) { nab_engine_new($0, b.count) }
        }
        guard let p else { return nil }
        self.init(ptr: p)
    }

    /// nil when the bytes are invalid or from an incompatible crate version (the caller rebuilds from list text).
    public convenience init?(serialized data: Data) {
        guard !data.isEmpty else { return nil }
        let p = data.withUnsafeBytes { raw in nab_deserialize(raw.bindMemory(to: UInt8.self).baseAddress, data.count) }
        guard let p else { return nil }
        self.init(ptr: p)
    }

    public func check(url: String, sourceURL: String, type: String) -> Bool {
        nab_check(ptr, url, sourceURL, type) == 1
    }

    public func cosmetic(url: String) -> CosmeticResources? {
        guard let s = nab_cosmetic(ptr, url) else { return nil }
        defer { nab_string_free(s) }
        return try? JSONDecoder().decode(CosmeticResources.self, from: Data(String(cString: s).utf8))
    }

    public func serialize() -> Data {
        var len = 0
        guard let p = nab_serialize(ptr, &len) else { return Data() }
        defer { nab_bytes_free(p, len) }
        return Data(bytes: p, count: len)
    }
}
