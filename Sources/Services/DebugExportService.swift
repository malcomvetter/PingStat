import Foundation

struct DebugExportPayload: Codable {
    let createdAt: Date
    let context: NetworkContext
    let config: AppConfig
    let snapshot: HealthSnapshot
    let endpoints: [EndpointStatus]
    let dnsStatus: DNSCheckStatus
    let dnsStatusVPN: DNSCheckStatus
    let logs: [LogEntry]
}

@MainActor
final class DebugExportService {
    private let logger: LoggingService

    init(logger: LoggingService) {
        self.logger = logger
    }

    func exportJSON(
        to directoryURL: URL,
        payload: DebugExportPayload
    ) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = directoryURL.appendingPathComponent("\(AppBranding.productName)-debug-\(timestamp).json")
        try data.write(to: fileURL, options: .atomic)
        logger.log(.notice, category: .ui, "Debug export created at \(fileURL.path)")
        return fileURL
    }
}
