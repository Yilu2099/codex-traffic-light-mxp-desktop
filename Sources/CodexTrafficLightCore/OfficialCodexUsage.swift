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
    private struct EventEnvelope: Decodable {
        struct Payload: Decodable {
            struct Content: Decodable {
                var type: String?
                var text: String?
            }

            var type: String?
            var role: String?
            var content: [Content]?

            var hasUserAuthoredContent: Bool {
                guard let content, !content.isEmpty else { return true }
                let systemPrefixes = [
                    "<recommended_plugins>", "# AGENTS.md instructions", "<environment_context>",
                    "<app-context>", "<permissions instructions>", "<collaboration_mode>",
                    "<apps_instructions>", "<plugins_instructions>",
                ]
                return content.contains { item in
                    guard item.type == "input_text" else { return true }
                    let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return false }
                    return !systemPrefixes.contains { text.hasPrefix($0) }
                }
            }
        }
        var timestamp: String?
        var type: String?
        var payload: Payload?

        var isUserInteraction: Bool {
            if type == "event_msg", payload?.type == "user_message" { return true }
            return type == "response_item"
                && payload?.type == "message"
                && payload?.role == "user"
                && payload?.hasUserAuthoredContent == true
        }
    }

    private let timezone = TimeZone(identifier: "Asia/Hong_Kong")!

    public init() {}

    public func collect(codexHome: URL, days: Int = 30, now: Date = Date()) -> [TeamGrindHistoryDay] {
        let cutoff = now.addingTimeInterval(-Double(max(1, days) + 1) * 86_400)
        let roots = ["sessions", "archived_sessions"].map { codexHome.appendingPathComponent($0) }
        var history: [String: (day: Date?, night: Date?)] = [:]

        func recordUserInteraction(_ date: Date) {
            guard date >= cutoff else { return }
            let components = Calendar(identifier: .gregorian).dateComponents(in: timezone, from: date)
            guard let hour = components.hour else { return }
            let day = grindDay(for: date, hour: hour)
            var current = history[day] ?? (nil, nil)
            if hour >= 5, current.day == nil || date < current.day! { current.day = date }
            if hour >= 23 || hour < 5, current.night == nil || date > current.night! { current.night = date }
            history[day] = current
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
                guard let data = try? Data(contentsOf: url),
                      let text = String(data: data, encoding: .utf8) else { continue }
                text.enumerateLines { line, _ in
                    guard let event = try? JSONDecoder().decode(EventEnvelope.self, from: Data(line.utf8)),
                          event.isUserInteraction,
                          let timestamp = event.timestamp,
                          let date = Self.isoDate(timestamp) else { return }
                    // Day start is the first prompt actually sent by the user,
                    // including prompts in a conversation created on an older day.
                    recordUserInteraction(date)
                }
            }
        }

        return history.keys.sorted().suffix(max(1, days)).map { day in
            let item = history[day] ?? (nil, nil)
            return TeamGrindHistoryDay(
                grindDay: day,
                dayGrindTime: item.day.map(timeString),
                nightGrindTime: item.night.map(timeString)
            )
        }
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
