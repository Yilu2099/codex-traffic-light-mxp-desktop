import Foundation

public enum OfficialCodexUsageError: Error, CustomStringConvertible {
    case launchFailed(String)
    case initializeTimedOut
    case usageTimedOut
    case invalidResponse
    case processFailed(String)

    public var description: String {
        switch self {
        case .launchFailed(let message): return "Could not start Codex app-server: \(message)"
        case .initializeTimedOut: return "Codex app-server initialization timed out"
        case .usageTimedOut: return "Codex official usage request timed out"
        case .invalidResponse: return "Codex official usage response was invalid"
        case .processFailed(let message): return "Codex app-server failed: \(message)"
        }
    }
}

public struct OfficialDailyUsageBucket: Codable, Equatable, Sendable {
    public var startDate: String
    public var tokens: Int
}

public struct OfficialCodexUsageReport: Codable, Equatable, Sendable {
    public var lifetimeTokens: Int
    public var peakDailyTokens: Int
    public var dailyUsageBuckets: [OfficialDailyUsageBucket]
    public var updatedAt: String

    public var dataThrough: String? {
        dailyUsageBuckets.map(\.startDate).max()
    }
}

public struct TeamSessionActivity: Codable, Equatable, Sendable {
    public var sessionId: String
    public var day: String
    public var startedAt: String?
    public var updatedAt: String?
}

public struct TeamGrindHistoryDay: Codable, Equatable, Sendable {
    public var grindDay: String
    public var dayGrindTime: String?
    public var nightGrindTime: String?

    public init(grindDay: String, dayGrindTime: String? = nil, nightGrindTime: String? = nil) {
        self.grindDay = grindDay
        self.dayGrindTime = dayGrindTime
        self.nightGrindTime = nightGrindTime
    }
}

public struct OfficialCodexUsageCollector: Sendable {
    private let codexBinary: String
    private let initializeTimeout: TimeInterval
    private let usageTimeout: TimeInterval

    public init(
        codexBinary: String = OfficialCodexUsageCollector.defaultCodexBinary(),
        initializeTimeout: TimeInterval = 30,
        usageTimeout: TimeInterval = 20
    ) {
        self.codexBinary = codexBinary
        self.initializeTimeout = initializeTimeout
        self.usageTimeout = usageTimeout
    }

    public static func defaultCodexBinary() -> String {
        if let configured = ProcessInfo.processInfo.environment["CODEX_TRAFFIC_LIGHT_CODEX_BIN"], !configured.isEmpty {
            return configured
        }
        let bundled = "/Applications/ChatGPT.app/Contents/Resources/codex"
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path
        if FileManager.default.isExecutableFile(atPath: local) { return local }
        return "codex"
    }

