import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    @Published var config: AppConfig {
        didSet {
            persist()
        }
    }

    /// True when no saved settings existed at launch (a fresh install).
    let isFirstLaunch: Bool

    private let defaults: UserDefaults
    private let key = "PingStat.AppConfig"
    private static let legacyDefaultsKey = "MacNetStatus.AppConfig"
    private static let launchAtLoginPromptedKey = "PingStat.LaunchAtLoginPrompted"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isFirstLaunch = defaults.data(forKey: key) == nil && defaults.data(forKey: Self.legacyDefaultsKey) == nil
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

    /// Returns true exactly once per fresh install; existing installs never see the prompt.
    func consumeLaunchAtLoginPrompt() -> Bool {
        guard !defaults.bool(forKey: Self.launchAtLoginPromptedKey) else { return false }
        defaults.set(true, forKey: Self.launchAtLoginPromptedKey)
        return isFirstLaunch && !config.launchAtLoginEnabled
    }

    func resetDefaults() {
        config = .defaults
    }

    private func persist() {
        guard let encoded = try? JSONEncoder().encode(config) else { return }
        defaults.set(encoded, forKey: key)
    }
}
