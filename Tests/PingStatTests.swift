import Darwin
import XCTest
@testable import PingStat

@MainActor
final class PingStatTests: XCTestCase {
    func testHealthEvaluatorMarksOfflineWhenNoConnectivity() {
        let evaluator = HealthEvaluator()
        let input = HealthEvaluationInput(
            context: .init(
                connected: false,
                interfaceName: nil,
                interfaceType: nil,
                localIP: nil,
                gatewayIP: nil,
                dnsServers: []
            ),
            endpointStatuses: [:],
            dnsStatus: DNSCheckStatus(),
            config: .defaults
        )

        _ = evaluator.evaluate(input)
        let snapshot = evaluator.evaluate(input)

        XCTAssertEqual(snapshot.state, .offline)
    }

    func testHealthEvaluatorClassifiesBlazing() {
        let evaluator = HealthEvaluator()
        let now = Date()
        let gateway = EndpointStatus(
            id: "gateway",
            label: "Gateway",
            host: "192.168.1.1",
            kind: .gateway,
            meanLast5Ms: 3,
            last10: [],
            latest: .init(timestamp: now, success: true, rttMs: 3, timedOut: false, message: "ok")
        )
        let cloudflare = EndpointStatus(
            id: "cloudflare",
            label: "Cloudflare",
            host: "1.1.1.1",
            kind: .cloudflare,
            meanLast5Ms: 18,
            last10: [],
            latest: .init(timestamp: now, success: true, rttMs: 18, timedOut: false, message: "ok")
        )
        let google = EndpointStatus(
            id: "google",
            label: "Google",
            host: "8.8.8.8",
            kind: .google,
            meanLast5Ms: 22,
            last10: [],
            latest: .init(timestamp: now, success: true, rttMs: 22, timedOut: false, message: "ok")
        )
        let openDNS = EndpointStatus(
            id: "opendns",
            label: "OpenDNS",
            host: "208.67.220.220",
            kind: .openDNS,
            meanLast5Ms: 21,
            last10: [],
            latest: .init(timestamp: now, success: true, rttMs: 21, timedOut: false, message: "ok")
        )
        let level3 = EndpointStatus(
            id: "level3",
            label: "Level3",
            host: "4.2.2.1",
            kind: .level3,
            meanLast5Ms: 19,
            last10: [],
            latest: .init(timestamp: now, success: true, rttMs: 19, timedOut: false, message: "ok")
        )
        let quad9 = EndpointStatus(
            id: "quad9",
            label: "Quad9",
            host: "9.9.9.9",
            kind: .quad9,
            meanLast5Ms: 20,
            last10: [],
            latest: .init(timestamp: now, success: true, rttMs: 20, timedOut: false, message: "ok")
        )
        let input = HealthEvaluationInput(
            context: .init(
                connected: true,
                interfaceName: "en0",
                interfaceType: "Ethernet/Wi-Fi",
                localIP: "192.168.1.25",
                gatewayIP: "192.168.1.1",
                dnsServers: ["9.9.9.9"]
            ),
            endpointStatuses: [
                .gateway: gateway,
                .cloudflare: cloudflare,
                .google: google,
                .openDNS: openDNS,
                .level3: level3,
                .quad9: quad9
            ],
            dnsStatus: DNSCheckStatus(),
            config: .defaults
        )

        _ = evaluator.evaluate(input)
        _ = evaluator.evaluate(input)
        let snapshot = evaluator.evaluate(input)

        XCTAssertEqual(snapshot.state, .blazing)
    }

