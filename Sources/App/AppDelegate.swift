import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private var viewModel: NetworkMonitorViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let viewModel = NetworkMonitorViewModel()
        self.viewModel = viewModel
        statusItemController = StatusItemController(viewModel: viewModel)
        statusItemController?.setup()
        viewModel.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel?.stop()
    }
}
