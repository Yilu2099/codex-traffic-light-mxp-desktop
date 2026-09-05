import CryptoKit
import Foundation

public enum OfficialCodexUsageError: Error, CustomStringConvertible {
    case launchFailed(String)
    case initializeTimedOut
    case usageTimedOut
    case invalidResponse
    case requestRejected
    case processFailed(String)

    public var description: String {
        switch self {
        case .launchFailed(let message): return "Could not start Codex app-server: \(message)"
        case .initializeTimedOut: return "Codex app-server initialization timed out"
        case .usageTimedOut: return "Codex official usage request timed out"
        case .invalidResponse: return "Codex official usage response was invalid"
        case .requestRejected: return "Codex official usage request was rejected"
        case .processFailed(let message): return "Codex app-server failed: \(message)"
        }
    }
}

public struct OfficialDailyUsageBucket: Codable, Equatable, Sendable {
    public var startDate: String
    public var tokens: Int

    public init(startDate: String, tokens: Int) {
        self.startDate = startDate
        self.tokens = tokens
    }
}

public struct OfficialCodexUsageReport: Codable, Equatable, Sendable {
    public var lifetimeTokens: Int?
    public var peakDailyTokens: Int?
    public var dailyUsageBuckets: [OfficialDailyUsageBucket]
    public var updatedAt: String
    public var accountFingerprint: String?

    public init(lifetimeTokens: Int?, peakDailyTokens: Int?, dailyUsageBuckets: [OfficialDailyUsageBucket], updatedAt: String, accountFingerprint: String? = nil) {
        self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens
        self.dailyUsageBuckets = dailyUsageBuckets
        self.updatedAt = updatedAt
        self.accountFingerprint = accountFingerprint
    }

    public var dataThrough: String? {
        dailyUsageBuckets.map(\.startDate).max()
    }
}

public enum OfficialUsageRefreshPolicy {
    public static let normalCacheAge: TimeInterval = 2 * 60 * 60
    public static let convergenceCacheAge: TimeInterval = 5 * 60
    public static let delayedCacheAge: TimeInterval = 30 * 60

    public static func expectedSettledDay(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: now)
        let previous = calendar.date(byAdding: .day, value: -1, to: start)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: previous)
    }

    public static func cacheAge(for cached: OfficialCodexUsageReport?, now: Date = Date()) -> TimeInterval {
        guard let cached, (cached.dataThrough ?? "") < expectedSettledDay(now: now) else {
            return normalCacheAge
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if minutes < 5 { return normalCacheAge }
        if minutes < 120 { return convergenceCacheAge }
        return delayedCacheAge
    }
}

public struct TeamSessionActivity: Codable, Equatable, Sendable {
    public var sessionId: String
    public var day: String
    public var startedAt: String?
    public var updatedAt: String?

    public init(sessionId: String, day: String, startedAt: String? = nil, updatedAt: String? = nil) {
        self.sessionId = sessionId
        self.day = day
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
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
        var report = try Self.parse(result, now: now)
        // The fingerprint lets the server keep accounts apart when a device
        // switches or borrows a Codex account. It is best-effort: usage
        // collection must still succeed when account/read is unavailable.
        report.accountFingerprint = fetchAccountFingerprint()
        return report
    }

    private func fetchAccountFingerprint() -> String? {
        guard let data = try? readAppServerMethod("account/read") else { return nil }
        return Self.accountFingerprint(fromAccountRead: data)
    }

