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

    func testDNSProbeDetailNameserverKeyHandlesZonedIPv6() {
        let line =
            "@fe80::783f:4dff:feea:ad64%en0 Q A captive.apple.com → CNAME captive.g.aaplimg.com.; A 17.253.7.133"
        XCTAssertEqual(DNSProbeDetailLine.nameserverKey(from: line), "fe80::783f:4dff:feea:ad64%en0")
    }

    func testDNSProbeDetailNameserverKeyIPv4() {
        let line = "@192.168.1.1 Q A example.com → A 93.184.216.34"
        XCTAssertEqual(DNSProbeDetailLine.nameserverKey(from: line), "192.168.1.1")
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
                dnsServers: [],
                vpnPathActive: false,
                vpnDefaultInterfaceName: nil,
                vpnTunnelGatewayIPv4: nil,
                dnsServersVPN: []
            ),
            endpointStatuses: [:],
            dnsStatus: DNSCheckStatus(),
            config: .defaults,
            lowDataModePathActive: false
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
                dnsServers: ["9.9.9.9"],
                vpnPathActive: false,
                vpnDefaultInterfaceName: nil,
                vpnTunnelGatewayIPv4: nil,
                dnsServersVPN: []
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
            config: .defaults,
            lowDataModePathActive: false
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
                dnsServers: ["192.168.1.1"],
                vpnPathActive: false,
                vpnDefaultInterfaceName: nil,
                vpnTunnelGatewayIPv4: nil,
                dnsServersVPN: []
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
            config: .defaults,
            lowDataModePathActive: false
        )

        let confirmations = AppConfig.defaults.statusChangeConfirmationCount
        for _ in 0 ..< confirmations {
            _ = evaluator.evaluate(input)
        }
        let snapshot = evaluator.evaluate(input)

        XCTAssertEqual(snapshot.state, .degraded)
    }

    func testAdjustedPingIntervalStacksLowPowerAndLowDataMode() {
        let c = AppConfig.defaults
        XCTAssertEqual(c.adjustedPingInterval(lowPowerMode: false, lowDataMode: false), 1, accuracy: 0.001)
        XCTAssertEqual(c.adjustedPingInterval(lowPowerMode: true, lowDataMode: false), 5, accuracy: 0.001)
        XCTAssertEqual(c.adjustedPingInterval(lowPowerMode: false, lowDataMode: true), 5, accuracy: 0.001)
        XCTAssertEqual(c.adjustedPingInterval(lowPowerMode: true, lowDataMode: true), 25, accuracy: 0.001)
    }

    /// `runDNSTick` passes this list as UDP fallbacks; hosts excluded here receive no DNS probes under LDM.
    func testFallbackDNSServersForProbesFiltersWhenLowDataModeActive() {
        var c = AppConfig.defaults
        c.pingCloudflareEnabled = true
        c.pingGoogleEnabled = true
        c.lowDataModeUseCloudflare = true
        c.lowDataModeUseGoogle = false
        XCTAssertEqual(c.fallbackDNSServersForProbes(lowDataModePathActive: false), ["1.1.1.1", "8.8.8.8"])
        XCTAssertEqual(c.fallbackDNSServersForProbes(lowDataModePathActive: true), ["1.1.1.1"])
    }

    func testHealthEvaluatorDoesNotTreatSkippedICMPAsAllMonitoredTimedOut() {
        let evaluator = HealthEvaluator()
        let now = Date()
        let timedOut = PingSample(
            timestamp: now,
            success: false,
            rttMs: nil,
            timedOut: true,
            message: "timeout"
        )
        let cloudflare = EndpointStatus(
            id: "cloudflare",
            label: "Cloudflare",
            host: "1.1.1.1",
            kind: .cloudflare,
            meanLast5Ms: nil,
            last10: [],
            latest: timedOut,
            icmpProbingActive: false,
            dnsProbingActive: false
        )
        let input = HealthEvaluationInput(
            context: .init(
                connected: true,
                interfaceName: "en0",
                interfaceType: "Wi-Fi",
                localIP: "10.0.0.2",
                gatewayIP: "10.0.0.1",
                dnsServers: ["1.1.1.1"],
                vpnPathActive: false,
                vpnDefaultInterfaceName: nil,
                vpnTunnelGatewayIPv4: nil,
                dnsServersVPN: []
            ),
            endpointStatuses: [.cloudflare: cloudflare],
            dnsStatus: DNSCheckStatus(lastCheck: now, resolvedIPs: ["17.253.144.10"]),
            config: .defaults,
            lowDataModePathActive: false
        )
        let confirmations = AppConfig.defaults.statusChangeConfirmationCount
        for _ in 0 ..< confirmations {
            _ = evaluator.evaluate(input)
        }
        let snapshot = evaluator.evaluate(input)
        XCTAssertNotEqual(snapshot.state, .offline)
        XCTAssertFalse(snapshot.reason.contains("All monitored endpoints timed out"))
    }

    func testHealthEvaluatorAppendsLowDataModeSuffixToReason() {
        let evaluator = HealthEvaluator()
        let now = Date()
        let cloudflare = EndpointStatus(
            id: "cloudflare",
            label: "Cloudflare",
            host: "1.1.1.1",
            kind: .cloudflare,
            meanLast5Ms: 20,
            last10: [],
            latest: .init(timestamp: now, success: true, rttMs: 20, timedOut: false, message: "ok"),
            icmpProbingActive: true,
            dnsProbingActive: true
        )
        let input = HealthEvaluationInput(
            context: .init(
                connected: true,
                interfaceName: "en0",
                interfaceType: "Wi-Fi",
                localIP: "10.0.0.2",
                gatewayIP: "10.0.0.1",
                dnsServers: ["1.1.1.1"],
                vpnPathActive: false,
                vpnDefaultInterfaceName: nil,
                vpnTunnelGatewayIPv4: nil,
                dnsServersVPN: []
            ),
            endpointStatuses: [.cloudflare: cloudflare],
            dnsStatus: DNSCheckStatus(),
            config: .defaults,
            lowDataModePathActive: true
        )
        let confirmations = AppConfig.defaults.statusChangeConfirmationCount
        for _ in 0 ..< confirmations {
            _ = evaluator.evaluate(input)
        }
        let snapshot = evaluator.evaluate(input)
        XCTAssertTrue(snapshot.reason.hasSuffix(" – Low Data Mode"))
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

    // MARK: - Low Data Mode probe eligibility

    /// Ping/DNS loops only hit endpoints with `icmpProbingActive` / `dnsProbingActive`; those flags are set from
    /// `LowDataModeProbeEligibility`, matching `NetworkMonitorViewModel.rebuildEndpoints()`.
    func testLowDataModeDisablesWANICMPAndDNSWhenPerResolverLDMToggleOff() {
        var c = AppConfig.defaults
        c.lowDataModeUseGoogle = false
        XCTAssertFalse(
            LowDataModeProbeEligibility.wanProbingEligible(lowDataModePathActive: true, config: c, kind: .google),
            "LDM on and “Use in Low Data Mode” off for Google ⇒ no ICMP/DNS to that resolver"
        )
    }

    func testLowDataModeAllowsWANProbesWhenPerResolverLDMToggleOn() {
        var c = AppConfig.defaults
        c.lowDataModeUseCloudflare = true
        XCTAssertTrue(
            LowDataModeProbeEligibility.wanProbingEligible(lowDataModePathActive: true, config: c, kind: .cloudflare)
        )
    }

    func testWANProbesIgnoreLDMResolverTogglesWhenLowDataModePathInactive() {
        var c = AppConfig.defaults
        c.lowDataModeUseGoogle = false
        XCTAssertTrue(
            LowDataModeProbeEligibility.wanProbingEligible(lowDataModePathActive: false, config: c, kind: .google),
            "Normal path: probes run to all master-enabled WAN targets regardless of LDM toggles"
        )
    }

    func testLowDataModeNeverSendsGatewayICMP() {
        XCTAssertFalse(LowDataModeProbeEligibility.gatewayICMPProbingActive(lowDataModePathActive: true))
        XCTAssertTrue(LowDataModeProbeEligibility.gatewayICMPProbingActive(lowDataModePathActive: false))
    }

    func testLowDataModeGatewayDNSEnabledOnlyWithLocalNetworkLDMToggle() {
        var c = AppConfig.defaults
        c.lowDataModeUseLocalNetworkDNS = false
        XCTAssertFalse(
            LowDataModeProbeEligibility.gatewayDNSProbingActive(lowDataModePathActive: true, config: c),
            "LDM on without “Use system DNS in Low Data Mode” ⇒ no DNS probes to system resolvers"
        )
        c.lowDataModeUseLocalNetworkDNS = true
        XCTAssertTrue(LowDataModeProbeEligibility.gatewayDNSProbingActive(lowDataModePathActive: true, config: c))
    }

    func testLowDataModeDisablesCustomICMPAndDNSWhenUseInLowDataModeOff() {
        let target = CustomPingTarget(
            label: "x",
            ipAddress: "10.0.0.5",
            dnsProbesEnabled: true,
            useInLowDataMode: false
        )
        XCTAssertFalse(LowDataModeProbeEligibility.customICMPProbingActive(lowDataModePathActive: true, target: target))
        XCTAssertFalse(LowDataModeProbeEligibility.customDNSProbingActive(lowDataModePathActive: true, target: target))
    }

    func testLowDataModeCustomDNSOffWhenDNSToggleOffEvenIfUseInLowDataModeOn() {
        let target = CustomPingTarget(
            label: "x",
            ipAddress: "10.0.0.5",
            dnsProbesEnabled: false,
            useInLowDataMode: true
        )
        XCTAssertTrue(LowDataModeProbeEligibility.customICMPProbingActive(lowDataModePathActive: true, target: target))
        XCTAssertFalse(
            LowDataModeProbeEligibility.customDNSProbingActive(lowDataModePathActive: true, target: target),
            "No DNS column ⇒ no DNS probes"
        )
    }

    func testWideInternetIPv4RouteRecognizesSplitDefaults() {
        XCTAssertTrue(
            NativeNetworkConfiguration.isWideInternetIPv4DestinationAndMask(destinationIPv4: "0.0.0.0", netmaskIPv4: nil)
        )
        XCTAssertTrue(
            NativeNetworkConfiguration.isWideInternetIPv4DestinationAndMask(destinationIPv4: "0.0.0.0", netmaskIPv4: "0.0.0.0")
        )
        XCTAssertTrue(
            NativeNetworkConfiguration.isWideInternetIPv4DestinationAndMask(destinationIPv4: "0.0.0.0", netmaskIPv4: "128.0.0.0")
        )
        XCTAssertTrue(
            NativeNetworkConfiguration.isWideInternetIPv4DestinationAndMask(destinationIPv4: "128.0.0.0", netmaskIPv4: "128.0.0.0")
        )
        XCTAssertFalse(
            NativeNetworkConfiguration.isWideInternetIPv4DestinationAndMask(destinationIPv4: "10.0.0.0", netmaskIPv4: "255.0.0.0")
        )
        XCTAssertFalse(
            NativeNetworkConfiguration.isWideInternetIPv4DestinationAndMask(destinationIPv4: "0.0.0.0", netmaskIPv4: "255.0.0.0")
        )
    }

    func testVPNPathEvaluatorDetectsUtunDefaultRoute() {
        let r = VPNPathEvaluator.evaluate(
            primaryInterface: "en0",
            primaryRouterIPv4: "192.168.1.1",
            defaultRouteInterface: "utun4",
            defaultRouteGatewayIPv4: "10.2.0.1"
        )
        XCTAssertTrue(r.active)
        XCTAssertEqual(r.vpnInterfaceName, "utun4")
        XCTAssertEqual(r.tunnelGatewayIPv4, "10.2.0.1")
    }

    func testVPNPathEvaluatorInactiveWhenPrimaryMatchesNonTunnelRoute() {
        let r = VPNPathEvaluator.evaluate(
            primaryInterface: "en0",
            primaryRouterIPv4: "192.168.1.1",
            defaultRouteInterface: "en0",
            defaultRouteGatewayIPv4: "192.168.1.1"
        )
        XCTAssertFalse(r.active)
        XCTAssertNil(r.vpnInterfaceName)
        XCTAssertNil(r.tunnelGatewayIPv4)
    }

    func testVPNPathEvaluatorDetectsPrimaryVsDefaultInterfaceMismatch() {
        let r = VPNPathEvaluator.evaluate(
            primaryInterface: "en0",
            primaryRouterIPv4: "192.168.1.1",
            defaultRouteInterface: "en9",
            defaultRouteGatewayIPv4: "192.168.1.1"
        )
        XCTAssertTrue(r.active)
        XCTAssertEqual(r.vpnInterfaceName, "en9")
    }

    func testVPNPathEvaluatorDetectsGatewayMismatchWhenInterfacesDiffer() {
        let r = VPNPathEvaluator.evaluate(
            primaryInterface: "en0",
            primaryRouterIPv4: "192.168.1.1",
            defaultRouteInterface: "en9",
            defaultRouteGatewayIPv4: "10.0.0.1"
        )
        XCTAssertTrue(r.active)
    }

    func testVPNPathEvaluatorNoDefaultInterfaceMeansInactive() {
        let r = VPNPathEvaluator.evaluate(
            primaryInterface: "en0",
            primaryRouterIPv4: "192.168.1.1",
            defaultRouteInterface: nil,
            defaultRouteGatewayIPv4: "10.0.0.1"
        )
        XCTAssertFalse(r.active)
    }

    func testLowDataModeVpnTunnelICMPOffMatchesGateway() {
        XCTAssertFalse(LowDataModeProbeEligibility.vpnTunnelICMPProbingActive(lowDataModePathActive: true))
        XCTAssertTrue(LowDataModeProbeEligibility.vpnTunnelICMPProbingActive(lowDataModePathActive: false))
    }

    func testLowDataModeVpnTunnelDNSUsesSystemLocalNetworkToggle() {
        var c = AppConfig.defaults
        c.lowDataModeUseLocalNetworkDNS = false
        XCTAssertFalse(
            LowDataModeProbeEligibility.vpnTunnelDNSProbingActive(lowDataModePathActive: true, config: c)
        )
        c.lowDataModeUseLocalNetworkDNS = true
        XCTAssertTrue(
            LowDataModeProbeEligibility.vpnTunnelDNSProbingActive(lowDataModePathActive: true, config: c)
        )
    }
}
