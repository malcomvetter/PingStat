import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusItemController {
    private let viewModel: NetworkMonitorViewModel
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var cancellables = Set<AnyCancellable>()

    init(viewModel: NetworkMonitorViewModel) {
        self.viewModel = viewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
    }

    func setup() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        updateStatusIcon(for: viewModel.snapshot.state)
        viewModel.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.updateStatusIcon(for: snapshot.state)
            }
            .store(in: &cancellables)

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 420, height: 340)
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(viewModel: viewModel)
        )
    }

    @objc
    private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusIcon(for state: NetworkHealthState) {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: state.systemImageName, accessibilityDescription: state.title)
        image?.isTemplate = true
        button.image = image
        button.toolTip = "MacNetStatus: \(state.title)"
    }
}
