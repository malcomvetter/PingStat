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

    // MARK: - Routing table (sysctl `PF_ROUTE`, parity with `netstat -rn -f inet` / `route -n get`)

    static func defaultIPv4GatewaysViaSysctl(preferredInterface: String) -> (preferred: String?, any: String?) {
        IPv4RouteTable.defaultGateways(preferredInterface: preferredInterface)
    }

    /// First `AF_LINK` interface name on an IPv4 default route (`netstat -rn -f inet` default row).
    static func defaultRouteInterfaceNameFromSysctl() -> String? {
        IPv4RouteTable.firstDefaultInterfaceName()
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
                if rtm.rtm_version == RTM_VERSION, rtm.rtm_errno == 0,
                   flags & Int(RTF_UP) != 0,
                   flags & Int(RTF_GATEWAY) != 0 {
                    let msgRaw = UnsafeRawPointer(rtmPtr)
                    let addrs = extractAddresses(msgBase: msgRaw, rtm: rtm, limit: offset + msglen)

                    guard isDefaultInetDestination(addrs[Int(RTAX_DST)]) else {
                        offset += msglen
                        continue
                    }

                    guard let gwStr = ipv4String(fromSockaddr: addrs[Int(RTAX_GATEWAY)]) else {
                        offset += msglen
                        continue
                    }

                    let ifName = linkInterfaceName(fromSockaddr: addrs[Int(RTAX_IFP)])

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
        data.withUnsafeBytes { raw -> String? in
            guard let rawBase = raw.baseAddress else { return nil }
            let base = UnsafeRawPointer(rawBase)
            var offset = 0
            let count = raw.count
            while offset + MemoryLayout<rt_msghdr>.size <= count {
                let rtmPtr = base.advanced(by: offset).assumingMemoryBound(to: rt_msghdr.self)
                let rtm = rtmPtr.pointee
                let msglen = Int(rtm.rtm_msglen)
                guard msglen >= MemoryLayout<rt_msghdr>.size, offset + msglen <= count else { break }

                let flags = Int(rtm.rtm_flags)
                if rtm.rtm_version == RTM_VERSION, rtm.rtm_errno == 0,
                   flags & Int(RTF_UP) != 0,
                   flags & Int(RTF_GATEWAY) != 0 {
                    let msgRaw = UnsafeRawPointer(rtmPtr)
                    let addrs = extractAddresses(msgBase: msgRaw, rtm: rtm, limit: offset + msglen)
                    if isDefaultInetDestination(addrs[Int(RTAX_DST)]),
                       let ifn = linkInterfaceName(fromSockaddr: addrs[Int(RTAX_IFP)]), !ifn.isEmpty {
                        return ifn
                    }
                }
                offset += msglen
            }
            return nil as String?
        }
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

    private static func isDefaultInetDestination(_ sa: UnsafePointer<sockaddr>?) -> Bool {
        guard let sa else { return false }
        guard sa.pointee.sa_family == UInt8(AF_INET) else { return false }
        let sin = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self).pointee
        return sin.sin_addr.s_addr == 0
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
