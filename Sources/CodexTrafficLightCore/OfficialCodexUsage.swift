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
        guard let cached else { return normalCacheAge }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // A bucket returned before its UTC day ended is still preliminary.
        let observedAfterCutover = SharedDateFormatters.shared.iso8601Date(from: cached.updatedAt)
            .map { $0 >= calendar.startOfDay(for: now) && $0 <= now } ?? false
        if (cached.dataThrough ?? "") >= expectedSettledDay(now: now), observedAfterCutover {
            return normalCacheAge
        }
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
    public var inputProvenance: String?

    public init(grindDay: String, dayGrindTime: String? = nil, nightGrindTime: String? = nil, inputProvenance: String? = nil) {
        self.grindDay = grindDay
        self.dayGrindTime = dayGrindTime
        self.nightGrindTime = nightGrindTime
        self.inputProvenance = inputProvenance
    }
}

public struct NativeWorkdayCollectionReport: Sendable {
    public var history: [TeamGrindHistoryDay]
    public var sessions: [TeamSessionInteractionSummary]
    public var legacyUnknownHistory: [TeamGrindHistoryDay]
    public var legacyUnknownSessions: [TeamSessionInteractionSummary]
    public var coverageComplete: Bool
    public var coverageStartDay: String?
    public var coverageEndDay: String?
    public var coverageThroughAt: String?
}

public struct OfficialCodexUsageCollector: Sendable {
    private let codexBinaries: [String]
    private let initializeTimeout: TimeInterval
    private let usageTimeout: TimeInterval

    public init(
        codexBinary: String? = nil,
        initializeTimeout: TimeInterval = 30,
        usageTimeout: TimeInterval = 20
    ) {
        self.codexBinaries = codexBinary.map { [$0] } ?? Self.defaultCodexBinaries()
        self.initializeTimeout = initializeTimeout
        self.usageTimeout = usageTimeout
    }

    public init(codexBinaries: [String], initializeTimeout: TimeInterval = 30, usageTimeout: TimeInterval = 20) {
        self.codexBinaries = codexBinaries
        self.initializeTimeout = initializeTimeout
        self.usageTimeout = usageTimeout
    }

    public static func defaultCodexBinary() -> String {
        defaultCodexBinaries()[0]
    }

    public static func defaultCodexBinaries() -> [String] {
        if let configured = ProcessInfo.processInfo.environment["CODEX_TRAFFIC_LIGHT_CODEX_BIN"], !configured.isEmpty {
            return [configured]
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ].filter { FileManager.default.isExecutableFile(atPath: $0) }
        return candidates.isEmpty ? ["codex"] : candidates
    }

    public func fetch(now: Date = Date()) throws -> OfficialCodexUsageReport {
        let deadline = Date().addingTimeInterval(initializeTimeout + usageTimeout)
        var lastError: Error = OfficialCodexUsageError.launchFailed("No Codex binary available")
        for (index, binary) in codexBinaries.enumerated() {
            guard Date() < deadline else { break }
            do {
                let attemptDeadline = Date().addingTimeInterval(deadline.timeIntervalSinceNow / Double(codexBinaries.count - index))
                let result = try readAppServerMethod("account/usage/read", binary: binary, deadline: attemptDeadline)
                var report = try Self.parse(result, now: now)
                // Identity comes from the same binary as usage; never combine accounts across fallbacks.
                report.accountFingerprint = fetchAccountFingerprint(binary: binary, deadline: deadline)
                return report
            } catch { lastError = error }
        }
        throw lastError
    }

