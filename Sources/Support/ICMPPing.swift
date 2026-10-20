import Darwin
import Foundation

enum ICMPPingError: Error {
    case resolveFailed(String)
    case socketFailed(errno: Int32)
    case optionFailed(errno: Int32)
    case sendFailed(errno: Int32)
    case recvFailed(errno: Int32)
    case timedOut
}

/// IPv4 ICMP echo using `SOCK_DGRAM` + `IPPROTO_ICMP` (same mechanism as `/sbin/ping`, without shelling out).
enum ICMPPing {
    private static let echoRequestType: UInt8 = 8
    private static let echoReplyType: UInt8 = 0

    /// Sends one ICMP echo request and measures RTT. Blocking socket IO runs on a child task so cancellation can propagate from the ping loop.
    static func echo(host: String, timeoutMs: Int) async throws -> Double {
        try await Task(priority: .utility) { @Sendable in
            try echoSync(host: host, timeoutMs: timeoutMs)
        }.value
    }

    private nonisolated static func echoSync(host: String, timeoutMs: Int) throws -> Double {
        let overallDeadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(1, timeoutMs)) * 1_000_000
        var peer = try sockaddrIPv4(host: host)

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else {
            throw ICMPPingError.socketFailed(errno: errno)
        }
        defer { close(fd) }
        disableSIGPIPE(fd: fd)

