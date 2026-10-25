import Foundation
import NocheCore

/// Which test switch is on (always false in a build without the self-test hooks).
enum BarHook {
    static func on(_ name: String) -> Bool {
#if NOCHE_TESTHOOKS
        ProcessInfo.processInfo.environment["NOCHE_TEST_" + name] == "1"
#else
        false
#endif
    }
}

/// Remote query suggestions (note section 3d), off unless the setting `suggestRemote` is "1". The endpoint follows the default search engine;
/// the session is ephemeral with no cookies, cache, credentials or referrer; 100 ms debounce, 500 ms timeout, the last 20 answers cached
/// in memory; never sent for URL-like text, text with no letter or fewer than 2 characters.
@MainActor
enum RemoteSuggest {
    /// Every request this process made (host and uptime), for the self-tests.
    static var requests: [(host: String, time: TimeInterval)] = []
    /// Requests that were about to go to a host other than the configured one (they are not sent).
    static var foreign = 0

    private static var pending: DispatchWorkItem?
    private static var task: URLSessionDataTask?
    private static var cache: [(key: String, rows: [String])] = []
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 0.5
        c.timeoutIntervalForResource = 0.5
        c.httpAdditionalHeaders = ["Accept-Language": Locale.preferredLanguages.first ?? "en"]
        return URLSession(configuration: c)
    }()

    /// The suggest URL (with %s) for a search template, nil for an engine without one. The pair lives here, next to the one default template.
    static func endpoint(forSearchTemplate template: String) -> String? {
#if NOCHE_TESTHOOKS
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-suggest-url"), i + 1 < CommandLine.arguments.count { return CommandLine.arguments[i + 1] }
#endif
        guard let host = URL(string: template.replacingOccurrences(of: "%s", with: "x"))?.host?.lowercased() else { return nil }
        if host.hasSuffix("google.com") { return "https://suggestqueries.google.com/complete/search?client=firefox&q=%s" }
        if host.hasSuffix("duckduckgo.com") { return "https://duckduckgo.com/ac/?q=%s" }
        return nil
    }

    static func eligible(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.contains(where: \.isLetter) else { return false }
        let scheme = t.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
        if let first = scheme.first, first.isLetter, t.dropFirst(scheme.count).hasPrefix(":") { return false }
        // Host-like text resolves to a URL, never a search.
        guard let url = AddressInput.resolve(t, searchTemplate: "noche-probe://q/?q=%s"), url.scheme == "noche-probe" else { return false }
        return true
    }

    /// Cancels what is pending or in flight, then (when allowed) asks after the debounce. |deliver| runs on the main actor with up to 4 rows.
    static func request(_ text: String, searchTemplate: String, enabled: Bool, deliver: @escaping @MainActor @Sendable ([String]) -> Void) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !BarHook.on("NO_DEBOUNCE") { pending?.cancel(); task?.cancel() }
        guard enabled, eligible(q), let base = endpoint(forSearchTemplate: searchTemplate) else { return }
        if let hit = cache.first(where: { $0.key == q.lowercased() }) { deliver(hit.rows); return }
        let work = DispatchWorkItem { fire(q, base: base, deliver: deliver) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (BarHook.on("NO_DEBOUNCE") ? 0 : 0.1), execute: work)
    }

    private static func fire(_ q: String, base: String, deliver: @escaping @MainActor @Sendable ([String]) -> Void) {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = q.addingPercentEncoding(withAllowedCharacters: allowed) ?? q
        guard let url = URL(string: base.replacingOccurrences(of: "%s", with: encoded)), let baseHost = URL(string: base.replacingOccurrences(of: "%s", with: "x"))?.host,
              url.host == baseHost else { foreign += 1; return }
        requests.append((baseHost, ProcessInfo.processInfo.systemUptime))
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(nil, forHTTPHeaderField: "Referer")
        let key = q.lowercased()
        task = session.dataTask(with: request) { data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let rows = SuggestParser.parse(data)
            Task { @MainActor in
                cache.append((key, rows))
                if cache.count > 20 { cache.removeFirst() }
                deliver(rows)
            }
        }
        task?.resume()
    }
}
