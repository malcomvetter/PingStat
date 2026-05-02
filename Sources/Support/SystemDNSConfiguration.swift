import Darwin
import Foundation
import SystemConfiguration

/// Reads DNS resolver addresses from `configd` via **SystemConfiguration** (`SCDynamicStore`), the same
/// underlying store `scutil --dns` prints—without shelling out.
enum SystemDNSConfiguration {

    /// Ordered unique nameserver IPs (IPv4 / IPv6). Link-local IPv6 without a zone gets `%PrimaryInterface`
    /// from `State:/Network/Global/IPv4` or the per-service `Interface` when available.
    static func orderedNameserverAddresses(interfaceHint: String?) -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "PingStat.DNS" as CFString, nil, nil) else {
            return []
        }

        var ordered: [String] = []
        var seen = Set<String>()

        func appendUnique(_ addresses: [String], zoneInterface: String?) {
            let zone = zoneInterface ?? interfaceHint
            for s in addresses {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isIPLiteral(trimmed) else { continue }
                let zoned = zoneLinkLocalIfNeeded(trimmed, bsdIf: zone)
                guard !seen.contains(zoned) else { continue }
                ordered.append(zoned)
                seen.insert(zoned)
            }
        }

        if let globalDNS = copyDictionary(store, "State:/Network/Global/DNS"),
           let addrs = serverAddresses(from: globalDNS), !addrs.isEmpty {
            let globalIf = interfaceName(fromIPv4: copyDictionary(store, "State:/Network/Global/IPv4"))
                ?? interfaceHint
            appendUnique(addrs, zoneInterface: globalIf)
        }

        let pattern = "^State:/Network/Service/[^/]+/DNS$" as CFString
        guard let keyList = SCDynamicStoreCopyKeyList(store, pattern) as? [String] else {
            return preferNonLoopback(ordered)
        }
        for key in keyList.sorted() {
            guard let serviceID = serviceID(fromDNSKey: key) else { continue }
            let ipv4Path = "State:/Network/Service/\(serviceID)/IPv4"
            let serviceIf = interfaceName(fromIPv4: copyDictionary(store, ipv4Path))
            guard let dnsDict = copyDictionary(store, key),
                  let addrs = serverAddresses(from: dnsDict) else { continue }
            appendUnique(addrs, zoneInterface: serviceIf)
        }

        return preferNonLoopback(ordered)
    }

    private static func preferNonLoopback(_ raw: [String]) -> [String] {
        let nonLoopback = raw.filter { !["127.0.0.1", "0.0.0.0", "::1"].contains($0) }
        if !nonLoopback.isEmpty { return nonLoopback }
        return raw
    }

    private static func copyDictionary(_ store: SCDynamicStore, _ path: String) -> [String: Any]? {
        guard let value = SCDynamicStoreCopyValue(store, path as CFString) else { return nil }
        return value as? [String: Any]
    }

    private static func serviceID(fromDNSKey key: String) -> String? {
        let prefix = "State:/Network/Service/"
        let suffix = "/DNS"
        guard key.hasPrefix(prefix), key.hasSuffix(suffix) else { return nil }
        let inner = key.dropFirst(prefix.count).dropLast(suffix.count)
        let id = String(inner)
        return id.isEmpty ? nil : id
    }

    private static func serverAddresses(from dict: [String: Any]) -> [String]? {
        guard let raw = dict["ServerAddresses"] else { return nil }
        if let a = raw as? [String] { return a }
        if let a = raw as? [Any] {
            return a.compactMap { $0 as? String }
        }
        if let a = raw as? NSArray {
            return (0 ..< a.count).compactMap { a.object(at: $0) as? String }
        }
        return nil
    }

    private static func interfaceName(fromIPv4 dict: [String: Any]?) -> String? {
        guard let dict else { return nil }
        if let s = dict["Interface"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let s = dict["InterfaceName"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func zoneLinkLocalIfNeeded(_ raw: String, bsdIf: String?) -> String {
        guard let bsdIf, !bsdIf.isEmpty else { return raw }
        guard !raw.contains("%") else { return raw }
        guard isIPv6LinkLocal(raw) else { return raw }
        return "\(raw)%\(bsdIf)"
    }

    private static func isIPv6LinkLocal(_ value: String) -> Bool {
        let unzoned = stripZoneIndex(value.trimmingCharacters(in: .whitespacesAndNewlines))
        var addr = in6_addr()
        guard unzoned.withCString({ inet_pton(AF_INET6, $0, &addr) == 1 }) else { return false }
        return withUnsafeBytes(of: &addr) { raw in
            let p = raw.bindMemory(to: UInt8.self)
            guard p.count >= 2 else { return false }
            return p[0] == 0xfe && (p[1] & 0xc0) == 0x80
        }
    }

    private static func stripZoneIndex(_ value: String) -> String {
        if let i = value.firstIndex(of: "%") {
            return String(value[..<i])
        }
        return value
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let pattern = #"^(\d{1,3}\.){3}\d{1,3}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isIPv6Literal(_ value: String) -> Bool {
        let v = stripZoneIndex(value.trimmingCharacters(in: .whitespacesAndNewlines))
        var addr = in6_addr()
        return v.withCString { inet_pton(AF_INET6, $0, &addr) == 1 }
    }

    private static func isIPLiteral(_ value: String) -> Bool {
        isIPv4Address(value) || isIPv6Literal(value)
    }
}
