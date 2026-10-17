import AppKit
import Combine
import Sparkle

/// Sparkle updater (feed: `SUFeedURL` in Info.plist; archives are GitHub Release zips signed with `SUPublicEDKey`).
@MainActor
final class UpdateService: NSObject, ObservableObject {
    static let shared = UpdateService()

    @Published private(set) var automaticallyChecksForUpdates = false

    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        LoggingService.shared.log(
            .notice,
            category: .lifecycle,
            "event=updater_started feed=\(controller.updater.feedURL?.absoluteString ?? "none") auto_checks=\(automaticallyChecksForUpdates)"
        )
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = enabled
    }
}

extension UpdateService: SPUStandardUserDriverDelegate {
    // Menu bar (LSUIElement) app: opt in so Sparkle does not warn, and bring update windows to the front.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
