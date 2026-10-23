import Foundation

public struct SmokeOptions: Equatable {
    public let url: URL
    public let timeout: TimeInterval

    public static func parse(_ arguments: [String]) -> SmokeOptions? {
        func value(_ flag: String) -> String?? {
            guard let i = arguments.firstIndex(of: flag) else { return .none }
            return .some(i + 1 < arguments.count ? arguments[i + 1] : nil)
        }
        guard let rawURL = value("--smoke-url") else { return nil }
        guard let s = rawURL, let url = URL(string: s), url.scheme != nil, url.host != nil else { return nil }
        var timeout: TimeInterval = 30
        if let rawTimeout = value("--smoke-timeout") {
            guard let t = rawTimeout.flatMap(Double.init), t > 0, t.isFinite else { return nil }
            timeout = t
        }
        return SmokeOptions(url: url, timeout: timeout)
    }
}

public enum SmokeEvent: Equatable {
    case loadEnd(status: Int, title: String)
    case loadError(code: Int)
    case timeout
    case alreadyRunning

    public var line: String {
        switch self {
        case let .loadEnd(status, title): "NOCHE_SMOKE load_end status=\(status) title=\(title)"
        case let .loadError(code): "NOCHE_SMOKE load_error code=\(code)"
        case .timeout: "NOCHE_SMOKE timeout"
        case .alreadyRunning: "NOCHE already running"
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .loadEnd: 0
        case .timeout: 1
        case .loadError: 2
        case .alreadyRunning: 3
        }
    }
}
