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

        let viewModel = NetworkMonitorViewModel(settingsStore: SettingsStore())
        self.viewModel = viewModel
        let status = StatusItemController(viewModel: viewModel)
        statusItemController = status
        status.setup()
        viewModel.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.stop()
    }
}
