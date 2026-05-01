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
    private let key = "PingStat.AppConfig"
    private static let legacyDefaultsKey = "MacNetStatus.AppConfig"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
        } else if let data = defaults.data(forKey: Self.legacyDefaultsKey),
                  let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            if let encoded = try? JSONEncoder().encode(config) {
                defaults.set(encoded, forKey: key)
            }
        } else {
            config = .defaults
        }
    }

    func resetDefaults() {
        config = .defaults
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(config) else { return }
        defaults.set(encoded, forKey: key)
    }
}
