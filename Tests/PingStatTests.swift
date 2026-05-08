import Darwin
import XCTest
@testable import PingStat

@MainActor
final class PingStatTests: XCTestCase {
    func testConnectivityProbePolicySkipsICMPAndDNSWhenPathUnsatisfied() {
        XCTAssertFalse(ConnectivityProbePolicy.shouldRunICMPProbes(pathSatisfied: false))
        XCTAssertFalse(ConnectivityProbePolicy.shouldRunDNSProbes(pathSatisfied: false))
        XCTAssertTrue(ConnectivityProbePolicy.shouldRunICMPProbes(pathSatisfied: true))
        XCTAssertTrue(ConnectivityProbePolicy.shouldRunDNSProbes(pathSatisfied: true))
    }

    func testFallbackDNSServersOnlyIncludesEnabledWANTargets() {
        var c = AppConfig.defaults
        c.pingCloudflareEnabled = false
        c.pingGoogleEnabled = true
        c.pingOpenDNSEnabled = false
        c.pingLevel3Enabled = false
        c.pingQuad9Enabled = false
        XCTAssertEqual(c.fallbackDNSServers, ["8.8.8.8"])
        XCTAssertEqual(c.enabledWanResolverTargets.map(\.kind), [.google])
    }

    func testFallbackDNSServersEmptyWhenAllPublicWANDisabled() {
        var c = AppConfig.defaults
        c.pingCloudflareEnabled = false
        c.pingGoogleEnabled = false
        c.pingOpenDNSEnabled = false
        c.pingLevel3Enabled = false
        c.pingQuad9Enabled = false
        XCTAssertTrue(c.fallbackDNSServers.isEmpty)
        XCTAssertTrue(c.enabledWanResolverTargets.isEmpty)
    }

    func testOfflineProbeDisplayClearsEndpointHistory() {
        let now = Date()
        let sample = PingSample(
            timestamp: now,
            success: true,
            rttMs: 12,
            timedOut: false,
            message: "ok"
        )
        let ep = EndpointStatus(
            id: "cloudflare",
            label: "Cloudflare",
            host: "1.1.1.1",
            kind: .cloudflare,
            meanLast5Ms: 12,
            last10: [sample],
            latest: sample
        )
        let cleared = OfflineProbeDisplayPolicy.probeHistoryClearedEndpoints([ep])
        XCTAssertEqual(cleared.count, 1)
        XCTAssertTrue(cleared[0].last10.isEmpty)
        XCTAssertNil(cleared[0].latest)
        XCTAssertNil(cleared[0].meanLast5Ms)
    }

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
        let centuryLink = EndpointStatus(
            id: "level3",
            label: "CenturyLink",
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
                .level3: centuryLink,
                .quad9: quad9
            ],
            dnsStatus: DNSCheckStatus(),
            config: .defaults
        )

        let confirmations = AppConfig.defaults.statusChangeConfirmationCount
        for _ in 0 ..< confirmations {
            _ = evaluator.evaluate(input)
        }
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
        let centuryLink = EndpointStatus(
            id: "level3",
            label: "CenturyLink",
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
                .level3: centuryLink,
                .quad9: quad9
            ],
            dnsStatus: dns,
            config: .defaults
        )

        let confirmations = AppConfig.defaults.statusChangeConfirmationCount
        for _ in 0 ..< confirmations {
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

    func testParseDNSDetailedResponseIncludesATypeAndRdata() {
        let id: UInt16 = 0xACE1
        var d = Data()
        d.append(UInt8(truncatingIfNeeded: id >> 8))
        d.append(UInt8(truncatingIfNeeded: id & 0xff))
        d.append(contentsOf: [0x81, 0x80])
        d.append(contentsOf: [0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        func label(_ s: String) {
            let b = Array(s.utf8)
            d.append(UInt8(b.count))
            d.append(contentsOf: b)
        }
        label("captive")
        label("apple")
        label("com")
        d.append(0)
        d.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        d.append(contentsOf: [0xc0, 0x0c])
        d.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        d.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        d.append(contentsOf: [0x00, 0x04])
        d.append(contentsOf: [17, 253, 144, 10])

        let r = DNSUDPQuery.parseDetailedResponse(data: d, expectedID: id)
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.ipv4Addresses, ["17.253.144.10"])
        XCTAssertEqual(r?.responseCode, 0)
        XCTAssertTrue(r?.answerSummaries.contains("A 17.253.144.10") ?? false)
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
