import Foundation

@MainActor
final class AppContainer {
    static let shared = AppContainer()

    let viewModel = NetworkMonitorViewModel()

    private init() {}
}
