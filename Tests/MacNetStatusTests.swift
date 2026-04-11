import XCTest
@testable import MacNetStatus

@MainActor
final class MacNetStatusTests: XCTestCase {
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
            config: .default
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
                .google: google
            ],
            dnsStatus: DNSCheckStatus(),
            config: .default
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
        let input = HealthEvaluationInput(
            context: .init(
                connected: true,
                interfaceName: "en0",
                interfaceType: "Ethernet/Wi-Fi",
                localIP: "192.168.1.25",
                gatewayIP: "192.168.1.1",
                dnsServers: ["192.168.1.1"]
            ),
            endpointStatuses: [:],
            dnsStatus: dns,
            config: .default
        )

        _ = evaluator.evaluate(input)
        let snapshot = evaluator.evaluate(input)

        XCTAssertEqual(snapshot.state, .degraded)
    }
}
