import Darwin
import Foundation

/// Result of a single A-record DNS query (RFC 1035).
struct DNSUDPResolution: Equatable, Sendable {
    /// A-record IPv4 answers (legacy health checks use this).
    let ipv4Addresses: [String]
    /// Human-readable answer RRs, e.g. `"A 17.253.144.10"`, `"CNAME host.example.com."`.
    let answerSummaries: [String]
    /// DNS RCODE when a response packet was parsed (`nil` = timeout or unrelated datagram).
    let responseCode: UInt16?
}

/// Minimal DNS-over-UDP (RFC 1035) A-record query to a specific resolver — replaces `dig @server ... +short`.
enum DNSUDPQuery {
    private static let dnsPort: UInt16 = 53
    private static let typeA: UInt16 = 1
    private static let typeCNAME: UInt16 = 5
    private static let classIN: UInt16 = 1

    /// Full resolution: IPv4 list plus display strings for answer section (types + RDATA).
    static func resolveARecordDetails(hostname: String, nameserver: String, timeoutMs: Int) async -> DNSUDPResolution {
        let ns = nameserver.trimmingCharacters(in: .whitespacesAndNewlines)
        var v4 = sockaddr_in()
        if ns.withCString({ inet_pton(AF_INET, $0, &v4.sin_addr) }) == 1 {
            return await Task(priority: .utility) { @Sendable in
                (try? resolveSync(hostname: hostname, nameserverIPv4: ns, timeoutMs: timeoutMs))
                    ?? DNSUDPResolution(ipv4Addresses: [], answerSummaries: [], responseCode: nil)
            }.value
        }
        guard let v6parsed = parseIPv6Nameserver(ns) else {
            return DNSUDPResolution(ipv4Addresses: [], answerSummaries: [], responseCode: nil)
        }
        return await Task(priority: .utility) { @Sendable in
            (try? resolveSyncIPv6(
                hostname: hostname,
                nameserver: v6parsed.address,
                scopeId: v6parsed.scopeId,
                timeoutMs: timeoutMs
            )) ?? DNSUDPResolution(ipv4Addresses: [], answerSummaries: [], responseCode: nil)
        }.value
    }

    /// Returns IPv4 addresses from A answers (empty if timeout, NXDOMAIN, or parse failure).
    static func resolveIPv4A(hostname: String, nameserverIPv4: String, timeoutMs: Int) async -> [String] {
        await Task(priority: .utility) { @Sendable in
            (try? resolveSync(hostname: hostname, nameserverIPv4: nameserverIPv4, timeoutMs: timeoutMs))?.ipv4Addresses ?? []
        }.value
    }

    /// Same A-record query over UDP, to an IPv4 or IPv6 resolver address.
    static func resolveA(hostname: String, nameserver: String, timeoutMs: Int) async -> [String] {
        await resolveARecordDetails(hostname: hostname, nameserver: nameserver, timeoutMs: timeoutMs).ipv4Addresses
    }

