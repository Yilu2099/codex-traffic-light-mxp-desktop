import Foundation

public struct TeamClientMetadata: Codable, Equatable, Sendable {
    public var version: String
    public var platform: String
    public var capabilities: [String]

    public static var current: Self {
        Self(version: ClientVersion.current, platform: "mac", capabilities: [
            "local_tokens", "official_account_usage", "presence", "signed_updates", "updater_schedule_health",
        ])
    }
}

/// A recent local schedule inspection, not an update check or installation ACK.
public struct TeamUpdaterHealth: Codable, Equatable, Sendable {
    public var status: String
    public var checkedAt: String

    public static func cached(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> Self? {
        let file = home.appendingPathComponent(".wanhe-codex-token/updater-health.json")
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4097), data.count <= 4096,
              let report = try? JSONDecoder().decode(Self.self, from: data),
              UpdaterScheduleRepair.Result(rawValue: report.status) != nil,
              report.status != "notInstalled" else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.date(from: report.checkedAt) ?? ISO8601DateFormatter().date(from: report.checkedAt)
        guard let stamp, now.timeIntervalSince(stamp) >= 0, now.timeIntervalSince(stamp) <= 30 * 60 else { return nil }
        return report
    }
}
