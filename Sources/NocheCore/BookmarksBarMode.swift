import Foundation

/// View > Show Bookmarks Bar. The raw value is what the `setting` row `bookmarksBar` stores.
public enum BookmarksBarMode: String, CaseIterable, Sendable {
    case always, newTabOnly, never
    public static let settingKey = "bookmarksBar"

    public init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .newTabOnly }

    public func visible(onNewTab: Bool) -> Bool {
        switch self {
        case .always: true
        case .newTabOnly: onNewTab
        case .never: false
        }
    }

    /// Toggle Bookmarks Bar: what is shown now goes away, what is hidden now stays on every page.
    public func toggled(onNewTab: Bool) -> BookmarksBarMode { visible(onNewTab: onNewTab) ? .never : .always }
}
