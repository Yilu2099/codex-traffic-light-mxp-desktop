import CryptoKit
import Foundation

public struct TeamProjectActivity: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sessionCount: Int
    public var firstActiveAt: String
    public var lastActiveAt: String
    public var summary: String?
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

    public func report(days: Int = 30, now: Date = Date(), codexHome: URL? = nil) -> [TeamProjectActivity] {
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86_400).timeIntervalSince1970
        let summaries = codexHome.map {
            ProjectConversationSummaryCollector().collect(codexHome: $0, days: days, now: now)
        } ?? [:]
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
                lastActiveAt: formatter.string(from: Date(timeIntervalSince1970: last)),
                summary: summaries[record.id]
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

private struct ProjectConversationSummaryCollector {
    private let ignoredPrefixes = [
        "<recommended_plugins>", "# AGENTS.md instructions", "<environment_context>",
        "<app-context>", "<permissions instructions>", "<collaboration_mode>",
        "<apps_instructions>", "<plugins_instructions>", "# Files mentioned by the user:",
        "<image name=", "Continue where you left off.", "The following is the Codex agent history",
    ]

    func collect(codexHome: URL, days: Int, now: Date) -> [String: String] {
        let cutoff = now.addingTimeInterval(-Double(max(1, days) + 1) * 86_400)
        var candidates: [String: [(Date, String)]] = [:]
        for folder in ["sessions", "archived_sessions"] {
            let root = codexHome.appendingPathComponent(folder)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard modifiedAt >= cutoff, let data = try? Data(contentsOf: url),
                      let source = String(data: data, encoding: .utf8) else { continue }
                var projectID: String?
                var messages: [(Date, String)] = []
                var isSubagent = false
                for line in source.split(whereSeparator: \.isNewline) {
                    guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let payload = json["payload"] as? [String: Any] else { continue }
                    if json["type"] as? String == "session_meta" {
                        if payload["source"] is [String: Any] { isSubagent = true }
                        if let cwd = payload["cwd"] as? String {
                            projectID = ProjectActivityStore.projectIdentity(workspace: cwd)?.id
                        }
                        continue
                    }
                    guard json["type"] as? String == "response_item",
                          payload["type"] as? String == "message",
                          payload["role"] as? String == "user",
                          let content = payload["content"] as? [[String: Any]],
                          let timestamp = json["timestamp"] as? String,
                          let date = Self.isoDate(timestamp), date >= cutoff else { continue }
                    for item in content where item["type"] as? String == "input_text" {
                        if let summary = cleanedSummary(item["text"] as? String ?? "") {
                            messages.append((date, summary))
                        }
                    }
                }
                guard !isSubagent, let projectID else { continue }
                candidates[projectID, default: []].append(contentsOf: messages)
            }
        }
        return candidates.compactMapValues { values in
            values.sorted { $0.0 > $1.0 }.first?.1
        }
    }

    private func cleanedSummary(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !ignoredPrefixes.contains(where: value.hasPrefix) else { return nil }
        guard value.range(of: #"^</?[a-zA-Z][^>]*>$"#, options: .regularExpression) == nil else { return nil }
        value = value.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "[代码操作]", options: .regularExpression)
        value = value.replacingOccurrences(of: #"https?://\S+"#, with: "[链接]", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?:/[\w.\-\p{Han} ]+){2,}"#, with: "[本地项目]", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\b[a-fA-F0-9]{24,}\b"#, with: "[标识已隐藏]", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[\r\n\t]+"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let generic = ["可以", "好的", "好", "确认", "继续", "修改吧", "更新吧", "没问题", "是的", "对"]
        guard value.count >= 8, !generic.contains(value.trimmingCharacters(in: .punctuationCharacters)) else { return nil }
        return String(value.prefix(140))
    }

    private static func isoDate(_ value: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
