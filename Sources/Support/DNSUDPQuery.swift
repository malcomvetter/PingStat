import Darwin
import Foundation

/// Minimal DNS-over-UDP (RFC 1035) A-record query to a specific IPv4 resolver — replaces `dig @server ... +short`.
enum DNSUDPQuery {
    private static let dnsPort: UInt16 = 53
    private static let typeA: UInt16 = 1
    private static let classIN: UInt16 = 1

    /// Returns IPv4 addresses from A answers (empty if timeout, NXDOMAIN, or parse failure).
    static func resolveIPv4A(hostname: String, nameserverIPv4: String, timeoutMs: Int) async -> [String] {
        await Task.detached(priority: .utility) {
            (try? resolveSync(hostname: hostname, nameserverIPv4: nameserverIPv4, timeoutMs: timeoutMs)) ?? []
        }.value
    }

    private nonisolated static func resolveSync(
        hostname: String,
        nameserverIPv4: String,
        timeoutMs: Int
    ) throws -> [String] {
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

        while DispatchTime.now().uptimeNanoseconds < deadline {
            let remainingNs = deadline - DispatchTime.now().uptimeNanoseconds
            if remainingNs <= 0 { break }
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
            if let ips = parseResponse(data: data, expectedID: queryID) {
                return ips
            }
        }

        return []
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

    /// Parses a DNS response. `nil` = wrong transaction id (ignore). Non-`nil` = our response (possibly empty A list).
    private nonisolated static func parseResponse(data: Data, expectedID: UInt16) -> [String]? {
        guard data.count >= 12 else { return nil }
        let id = readUInt16BE(data, offset: 0)
        guard id == expectedID else { return nil }

        let flags = readUInt16BE(data, offset: 2)
        let isResponse = (flags & 0x8000) != 0
        guard isResponse else { return [] }

        let rcode = flags & 0x000F
        guard rcode == 0 else { return [] }

        let qdCount = Int(readUInt16BE(data, offset: 4))
        let anCount = Int(readUInt16BE(data, offset: 6))
        guard qdCount >= 1, anCount >= 0 else { return [] }

        var offset = 12
        for _ in 0 ..< qdCount {
            guard skipName(data, offset: &offset) else { return [] }
            guard offset + 4 <= data.count else { return [] }
            offset += 4
        }

        var ips: [String] = []
        for _ in 0 ..< anCount {
            guard skipName(data, offset: &offset) else { return [] }
            guard offset + 10 <= data.count else { return [] }
            let type = readUInt16BE(data, offset: offset)
            offset += 2
            offset += 2 // class
            offset += 4 // ttl
            let rdlength = Int(readUInt16BE(data, offset: offset))
            offset += 2
            guard offset + rdlength <= data.count else { return [] }

            if type == typeA, rdlength == 4 {
                let ip = "\(data[offset]).\(data[offset + 1]).\(data[offset + 2]).\(data[offset + 3])"
                ips.append(ip)
            }
            offset += rdlength
        }

        return ips
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
