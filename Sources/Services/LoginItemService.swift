import Foundation
import ServiceManagement

@MainActor
final class LoginItemService {
    private let logger: LoggingService

    init(logger: LoggingService) {
        self.logger = logger
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
            logger.log(
                .error,
                category: .errors,
                "Failed to update launch-at-login registration: \(error.localizedDescription)"
            )
        }
    }
}
