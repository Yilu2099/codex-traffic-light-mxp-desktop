import CryptoKit
import Foundation

public struct TeamProjectActivity: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var sessionCount: Int
    public var firstActiveAt: String
    public var lastActiveAt: String
    public var purpose: String?
    public var summary: String?
}

public struct TeamInputEvent: Codable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var projectName: String
    public var sessionId: String
    public var sentAt: String
    public var text: String
}

public struct ProjectActivitySyncReport: Equatable, Sendable {
    public var projects: [TeamProjectActivity]
    public var inputEvents: [TeamInputEvent]
}

private struct ProjectActivityRecord: Codable {
    var id: String
    var name: String
    var sessions: [String: TimeInterval]
    var purpose: String? = nil
    var purposeScore: Int? = nil
    var latestSummary: String? = nil
    var latestSummaryAt: TimeInterval? = nil
}

private struct ProjectActivityLedger: Codable {
    var projects: [String: ProjectActivityRecord] = [:]
    var conversationCursors: [String: ProjectConversationCursor]? = nil
    var pendingInputEvents: [TeamInputEvent]? = nil
    var inputEventCollectionVersion: Int? = nil
}

private struct ProjectConversationCursor: Codable, Equatable {
    var projectID: String?
    var projectName: String? = nil
    var sessionID: String? = nil
    var offset: UInt64
    var isSubagent: Bool
    var updatedAt: TimeInterval
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
        prepareSync(days: days, now: now, codexHome: codexHome).projects
    }

    public func prepareSync(
        days: Int = 30,
        now: Date = Date(),
        codexHome: URL? = nil,
        sessionFileIndex: CodexSessionFileIndex? = nil
    ) -> ProjectActivitySyncReport {
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86_400).timeIntervalSince1970
        var ledger = read()
        var conversationCursors = ledger.inputEventCollectionVersion == 2 ? (ledger.conversationCursors ?? [:]) : [:]
        let previousConversationCursors = conversationCursors
        let collection: ProjectConversationCollection
        if let codexHome {
            let fileIndex = sessionFileIndex ?? CodexSessionFileIndex(codexHome: codexHome)
            if ledger.inputEventCollectionVersion != 2 {
                // The first run establishes an EOF baseline only. Historical prompts are
                // deliberately not parsed or uploaded, keeping upgrades lightweight.
                ProjectConversationCollector().establishBaseline(
                    sessionFileIndex: fileIndex, now: now, cursors: &conversationCursors
                )
                collection = ProjectConversationCollection(events: [])
                ledger.pendingInputEvents = []
            } else {
                collection = ProjectConversationCollector().collect(
                    sessionFileIndex: fileIndex,
                    days: days,
                    now: now,
                    cursors: &conversationCursors
                )
            }
        } else {
            collection = ProjectConversationCollection(events: [])
        }
        ledger.conversationCursors = conversationCursors
        var ledgerChanged = previousConversationCursors != conversationCursors || ledger.inputEventCollectionVersion != 2
        ledger.inputEventCollectionVersion = 2
        var pendingByID = Dictionary(uniqueKeysWithValues: (ledger.pendingInputEvents ?? []).map { ($0.id, $0) })
        for event in collection.events {
            if pendingByID[event.id] == nil {
                pendingByID[event.id] = event
                ledgerChanged = true
            }
            if let sentAt = Self.isoDate(event.sentAt)?.timeIntervalSince1970 {
                var record = ledger.projects[event.projectId] ?? ProjectActivityRecord(
                    id: event.projectId, name: event.projectName, sessions: [:]
                )
                record.name = event.projectName
                if sentAt > (record.sessions[event.sessionId] ?? 0) {
                    record.sessions[event.sessionId] = sentAt
                    ledger.projects[event.projectId] = record
                    ledgerChanged = true
                }
            }
        }
        let eventCutoff = now.addingTimeInterval(-90 * 86_400)
        let pending = pendingByID.values.filter { Self.isoDate($0.sentAt).map { $0 >= eventCutoff } ?? false }
            .sorted { $0.sentAt < $1.sentAt }
        if pending.count != (ledger.pendingInputEvents ?? []).count { ledgerChanged = true }
        ledger.pendingInputEvents = pending
        for key in Array(ledger.projects.keys) {
            guard var record = ledger.projects[key] else { continue }
            if record.latestSummary != nil || record.latestSummaryAt != nil {
                record.latestSummary = nil
                record.latestSummaryAt = nil
                ledgerChanged = true
            }
            if Self.isGenericPurpose(record.purpose) || (record.purposeScore ?? 0) < 1_000 {
                record.purpose = nil
                record.purposeScore = nil
                ledgerChanged = true
            }
            let suggestion = Self.purposeSuggestion(name: record.name)
            if let text = suggestion.text,
               record.purpose == nil || suggestion.score > (record.purposeScore ?? -1) {
                record.purpose = text
                record.purposeScore = suggestion.score
                ledgerChanged = true
            }
            ledger.projects[key] = record
        }
        if ledgerChanged { try? write(ledger) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let projects: [TeamProjectActivity] = ledger.projects.values.compactMap { record -> TeamProjectActivity? in
            let timestamps = record.sessions.values.filter { $0 >= cutoff }
            guard let first = timestamps.min(), let last = timestamps.max() else { return nil }
            return TeamProjectActivity(
                id: record.id,
                name: record.name,
                sessionCount: timestamps.count,
                firstActiveAt: formatter.string(from: Date(timeIntervalSince1970: first)),
                lastActiveAt: formatter.string(from: Date(timeIntervalSince1970: last)),
                purpose: record.purpose,
                summary: record.latestSummary
            )
        }
        .sorted { left, right in
            if left.lastActiveAt != right.lastActiveAt { return left.lastActiveAt > right.lastActiveAt }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
        .prefix(30)
        .map { $0 }
        return ProjectActivitySyncReport(projects: projects, inputEvents: Self.inputEventBatch(pending))
    }

    public func acknowledgeInputEvents(ids: [String]) {
        guard !ids.isEmpty else { return }
        let acknowledged = Set(ids)
        var ledger = read()
        let current = ledger.pendingInputEvents ?? []
        let remaining = current.filter { !acknowledged.contains($0.id) }
        guard remaining.count != current.count else { return }
        ledger.pendingInputEvents = remaining
        try? write(ledger)
    }

    private static func purposeSuggestion(
        name: String
    ) -> (text: String?, score: Int) {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("创新局") {
            return ("团队共同使用 Codex 的用量排行与协作管理平台", 1_000)
        }
        if normalized.contains("智替") {
            return ("面向股票研究、选股与买卖点辅助的智能工具", 1_000)
        }
        if normalized.contains("香港房产") || normalized.contains("入港通") || normalized.contains("港盘通") {
            return ("楼盘查询、估价与找房服务的产品研发项目", 1_000)
        }
        return (nil, 0)
    }

    private static func isGenericPurpose(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.hasPrefix("围绕「") && value.contains("持续开发与维护")
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

    fileprivate static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func inputEventBatch(_ events: [TeamInputEvent]) -> [TeamInputEvent] {
        var result: [TeamInputEvent] = []
        var bytes = 0
        for event in events.prefix(300) {
            let eventBytes = event.text.lengthOfBytes(using: .utf8)
            if !result.isEmpty && bytes + eventBytes > 1_000_000 { break }
            result.append(event)
            bytes += eventBytes
        }
        return result
    }

    private static func isoDate(_ value: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct ProjectConversationCollection {
    var events: [TeamInputEvent]
}

private struct ProjectConversationFileCandidate {
    var url: URL
    var cursorKey: String
    var modifiedAt: Date
    var fileSize: UInt64
}

private struct ProjectConversationCollector {
    private let ignoredPrefixes = [
        "<recommended_plugins>", "# AGENTS.md instructions", "<environment_context>",
        "<app-context>", "<permissions instructions>", "<collaboration_mode>",
        "<apps_instructions>", "<plugins_instructions>", "# Files mentioned by the user:",
        "<image name=", "Continue where you left off.", "The following is the Codex agent history",
    ]

    func establishBaseline(
        sessionFileIndex: CodexSessionFileIndex,
        now: Date,
        cursors: inout [String: ProjectConversationCursor]
    ) {
        for file in sessionFileIndex.uniqueFiles() {
            let cursorKey = ProjectActivityStore.digest(file.stableKey)
            cursors[cursorKey] = ProjectConversationCursor(
                projectID: nil,
                projectName: nil,
                sessionID: nil,
                offset: UInt64(file.size),
                isSubagent: false,
                updatedAt: (file.modifiedAt == .distantPast ? now : file.modifiedAt).timeIntervalSince1970
            )
        }
    }

    func collect(
        sessionFileIndex: CodexSessionFileIndex,
        days: Int,
        now: Date,
        cursors: inout [String: ProjectConversationCursor]
    ) -> ProjectConversationCollection {
        let cutoff = now.addingTimeInterval(-Double(max(1, days) + 1) * 86_400)
        let startedAt = Date()
        let maxReadBytes = 4 * 1_024 * 1_024
        let maxChunks = 16
        let chunkBytes = 256 * 1_024
        var events: [TeamInputEvent] = []
        var candidates: [ProjectConversationFileCandidate] = []
        for file in sessionFileIndex.uniqueFiles() {
            let fileSize = UInt64(file.size)
            let cursorKey = ProjectActivityStore.digest(file.stableKey)
            let legacyCursorKey = ProjectActivityStore.digest(file.path)
            if cursors[cursorKey] == nil, let legacy = cursors.removeValue(forKey: legacyCursorKey) {
                cursors[cursorKey] = legacy
            }
            let existing = cursors[cursorKey]
            guard file.modifiedAt >= cutoff || existing != nil else { continue }
            guard fileSize != (existing?.offset ?? 0) else { continue }
            candidates.append(ProjectConversationFileCandidate(
                url: file.url,
                cursorKey: cursorKey,
                modifiedAt: file.modifiedAt,
                fileSize: fileSize
            ))
        }
        candidates.sort { left, right in
            if left.modifiedAt != right.modifiedAt { return left.modifiedAt > right.modifiedAt }
            return left.cursorKey < right.cursorKey
        }

        var bytesRead = 0
        var chunksRead = 0
        for candidate in candidates {
            if bytesRead >= maxReadBytes || chunksRead >= maxChunks || Date().timeIntervalSince(startedAt) >= 1 { break }
            let url = candidate.url
            let cursorKey = candidate.cursorKey
            let modifiedAt = candidate.modifiedAt
            let fileSize = candidate.fileSize
            var cursor = cursors[cursorKey] ?? ProjectConversationCursor(
                    projectID: nil,
                    projectName: nil,
                    sessionID: nil,
                    offset: 0,
                    isSubagent: false,
                    updatedAt: modifiedAt.timeIntervalSince1970
            )
            if fileSize < cursor.offset { cursor.offset = 0 }
            if cursor.projectID == nil, cursor.offset > 0 {
                hydrateMetadata(url: url, cursorKey: cursorKey, cursor: &cursor)
            }
            guard fileSize > cursor.offset,
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            do {
                try handle.seek(toOffset: cursor.offset)
            } catch {
                try? handle.close()
                continue
            }
            let remainingBudget = maxReadBytes - bytesRead
            let unreadBytes = Int(min(UInt64(Int.max), fileSize - cursor.offset))
            let requestedBytes = min(chunkBytes, min(remainingBudget, unreadBytes))
                let tail = try? handle.read(upToCount: max(1, requestedBytes))
                try? handle.close()
                guard let data = tail, !data.isEmpty else { continue }
                guard let newline = data.lastIndex(of: 0x0A) else {
                    // Preserve an incomplete JSONL row until its terminating
                    // newline arrives. A non-EOF 256 KB row is deliberately
                    // skipped in bounded pieces so it cannot block all newer
                    // project events forever.
                    let reachedEOF = cursor.offset + UInt64(data.count) >= fileSize
                    if !reachedEOF {
                        cursor.offset += UInt64(data.count)
                        cursor.updatedAt = modifiedAt.timeIntervalSince1970
                        cursors[cursorKey] = cursor
                    }
                    bytesRead += data.count
                    chunksRead += 1
                    continue
                }
                let consumable = Data(data.prefix(through: newline))
                guard let source = String(data: consumable, encoding: .utf8) else {
                    cursor.offset += UInt64(consumable.count)
                    cursor.updatedAt = modifiedAt.timeIntervalSince1970
                    cursors[cursorKey] = cursor
                    bytesRead += consumable.count
                    chunksRead += 1
                    continue
                }
                var projectID = cursor.projectID
                var projectName = cursor.projectName
                var sessionID = cursor.sessionID ?? cursorKey
                var messages: [(Date, String)] = []
                var isSubagent = cursor.isSubagent
                for line in source.split(whereSeparator: \.isNewline) {
                    guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let payload = json["payload"] as? [String: Any] else { continue }
                    if json["type"] as? String == "session_meta" {
                        if payload["source"] is [String: Any] { isSubagent = true }
                        if let cwd = payload["cwd"] as? String {
                            let identity = ProjectActivityStore.projectIdentity(workspace: cwd)
                            projectID = identity?.id
                            projectName = identity?.name
                        }
                        if let rawSessionID = payload["id"] as? String, !rawSessionID.isEmpty {
                            sessionID = ProjectActivityStore.digest(rawSessionID)
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
                        if let text = cleanedInputText(item["text"] as? String ?? "") {
                            messages.append((date, text))
                        }
                    }
                }
                cursor.projectID = projectID
                cursor.projectName = projectName
                cursor.sessionID = sessionID
                cursor.isSubagent = isSubagent
                cursor.offset += UInt64(consumable.count)
                cursor.updatedAt = modifiedAt.timeIntervalSince1970
                cursors[cursorKey] = cursor
                bytesRead += consumable.count
                chunksRead += 1
                guard !isSubagent, let projectID, let projectName else { continue }
                for (date, text) in messages {
                    let sentAt = Self.isoString(date)
                    events.append(TeamInputEvent(
                        id: ProjectActivityStore.digest("\(sessionID)|\(sentAt)|\(text)"),
                        projectId: projectID,
                        projectName: projectName,
                        sessionId: sessionID,
                        sentAt: sentAt,
                        text: text
                    ))
                }
        }
        let cursorCutoff = now.addingTimeInterval(-45 * 86_400).timeIntervalSince1970
        cursors = cursors.filter { $0.value.updatedAt >= cursorCutoff }
        return ProjectConversationCollection(events: events.sorted { $0.sentAt < $1.sentAt })
    }

    private func hydrateMetadata(
        url: URL,
        cursorKey: String,
        cursor: inout ProjectConversationCursor
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        let header = try? handle.read(upToCount: 64 * 1_024)
        try? handle.close()
        guard let header, let source = String(data: header, encoding: .utf8) else { return }
        for line in source.split(whereSeparator: \.isNewline) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["type"] as? String == "session_meta",
                  let payload = json["payload"] as? [String: Any] else { continue }
            if payload["source"] is [String: Any] { cursor.isSubagent = true }
            if let cwd = payload["cwd"] as? String,
               let identity = ProjectActivityStore.projectIdentity(workspace: cwd) {
                cursor.projectID = identity.id
                cursor.projectName = identity.name
            }
            if let rawSessionID = payload["id"] as? String, !rawSessionID.isEmpty {
                cursor.sessionID = ProjectActivityStore.digest(rawSessionID)
            } else {
                cursor.sessionID = cursorKey
            }
            return
        }
    }

    private func cleanedInputText(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestRange = value.range(of: "## My request:") {
            value = String(value[requestRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty, !ignoredPrefixes.contains(where: value.hasPrefix) else { return nil }
        guard value.range(of: #"^</?[a-zA-Z][^>]*>$"#, options: .regularExpression) == nil else { return nil }
        for tag in ["app-context", "environment_context", "permissions instructions", "collaboration_mode", "apps_instructions", "plugins_instructions", "recommended_plugins"] {
            value = value.replacingOccurrences(of: #"<\#(tag)>[\s\S]*?</\#(tag)>"#, with: "", options: .regularExpression)
        }
        value = value.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"`[^`\n]+`"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"!\[[^\]]*\]\([^\)]*\)"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"</?image[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"(?i)(?:api[_-]?key|access[_-]?token|secret|password|passwd)\s*[:=]\s*\S+"#, with: "[凭据已隐藏]", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !looksLikeCode(value) else { return nil }
        return String(value.prefix(2_000_000))
    }

    private func looksLikeCode(_ value: String) -> Bool {
        let lines = value.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return false }
        let codePrefixes = ["import ", "from ", "func ", "class ", "struct ", "enum ", "let ", "var ", "const ", "function ", "def ", "SELECT ", "INSERT ", "UPDATE ", "#!/"]
        let codeLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return codePrefixes.contains(where: trimmed.hasPrefix)
                || trimmed.hasSuffix("{") || trimmed == "}" || trimmed.hasPrefix("</")
        }.count
        return codeLines == lines.count || (lines.count >= 4 && codeLines * 2 >= lines.count)
    }

    private static func isoDate(_ value: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
