import Darwin
import Foundation
import SystemConfiguration

/// Native replacements for `route`, `netstat`, `ipconfig`, `networksetup`, and `scutil --dns` subprocesses.
enum NativeNetworkConfiguration {

    // MARK: - IPv4 interface + router (configd)

    static func globalIPv4FromStore() -> (interface: String?, router: String?) {
        guard let store = SCDynamicStoreCreate(nil, "PingStat.GlobalIPv4" as CFString, nil, nil) else {
            return (nil, nil)
        }
        guard let d = copyDict(store, "State:/Network/Global/IPv4") else { return (nil, nil) }
        let iface = (d["PrimaryInterface"] as? String) ?? (d["InterfaceName"] as? String)
        let trimmedIface = iface?.trimmingCharacters(in: .whitespacesAndNewlines)
        let routerRaw = (d["Router"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ifOut = (trimmedIface?.isEmpty == false) ? trimmedIface : nil
        let gwOut = (routerRaw?.isEmpty == false) ? routerRaw : nil
        return (ifOut, gwOut)
    }

    /// Per-service IPv4 `Router` for the active BSD interface (parity with `ipconfig getoption <if> router`).
    static func routerFromServiceIPv4(bsdInterface: String) -> String? {
        guard let store = SCDynamicStoreCreate(nil, "PingStat.SvcIPv4" as CFString, nil, nil) else {
            return nil
        }
        let pattern = "^State:/Network/Service/[^/]+/IPv4$" as CFString
        guard let keys = SCDynamicStoreCopyKeyList(store, pattern) as? [String] else { return nil }
        for key in keys {
            guard let d = copyDict(store, key) else { continue }
            let iface = (d["Interface"] as? String) ?? (d["InterfaceName"] as? String)
            guard iface?.trimmingCharacters(in: .whitespacesAndNewlines) == bsdInterface else { continue }
            if let r = d["Router"] as? String {
                let t = r.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    /// User-visible service name from the **current** network set in System Settings (same source as the list in **Network**), for the service whose interface BSD name matches `interfaceName` (e.g. `utun4` for many VPN clients).
    static func networkServiceDisplayName(forBSDInterface interfaceName: String) -> String? {
        let bsd = interfaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bsd.isEmpty else { return nil }
        guard let prefs = SCPreferencesCreate(nil, "PingStat.NetworkServiceName" as CFString, nil) else {
            return nil
        }
        guard SCPreferencesLock(prefs, true) else { return nil }
        defer { SCPreferencesUnlock(prefs) }

        guard let set = SCNetworkSetCopyCurrent(prefs) else { return nil }
        guard let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { return nil }

        for service in services {
            guard let iface = SCNetworkServiceGetInterface(service) else { continue }
            guard let name = SCNetworkInterfaceGetBSDName(iface) as String?, name == bsd else { continue }
            guard let display = SCNetworkServiceGetName(service) as String? else { return nil }
            let t = display.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    // MARK: - Routing table (sysctl `PF_ROUTE`, parity with `netstat -rn -f inet` / `route -n get`)

    static func defaultIPv4GatewaysViaSysctl(preferredInterface: String) -> (preferred: String?, any: String?) {
        IPv4RouteTable.defaultGateways(preferredInterface: preferredInterface)
    }

    /// Output `AF_LINK` interface on the preferred wide-Internet IPv4 route (see ``ipv4DefaultRouteInterfaceAndGateway()``).
    static func defaultRouteInterfaceNameFromSysctl() -> String? {
        IPv4RouteTable.preferredWideInternetIPv4Route().interfaceName
    }

    /// Interface name and IPv4 next hop on the **preferred** wide-Internet IPv4 route from the routing table
    /// (`0.0.0.0/0`, or WireGuard-style ``0.0.0.0/1`` + ``128.0.0.0/1`` splits). When several exist, a
    /// ``utun`` / ``ppp`` / ``ipsec`` interface wins so VPN clients are detected even when a physical default remains.
    static func ipv4DefaultRouteInterfaceAndGateway() -> (interfaceName: String?, gatewayIPv4: String?) {
        IPv4RouteTable.preferredWideInternetIPv4Route()
    }

    /// First non-loopback IPv4 configured on the given BSD interface (e.g. the WireGuard tunnel address when no IPv4 gateway appears in the route message).
    static func primaryIPv4Address(onBSDInterface interfaceName: String) -> String? {
        let trimmed = interfaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ipv4FromGetifaddrs(interfaceName: trimmed)
    }

    /// True for ``0.0.0.0/0``, ``0.0.0.0/1``, or ``128.0.0.0/1`` (common WireGuard / VPN split-default patterns).
    internal static func isWideInternetIPv4DestinationAndMask(destinationIPv4: String, netmaskIPv4: String?) -> Bool {
        let dest = destinationIPv4.trimmingCharacters(in: .whitespacesAndNewlines)
        let mask = netmaskIPv4?.trimmingCharacters(in: .whitespacesAndNewlines)
        if dest == "128.0.0.0" {
            return mask == "128.0.0.0"
        }
        guard dest == "0.0.0.0" else { return false }
        guard let m = mask, !m.isEmpty else { return true }
        return m == "0.0.0.0" || m == "128.0.0.0"
    }

    // MARK: - Manual DNS (parity with `networksetup -getdnsservers`)

    static func manualDNSServersFromPreferences(bsdInterface: String) -> [String]? {
        guard let prefs = SCPreferencesCreate(nil, "PingStat.ReadDNS" as CFString, nil) else { return nil }
        guard SCPreferencesLock(prefs, true) else { return nil }
        defer { SCPreferencesUnlock(prefs) }

        guard let set = SCNetworkSetCopyCurrent(prefs) else { return nil }
        guard let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { return nil }

        for service in services {
            guard let iface = SCNetworkServiceGetInterface(service) else { continue }
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String?, bsd == bsdInterface else { continue }
            guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else { continue }
            guard let cfg = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] else { continue }
            let addrs = (cfg[kSCPropNetDNSServerAddresses as String] as? [String])
                ?? (cfg["ServerAddresses"] as? [String])
            if let addrs, !addrs.isEmpty { return addrs }
        }
        return nil
    }

    private static func copyDict(_ store: SCDynamicStore, _ path: String) -> [String: Any]? {
        guard let v = SCDynamicStoreCopyValue(store, path as CFString) else { return nil }
        return v as? [String: Any]
    }

    /// Enumerates kernel interface addresses (same idea as ``getifaddr`` for a single interface).
    private static func ipv4FromGetifaddrs(interfaceName: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(first) }

        var candidates: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let node = ptr {
            defer { ptr = node.pointee.ifa_next }

            guard let addr = node.pointee.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: node.pointee.ifa_name)
            guard name == interfaceName else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard rc == 0 else { continue }

            let ip = String(cString: host).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ip.isEmpty, !ip.hasPrefix("127.") else { continue }
            candidates.append(ip)
        }

        guard !candidates.isEmpty else { return nil }
        let unique = Array(Set(candidates))
        return unique.sorted { lhs, rhs in
            let lLink = lhs.hasPrefix("169.254.")
            let rLink = rhs.hasPrefix("169.254.")
            if lLink != rLink { return !lLink }
            return lhs < rhs
        }.first
    }

    /// BSD interface names commonly used for VPN / tunnel endpoints (WireGuard, IPsec, PPP).
    static func isLikelyVpnTunnelInterfaceName(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.hasPrefix("utun") { return true }
        if n.hasPrefix("ppp") { return true }
        if n.contains("ipsec") { return true }
        return false
    }

    /// True when the IPv4 routing dump includes a wide-Internet route (``0/0``, ``0/1``, ``128/1``) whose output interface resolves to `bsdInterface` (including via ``rtm_index`` when ``RTAX_IFP`` is absent).
    static func hasWideInternetIPv4Route(onBSDInterface bsdInterface: String) -> Bool {
        let name = bsdInterface.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return IPv4RouteTable.hasWideInternetIPv4Route(onBSDInterface: name)
    }
}

// MARK: - IPv4 routing messages (sysctl)

private enum IPv4RouteTable {

    private static func roundup(_ len: Int) -> Int {
        let a = 4
        return ((len + a - 1) / a) * a
    }

    static func firstDefaultInterfaceName() -> String? {
        guard let data = sysctlRouteDump() else { return nil }
        return firstDefaultInterface(in: data)
    }

    static func defaultGateways(preferredInterface: String) -> (preferred: String?, any: String?) {
        guard let data = sysctlRouteDump() else { return (nil, nil) }
        var anyGw: String?
        var prefGw: String?
        data.withUnsafeBytes { raw in
            guard let rawBase = raw.baseAddress else { return }
            let base = UnsafeRawPointer(rawBase)
            var offset = 0
            let count = raw.count
            while offset + MemoryLayout<rt_msghdr>.size <= count {
                let rtmPtr = base.advanced(by: offset).assumingMemoryBound(to: rt_msghdr.self)
                let rtm = rtmPtr.pointee
                let msglen = Int(rtm.rtm_msglen)
                guard msglen >= MemoryLayout<rt_msghdr>.size, offset + msglen <= count else { break }

                let flags = Int(rtm.rtm_flags)
                let rtmType = Int(rtm.rtm_type)
                if rtm.rtm_version == RTM_VERSION, rtm.rtm_errno == 0,
                   Self.isRoutableRtmType(rtmType),
                   flags & Int(RTF_UP) != 0 {
                    let msgRaw = UnsafeRawPointer(rtmPtr)
                    let addrs = extractAddresses(msgBase: msgRaw, rtm: rtm, limit: offset + msglen)

                    guard isWideInternetInetRoute(
                        dst: addrs[Int(RTAX_DST)],
                        mask: addrs[Int(RTAX_NETMASK)],
                        genmask: addrs[Int(RTAX_GENMASK)]
                    ) else {
                        offset += msglen
                        continue
                    }

                    guard let ifName = resolvedOutputInterfaceName(
                        linkSockaddr: addrs[Int(RTAX_IFP)],
                        rtmIndex: rtm.rtm_index
                    ), !ifName.isEmpty else {
                        offset += msglen
                        continue
                    }

                    let tunnel = NativeNetworkConfiguration.isLikelyVpnTunnelInterfaceName(ifName)
                    guard (flags & Int(RTF_GATEWAY) != 0) || tunnel else {
                        offset += msglen
                        continue
                    }

                    guard let gwStr = ipv4String(fromSockaddr: addrs[Int(RTAX_GATEWAY)]) else {
                        offset += msglen
                        continue
                    }

                    if ifName == preferredInterface, prefGw == nil {
                        prefGw = gwStr
                    }
                    if anyGw == nil {
                        anyGw = gwStr
                    }
                }

                offset += msglen
            }
        }
        return (prefGw, anyGw)
    }

    private static func firstDefaultInterface(in data: Data) -> String? {
        preferredWideInternetIPv4Route(in: data).interfaceName
    }

    /// Collects ``0.0.0.0/0``, ``0.0.0.0/1``, and ``128.0.0.0/1`` routes; prefers a tunnel output interface.
    private static func preferredWideInternetIPv4Route(in data: Data) -> (interfaceName: String?, gatewayIPv4: String?) {
        data.withUnsafeBytes { raw -> (String?, String?) in
            guard let rawBase = raw.baseAddress else { return (nil, nil) }
            let base = UnsafeRawPointer(rawBase)
            var offset = 0
            let count = raw.count
            var candidates: [(ifn: String, gw: String?)] = []
            while offset + MemoryLayout<rt_msghdr>.size <= count {
                let rtmPtr = base.advanced(by: offset).assumingMemoryBound(to: rt_msghdr.self)
                let rtm = rtmPtr.pointee
                let msglen = Int(rtm.rtm_msglen)
                guard msglen >= MemoryLayout<rt_msghdr>.size, offset + msglen <= count else { break }

                let flags = Int(rtm.rtm_flags)
                let rtmType = Int(rtm.rtm_type)
                if rtm.rtm_version == RTM_VERSION, rtm.rtm_errno == 0,
                   Self.isRoutableRtmType(rtmType),
                   flags & Int(RTF_UP) != 0 {
                    let msgRaw = UnsafeRawPointer(rtmPtr)
                    let addrs = extractAddresses(msgBase: msgRaw, rtm: rtm, limit: offset + msglen)

                    guard isWideInternetInetRoute(
                        dst: addrs[Int(RTAX_DST)],
                        mask: addrs[Int(RTAX_NETMASK)],
                        genmask: addrs[Int(RTAX_GENMASK)]
                    ) else {
                        offset += msglen
                        continue
                    }

                    guard let ifn = resolvedOutputInterfaceName(
                        linkSockaddr: addrs[Int(RTAX_IFP)],
                        rtmIndex: rtm.rtm_index
                    ), !ifn.isEmpty else {
                        offset += msglen
                        continue
                    }

                    let tunnel = NativeNetworkConfiguration.isLikelyVpnTunnelInterfaceName(ifn)
                    guard (flags & Int(RTF_GATEWAY) != 0) || tunnel else {
                        offset += msglen
                        continue
                    }

                    let gw = ipv4String(fromSockaddr: addrs[Int(RTAX_GATEWAY)])
                    candidates.append((ifn, gw))
                }
                offset += msglen
            }
            if let t = candidates.first(where: { NativeNetworkConfiguration.isLikelyVpnTunnelInterfaceName($0.ifn) }) {
                return (t.ifn, t.gw)
            }
            if let first = candidates.first {
                return (first.ifn, first.gw)
            }
            return (nil, nil)
        }
    }

    /// ``NET_RT_DUMP`` includes interface / address events; skip types that are not IPv4 forwarding routes.
    private static func isRoutableRtmType(_ type: Int) -> Bool {
        let skip: Set<Int> = [
            Int(RTM_IFINFO),
            Int(RTM_NEWADDR),
            Int(RTM_DELADDR),
            Int(RTM_NEWMADDR),
            Int(RTM_DELMADDR)
        ]
        return !skip.contains(type)
    }

    private static func interfaceNameFromRtmIndex(_ index: UInt16) -> String? {
        guard index > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(UInt32(index), &buf) != nil else { return nil }
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private static func resolvedOutputInterfaceName(
        linkSockaddr: UnsafePointer<sockaddr>?,
        rtmIndex: UInt16
    ) -> String? {
        if let link = linkInterfaceName(fromSockaddr: linkSockaddr) {
            let t = link.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return interfaceNameFromRtmIndex(rtmIndex)
    }

    static func hasWideInternetIPv4Route(onBSDInterface bsd: String) -> Bool {
        guard let data = sysctlRouteDump() else { return false }
        return hasWideInternetIPv4Route(onBSDInterface: bsd, data: data)
    }

    private static func hasWideInternetIPv4Route(onBSDInterface bsd: String, data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let rawBase = raw.baseAddress else { return false }
            let base = UnsafeRawPointer(rawBase)
            var offset = 0
            let count = raw.count
            while offset + MemoryLayout<rt_msghdr>.size <= count {
                let rtmPtr = base.advanced(by: offset).assumingMemoryBound(to: rt_msghdr.self)
                let rtm = rtmPtr.pointee
                let msglen = Int(rtm.rtm_msglen)
                guard msglen >= MemoryLayout<rt_msghdr>.size, offset + msglen <= count else { break }

                let flags = Int(rtm.rtm_flags)
                let rtmType = Int(rtm.rtm_type)
                if rtm.rtm_version == RTM_VERSION, rtm.rtm_errno == 0,
                   Self.isRoutableRtmType(rtmType),
                   flags & Int(RTF_UP) != 0 {
                    let msgRaw = UnsafeRawPointer(rtmPtr)
                    let addrs = extractAddresses(msgBase: msgRaw, rtm: rtm, limit: offset + msglen)

                    guard isWideInternetInetRoute(
                        dst: addrs[Int(RTAX_DST)],
                        mask: addrs[Int(RTAX_NETMASK)],
                        genmask: addrs[Int(RTAX_GENMASK)]
                    ) else {
                        offset += msglen
                        continue
                    }

                    guard let ifn = resolvedOutputInterfaceName(
                        linkSockaddr: addrs[Int(RTAX_IFP)],
                        rtmIndex: rtm.rtm_index
                    ), ifn == bsd else {
                        offset += msglen
                        continue
                    }

                    let tunnel = NativeNetworkConfiguration.isLikelyVpnTunnelInterfaceName(ifn)
                    guard (flags & Int(RTF_GATEWAY) != 0) || tunnel else {
                        offset += msglen
                        continue
                    }
                    return true
                }
                offset += msglen
            }
            return false
        }
    }

    private static func isWideInternetInetRoute(
        dst: UnsafePointer<sockaddr>?,
        mask: UnsafePointer<sockaddr>?,
        genmask: UnsafePointer<sockaddr>?
    ) -> Bool {
        guard let dStr = ipv4String(fromSockaddr: dst) else { return false }
        let mStr = ipv4String(fromSockaddr: mask) ?? ipv4String(fromSockaddr: genmask)
        return NativeNetworkConfiguration.isWideInternetIPv4DestinationAndMask(
            destinationIPv4: dStr,
            netmaskIPv4: mStr
        )
    }

    static func preferredWideInternetIPv4Route() -> (interfaceName: String?, gatewayIPv4: String?) {
        guard let data = sysctlRouteDump() else { return (nil, nil) }
        return preferredWideInternetIPv4Route(in: data)
    }

    private static func sysctlRouteDump() -> Data? {
        var mib = [Int32]([CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0])
        let mibLen = UInt32(mib.count)
        var needed = 0
        let r0 = mib.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let p = buf.baseAddress else { return -1 }
            return sysctl(p, mibLen, nil, &needed, nil, 0)
        }
        guard r0 == 0, needed > 0 else { return nil }

        var buffer = Data(count: needed)
        let r1 = buffer.withUnsafeMutableBytes { raw -> Int32 in
            mib.withUnsafeMutableBufferPointer { mibBuf in
                guard let mb = mibBuf.baseAddress, let rb = raw.baseAddress else { return -1 }
                var len = raw.count
                return sysctl(mb, mibLen, rb, &len, nil, 0)
            }
        }
        guard r1 == 0 else { return nil }
        return buffer
    }

    private static func extractAddresses(msgBase: UnsafeRawPointer, rtm: rt_msghdr, limit: Int) -> [UnsafePointer<sockaddr>?] {
        let rtaxMax = Int(RTAX_MAX)
        var out: [UnsafePointer<sockaddr>?] = Array(repeating: nil, count: rtaxMax)
        var off = MemoryLayout<rt_msghdr>.size
        let mask = Int(rtm.rtm_addrs)
        for i in 0 ..< rtaxMax {
            guard (mask & (1 << i)) != 0 else { continue }
            guard off + MemoryLayout<sockaddr>.size <= limit else { break }
            let saPtr = msgBase.advanced(by: off).assumingMemoryBound(to: sockaddr.self)
            let saLen = Int(saPtr.pointee.sa_len)
            guard saLen > 0, off + saLen <= limit else { break }
            out[i] = UnsafePointer(saPtr)
            off += roundup(saLen)
        }
        return out
    }

    private static func ipv4String(fromSockaddr sa: UnsafePointer<sockaddr>?) -> String? {
        guard let sa else { return nil }
        guard sa.pointee.sa_family == UInt8(AF_INET) else { return nil }
        var sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let ok = withUnsafePointer(to: &sin.sin_addr) { p in
            inet_ntop(AF_INET, p, &buf, socklen_t(INET_ADDRSTRLEN))
        }
        guard ok != nil else { return nil }
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let pattern = #"^(\d{1,3}\.){3}\d{1,3}$"#
        guard s.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return s
    }

    private static func linkInterfaceName(fromSockaddr sa: UnsafePointer<sockaddr>?) -> String? {
        guard let sa else { return nil }
        guard sa.pointee.sa_family == UInt8(AF_LINK) else { return nil }
        let dl = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_dl.self).pointee
        let nlen = Int(dl.sdl_nlen)
        guard nlen > 0, nlen < 256 else { return nil }
        let off = MemoryLayout<sockaddr_dl>.offset(of: \sockaddr_dl.sdl_data) ?? 8
        let namePtr = UnsafeRawPointer(sa).advanced(by: off).assumingMemoryBound(to: UInt8.self)
        return String(bytes: UnsafeBufferPointer(start: namePtr, count: nlen), encoding: .utf8)
    }
}
