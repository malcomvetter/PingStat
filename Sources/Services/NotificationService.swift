import AppKit
import Foundation
import UserNotifications

/// User-facing summary for Settings: why banners might not appear and what to do next.
struct NotificationBannerHelp: Equatable {
    var headline: String
    var detail: String
    var showRequestPermissionButton: Bool

    static let unknown = Self(
        headline: "Status not loaded",
        detail: "Use “Refresh status” to see whether macOS allows \(AppBranding.productName) to show banner alerts.",
        showRequestPermissionButton: false
    )
}

@MainActor
final class NotificationService: NSObject {
    private let center = UNUserNotificationCenter.current()
    private let logger: LoggingService
    private var lastSentAtByKey: [String: Date] = [:]

    init(logger: LoggingService) {
        self.logger = logger
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    return
                case .denied, .ephemeral:
                    return
                case .notDetermined:
                    self.center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                        Task { @MainActor in
                            if let error {
                                Self.logAuthFailure(error: error, logger: self.logger)
                                return
                            }
                            if !granted {
                                self.logger.log(
                                    .notice,
                                    category: .config,
                                    "Notifications not granted; enable in System Settings if you want alerts."
                                )
                            }
                        }
                    }
                @unknown default:
                    return
                }
            }
        }
    }

    /// Opens System Settings on the Notifications pane so the user can allow banners for this app.
    func openSystemNotificationsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func bannerHelpSnapshot() async -> NotificationBannerHelp {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: Self.makeBannerHelp(from: settings))
            }
        }
    }

    /// Shows the system permission dialog when status is still “not determined”.
    func requestAuthorizationFromUserPrompt() async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                Task { @MainActor in
                    if let error {
                        Self.logAuthFailure(error: error, logger: self.logger)
                        continuation.resume(returning: false)
                        return
                    }
                    if !granted {
                        self.logger.log(
                            .notice,
                            category: .config,
                            "Notifications not granted; you can enable them in System Settings → Notifications."
                        )
                    }
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private nonisolated static func makeBannerHelp(from settings: UNNotificationSettings) -> NotificationBannerHelp {
        let app = AppBranding.productName
        switch settings.authorizationStatus {
        case .notDetermined:
            return NotificationBannerHelp(
                headline: "Permission not decided",
                detail:
                    "macOS has not been asked yet, or the choice was reset. Grant alerts so \(app) can show network banners.",
                showRequestPermissionButton: true
            )
        case .denied:
            return NotificationBannerHelp(
                headline: "Notifications are off for \(app)",
                detail:
                    "Banners are blocked until you allow this app. Open System Settings → Notifications, select \(app), then turn on notifications and choose Banners or Alerts.",
                showRequestPermissionButton: false
            )
        case .ephemeral:
            return NotificationBannerHelp(
                headline: "Limited notification access",
                detail:
                    "macOS granted only ephemeral delivery. For reliable banners, allow full notifications for \(app) in System Settings → Notifications.",
                showRequestPermissionButton: false
            )
        case .provisional:
            return NotificationBannerHelp(
                headline: "Quiet delivery only",
                detail:
                    "Notifications go to the Notification Center quietly. To get banners, open System Settings → Notifications and promote \(app) to full alerts.",
                showRequestPermissionButton: false
            )
        case .authorized:
            if settings.alertSetting == .disabled {
                return NotificationBannerHelp(
                    headline: "Banner style disabled",
                    detail:
                        "\(app) is allowed, but Alerts are turned off for this app. In System Settings → Notifications, enable Alerts and pick Banners or Alerts.",
                    showRequestPermissionButton: false
                )
            }
            return NotificationBannerHelp(
                headline: "Banners allowed",
                detail:
                    "\(app) can show banners for network changes. Focus or Do Not Disturb can still hide them temporarily.",
                showRequestPermissionButton: false
            )
        @unknown default:
            return NotificationBannerHelp(
                headline: "Unknown notification state",
                detail: "Use “Open System Settings” and check Notifications for \(app).",
                showRequestPermissionButton: false
            )
        }
    }

    private static func logAuthFailure(error: Error, logger: LoggingService) {
        let desc = error.localizedDescription
        if desc.localizedCaseInsensitiveContains("not allowed") {
            logger.log(
                .notice,
                category: .config,
                "Notifications are not allowed for this application. Enable in System Settings → Notifications if you want alerts."
            )
        } else {
            logger.log(.error, category: .errors, "Notification auth failed: \(desc)")
        }
    }

    func notifyStateTransition(
        to state: NetworkHealthState,
        reason: String,
        cooldownSeconds: Double
    ) {
        guard state == .offline || state == .degraded else { return }
        let key = "state-\(state.rawValue)"
        guard shouldSend(key: key, cooldownSeconds: cooldownSeconds) else { return }
        send(
            title: "Network \(state.title)",
            body: reason
        )
    }

    func notifyDNSFiltering(cooldownSeconds: Double) {
        let key = "dns-filtering"
        guard shouldSend(key: key, cooldownSeconds: cooldownSeconds) else { return }
        send(
            title: "DNS Filtering Detected",
            body: "Your network appears to filter DNS. Cloudflare/Google DNS still works."
        )
    }

    private func shouldSend(key: String, cooldownSeconds: Double) -> Bool {
        let now = Date()
        if let last = lastSentAtByKey[key], now.timeIntervalSince(last) < cooldownSeconds {
            return false
        }
        lastSentAtByKey[key] = now
        return true
    }

    private func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            guard let error else { return }
            Task { @MainActor in
                let desc = error.localizedDescription
                if desc.localizedCaseInsensitiveContains("not allowed") {
                    self.logger.log(
                        .notice,
                        category: .config,
                        "Skipped notification (not allowed). Check System Settings → Notifications for \(AppBranding.productName)."
                    )
                } else {
                    self.logger.log(.error, category: .errors, "Failed to post notification: \(desc)")
                }
            }
        }
    }
}

@MainActor
extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
