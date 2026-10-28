import Foundation

/// Which window was key most recently: the window that menu actions and opened links go to while no browser window is key (the History, Bookmarks
/// or Downloads window is key, or the app is inactive).
public struct KeyRecency<ID: Hashable> {
    private var order: [ID] = []  // newest first

    public init() {}

    public mutating func becameKey(_ id: ID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    public mutating func remove(_ id: ID) { order.removeAll { $0 == id } }

    /// The most recently key window that is still in |alive|; nil when none of them was ever key.
    public func mostRecent(among alive: [ID]) -> ID? { order.first { alive.contains($0) } }

    /// |alive| from the front window to the back: the key order first, then the ones never key in the order given.
    public func frontToBack(among alive: [ID]) -> [ID] {
        let keyed = order.filter { alive.contains($0) }
        return keyed + alive.filter { !keyed.contains($0) }
    }
}