    /// IPv6 literal plus optional zone (`fe80::1%en0`). **Link-local** (`fe80::/10`) only works on the wire if
    /// `sin6_scope_id` matches the interface; `%en0` is turned into `if_nametoindex("en0")`.
    internal nonisolated static func parseIPv6Nameserver(_ raw: String) -> (address: String, scopeId: UInt32)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pct = trimmed.firstIndex(of: "%") {
            let addr = String(trimmed[..<pct])
            let zone = String(trimmed[trimmed.index(after: pct)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !addr.isEmpty else { return nil }
            var a6 = in6_addr()
            guard addr.withCString({ inet_pton(AF_INET6, $0, &a6) }) == 1 else { return nil }
            if zone.isEmpty {
                return (addr, 0)
            }
            if let numeric = UInt32(zone), numeric > 0 {
                return (addr, numeric)
            }
            let idx = zone.withCString { if_nametoindex($0) }
            return idx > 0 ? (addr, idx) : (addr, 0)
        }
        var a6 = in6_addr()
        guard trimmed.withCString({ inet_pton(AF_INET6, $0, &a6) }) == 1 else { return nil }
        return (trimmed, 0)
    }

    private nonisolated static func resolveSync(
        hostname: String,
        nameserverIPv4: String,
        timeoutMs: Int
    ) throws -> DNSUDPResolution {
        let queryID = UInt16.random(in: .min ... .max)
        let payload = try buildQuery(hostname: hostname, queryID: queryID)

        var peer = sockaddr_in()
        peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_port = in_port_t(UInt16(dnsPort).bigEndian)
        let pton = nameserverIPv4.withCString { inet_pton(AF_INET, $0, &peer.sin_addr) }
        guard pton == 1 else {
            throw DNSUDPError.invalidNameserver
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw DNSUDPError.socketFailed(errno) }
        defer { close(fd) }
        ICMPPing.disableSIGPIPE(fd: fd)

        let peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let sent = payload.withUnsafeBytes { raw -> ssize_t in
            guard let base = raw.baseAddress else { return -1 }
            return withUnsafePointer(to: &peer) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, base, payload.count, 0, sa, peerLen)
                }
            }
        }
        guard sent == ssize_t(payload.count) else {
            throw DNSUDPError.sendFailed(errno)
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(1, timeoutMs)) * 1_000_000
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            let remainingNs = deadline - now
            let sliceMs = max(1, min(Int(remainingNs / 1_000_000), Int(UInt16.max)))
            try setReceiveTimeout(fd: fd, timeoutMs: sliceMs)

            let recvLen = buffer.withUnsafeMutableBytes { raw -> ssize_t in
                guard let base = raw.baseAddress else { return -1 }
                return recvfrom(fd, base, raw.count, 0, nil, nil)
            }

            if recvLen < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    continue
                }
                throw DNSUDPError.recvFailed(err)
            }

            let data = Data(buffer.prefix(Int(recvLen)))
            if let parsed = parseDetailedResponse(data: data, expectedID: queryID) {
                return parsed
            }
        }

        return DNSUDPResolution(ipv4Addresses: [], answerSummaries: [], responseCode: nil)
    }

    private nonisolated static func resolveSyncIPv6(
        hostname: String,
        nameserver: String,
        scopeId: UInt32,
        timeoutMs: Int
    ) throws -> DNSUDPResolution {
        let queryID = UInt16.random(in: .min ... .max)
        let payload = try buildQuery(hostname: hostname, queryID: queryID)

        var peer = sockaddr_in6()
        peer.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        peer.sin6_family = sa_family_t(AF_INET6)
        peer.sin6_port = in_port_t(UInt16(dnsPort).bigEndian)
        peer.sin6_scope_id = scopeId
        let pton = nameserver.withCString { inet_pton(AF_INET6, $0, &peer.sin6_addr) }
        guard pton == 1 else {
            throw DNSUDPError.invalidNameserver
        }

        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw DNSUDPError.socketFailed(errno) }
        defer { close(fd) }
        ICMPPing.disableSIGPIPE(fd: fd)

        let peerLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let sent = payload.withUnsafeBytes { raw -> ssize_t in
            guard let base = raw.baseAddress else { return -1 }
            return withUnsafePointer(to: &peer) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, base, payload.count, 0, sa, peerLen)
                }
            }
        }
        guard sent == ssize_t(payload.count) else {
            throw DNSUDPError.sendFailed(errno)
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(1, timeoutMs)) * 1_000_000
        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            let remainingNs = deadline - now
            let sliceMs = max(1, min(Int(remainingNs / 1_000_000), Int(UInt16.max)))
            try setReceiveTimeout(fd: fd, timeoutMs: sliceMs)

            let recvLen = buffer.withUnsafeMutableBytes { raw -> ssize_t in
                guard let base = raw.baseAddress else { return -1 }
                return recvfrom(fd, base, raw.count, 0, nil, nil)
            }

            if recvLen < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    continue
                }
                throw DNSUDPError.recvFailed(err)
            }

            let data = Data(buffer.prefix(Int(recvLen)))
            if let parsed = parseDetailedResponse(data: data, expectedID: queryID) {
                return parsed
            }
        }

        return DNSUDPResolution(ipv4Addresses: [], answerSummaries: [], responseCode: nil)
    }

    private nonisolated static func setReceiveTimeout(fd: Int32, timeoutMs: Int) throws {
        let ms = max(1, timeoutMs)
        var tv = timeval(
            tv_sec: time_t(ms / 1000),
            tv_usec: Int32((ms % 1000) * 1000)
        )
        let rc = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard rc == 0 else { throw DNSUDPError.optionFailed(errno) }
    }

    private nonisolated static func buildQuery(hostname: String, queryID: UInt16) throws -> Data {
        var data = Data()
        data.append(contentsOf: u16be(queryID))
        data.append(contentsOf: [0x01, 0x00]) // flags: standard query, RD
        data.append(contentsOf: [0x00, 0x01]) // QDCOUNT = 1
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // AN, NS, AR = 0

        try encodeHostname(hostname, into: &data)
        data.append(contentsOf: u16be(typeA))
        data.append(contentsOf: u16be(classIN))

        guard data.count <= 512 else { throw DNSUDPError.queryTooLarge }
        return data
    }

    private nonisolated static func encodeHostname(_ host: String, into data: inout Data) throws {
        let labels = host.split(separator: ".").map(String.init)
        guard !labels.isEmpty else { throw DNSUDPError.invalidHostname }
        for label in labels {
            guard let ascii = label.data(using: .ascii), ascii.count <= 63 else {
                throw DNSUDPError.invalidHostname
            }
            data.append(UInt8(ascii.count))
            data.append(ascii)
        }
        data.append(0)
    }

    /// Parses a DNS response. `nil` = wrong transaction id (ignore).
    internal nonisolated static func parseDetailedResponse(data: Data, expectedID: UInt16) -> DNSUDPResolution? {
        guard data.count >= 12 else { return nil }
        let id = readUInt16BE(data, offset: 0)
        guard id == expectedID else { return nil }

        let flags = readUInt16BE(data, offset: 2)
        let isResponse = (flags & 0x8000) != 0
        let rcode = flags & 0x000F

        guard isResponse else { return nil }

        if rcode != 0 {
            return DNSUDPResolution(
                ipv4Addresses: [],
                answerSummaries: ["RCODE \(dnsRCODEName(rcode)) (\(rcode))"],
                responseCode: rcode
            )
        }

        let qdCount = Int(readUInt16BE(data, offset: 4))
        let anCount = Int(readUInt16BE(data, offset: 6))
        guard qdCount >= 1, anCount >= 0 else {
            return DNSUDPResolution(ipv4Addresses: [], answerSummaries: ["malformed header counts"], responseCode: 0)
        }

        var offset = 12
        for _ in 0 ..< qdCount {
            guard skipName(data, offset: &offset) else { return nil }
            guard offset + 4 <= data.count else { return nil }
            offset += 4
        }

        var ips: [String] = []
        var summaries: [String] = []
        for _ in 0 ..< anCount {
            guard skipName(data, offset: &offset) else { return nil }
            guard offset + 10 <= data.count else { return nil }
            let type = readUInt16BE(data, offset: offset)
            offset += 2
            offset += 2 // class
            offset += 4 // ttl
            let rdlength = Int(readUInt16BE(data, offset: offset))
            offset += 2
            guard offset + rdlength <= data.count else { return nil }
            let rdStart = offset

            if type == typeA, rdlength == 4 {
                let ip = "\(data[offset]).\(data[offset + 1]).\(data[offset + 2]).\(data[offset + 3])"
                ips.append(ip)
                summaries.append("A \(ip)")
            } else if type == typeCNAME {
                var nameOffset = rdStart
                let boundary = rdStart + rdlength
                if let cname = decodeDomainName(data, offset: &nameOffset, packetEnd: data.count, rdEnd: boundary) {
                    summaries.append("CNAME \(cname)")
                } else {
                    summaries.append("CNAME <unparseable>")
                }
            } else {
                summaries.append("TYPE \(type) rdlen=\(rdlength)")
            }
            offset += rdlength
        }

        if summaries.isEmpty, anCount == 0 {
            summaries.append("NOERROR (no answers)")
        }

        return DNSUDPResolution(ipv4Addresses: ips, answerSummaries: summaries, responseCode: 0)
    }

    private nonisolated static func dnsRCODEName(_ rcode: UInt16) -> String {
        switch rcode {
        case 1: return "FORMERR"
        case 2: return "SERVFAIL"
        case 3: return "NXDOMAIN"
        case 4: return "NOTIMP"
        case 5: return "REFUSED"
        default: return "RCODE"
        }
    }

    /// Decodes a QNAME / RDATA domain name. `rdEnd` is exclusive end of this RDATA when parsing inside an RR.
    private nonisolated static func decodeDomainName(
        _ data: Data,
        offset: inout Int,
        packetEnd: Int,
        rdEnd: Int?
    ) -> String? {
        var parts: [String] = []
        var pos = offset
        var resumeAfterFirstPointer: Int?
        var hops = 0
        let hardEnd = min(packetEnd, data.count)

        while hops < 64, pos < hardEnd {
            hops += 1
            let lenByte = Int(data[pos])
            if lenByte == 0 {
                pos += 1
                offset = resumeAfterFirstPointer ?? pos
                return parts.joined(separator: ".")
            }
            if (lenByte & 0xC0) == 0xC0 {
                guard pos + 1 < data.count else { return nil }
                let ptr = ((lenByte & 0x3F) << 8) | Int(data[pos + 1])
                guard ptr < data.count else { return nil }
                if resumeAfterFirstPointer == nil {
                    resumeAfterFirstPointer = pos + 2
                }
                pos = ptr
                continue
            }
            pos += 1
            guard pos + lenByte <= data.count else { return nil }
            if let rdEnd, pos + lenByte > rdEnd, resumeAfterFirstPointer == nil { return nil }
            let labelData = data.subdata(in: pos ..< pos + lenByte)
            guard let s = String(data: labelData, encoding: .ascii), !s.isEmpty else { return nil }
            parts.append(s)
            pos += lenByte
        }
        return nil
    }

    /// Skips a QNAME or RNAME; supports label pointers (RFC 1035 §4.1.4).
    private nonisolated static func skipName(_ data: Data, offset: inout Int) -> Bool {
        var steps = 0
        while offset < data.count && steps < 128 {
            steps += 1
            let len = Int(data[offset])
            if len == 0 {
                offset += 1
                return true
            }
            if (len & 0xC0) == 0xC0 {
                guard offset + 1 < data.count else { return false }
                offset += 2
                return true
            }
            offset += 1
            guard offset + len <= data.count else { return false }
            offset += len
        }
        return false
    }

    private nonisolated static func readUInt16BE(_ data: Data, offset: Int) -> UInt16 {
        guard data.count >= offset + 2 else { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
}

private enum DNSUDPError: Error {
    case invalidNameserver
    case invalidHostname
    case queryTooLarge
    case socketFailed(Int32)
    case sendFailed(Int32)
    case recvFailed(Int32)
    case optionFailed(Int32)
}

private func u16be(_ value: UInt16) -> Data {
    var be = value.bigEndian
    return withUnsafeBytes(of: &be) { Data($0) }
}
