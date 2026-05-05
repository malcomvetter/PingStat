import Foundation

/// Bundle metadata for UI and logging (reads generated Info.plist keys).
enum AppVersion {
    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    static var marketing: String {
        let s = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "0" : s
    }

    static var build: String {
        let s = (info["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "0" : s
    }

    /// Example: `1.0.1 (2)`
    static var marketingAndBuild: String {
        "\(marketing) (\(build))"
    }

    /// Subsystem string used by ``LoggingService`` and `Logger` (matches bundle id in release builds).
    static var loggingSubsystem: String {
        Bundle.main.bundleIdentifier ?? "org.malcomvetter.PingStat"
    }

    /// Paste into Console.app’s filter bar to show only this app’s unified logs.
    static var consoleSubsystemFilter: String {
        "subsystem:\(loggingSubsystem)"
    }

    /// Example `log stream` invocation for Terminal (subsystem matches this app’s bundle id).
    static var logStreamShellExample: String {
        "log stream --predicate 'subsystem == \"\(loggingSubsystem)\"' --level debug"
    }

    /// Single line for unified logging at process launch (filter-friendly `key=value` fields).
    static var lifecycleLaunchLogLine: String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let pid = ProcessInfo.processInfo.processIdentifier
        let bid = Bundle.main.bundleIdentifier ?? "unknown"
        return "event=app_launch version=\(marketing) build=\(build) bundle_id=\(bid) pid=\(pid) os=\"\(os)\""
    }
}
