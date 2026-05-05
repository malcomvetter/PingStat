import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var viewModel: NetworkMonitorViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppResilience.install()
        // Menu bar + Settings window: refuse “last window closed” termination so the app keeps running.
        _ = NSApp.setActivationPolicy(.accessory)

        LoggingService.shared.log(.notice, category: .lifecycle, AppVersion.lifecycleLaunchLogLine)

        let viewModel = NetworkMonitorViewModel(settingsStore: SettingsStore())
        self.viewModel = viewModel
        let status = StatusItemController(viewModel: viewModel)
        statusItemController = status
        status.setup()
        viewModel.start()

        LoggingService.shared.log(
            .notice,
            category: .lifecycle,
            "event=app_ready phase=didFinishLaunching accessory_policy=1"
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        LoggingService.shared.log(
            .notice,
            category: .lifecycle,
            "event=app_terminate phase=willTerminate version=\(AppVersion.marketing) build=\(AppVersion.build)"
        )
        viewModel?.stop()
        LoggingService.shared.log(.notice, category: .lifecycle, "event=app_terminate phase=exited")
    }
}