    private func fetchAccountFingerprint(binary: String, deadline: Date) -> String? {
        guard let data = try? readAppServerMethod("account/read", binary: binary, deadline: deadline) else { return nil }
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

    private func readAppServerMethod(_ method: String, binary: String, deadline: Date) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [binary, "app-server", "--stdio"]
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
            try? input.fileHandleForWriting.close()
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
        let initializeDeadline = min(deadline, Date().addingTimeInterval(initializeTimeout))
        var initialized = false
        while Date() < initializeDeadline {
            if try response(forID: 1, in: responseBuffer.snapshot()) != nil {
                initialized = true
                break
            }
            if !process.isRunning { throw OfficialCodexUsageError.processFailed("Process exited before initialization") }
            Thread.sleep(forTimeInterval: 0.15)
        }
        guard initialized else { throw OfficialCodexUsageError.initializeTimedOut }

        let notification = try CodexAppServerJSONRPCLineCodec.encodeMessage(["method": "initialized", "params": [:]])
        let request = try CodexAppServerJSONRPCLineCodec.encodeRequest(id: 2, method: method, params: [:])
        try input.fileHandleForWriting.write(contentsOf: notification)
        try input.fileHandleForWriting.write(contentsOf: request)
        let usageDeadline = min(deadline, Date().addingTimeInterval(usageTimeout))
        while Date() < usageDeadline {
            if let result = try response(forID: 2, in: responseBuffer.snapshot()) {
                return result
            }
            if !process.isRunning { throw OfficialCodexUsageError.processFailed("Process exited before usage response") }
            Thread.sleep(forTimeInterval: 0.15)
        }
        if !errorBuffer.snapshot().isEmpty { throw OfficialCodexUsageError.processFailed("No valid usage response") }
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
        var fileIdentifiers: [String: String]? = nil
        var partialRowStarts: [String: Int64]? = nil
        var attribution: [String: NativeInputTurnState]? = nil
        var pendingLegacyHistory: [TeamGrindHistoryDay]? = nil
        var pendingLegacySessions: [TeamSessionInteractionSummary]? = nil
        var replayRequired: Bool? = nil
        var coverageComplete: Bool? = nil
        var coverageStartDay: String? = nil
        var coverageEndDay: String? = nil
        var coverageThroughAt: String? = nil
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
                "<external_codex_apps_open_page>", "<codex_internal_context", "<turn_aborted>",
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

    // Screenshot attachments are commonly several MiB in a single JSONL row.
    // Retain a bounded ceiling shared by replay and incremental reassembly.
    private static let maximumNativeRowBytes = 32 * 1024 * 1024
    private let timezone = TimeZone(identifier: "Asia/Shanghai")!

    public init() {}

    public func collect(codexHome: URL, days: Int = 30, now: Date = Date()) -> [TeamGrindHistoryDay] {
        collectDetailed(codexHome: codexHome, days: days, now: now).history
    }

    // Share the existing human-input filter without exposing or retaining text.
    static func authoredEventMetadata(_ data: Data) -> (date: Date, type: String, identifier: String?, timestamp: String)? {
        guard let event = try? JSONDecoder().decode(EventEnvelope.self, from: data),
              event.isAuthoredResponse || event.isLegacyUserEvent,
              let timestamp = event.timestamp, let date = isoDate(timestamp) else { return nil }
        let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let identifier = (raw?["payload"] as? [String: Any])?["id"] as? String
        return (date, event.type ?? "other", identifier?.isEmpty == false ? identifier : nil, timestamp)
    }

    public func collectDetailed(
        codexHome: URL,
        days: Int = 30,
        now: Date = Date()
    ) -> NativeWorkdayCollectionReport {
        fullReplay(codexHome: codexHome, days: days, now: now).report
    }

    private func replayRange(days: Int, now: Date) -> (start: Date, startDay: String, endDay: String) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timezone
        let morning = calendar.date(byAdding: .hour, value: 5, to: calendar.startOfDay(for: now))!
        let current = now < morning ? calendar.date(byAdding: .day, value: -1, to: morning)! : morning
        let start = calendar.date(byAdding: .day, value: -(max(1, min(days, 30)) - 1), to: current)!
        return (start, grindDay(for: start, hour: 5), grindDay(for: current, hour: 5))
    }

