import Foundation

public enum SuggestParser {
    /// OpenSearch `[query, [strings]]` or DuckDuckGo `[{"phrase": ...}]`; anything else gives []. Entries over 200 characters drop, 4 kept.
    public static func parse(_ data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any], let first = json.first else { return [] }
        let all: [String]
        if first is String {
            all = (json.count > 1 ? json[1] as? [Any] : nil)?.compactMap { $0 as? String } ?? []
        } else {
            all = json.compactMap { ($0 as? [String: Any])?["phrase"] as? String }
        }
        return Array(all.filter { !$0.isEmpty && $0.count <= 200 }.prefix(4))
    }
}