    func testHealthEvaluatorClassifiesDegradedWhenDNSFiltered() {
        let evaluator = HealthEvaluator()
        var dns = DNSCheckStatus()
        dns.allConfiguredTimedOut = true
        dns.fallbackWorked = true
        let now = Date()
        let gateway = EndpointStatus(
            id: "gateway",
            label: "Gateway",
            host: "192.168.1.1",
            kind: .gateway,
            meanLast5Ms: 5,
            last10: [],
            latest: .init(timestamp: now, success: true, rttMs: 5, timedOut: false, message: "ok")
        )
        let cloudflare = EndpointStatus(
            id: "cloudflare",
            label: "Cloudflare",
            host: "1.1.1.1",
            kind: .cloudflare,
            meanLast5Ms: 50,
            last10: [],
            latest: .init(timestamp: now, success: true, rttMs: 50, timedOut: false, message: "ok")
        )
        let google = EndpointStatus(
            id: "google",
            label: "Google",
            host: "8.8.8.8",
            kind: .google,
            meanLast5Ms: 55,
            last10: [],
            latest: .init(timestamp: now, success: true, rttMs: 55, timedOut: false, message: "ok")
        )
        let openDNS = EndpointStatus(
            id: "opendns",
            label: "OpenDNS",
            host: "208.67.220.220",
            kind: .openDNS,
            meanLast5Ms: 53,
            last10: [],
            latest: .init(timestamp: now, success: true, rttMs: 53, timedOut: false, message: "ok")
        )
        let level3 = EndpointStatus(
            id: "level3",
            label: "Level3",
            host: "4.2.2.1",
            kind: .level3,
            meanLast5Ms: 54,
            last10: [],
            latest: .init(timestamp: now, success: true, rttMs: 54, timedOut: false, message: "ok")
        )
        let quad9 = EndpointStatus(
            id: "quad9",
            label: "Quad9",
            host: "9.9.9.9",
            kind: .quad9,
            meanLast5Ms: 52,
            last10: [],
            latest: .init(timestamp: now, success: true, rttMs: 52, timedOut: false, message: "ok")
        )
        let input = HealthEvaluationInput(
            context: .init(
                connected: true,
                interfaceName: "en0",
                interfaceType: "Ethernet/Wi-Fi",
                localIP: "192.168.1.25",
                gatewayIP: "192.168.1.1",
                dnsServers: ["192.168.1.1"]
            ),
            endpointStatuses: [
                .gateway: gateway,
                .cloudflare: cloudflare,
                .google: google,
                .openDNS: openDNS,
                .level3: level3,
                .quad9: quad9
            ],
            dnsStatus: dns,
            config: .defaults
        )

        for _ in 0 ..< 4 {
            _ = evaluator.evaluate(input)
        }
        let snapshot = evaluator.evaluate(input)

        XCTAssertEqual(snapshot.state, .degraded)
    }

    func testCollectNameserversFromScutilKeepsFullIPv6Literal() {
        let sample = """
        resolver #1
          nameserver[0] : 2001:4860:4860::8888
          nameserver[1] : 8.8.8.8
        """
        let servers = NetworkContextService.collectNameserversInOrder(from: sample)
        XCTAssertEqual(servers, ["2001:4860:4860::8888", "8.8.8.8"])
    }

    func testCollectNameserversAddsNumericZoneFromIfIndexForLinkLocalIPv6() {
        let sample = """
        resolver #1
          nameserver[0] : fe80::783f:4dff:feea:ad64
          if_index : 14 (en0)
        resolver #2
          nameserver[0] : 8.8.8.8
        """
        let servers = NetworkContextService.collectNameserversInOrder(from: sample)
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers[0], "fe80::783f:4dff:feea:ad64%14")
        XCTAssertEqual(servers[1], "8.8.8.8")
    }

    func testCollectNameserversIfIndexBeforeNameserverStillScopesLinkLocal() {
        let sample = """
        resolver #1
          if_index : 3 (lo0)
          nameserver[0] : fe80::1
        """
        let servers = NetworkContextService.collectNameserversInOrder(from: sample)
        XCTAssertEqual(servers, ["fe80::1%3"])
    }

    func testICMPEchoReplyParsingSkipsPrependedIPv4Header() {
        let sentNanos: UInt64 = 0x1234_5678_90AB_CDEF
        let identifier: UInt16 = 0xABCD
        let sequence: UInt16 = 42

        var icmp = Data()
        icmp.append(0)
        icmp.append(0)
        icmp.append(contentsOf: [0, 0])
        var idBE = identifier.bigEndian
        icmp.append(contentsOf: withUnsafeBytes(of: &idBE) { Data($0) })
        var seqBE = sequence.bigEndian
        icmp.append(contentsOf: withUnsafeBytes(of: &seqBE) { Data($0) })
        var nanoBE = sentNanos.bigEndian
        icmp.append(contentsOf: withUnsafeBytes(of: &nanoBE) { Data($0) })

        XCTAssertNotNil(
            ICMPPing.parseEchoReply(
                data: icmp,
                expectedIdentifier: identifier,
                expectedSequence: sequence,
                sentNanos: sentNanos
            )
        )

        var withIPv4 = Data(count: 20)
        withIPv4[0] = 0x45
        withIPv4[9] = 1
        withIPv4.append(icmp)

        XCTAssertEqual(ICMPPing.icmpStartOffset(in: withIPv4), 20)
        XCTAssertNotNil(
            ICMPPing.parseEchoReply(
                data: withIPv4,
                expectedIdentifier: identifier,
                expectedSequence: sequence,
                sentNanos: sentNanos
            )
        )
    }

    func testParseIPv6NameserverLinkLocalScope() {
        let global = DNSUDPQuery.parseIPv6Nameserver("2001:db8::1")
        XCTAssertEqual(global?.address, "2001:db8::1")
        XCTAssertEqual(global?.scopeId, 0)

        let lo = "lo0".withCString { if_nametoindex($0) }
        guard lo > 0 else {
            XCTSkip("lo0 not available")
            return
        }
        let scoped = DNSUDPQuery.parseIPv6Nameserver("fe80::1%lo0")
        XCTAssertEqual(scoped?.address, "fe80::1")
        XCTAssertEqual(scoped?.scopeId, lo)
    }
}
