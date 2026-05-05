import Foundation
import os

enum LogCategory: String, CaseIterable, Codable {
    case lifecycle = "app.lifecycle"
    case networkContext = "network.context"
    case ping = "probe.ping"
    case dns = "probe.dns"
    case health = "health.state"
    case ui = "ui.popover"
    case config = "config"
    case errors = "errors"
}

enum LogLevel: String, Codable {
    case debug
    case info
    case notice
    case error
    case fault
}

struct LogEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let category: LogCategory
    let message: String
}

actor LogRingBuffer {
    private var entries: [LogEntry] = []
    private let capacity: Int

    init(capacity: Int = 2_000) {
        self.capacity = max(100, capacity)
    }

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    func snapshot() -> [LogEntry] {
        entries
    }
}

final class LoggingService {
    /// Process-wide logger and ring buffer (menu bar apps should not create multiple buffers per launch).
    static let shared = LoggingService()

    private let subsystem: String
    private let ringBuffer: LogRingBuffer
    private var cachedLoggers: [LogCategory: Logger] = [:]

    init(
        subsystem: String = AppVersion.loggingSubsystem,
        ringBuffer: LogRingBuffer = LogRingBuffer()
    ) {
        self.subsystem = subsystem
        self.ringBuffer = ringBuffer
    }

    func log(
        _ level: LogLevel,
        category: LogCategory,
        _ message: String,
        includeInRingBuffer: Bool = true
    ) {
        let logger = loggerForCategory(category)
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        case .fault:
            logger.fault("\(message, privacy: .public)")
        }

        guard includeInRingBuffer else { return }
        let entry = LogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            category: category,
            message: message
        )
        Task {
            await ringBuffer.append(entry)
        }
    }

    func debug(_ category: LogCategory, _ message: String, enabled: Bool) {
        guard enabled else { return }
        log(.debug, category: category, message)
    }

    func exportEntries() async -> [LogEntry] {
        await ringBuffer.snapshot()
    }

    private func loggerForCategory(_ category: LogCategory) -> Logger {
        if let existing = cachedLoggers[category] {
            return existing
        }
        let logger = Logger(subsystem: subsystem, category: category.rawValue)
        cachedLoggers[category] = logger
        return logger
    }
}
