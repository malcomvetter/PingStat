import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    private let center = UNUserNotificationCenter.current()
    private let logger: LoggingService
    private var lastSentAtByKey: [String: Date] = [:]

    init(logger: LoggingService) {
        self.logger = logger
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                self.logger.log(.error, category: .errors, "Notification auth failed: \(error.localizedDescription)")
            }
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
            if let error {
                self.logger.log(.error, category: .errors, "Failed to post notification: \(error.localizedDescription)")
            }
        }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
