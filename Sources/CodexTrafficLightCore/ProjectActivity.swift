import CryptoKit
import Foundation

public struct TeamProjectActivity: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sessionCount: Int
    public var firstActiveAt: String
    public var lastActiveAt: String
}

private struct ProjectActivityRecord: Codable {
    var id: String
    var name: String
    var sessions: [String: TimeInterval]
}

private struct ProjectActivityLedger: Codable {
    var projects: [String: ProjectActivityRecord] = [:]
}

public final class ProjectActivityStore {
    public let activityURL: URL

    public init(activityURL: URL = ProjectActivityStore.defaultActivityURL()) {
        self.activityURL = activityURL
    }

    public static func defaultActivityURL() -> URL {
        StateStore.defaultSupportDirectory().appendingPathComponent("project-activity.json")
    }

    public func record(workspace: String, taskID: String, now: Date = Date()) throws {
        guard let project = Self.projectIdentity(workspace: workspace), !taskID.isEmpty else { return }
        var ledger = read()
        var record = ledger.projects[project.id] ?? ProjectActivityRecord(id: project.id, name: project.name, sessions: [:])
        record.name = project.name
        record.sessions[Self.digest(taskID)] = now.timeIntervalSince1970

        let retentionCutoff = now.addingTimeInterval(-90 * 86_400).timeIntervalSince1970
        record.sessions = record.sessions.filter { $0.value >= retentionCutoff }
        ledger.projects[project.id] = record
        ledger.projects = ledger.projects.filter { !$0.value.sessions.isEmpty }
        try write(ledger)
    }

    public func report(days: Int = 30, now: Date = Date()) -> [TeamProjectActivity] {
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86_400).timeIntervalSince1970
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return read().projects.values.compactMap { record in
            let timestamps = record.sessions.values.filter { $0 >= cutoff }
            guard let first = timestamps.min(), let last = timestamps.max() else { return nil }
            return TeamProjectActivity(
                id: record.id,
                name: record.name,
                sessionCount: timestamps.count,
                firstActiveAt: formatter.string(from: Date(timeIntervalSince1970: first)),
                lastActiveAt: formatter.string(from: Date(timeIntervalSince1970: last))
            )
        }
        .sorted { left, right in
            if left.lastActiveAt != right.lastActiveAt { return left.lastActiveAt > right.lastActiveAt }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        .prefix(30)
        .map { $0 }
    }

    public static func projectIdentity(workspace: String) -> (id: String, name: String)? {
        let trimmed = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let original = URL(fileURLWithPath: trimmed).standardizedFileURL
        var projectRoot = original
        var cursor = original
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent(".git").path) {
                projectRoot = cursor
                break
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path || parent.path == home { break }
            cursor = parent
        }

        var name = projectRoot.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: #"[\\/\r\n\t]"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !name.isEmpty, name != ".", name != "..", name.count <= 80 else { return nil }
        return (Self.digest(projectRoot.path), String(name.prefix(48)))
    }

    private func read() -> ProjectActivityLedger {
        guard let data = try? Data(contentsOf: activityURL),
              let ledger = try? JSONDecoder().decode(ProjectActivityLedger.self, from: data) else {
            return ProjectActivityLedger()
        }
        return ledger
    }

    private func write(_ ledger: ProjectActivityLedger) throws {
        try FileManager.default.createDirectory(at: activityURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ledger).write(to: activityURL, options: [.atomic])
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