        let peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let connectResult = withUnsafePointer(to: &peer) { peerPtr in
            peerPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, peerLen)
            }
        }
        guard connectResult == 0 else {
            throw ICMPPingError.socketFailed(errno: errno)
        }

        let identifier = UInt16.random(in: .min ... .max)
        let sequence = nextSequence()
        let sentNanos = DispatchTime.now().uptimeNanoseconds

        let packet = buildEchoRequest(identifier: identifier, sequence: sequence, sentNanos: sentNanos)

        let sendResult = packet.withUnsafeBytes { rawBuffer -> ssize_t in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return send(fd, base, packet.count, 0)
        }
        guard sendResult == ssize_t(packet.count) else {
            throw ICMPPingError.sendFailed(errno: errno)
        }

        var buffer = [UInt8](repeating: 0, count: 65_536)

        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < overallDeadline else { break }
            let remainingNs = overallDeadline - now
            let sliceMs = max(1, min(Int(remainingNs / 1_000_000), Int(UInt16.max)))
            try setReceiveTimeout(fd: fd, timeoutMs: sliceMs)

            let recvLen = buffer.withUnsafeMutableBytes { rawBuffer -> ssize_t in
                guard let base = rawBuffer.baseAddress else { return ssize_t(-1) }
                return recv(fd, base, rawBuffer.count, 0)
            }

            if recvLen < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    continue
                }
                throw ICMPPingError.recvFailed(errno: err)
            }

            let data = Data(buffer.prefix(Int(recvLen)))
            if let rtt = parseEchoReply(
                data: data,
                expectedIdentifier: identifier,
                expectedSequence: sequence,
                sentNanos: sentNanos
            ) {
                return rtt
            }
        }

        throw ICMPPingError.timedOut
    }

    private nonisolated static func sockaddrIPv4(host: String) throws -> sockaddr_in {
        var addr = sockaddr_in()
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let parseCode = trimmed.withCString { cstr in
            inet_pton(AF_INET, cstr, &addr.sin_addr)
        }
        if parseCode == 1 {
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            return addr
        }

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let lookupErr = trimmed.withCString { name in
            getaddrinfo(name, nil, &hints, &info)
        }
        guard lookupErr == 0, let info else {
            throw ICMPPingError.resolveFailed(trimmed)
        }
        defer { freeaddrinfo(info) }

        var cursor: UnsafeMutablePointer<addrinfo>? = info
        while let node = cursor {
            if node.pointee.ai_family == AF_INET, let sa = node.pointee.ai_addr {
                return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
                    var sin = ptr.pointee
                    sin.sin_port = 0
                    return sin
                }
            }
            cursor = node.pointee.ai_next
        }

        throw ICMPPingError.resolveFailed(trimmed)
    }

    /// Makes a failed send return `EPIPE` instead of raising `SIGPIPE`.
    nonisolated static func disableSIGPIPE(fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private nonisolated static func setReceiveTimeout(fd: Int32, timeoutMs: Int) throws {
        let ms = max(1, timeoutMs)
        var tv = timeval(
            tv_sec: time_t(ms / 1000),
            tv_usec: Int32((ms % 1000) * 1000)
        )
        let rc = setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &tv,
            socklen_t(MemoryLayout<timeval>.size)
        )
        guard rc == 0 else {
            throw ICMPPingError.optionFailed(errno: errno)
        }
    }

    private nonisolated static func buildEchoRequest(
        identifier: UInt16,
        sequence: UInt16,
        sentNanos: UInt64
    ) -> Data {
        var payload = Data()
        var nanosBE = sentNanos.bigEndian
        payload.append(contentsOf: withUnsafeBytes(of: &nanosBE) { Data($0) })

        var packet = Data()
        packet.append(echoRequestType)
        packet.append(0)
        packet.append(contentsOf: [0, 0])
        packet.append(contentsOf: identifier.bigEndianData)
        packet.append(contentsOf: sequence.bigEndianData)
        packet.append(payload)

        let checksum = icmpChecksum(packet)
        packet.replaceSubrange(2 ..< 4, with: checksum.bigEndianData)
        return packet
    }

    /// macOS (and other BSDs) often deliver `recv` buffers as **IPv4 header + ICMP**; Linux typically delivers ICMP only.
    internal nonisolated static func icmpStartOffset(in data: Data) -> Int {
        guard data.count >= 20 else { return 0 }
        let version = data[0] >> 4
        guard version == 4 else { return 0 }
        let headerLen = Int(data[0] & 0x0f) * 4
        guard headerLen >= 20, headerLen <= data.count else { return 0 }
        // IPv4 protocol field: 1 = ICMP
        guard data[9] == 1 else { return 0 }
        return headerLen
    }

    internal nonisolated static func parseEchoReply(
        data: Data,
        expectedIdentifier: UInt16,
        expectedSequence: UInt16,
        sentNanos: UInt64
    ) -> Double? {
        let icmpOffset = icmpStartOffset(in: data)
        guard data.count >= icmpOffset + 16 else { return nil }

        let type = data[icmpOffset]
        guard type == echoReplyType else { return nil }

        let idOffset = icmpOffset + 4
        let seqOffset = icmpOffset + 6
        let payloadOffset = icmpOffset + 8

        let identifier = UInt16(bigEndian: data.withUnsafeBytes { $0.load(fromByteOffset: idOffset, as: UInt16.self) })
        let sequence = UInt16(bigEndian: data.withUnsafeBytes { $0.load(fromByteOffset: seqOffset, as: UInt16.self) })
        guard identifier == expectedIdentifier, sequence == expectedSequence else {
            return nil
        }
        let echoed = readUInt64BigEndian(data, offset: payloadOffset)
        guard echoed == sentNanos else { return nil }

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedNs = now >= sentNanos ? now - sentNanos : 0
        return Double(elapsedNs) / 1_000_000
    }

    private nonisolated static func readUInt64BigEndian(_ data: Data, offset: Int) -> UInt64 {
        guard data.count >= offset + 8 else { return 0 }
        var value: UInt64 = 0
        for i in 0 ..< 8 {
            value = (value << 8) | UInt64(data[offset + i])
        }
        return value
    }

    private nonisolated static func icmpChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        let count = data.count
        var i = 0
        while i < count - 1 {
            sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }
        if i < count {
            sum += UInt32(data[i]) << 8
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xffff) + (sum >> 16)
        }
        return UInt16(truncatingIfNeeded: ~sum)
    }

    private static let sequenceLock = NSLock()
    private static var sequence: UInt16 = 0

    private nonisolated static func nextSequence() -> UInt16 {
        sequenceLock.lock()
        defer { sequenceLock.unlock() }
        sequence &+= 1
        return sequence
    }
}

private extension UInt16 {
    var bigEndianData: Data {
        var value = self.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