    private func fullReplay(codexHome: URL, days: Int, now: Date) -> (report: NativeWorkdayCollectionReport, offsets: [String: Int64], attribution: [String: NativeInputTurnState]) {
        let range = replayRange(days: days, now: now)
        let files = CodexSessionFileIndex(codexHome: codexHome).uniqueFiles().filter { file in
            // Unchanged logs whose creation and last write both predate this workday
            // range cannot contribute a later append. Active long sessions still replay
            // from their header so no attribution is inferred from a tail window.
            file.modifiedAt >= range.start
                || (CodexSessionFileCounter().timestampFromFilename(file.url.lastPathComponent) ?? file.modifiedAt) >= range.start
        }
        var confirmed: [String: InteractionDates] = [:], unknown: [String: InteractionDates] = [:]
        var offsets: [String: Int64] = [:], attribution: [String: NativeInputTurnState] = [:]
        // A missing/unreadable session root is not evidence that the prior history is empty.
        var complete = nativeInventoryComplete(codexHome)
        for file in files {
            var state = NativeInputTurnState(), inputs: [NativeInputTurnState.Input] = []
            let result = scanNativeLines(file: file, start: 0, maximumBytes: Int64.max) { line in
                if line.isEmpty { state.trigger = nil; state.turnID = nil; return true }
                let previous = state
                guard let event = state.consume(line) else { return true }
                if event.date > now { state = previous; return false }
                guard event.date >= range.start, event.classification != "automatic" else { return true }
                inputs.append(event)
                return true
            }
            for event in inputs where !state.hasModernMessages || event.type == "response_item" {
                let session = sessionID(from: file.url)
                if event.classification == "user_submission" { record(event.date, session: session, into: &confirmed) }
                else { record(event.date, session: session, into: &unknown) }
            }
            complete = complete && result.complete && !state.malformedRowSeen
            offsets[file.stableKey] = result.offset
            attribution[file.stableKey] = state
        }
        let human = summaries(confirmed, provenance: "user_submission")
        let legacy = summaries(unknown, provenance: "legacy_unknown")
        return (NativeWorkdayCollectionReport(history: human.history, sessions: human.sessions,
            legacyUnknownHistory: legacy.history, legacyUnknownSessions: legacy.sessions,
            coverageComplete: complete, coverageStartDay: range.startDay, coverageEndDay: range.endDay, coverageThroughAt: isoString(now)), offsets, attribution)
    }

