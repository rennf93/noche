import Foundation

public enum CommandRouter {
    public enum Route: Equatable, Sendable {
        case navigate(URL)
        case switchTo(TabID)
        case none
    }

    /// Stored rows (pages, sites, tabs) only ever open http and https; typed text goes through AddressInput.
    public static func route(_ row: Suggestion?, typed: String, searchTemplate: String) -> Route {
        guard let row else { return resolve(typed, searchTemplate) }
        switch row.kind {
        case .query, .remoteQuery:
            return resolve(row.title, searchTemplate)
        case .goTo:
            return resolve(row.url ?? typed, searchTemplate)
        case .page, .site, .tab:
            guard let s = row.url, let url = URL(string: s), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", AddressInput.allowedSchemes.contains(scheme) else { return .none }
            if row.kind == .tab { return row.tabID.map(Route.switchTo) ?? .none }
            return .navigate(url)
        }
    }

    private static func resolve(_ text: String, _ template: String) -> Route {
        AddressInput.resolve(text, searchTemplate: template).map(Route.navigate) ?? .none
    }
}
