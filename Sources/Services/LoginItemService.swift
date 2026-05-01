import Darwin
import Foundation
import ServiceManagement

@MainActor
final class LoginItemService {
    private let logger: LoggingService

    init(logger: LoggingService) {
        self.logger = logger
    }

    private static func isExpectedPermissionOrEnvironmentFailure(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        if text.contains("operation not permitted") { return true }
        if text.contains("not permitted") { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EPERM) { return true }
        return false
    }

    func apply(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                logger.log(.notice, category: .config, "Launch at login enabled")
            } else {
                try SMAppService.mainApp.unregister()
                logger.log(.notice, category: .config, "Launch at login disabled")
            }
        } catch {
            if Self.isExpectedPermissionOrEnvironmentFailure(error) {
                logger.log(
                    .notice,
                    category: .config,
                    "Launch at login could not be updated (permission or app requirements). \(error.localizedDescription)"
                )
            } else {
                logger.log(
                    .error,
                    category: .errors,
                    "Failed to update launch-at-login registration: \(error.localizedDescription)"
                )
            }
        }
    }
}