    private func nativeInventoryComplete(_ home: URL) -> Bool {
        var complete = FileManager.default.fileExists(atPath: home.appendingPathComponent("sessions").path)
        for name in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in complete = false; return true }) else { complete = false; continue }
            for case let url as URL in entries where url.pathExtension == "jsonl" {
                if (try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])) == nil { complete = false }
            }
        }
        return complete
    }

    private func record(_ date: Date, session: String, into values: inout [String: InteractionDates]) {
        let hour = Calendar(identifier: .gregorian).dateComponents(in: timezone, from: date).hour ?? 0
        let day = grindDay(for: date, hour: hour), key = "\(session)|\(day)"
        var item = values[key] ?? InteractionDates()
        if hour >= 5 { item.day.append(date) }
        if hour >= 23 || hour < 5 { item.night.append(date) }
        values[key] = item
    }

    private func summaries(_ values: [String: InteractionDates], provenance: String) -> (history: [TeamGrindHistoryDay], sessions: [TeamSessionInteractionSummary]) {
        var history: [String: (day: Date?, night: Date?)] = [:]
        let sessions = values.keys.sorted().compactMap { key -> TeamSessionInteractionSummary? in
            guard let dates = values[key] else { return nil }
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let day = uniqueTurns(dates.day), night = uniqueTurns(dates.night)
            var h = history[parts[1]] ?? (nil, nil)
            if let first = day.first, h.day == nil || first < h.day! { h.day = first }
            if let last = night.last, h.night == nil || last > h.night! { h.night = last }
            history[parts[1]] = h
            return TeamSessionInteractionSummary(sessionId: parts[0], day: parts[1],
                firstDayUserAt: day.first.map(isoString), lastDayUserAt: day.last.map(isoString), dayTurnCount: day.count,
                lastNightUserAt: night.last.map(isoString), nightTurnCount: night.count, inputProvenance: provenance)
        }
        let days = history.keys.sorted().map { day in
            TeamGrindHistoryDay(grindDay: day, dayGrindTime: history[day]!.day.map(timeString),
                nightGrindTime: history[day]!.night.map(timeString), inputProvenance: provenance)
        }
        return (days, sessions)
    }

    /// Streams all complete rows without retaining content between calls. A partial EOF
    /// or oversized row prevents authoritative replacement of any historical range.
    private func scanNativeLines(file: CodexSessionFileIndex.Entry, start: Int64, maximumBytes: Int64, discardingOversizedRow: Bool = false,
                                 visit: (Data) -> Bool) -> (offset: Int64, complete: Bool, discardingOversizedRow: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return (start, false, discardingOversizedRow) }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, start)))
            let target = min(file.size, start + min(maximumBytes, Int64.max - start))
            var offset = start, rowStart = start, buffer = Data(), oversized = discardingOversizedRow, complete = !discardingOversizedRow
            var searchedBytes = 0
            while offset < target {
                let count = Int(min(64 * 1024, target - offset))
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return (rowStart, false, oversized) }
                offset += Int64(chunk.count)
                buffer.append(chunk)
                // Large attachment rows have no newline until their end. Search
                // only newly appended bytes instead of rescanning the whole row.
                while let newline = buffer[buffer.index(buffer.startIndex, offsetBy: searchedBytes)...].firstIndex(of: 10) {
                    let row = Data(buffer.prefix(upTo: newline))
                    if !oversized, row.count <= Self.maximumNativeRowBytes {
                        if !visit(row) { return (rowStart, false, false) }
                    } else { complete = false; _ = visit(Data()) }
                    rowStart += Int64(newline + 1)
                    buffer.removeSubrange(...newline)
                    searchedBytes = 0
                    oversized = false
                }
                searchedBytes = buffer.count
                if buffer.count > Self.maximumNativeRowBytes {
                    complete = false; oversized = true; _ = visit(Data())
                    rowStart += Int64(buffer.count); buffer.removeAll(keepingCapacity: true); searchedBytes = 0
                }
            }
            // Normal appends belong to the next delta; replacement, truncation or deletion
            // invalidate the captured EOF snapshot proof.
            let current = try? file.url.resourceValues(forKeys: [.fileSizeKey, .fileResourceIdentifierKey])
            let currentID = current?.fileResourceIdentifier.map { String(describing: $0) }
            let unchanged = (current?.fileSize.map(Int64.init) ?? -1) >= file.size
                && (file.fileIdentifier == nil || currentID == file.fileIdentifier)
            // Do not advance into a partial row. The next poll reassembles it from disk.
            return (buffer.isEmpty && !oversized ? offset : rowStart,
                    complete && unchanged && buffer.isEmpty && !oversized && target == file.size, oversized)
        } catch { return (start, false, discardingOversizedRow) }
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
    ) -> NativeWorkdayCollectionReport {
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
        stateURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wanhe-codex-token/grind-live.json")
    ) -> NativeWorkdayCollectionReport {
        let range = replayRange(days: days, now: now)
        let loaded = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(IncrementalState.self, from: $0) }
        var state = loaded ?? IncrementalState(initialized: false, updatedAt: isoString(now), fileOffsets: [:])
        if state.collectionVersion == 4, state.coverageComplete == true { return pendingReport(state) }
        if !state.initialized || state.collectionVersion != 4 || state.replayRequired == true {
            let replay = fullReplay(codexHome: codexHome, days: days, now: now)
            // v4 replays v3 clients once so the server can durably establish coverage
            // and isolate older device reports. Re-read the source logs instead of
            // freezing a v3 outbox whose coverage was not persisted by that server.
            // Never merge pre-provenance pending summaries: those can contain automation.
            state.fileOffsets = replay.offsets; state.attribution = replay.attribution
            state.fileIdentifiers = Dictionary(uniqueKeysWithValues: sessionFileIndex.uniqueFiles().compactMap { file in
                file.fileIdentifier.map { (file.stableKey, $0) }
            })
            state.initialized = true; state.collectionVersion = 4; state.partialRowStarts = [:]
            state.pendingHistory = replay.report.history; state.pendingSessions = replay.report.sessions
            state.pendingLegacyHistory = replay.report.legacyUnknownHistory; state.pendingLegacySessions = replay.report.legacyUnknownSessions
            state.replayRequired = !replay.report.coverageComplete
            state.coverageComplete = replay.report.coverageComplete
            state.coverageStartDay = replay.report.coverageStartDay; state.coverageEndDay = replay.report.coverageEndDay
            state.coverageThroughAt = replay.report.coverageThroughAt
            state.updatedAt = isoString(now); saveIncrementalState(state, to: stateURL)
            return pendingReport(state)
        }
        var files = sessionFileIndex.uniqueFiles(modifiedSince: range.start)
        files.sort { $0.modifiedAt > $1.modifiedAt }
        var confirmed: [String: InteractionDates] = [:], unknown: [String: InteractionDates] = [:]
        var attributions = state.attribution ?? [:], identifiers = state.fileIdentifiers ?? [:]
        var processed = 0
        for file in files {
            let key = file.stableKey
            if let id = file.fileIdentifier, let old = identifiers[key], old != id {
                state.fileOffsets[key] = 0; attributions[key] = nil; state.partialRowStarts?[key] = nil
            }
            if let id = file.fileIdentifier { identifiers[key] = id }
            if state.fileOffsets[key] == nil {
                // Old absolute-path cursor keys can survive a move into archived_sessions.
                let previous = state.fileOffsets.first { URL(fileURLWithPath: $0.key).lastPathComponent == key }
                state.fileOffsets[key] = previous?.value ?? 0
                if let previous, previous.key != key { state.fileOffsets.removeValue(forKey: previous.key) }
            }
            var start = state.fileOffsets[key] ?? 0
            if start > file.size { start = 0; attributions[key] = nil; state.partialRowStarts?[key] = nil }
            guard start < file.size, processed < 16 else { continue }
            var attribution = attributions[key] ?? NativeInputTurnState()
            if attribution.isSubagent { state.fileOffsets[key] = file.size; processed += 1; continue }
            let progress = max(start, state.partialRowStarts?[key] ?? start)
            // First inspect one small chunk. A known partial row is reassembled on
            // the next poll within the same bounded ceiling, rather than taking
            // dozens of sync intervals to consume one normal screenshot input.
            let budget: Int64 = progress > start ? Int64(Self.maximumNativeRowBytes + 256 * 1024) : 256 * 1024
            let result = scanNativeLines(file: file, start: start, maximumBytes: budget, discardingOversizedRow: attribution.discardingOversizedRow) { line in
                if line.isEmpty { attribution.trigger = nil; attribution.turnID = nil; return true }
                let previous = attribution
                guard let event = attribution.consume(line) else { return true }
                if event.date > now { attribution = previous; return false }
                guard event.date >= range.start, event.classification != "automatic" else { return true }
                let session = sessionID(from: file.url)
                if event.classification == "user_submission" { record(event.date, session: session, into: &confirmed) }
                else { record(event.date, session: session, into: &unknown) }
                return true
            }
            let target = min(file.size, start + budget)
            if result.offset < target { state.partialRowStarts?[key] = target }
            else { state.partialRowStarts?.removeValue(forKey: key) }
            attribution.discardingOversizedRow = result.discardingOversizedRow
            state.fileOffsets[key] = result.offset; attributions[key] = attribution; processed += 1
            // Daily deltas never claim authoritative range coverage.
            state.coverageComplete = false
        }
        let human = summaries(confirmed, provenance: "user_submission"), legacy = summaries(unknown, provenance: "legacy_unknown")
        state.pendingHistory = mergeHistory(state.pendingHistory ?? [], human.history)
        state.pendingSessions = mergeSessions(state.pendingSessions ?? [], human.sessions)
        state.pendingLegacyHistory = mergeHistory(state.pendingLegacyHistory ?? [], legacy.history)
        state.pendingLegacySessions = mergeSessions(state.pendingLegacySessions ?? [], legacy.sessions)
        let activeKeys = Set(files.map(\.stableKey)), previousOffsetCount = state.fileOffsets.count
        let identifiersChanged = state.fileIdentifiers != identifiers
        state.fileOffsets = state.fileOffsets.filter { activeKeys.contains($0.key) }
        state.partialRowStarts = state.partialRowStarts?.filter { activeKeys.contains($0.key) }
        state.attribution = attributions.filter { activeKeys.contains($0.key) }
        state.fileIdentifiers = identifiers.filter { activeKeys.contains($0.key) }
        if processed > 0 || identifiersChanged || state.fileOffsets.count != previousOffsetCount {
            state.updatedAt = isoString(now); saveIncrementalState(state, to: stateURL)
        }
        return pendingReport(state)
    }

    private func pendingReport(_ state: IncrementalState) -> NativeWorkdayCollectionReport {
        NativeWorkdayCollectionReport(history: state.pendingHistory ?? [], sessions: state.pendingSessions ?? [],
            legacyUnknownHistory: state.pendingLegacyHistory ?? [], legacyUnknownSessions: state.pendingLegacySessions ?? [],
            coverageComplete: state.coverageComplete == true, coverageStartDay: state.coverageStartDay, coverageEndDay: state.coverageEndDay, coverageThroughAt: state.coverageThroughAt)
    }

    public func acknowledgeUploaded(
        stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/grind-live.json")
    ) {
        guard let data = try? Data(contentsOf: stateURL),
              var state = try? JSONDecoder().decode(IncrementalState.self, from: data),
              !(state.pendingHistory ?? []).isEmpty || !(state.pendingSessions ?? []).isEmpty
                || !(state.pendingLegacyHistory ?? []).isEmpty || !(state.pendingLegacySessions ?? []).isEmpty
                || state.coverageComplete == true else { return }
        state.pendingHistory = []
        state.pendingSessions = []
        state.pendingLegacyHistory = []; state.pendingLegacySessions = []
        state.coverageComplete = false; state.coverageStartDay = nil; state.coverageEndDay = nil; state.coverageThroughAt = nil
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
