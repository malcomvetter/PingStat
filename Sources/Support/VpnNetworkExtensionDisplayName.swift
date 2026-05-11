import Foundation
@preconcurrency import NetworkExtension

/// Best-effort VPN title from **Network Extension** APIs—the same configuration store that backs **System Settings › Network › VPN**,
/// though Apple only fully exposes **other apps’** profiles to their own binaries. We still read anything the system grants this process,
/// then fall back to ``NativeNetworkConfiguration.networkServiceDisplayName(forBSDInterface:)``.
enum VpnNetworkExtensionDisplayName {

    /// Prefer ``NETunnelProviderManager`` entries (packet-tunnel apps), then ``NEVPNManager.shared()`` (system VPN slot).
    static func preferredActiveTitle() async -> String? {
        if let t = await titleFromTunnelProviderManagers() { return t }
        return await titleFromSharedVPNManager()
    }

    // MARK: - Private

    private static func titleFromTunnelProviderManagers() async -> String? {
        await withCheckedContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                guard error == nil, let managers, !managers.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Self.pickTitle(from: managers))
            }
        }
    }

    private static func titleFromSharedVPNManager() async -> String? {
        await withCheckedContinuation { continuation in
            let manager = NEVPNManager.shared()
            manager.loadFromPreferences { error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                let title = (manager.localizedDescription ?? "")
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard !title.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                switch manager.connection.status {
                case .connected, .connecting, .reasserting:
                    continuation.resume(returning: title)
                default:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func pickTitle(from managers: [NEVPNManager]) -> String? {
        func rank(_ status: NEVPNStatus) -> Int {
            switch status {
            case .connected: return 0
            case .connecting, .reasserting: return 1
            case .disconnecting: return 2
            case .invalid, .disconnected: return 3
            @unknown default: return 9
            }
        }

        let sorted = managers.sorted { lhs, rhs in
            let lr = rank(lhs.connection.status)
            let rr = rank(rhs.connection.status)
            if lr != rr { return lr < rr }
            let ld = lhs.localizedDescription ?? ""
            let rd = rhs.localizedDescription ?? ""
            return ld.localizedCaseInsensitiveCompare(rd) == .orderedAscending
        }

        for manager in sorted {
            let title = (manager.localizedDescription ?? "")
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            switch manager.connection.status {
            case .connected, .connecting, .reasserting:
                return title
            default:
                continue
            }
        }
        return nil
    }
}
