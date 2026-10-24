import Foundation

/// Noche's own stable tab id; engine browser ids map onto it.
public struct TabID: Hashable, Sendable {
    public let raw: UUID
    public init(raw: UUID = UUID()) { self.raw = raw }
}

public struct TabItem: Equatable, Sendable {
    public let id: TabID
    public var engineID: Int
    public var url: String
    public var title: String
    public var isLoading: Bool

    public init(id: TabID, engineID: Int, url: String, title: String, isLoading: Bool) {
        self.id = id
        self.engineID = engineID
        self.url = url
        self.title = title
        self.isLoading = isLoading
    }
}

public struct TabList: Equatable, Sendable {
    public private(set) var items: [TabItem] = []
    public private(set) var activeID: TabID?

    public init() {}

    /// A nil or unknown opener appends at the end.
    public mutating func insert(_ item: TabItem, after opener: TabID?, activate: Bool) {
        if let opener, let i = items.firstIndex(where: { $0.id == opener }) {
            items.insert(item, at: i + 1)
        } else {
            items.append(item)
        }
        if activate { activeID = item.id }
    }

    /// Returns the id that became active, only when the removed tab was the active one.
    public mutating func remove(_ id: TabID) -> TabID? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        items.remove(at: i)
        guard activeID == id else { return nil }
        activeID = items.isEmpty ? nil : items[min(i, items.count - 1)].id
        return activeID
    }

    public mutating func update(_ id: TabID, url: String, title: String, isLoading: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].url = url
        items[i].title = title
        items[i].isLoading = isLoading
    }

    public mutating func activate(_ id: TabID) {
        if items.contains(where: { $0.id == id }) { activeID = id }
    }

    public func next(after id: TabID) -> TabID? { neighbor(of: id, offset: 1) }
    public func previous(before id: TabID) -> TabID? { neighbor(of: id, offset: -1) }

    private func neighbor(of id: TabID, offset: Int) -> TabID? {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items[(i + offset + items.count) % items.count].id
    }

    public func displayTitle(of id: TabID) -> String {
        guard let t = items.first(where: { $0.id == id }), t.url != "about:blank" else { return "New Tab" }
        if !t.title.isEmpty { return t.title }
        let host = AddressInput.displayHost(t.url)
        return t.url.isEmpty || host.isEmpty ? "New Tab" : host
    }
}
