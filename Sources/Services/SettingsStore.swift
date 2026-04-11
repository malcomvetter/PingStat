import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    @Published var config: AppConfig {
        didSet {
            persist()
        }
    }

    private let defaults: UserDefaults
    private let key = "MacNetStatus.AppConfig"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(AppConfig.self, from: data)
        {
            config = decoded
        } else {
            config = .default
        }
    }

    func resetDefaults() {
        config = .default
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(config) else { return }
        defaults.set(encoded, forKey: key)
    }
}