    public func fetch(now: Date = Date()) throws -> OfficialCodexUsageReport {
        let result = try readAppServerMethod("account/usage/read")
        return try Self.parse(result, now: now)
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> OfficialCodexUsageReport {
        struct Response: Decodable {
            struct Summary: Decodable {
                var lifetimeTokens: Int
                var peakDailyTokens: Int
            }
            var summary: Summary
            var dailyUsageBuckets: [OfficialDailyUsageBucket]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw OfficialCodexUsageError.invalidResponse
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return OfficialCodexUsageReport(
            lifetimeTokens: decoded.summary.lifetimeTokens,
            peakDailyTokens: decoded.summary.peakDailyTokens,
            dailyUsageBuckets: decoded.dailyUsageBuckets ?? [],
            updatedAt: formatter.string(from: now)
        )
    }

    private func readAppServerMethod(_ method: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [codexBinary, "app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorPipe
        let responseBuffer = OfficialUsageLockedBuffer()
        let errorBuffer = OfficialUsageLockedBuffer()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { responseBuffer.append(data) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { errorBuffer.append(data) }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw OfficialCodexUsageError.launchFailed(String(describing: error))
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }

        let initialize = try CodexAppServerJSONRPCLineCodec.encodeRequest(
            id: 1,
            method: "initialize",
            params: [
                "clientInfo": ["name": "codex-team-menu", "title": "Codex Team Menu", "version": "1.0.0"],
                "capabilities": [:]
            ]
        )
        try input.fileHandleForWriting.write(contentsOf: initialize)
        let initializeDeadline = Date().addingTimeInterval(initializeTimeout)
        var initialized = false
        while Date() < initializeDeadline {
            if let messages = try? CodexAppServerJSONRPCLineCodec.decodeMessages(from: responseBuffer.snapshot()),
               (try? CodexAppServerJSONRPCLineCodec.resultData(forID: 1, in: messages)) != nil {
                initialized = true
                break
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        guard initialized else { throw OfficialCodexUsageError.initializeTimedOut }

        let notification = try CodexAppServerJSONRPCLineCodec.encodeMessage(["method": "initialized", "params": [:]])
        let request = try CodexAppServerJSONRPCLineCodec.encodeRequest(id: 2, method: method, params: [:])
        try input.fileHandleForWriting.write(contentsOf: notification)
        try input.fileHandleForWriting.write(contentsOf: request)
        let usageDeadline = Date().addingTimeInterval(usageTimeout)
        while Date() < usageDeadline {
            if let messages = try? CodexAppServerJSONRPCLineCodec.decodeMessages(from: responseBuffer.snapshot()),
               let result = try? CodexAppServerJSONRPCLineCodec.resultData(forID: 2, in: messages) {
                return result
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        let stderr = String(data: errorBuffer.snapshot(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stderr, !stderr.isEmpty { throw OfficialCodexUsageError.processFailed(stderr) }
        throw OfficialCodexUsageError.usageTimedOut
    }
}

public struct CodexSessionFileCounter: Sendable {
    public init() {}

    public func collect(codexHome: URL, days: Int, now: Date = Date()) -> [TeamSessionActivity] {
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86_400)
        let roots = ["sessions", "archived_sessions"].map { codexHome.appendingPathComponent($0) }
        var sessions: [String: TeamSessionActivity] = [:]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let modifiedAt = values?.contentModificationDate ?? .distantPast
                let sessionStartedAt = timestampFromFilename(url.lastPathComponent) ?? modifiedAt
                guard max(sessionStartedAt, modifiedAt) >= cutoff else { continue }
                let sessionID = sessionIDFromFilename(url.deletingPathExtension().lastPathComponent)
                sessions[sessionID] = TeamSessionActivity(
                    sessionId: sessionID,
                    day: dayString(sessionStartedAt),
                    startedAt: isoString(sessionStartedAt),
                    updatedAt: modifiedAt == .distantPast ? nil : isoString(modifiedAt)
                )
            }
        }
        return sessions.values.sorted { ($0.day, $0.sessionId) < ($1.day, $1.sessionId) }
    }

    public func timestampFromFilename(_ filename: String) -> Date? {
        let pattern = #"rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})"#
        guard let range = filename.range(of: pattern, options: .regularExpression) else { return nil }
        let text = String(filename[range]).replacingOccurrences(of: "rollout-", with: "")
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Hong_Kong")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return formatter.date(from: text)
    }

    private func sessionIDFromFilename(_ filename: String) -> String {
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        return filename.range(of: pattern, options: .regularExpression).map { String(filename[$0]) } ?? filename
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_CA")
        formatter.timeZone = TimeZone(identifier: "Asia/Hong_Kong")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public struct CodexGrindHistoryCollector: Sendable {
    private struct InteractionDates {
        var day: [Date] = []
        var night: [Date] = []
    }

    private struct EventEnvelope: Decodable {
        struct Payload: Decodable {
            struct Content: Decodable {
                var type: String?
                var text: String?
            }

            var type: String?
            var role: String?
            var message: String?
            var content: [Content]?

            private static let systemPrefixes = [
                "<recommended_plugins>", "# AGENTS.md instructions", "<environment_context>",
                "<app-context>", "<permissions instructions>", "<collaboration_mode>",
                "<apps_instructions>", "<plugins_instructions>",
                "Continue where you left off. The previous model attempt failed or timed out.",
                "The following is the Codex agent history",
            ]
            private static let replayPrefixes = [
                "Continue where you left off. The previous model attempt failed or timed out.",
                "The following is the Codex agent history",
            ]

            private static func isUserAuthored(_ value: String) -> Bool {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return false }
                return !systemPrefixes.contains { text.hasPrefix($0) }
            }

            var hasUserAuthoredContent: Bool {
                guard let content, !content.isEmpty else { return false }
                return content.contains { item in
                    guard item.type == "input_text" else { return false }
                    return Self.isUserAuthored(item.text ?? "")
                }
            }

            var hasAutomatedReplayContent: Bool {
                content?.contains { item in
                    let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return Self.replayPrefixes.contains { text.hasPrefix($0) }
                } ?? false
            }

            var hasUserAuthoredMessage: Bool {
                guard let message else { return false }
                return Self.isUserAuthored(message)
            }

            var hasAutomatedReplayMessage: Bool {
                let text = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return Self.replayPrefixes.contains { text.hasPrefix($0) }
            }
        }
        var timestamp: String?
        var type: String?
        var payload: Payload?

        var isAuthoredResponse: Bool {
            type == "response_item"
                && payload?.type == "message"
                && payload?.role == "user"
                && payload?.hasUserAuthoredContent == true
                && payload?.hasAutomatedReplayContent == false
        }

        var isLegacyUserEvent: Bool {
            type == "event_msg"
                && payload?.type == "user_message"
                && payload?.hasUserAuthoredMessage == true
                && payload?.hasAutomatedReplayMessage == false
        }
    }

    private let timezone = TimeZone(identifier: "Asia/Hong_Kong")!

    public init() {}

    public func collect(codexHome: URL, days: Int = 30, now: Date = Date()) -> [TeamGrindHistoryDay] {
        collectDetailed(codexHome: codexHome, days: days, now: now).history
    }

    public func collectDetailed(
        codexHome: URL,
        days: Int = 30,
        now: Date = Date()
    ) -> (history: [TeamGrindHistoryDay], sessions: [TeamSessionInteractionSummary]) {
        let cutoff = now.addingTimeInterval(-Double(max(1, days) + 1) * 86_400)
        let roots = ["sessions", "archived_sessions"].map { codexHome.appendingPathComponent($0) }
        var history: [String: (day: Date?, night: Date?)] = [:]
        var interactionDates: [String: InteractionDates] = [:]

        func recordUserInteraction(_ date: Date, sessionID: String) {
            guard date >= cutoff else { return }
            let components = Calendar(identifier: .gregorian).dateComponents(in: timezone, from: date)
            guard let hour = components.hour else { return }
            let day = grindDay(for: date, hour: hour)
            var current = history[day] ?? (nil, nil)
            if hour >= 5, current.day == nil || date < current.day! { current.day = date }
            if hour >= 23 || hour < 5, current.night == nil || date > current.night! { current.night = date }
            history[day] = current

            let key = "\(sessionID)|\(day)"
            var summary = interactionDates[key] ?? InteractionDates()
            if hour >= 5 { summary.day.append(date) }
            if hour >= 23 || hour < 5 { summary.night.append(date) }
            interactionDates[key] = summary
        }

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let startedAt = CodexSessionFileCounter().timestampFromFilename(url.lastPathComponent) ?? modifiedAt
                guard max(startedAt, modifiedAt) >= cutoff else { continue }
                let sessionID = sessionID(from: url)
                var authoredResponseDates: [Date] = []
                var legacyEventDates: [Date] = []
                guard !isSubagentSession(url) else { continue }
                enumerateRecentLines(in: url) { line in
                    guard line.contains("\"user_message\"") || line.contains("\"role\":\"user\"") else { return }
                    guard let event = try? JSONDecoder().decode(EventEnvelope.self, from: Data(line.utf8)),
                          let timestamp = event.timestamp,
                          let date = Self.isoDate(timestamp) else { return }
                    if event.isAuthoredResponse { authoredResponseDates.append(date) }
                    if event.isLegacyUserEvent { legacyEventDates.append(date) }
                }
                // Modern Codex stores authored UI messages as response_item records.
                // event_msg user_message is only a legacy fallback because modern
                // files can also contain replay, automation and setup messages there.
                let dates = authoredResponseDates.isEmpty ? legacyEventDates : authoredResponseDates
                for date in dates { recordUserInteraction(date, sessionID: sessionID) }
            }
        }

        let grindHistory = history.keys.sorted().suffix(max(1, days)).map { day in
            let item = history[day] ?? (nil, nil)
            return TeamGrindHistoryDay(
                grindDay: day,
                dayGrindTime: item.day.map(timeString),
                nightGrindTime: item.night.map(timeString)
            )
        }
        let sessionSummaries = interactionDates.keys.sorted().compactMap { key -> TeamSessionInteractionSummary? in
            guard let values = interactionDates[key] else { return nil }
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let dayDates = uniqueTurns(values.day)
            let nightDates = uniqueTurns(values.night)
            return TeamSessionInteractionSummary(
                sessionId: parts[0],
                day: parts[1],
                firstDayUserAt: dayDates.first.map(isoString),
                lastDayUserAt: dayDates.last.map(isoString),
                dayTurnCount: dayDates.count,
                lastNightUserAt: nightDates.last.map(isoString),
                nightTurnCount: nightDates.count
            )
        }
        return (grindHistory, sessionSummaries)
    }

    private func enumerateRecentLines(in url: URL, maximumBytes: UInt64 = 4 * 1024 * 1024, visit: (String) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > maximumBytes ? size - maximumBytes : 0
        try? handle.seek(toOffset: start)
        var buffer = Data()
        var shouldDiscardPartialLine = start > 0
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                if shouldDiscardPartialLine {
                    shouldDiscardPartialLine = false
                } else if let text = String(data: line, encoding: .utf8) {
                    visit(text)
                }
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !shouldDiscardPartialLine, !buffer.isEmpty, let text = String(data: buffer, encoding: .utf8) { visit(text) }
    }

    private func isSubagentSession(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("\"type\":\"session_meta\"")
            && text.contains("\"source\":{\"subagent\"")
    }

    private func uniqueTurns(_ values: [Date]) -> [Date] {
        values.sorted().reduce(into: []) { result, date in
            if let previous = result.last, date.timeIntervalSince(previous) < 2.5 { return }
            result.append(date)
        }
    }

    private func sessionID(from url: URL) -> String {
        let filename = url.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        return filename.range(of: pattern, options: .regularExpression).map { String(filename[$0]) } ?? filename
    }

    private func grindDay(for date: Date, hour: Int) -> String {
        let adjusted = hour < 5 ? Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: date) ?? date : date
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_CA")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: adjusted)
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timezone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func isoDate(_ value: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let relaxed = ISO8601DateFormatter()
        relaxed.formatOptions = [.withInternetDateTime]
        return precise.date(from: value) ?? relaxed.date(from: value)
    }
}

private final class OfficialUsageLockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let copy = data
        lock.unlock()
        return copy
    }
}
