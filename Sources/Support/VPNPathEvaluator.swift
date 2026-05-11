import Foundation

/// Whether IPv4 traffic is using a **VPN / tunnel** path vs the primary link’s DHCP gateway alone.
enum VPNPathEvaluator {
    struct Result: Equatable {
        var active: Bool
        /// Interface carrying the first IPv4 default route (often `utun*`).
        var vpnInterfaceName: String?
        /// Next-hop IPv4 on that default route, when present (tunnel inner / peer).
        var tunnelGatewayIPv4: String?
    }

    /// - Parameters:
    ///   - primaryInterface: `State:/Network/Global/IPv4` `PrimaryInterface` (physical link).
    ///   - primaryRouterIPv4: Router from the same store or per-service IPv4 for that interface (DHCP gateway).
    ///   - defaultRouteInterface: First IPv4 default route’s output interface (sysctl / `PF_ROUTE`).
    ///   - defaultRouteGatewayIPv4: Gateway on that same default route row.
    static func evaluate(
        primaryInterface: String?,
        primaryRouterIPv4: String?,
        defaultRouteInterface: String?,
        defaultRouteGatewayIPv4: String?
    ) -> Result {
        let physIf = trimmedNonEmpty(primaryInterface)
        let physGw = trimmedNonEmpty(primaryRouterIPv4)
        let defIf = trimmedNonEmpty(defaultRouteInterface)
        let defGw = trimmedNonEmpty(defaultRouteGatewayIPv4)

        guard let defIf else { return Result(active: false, vpnInterfaceName: nil, tunnelGatewayIPv4: nil) }

        let tunnelLike = NativeNetworkConfiguration.isLikelyVpnTunnelInterfaceName(defIf)
        let interfaceMismatch = physIf != nil && physIf != defIf
        let gatewayMismatch = physGw != nil && defGw != nil && physGw != defGw && physIf != defIf

        let active = tunnelLike || interfaceMismatch || gatewayMismatch
        guard active else {
            return Result(active: false, vpnInterfaceName: nil, tunnelGatewayIPv4: nil)
        }
        return Result(active: true, vpnInterfaceName: defIf, tunnelGatewayIPv4: defGw)
    }

    private static func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
