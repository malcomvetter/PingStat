import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    private let container = AppContainer.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        let viewModel = container.viewModel
        statusItemController = StatusItemController(viewModel: viewModel)
        statusItemController?.setup()
        viewModel.start()
    }
}
