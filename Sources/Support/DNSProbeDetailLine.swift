import Foundation

/// Parsing helpers for ``DNSService`` resolver log lines (`@server Q A host → …`).
enum DNSProbeDetailLine {
    /// Extracts the resolver address for history bucketing. Uses the fixed ` Q A ` token so IPv6 literals
    /// (`:` and optional `%zone`) are never truncated at an interior space.
    static func nameserverKey(from detail: String) -> String? {
        guard let at = detail.firstIndex(of: "@") else { return nil }
        let afterAt = detail[detail.index(after: at)...]
        let marker = " Q A "
        if let range = afterAt.range(of: marker) {
            let key = String(afterAt[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        }
        if let space = afterAt.firstIndex(of: " ") {
            return String(afterAt[..<space])
        }
        let trimmed = String(afterAt).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
