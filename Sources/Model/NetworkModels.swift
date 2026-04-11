import Foundation

enum NetworkHealthState: String, Codable, CaseIterable {
    case offline
    case degraded
    case healthy
    case blazing

    var systemImageName: String {
        switch self {
        case .offline:
            return "xmark.octagon"
        case .degraded:
            return "exclamationmark.triangle"
        case .healthy:
            return "checkmark.circle"
        case .blazing:
            return "bolt"
        }
    }

    var title: String {
        rawValue.capitalized
    }
}

enum EndpointKind: String, Codable {
    case gateway
    case cloudflare
    case google
    case custom
}

struct PingTarget: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let label: String
    let host: String
    let kind: EndpointKind
}

struct PingSample: Codable, Equatable {
    let timestamp: Date
    let success: Bool
    let rttMs: Double?
    let timedOut: Bool
    let message: String
}

struct EndpointStatus: Identifiable, Codable, Equatable {
    let id: String
    let label: String
    let host: String
    let kind: EndpointKind
    var meanLast5Ms: Double?
    var last10: [PingSample]
    var latest: PingSample?

    var isOnline: Bool {
        latest?.success == true
    }
}

struct DNSCheckStatus: Codable, Equatable {
    var lastCheck: Date?
    var allConfiguredTimedOut: Bool = false
    var fallbackWorked: Bool = false
    var resolvedPrivateIP: Bool = false
    var configuredServers: [String] = []
    var fallbackServers: [String] = []
    var resolvedIPs: [String] = []
    var timedOutServers: [String] = []
}

struct NetworkContext: Codable, Equatable {
    var connected: Bool
    var interfaceName: String?
    var interfaceType: String?
    var localIP: String?
    var gatewayIP: String?
    var dnsServers: [String]

    static let empty = NetworkContext(
        connected: false,
        interfaceName: nil,
        interfaceType: nil,
        localIP: nil,
        gatewayIP: nil,
        dnsServers: []
    )
}

struct HealthSnapshot: Codable, Equatable {
    var state: NetworkHealthState
    var reason: String
    var updatedAt: Date
}