    public static func accountFingerprint(fromAccountRead data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let nested = ["account", "user", "profile"].compactMap { object[$0] as? [String: Any] }
        var candidates: [String] = []
        for key in ["email", "accountId", "userId", "id"] {
            if let value = object[key] as? String { candidates.append(value) }
        }
        for container in nested {
            for key in ["email", "accountId", "userId", "id"] {
                if let value = container[key] as? String { candidates.append(value) }
            }
        }
        guard let identifier = candidates
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            .first(where: { !$0.isEmpty && !$0.contains(" ") })
        else { return nil }
        // A truncated salted hash identifies an account without exposing it.
        let digest = SHA256.hash(data: Data(("wanhe-account-v1|" + identifier).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func parse(_ data: Data, now: Date = Date()) throws -> OfficialCodexUsageReport {
        struct Response: Decodable {
            struct Summary: Decodable {
                var lifetimeTokens: Int?
                var peakDailyTokens: Int?
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

    private func response(forID id: Int, in data: Data) throws -> Data? {
        guard let messages = try? CodexAppServerJSONRPCLineCodec.decodeMessages(from: data) else { return nil }
        do {
            return try CodexAppServerJSONRPCLineCodec.resultData(forID: id, in: messages)
        } catch CodexAppServerQuotaError.appServerReturnedError {
            // A complete error response is terminal, not an incomplete frame.
            // Keep remote error text out of sync logs; it may contain private data.
            throw OfficialCodexUsageError.requestRejected
        } catch {
            return nil
        }
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
            if try response(forID: 1, in: responseBuffer.snapshot()) != nil {
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
            if let result = try response(forID: 2, in: responseBuffer.snapshot()) {
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
        collect(
            codexHome: codexHome,
            sessionFileIndex: CodexSessionFileIndex(codexHome: codexHome),
            days: days,
            now: now
        )
    }

    public func collect(
        codexHome: URL,
        sessionFileIndex: CodexSessionFileIndex,
        days: Int,
        now: Date = Date()
    ) -> [TeamSessionActivity] {
        let cutoff = now.addingTimeInterval(-Double(max(1, days)) * 86_400)
        var sessions: [String: TeamSessionActivity] = [:]
        for file in sessionFileIndex.uniqueFiles() {
            let modifiedAt = file.modifiedAt
            let sessionStartedAt = timestampFromFilename(file.url.lastPathComponent) ?? modifiedAt
            guard max(sessionStartedAt, modifiedAt) >= cutoff else { continue }
            let sessionID = sessionIDFromFilename(file.url.deletingPathExtension().lastPathComponent)
            let candidate = TeamSessionActivity(
                sessionId: sessionID,
                day: dayString(sessionStartedAt),
                startedAt: isoString(sessionStartedAt),
                updatedAt: modifiedAt == .distantPast ? nil : isoString(modifiedAt)
            )
            if let existing = sessions[sessionID],
               (existing.updatedAt ?? "") >= (candidate.updatedAt ?? "") {
                continue
            }
            sessions[sessionID] = candidate
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
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
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
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
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
    private struct IncrementalState: Codable {
        var initialized: Bool
        var updatedAt: String
        var fileOffsets: [String: Int64]
        var collectionVersion: Int? = nil
        var pendingHistory: [TeamGrindHistoryDay]? = nil
        var pendingSessions: [TeamSessionInteractionSummary]? = nil
    }
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

    private let timezone = TimeZone(identifier: "Asia/Shanghai")!

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

    /// Tails only bytes appended after the collector starts. The server merges these
    /// compact timestamp summaries with earlier reports, so the menu-bar app never
    /// needs to rescan historical conversation files during its regular sync.
    public func collectIncremental(
        codexHome: URL,
        days: Int = 30,
        now: Date = Date(),
        stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/grind-live.json")
    ) -> (history: [TeamGrindHistoryDay], sessions: [TeamSessionInteractionSummary]) {
        collectIncremental(
            codexHome: codexHome,
            sessionFileIndex: CodexSessionFileIndex(codexHome: codexHome),
            days: days,
            now: now,
            stateURL: stateURL
        )
    }

    public func collectIncremental(
        codexHome: URL,
        sessionFileIndex: CodexSessionFileIndex,
        days: Int = 30,
        now: Date = Date(),
        stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/grind-live.json")
    ) -> (history: [TeamGrindHistoryDay], sessions: [TeamSessionInteractionSummary]) {
        let cutoff = now.addingTimeInterval(-Double(max(1, days) + 1) * 86_400)
        var files = sessionFileIndex.uniqueFiles(modifiedSince: cutoff)
        files.sort { $0.modifiedAt > $1.modifiedAt }
        let loadedState = (try? Data(contentsOf: stateURL))
            .flatMap { try? JSONDecoder().decode(IncrementalState.self, from: $0) }
        var state = loadedState
            ?? IncrementalState(initialized: false, updatedAt: isoString(now), fileOffsets: [:])
        var stateChanged = loadedState == nil
        if !state.initialized || state.collectionVersion != 2 {
            // First install (and the one-time v2 migration) reads only authored-user
            // timestamps from the recent 30-day window. Conversation text, assistant
            // replies, attachments, injected context and subagent sessions are never
            // retained in this state or included in the upload.
            let backfill = collectDetailed(codexHome: codexHome, days: min(30, days), now: now)
            for file in files { state.fileOffsets[file.stableKey] = file.size }
            state.initialized = true
            state.collectionVersion = 2
            state.pendingHistory = mergeHistory(state.pendingHistory ?? [], backfill.history)
            state.pendingSessions = mergeSessions(state.pendingSessions ?? [], backfill.sessions)
            state.updatedAt = isoString(now)
            saveIncrementalState(state, to: stateURL)
            return (state.pendingHistory ?? [], state.pendingSessions ?? [])
        }

        // Register every candidate before applying the per-run read budget.
        // Pending new live files retain offset zero, so files beyond the first
        // 16 are drained on later syncs instead of being baselined at EOF.
        for file in files {
            let key = file.stableKey
            if state.fileOffsets[key] == nil, let legacyOffset = state.fileOffsets[file.path] {
                state.fileOffsets[key] = legacyOffset
                state.fileOffsets.removeValue(forKey: file.path)
                stateChanged = true
            } else if state.fileOffsets[key] == nil,
                      let movedLegacy = state.fileOffsets.first(where: {
                          $0.key.contains("/")
                              && URL(fileURLWithPath: $0.key).lastPathComponent == key
                      }) {
                // A pre-stable-key state may still name the old sessions path
                // after Codex has already moved the file into archived_sessions.
                state.fileOffsets[key] = movedLegacy.value
                state.fileOffsets.removeValue(forKey: movedLegacy.key)
                stateChanged = true
            } else if state.fileOffsets[key] == nil {
                // Initialization already baselines all historical files. Any
                // rollout first discovered later is new work, even if Codex
                // created and archived the short session between two polls.
                state.fileOffsets[key] = 0
                stateChanged = true
            }
        }
        var interactionDates: [String: InteractionDates] = [:]
        var history: [String: (day: Date?, night: Date?)] = [:]
        var processed = 0
        for file in files where processed < 16 {
            let key = file.stableKey
            let knownOffset = state.fileOffsets[key]
            let start = knownOffset.map { offset in
                // Truncation or in-place replacement invalidates the former
                // byte boundary. Re-read this one file so complete new events
                // already present before the next sync are not lost.
                offset > file.size ? 0 : max(0, offset)
            } ?? file.size
            guard start < file.size else {
                if knownOffset != file.size { stateChanged = true }
                state.fileOffsets[key] = file.size
                continue
            }
            if isSubagentSession(file.url) {
                state.fileOffsets[key] = file.size
                stateChanged = true
                processed += 1
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: file.url) else { continue }
            try? handle.seek(toOffset: UInt64(start))
            let data = (try? handle.read(upToCount: 256 * 1_024)) ?? Data()
            try? handle.close()
            guard !data.isEmpty else { continue }
            guard let newline = data.lastIndex(of: 0x0A) else {
                let reachedEOF = start + Int64(data.count) >= file.size
                if !reachedEOF {
                    // Skip one bounded piece of an oversized JSONL row so it
                    // cannot block every newer event forever. At EOF, retain
                    // the offset because an ordinary partial row may complete.
                    state.fileOffsets[key] = start + Int64(data.count)
                    stateChanged = true
                }
                processed += 1
                continue
            }
            let complete = Data(data.prefix(through: newline))
            var modern: [Date] = []
            var legacy: [Date] = []
            for line in complete.split(separator: 0x0A) {
                guard let event = try? JSONDecoder().decode(EventEnvelope.self, from: Data(line)),
                      let timestamp = event.timestamp,
                      let date = Self.isoDate(timestamp), date >= cutoff else { continue }
                if event.isAuthoredResponse { modern.append(date) }
                if event.isLegacyUserEvent { legacy.append(date) }
            }
            let session = sessionID(from: file.url)
            for date in modern.isEmpty ? legacy : modern {
                let components = Calendar(identifier: .gregorian).dateComponents(in: timezone, from: date)
                guard let hour = components.hour else { continue }
                let day = grindDay(for: date, hour: hour)
                var item = history[day] ?? (nil, nil)
                if hour >= 5, item.day == nil || date < item.day! { item.day = date }
                if hour >= 23 || hour < 5, item.night == nil || date > item.night! { item.night = date }
                history[day] = item
                let key = "\(session)|\(day)"
                var values = interactionDates[key] ?? InteractionDates()
                if hour >= 5 { values.day.append(date) }
                if hour >= 23 || hour < 5 { values.night.append(date) }
                interactionDates[key] = values
            }
            state.fileOffsets[key] = start + Int64(complete.count)
            stateChanged = true
            processed += 1
        }
        let activeKeys = Set(files.map(\.stableKey))
        let previousOffsetCount = state.fileOffsets.count
        state.fileOffsets = state.fileOffsets.filter { activeKeys.contains($0.key) }
        if state.fileOffsets.count != previousOffsetCount { stateChanged = true }
        let sessions = interactionDates.compactMap { key, values -> TeamSessionInteractionSummary? in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let dayDates = uniqueTurns(values.day)
            let nightDates = uniqueTurns(values.night)
            return TeamSessionInteractionSummary(
                sessionId: parts[0], day: parts[1],
                firstDayUserAt: dayDates.first.map(isoString),
                lastDayUserAt: dayDates.last.map(isoString), dayTurnCount: dayDates.count,
                lastNightUserAt: nightDates.last.map(isoString), nightTurnCount: nightDates.count
            )
        }
        let grind = history.keys.sorted().map { day in
            let item = history[day] ?? (nil, nil)
            return TeamGrindHistoryDay(
                grindDay: day, dayGrindTime: item.day.map(timeString), nightGrindTime: item.night.map(timeString)
            )
        }
        if !grind.isEmpty || !sessions.isEmpty {
            state.pendingHistory = mergeHistory(state.pendingHistory ?? [], grind)
            state.pendingSessions = mergeSessions(state.pendingSessions ?? [], sessions)
            stateChanged = true
        }
        if stateChanged {
            state.updatedAt = isoString(now)
            saveIncrementalState(state, to: stateURL)
        }
        return (state.pendingHistory ?? [], state.pendingSessions ?? [])
    }

    public func acknowledgeUploaded(
        stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/grind-live.json")
    ) {
        guard let data = try? Data(contentsOf: stateURL),
              var state = try? JSONDecoder().decode(IncrementalState.self, from: data),
              !(state.pendingHistory ?? []).isEmpty || !(state.pendingSessions ?? []).isEmpty else { return }
        state.pendingHistory = []
        state.pendingSessions = []
        state.updatedAt = isoString(Date())
        saveIncrementalState(state, to: stateURL)
    }

    private func mergeHistory(
        _ current: [TeamGrindHistoryDay],
        _ incoming: [TeamGrindHistoryDay]
    ) -> [TeamGrindHistoryDay] {
        var byDay = Dictionary(uniqueKeysWithValues: current.map { ($0.grindDay, $0) })
        for item in incoming {
            var merged = byDay[item.grindDay] ?? item
            if let incomingStart = item.dayGrindTime,
               merged.dayGrindTime == nil || incomingStart < merged.dayGrindTime! {
                merged.dayGrindTime = incomingStart
            }
            if let incomingFinish = item.nightGrindTime,
               merged.nightGrindTime == nil || nightOrder(incomingFinish) > nightOrder(merged.nightGrindTime!) {
                merged.nightGrindTime = incomingFinish
            }
            byDay[item.grindDay] = merged
        }
        return byDay.values.sorted { $0.grindDay < $1.grindDay }.suffix(30).map { $0 }
    }

    private func mergeSessions(
        _ current: [TeamSessionInteractionSummary],
        _ incoming: [TeamSessionInteractionSummary]
    ) -> [TeamSessionInteractionSummary] {
        var byKey = Dictionary(uniqueKeysWithValues: current.map { ("\($0.sessionId)|\($0.day)", $0) })
        for item in incoming {
            let key = "\(item.sessionId)|\(item.day)"
            guard var merged = byKey[key] else {
                byKey[key] = item
                continue
            }
            if let value = item.firstDayUserAt,
               merged.firstDayUserAt == nil || value < merged.firstDayUserAt! {
                merged.firstDayUserAt = value
            }
            if let value = item.lastDayUserAt,
               merged.lastDayUserAt == nil || value > merged.lastDayUserAt! {
                merged.lastDayUserAt = value
            }
            if let value = item.lastNightUserAt,
               merged.lastNightUserAt == nil || value > merged.lastNightUserAt! {
                merged.lastNightUserAt = value
            }
            merged.dayTurnCount += item.dayTurnCount
            merged.nightTurnCount += item.nightTurnCount
            byKey[key] = merged
        }
        return byKey.values.sorted { "\($0.day)|\($0.sessionId)" < "\($1.day)|\($1.sessionId)" }
    }

    private func nightOrder(_ time: String) -> Int {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return -1 }
        return (parts[0] < 5 ? parts[0] + 24 : parts[0]) * 60 + parts[1]
    }

    private func saveIncrementalState(_ state: IncrementalState, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: [.atomic]) }
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
