import Foundation

public enum BlockList: String, CaseIterable, Sendable, Hashable {
    case ads, trackers, cookies

    public var id: String { rawValue }
    public var url: URL {
        switch self {
        case .ads: URL(string: "https://easylist.to/easylist/easylist.txt")!
        case .trackers: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!
        case .cookies: URL(string: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")!
        }
    }
    /// Substring the list's `! Title:` header must contain (case-insensitive).
    public var titleToken: String {
        switch self {
        case .ads: "EasyList"
        case .trackers: "EasyPrivacy"
        case .cookies: "Cookie"
        }
    }
}

/// Three engines, one per list, each swapped whole behind its own lock. A check retains the engine under the lock
/// and runs outside it, so a swap never waits on a check and a check never sees a half-built engine.
public final class BlockEngineSet: @unchecked Sendable {
    private final class Slot: @unchecked Sendable {
        let lock = NSLock()
        var engine: BlockEngine?
        func get() -> BlockEngine? { lock.lock(); defer { lock.unlock() }; return engine }
        func set(_ e: BlockEngine?) { lock.lock(); engine = e; lock.unlock() }
    }
    private let slots: [BlockList: Slot] = Dictionary(uniqueKeysWithValues: BlockList.allCases.map { ($0, Slot()) })

    public init() {}

    public func set(_ engine: BlockEngine?, for list: BlockList) { slots[list]!.set(engine) }
    public func engine(for list: BlockList) -> BlockEngine? { slots[list]!.get() }

    /// Blocks if any enabled list's engine blocks. A disabled list is not consulted.
    public func isBlocked(url: String, sourceURL: String, type: String, enabled: Set<BlockList>) -> Bool {
        for list in BlockList.allCases where enabled.contains(list) {
            if let e = engine(for: list), e.check(url: url, sourceURL: sourceURL, type: type) { return true }
        }
        return false
    }

    /// Union of the enabled lists' hide selectors for the page, in list order without duplicates.
    public func hideSelectors(url: String, enabled: Set<BlockList>) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for list in BlockList.allCases where enabled.contains(list) {
            for s in engine(for: list)?.cosmetic(url: url)?.hide ?? [] where seen.insert(s).inserted { out.append(s) }
        }
        return out
    }
}
