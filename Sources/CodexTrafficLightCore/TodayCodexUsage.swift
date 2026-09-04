import Foundation

public struct TodayLiveUsageReport: Codable, Equatable, Sendable {
    public var day: String
    public var tokens: Int
    /// Tokens appended since the current UTC day began. The server uses this
    /// continuation to join official settled buckets without changing the
    /// user-facing local calendar day.
    public var utcDay: String?
    public var utcTokens: Int?
    public var updatedAt: String
    public var source: String
    /// Version 4 validates every appended turn and reports suspicious usage
    /// separately. Version 3 is reserved for the earlier manual audit repair.
    public var counterVersion: Int?
    /// Parser/anomaly-isolation capability. This is deliberately independent
    /// from counterVersion, which controls same-day replacement authority.
    public var validationVersion: Int?
    /// Confirmed usage in the trailing 30 minutes. Quarantined usage is kept
    /// only in `pendingTokens`, so one bad event cannot freeze later work.
    public var recent30MinuteTokens: Int?
    /// Suspicious usage observed on this local calendar day. It is never
    /// included in `tokens` or `utcTokens`.
    public var pendingTokens: Int?
    public var anomalyCount: Int?

    public init(
        day: String,
        tokens: Int,
        utcDay: String? = nil,
        utcTokens: Int? = nil,
        updatedAt: String,
        source: String = "local_live_increment",
        counterVersion: Int? = 4,
        validationVersion: Int? = 4,
        recent30MinuteTokens: Int? = 0,
        pendingTokens: Int? = 0,
        anomalyCount: Int? = 0
    ) {
        self.day = day
        self.tokens = max(0, tokens)
        self.utcDay = utcDay
        self.utcTokens = utcTokens.map { max(0, $0) }
        self.updatedAt = updatedAt
        self.source = source
        self.counterVersion = counterVersion
        self.validationVersion = validationVersion
        self.recent30MinuteTokens = recent30MinuteTokens.map { max(0, $0) }
        self.pendingTokens = pendingTokens.map { max(0, $0) }
        self.anomalyCount = anomalyCount.map { max(0, $0) }
    }
}

/// Counts only token usage events appended after the collector starts. Existing files are
/// baselined at EOF, so historical conversations are never rescanned.
public struct TodayCodexUsageCollector: Sendable {
    private struct RecentTokenEvent: Codable {
        var timestamp: String
        var tokens: Int
        var confirmed: Bool
    }

    private struct State: Codable {
        var initialized: Bool
        var day: String
        var tokens: Int
        var utcDay: String?
        var utcTokens: Int?
        var utcBaselineComplete: Bool?
        var updatedAt: String
        var fileOffsets: [String: Int64]
        var sessionCumulativeTokens: [String: Int]
        var eventValidationVersion: Int?
        /// Separate from the parser version: only a fresh day may claim v4's
        /// authority to replace a lower same-day server counter.
        var reportCounterVersion: Int?
        var pendingTokens: Int?
        var anomalyCount: Int?
        var recentEvents: [RecentTokenEvent]?
    }

    private struct UsageSample {
        var inputTokens: Int?
        var cachedInputTokens: Int?
        var cacheWriteInputTokens: Int?
        var outputTokens: Int?
        var reasoningOutputTokens: Int?
        var totalTokens: Int
        var componentsPresent: Bool
        var componentsValid: Bool
    }

    private struct CandidateEvent {
        var timestamp: Date
        var tokens: Int
        var structurallyValid: Bool
    }

    private struct AppendedUsageResult {
        var events: [CandidateEvent]
        var nextOffset: Int64
        var cumulative: Int?
    }

    /// If an older Codex event omits `model_context_window`, quarantine only
    /// very large turns. Current events use their actual context limit.
    private static let fallbackMaximumSingleEventTokens = 2_000_000
    private static let maximumConfirmedThirtyMinuteTokens = 50_000_000
    private static let recentWindow: TimeInterval = 30 * 60

    private let stateURL: URL
    private let timeZone: TimeZone

    public init(
        stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/today-live.json"),
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    ) {
        self.stateURL = stateURL
        self.timeZone = timeZone
    }

    public func collect(codexHome: URL, now: Date = Date()) -> TodayLiveUsageReport {
        collect(
            codexHome: codexHome,
            sessionFileIndex: CodexSessionFileIndex(codexHome: codexHome),
            now: now
        )
    }

    /// Reads the small persisted counter without enumerating or opening any
    /// Codex session file. Presence heartbeats use this as a lightweight
    /// fallback when a full team payload is still being prepared.
    public func cachedReport(now: Date = Date()) -> TodayLiveUsageReport? {
        guard let state = loadState(), state.initialized, state.day == dayString(now) else { return nil }
        let utcDay = utcDayString(now)
        let cutoff = now.addingTimeInterval(-Self.recentWindow)
        let latestAllowed = now.addingTimeInterval(5 * 60)
        let recent = (state.recentEvents ?? []).filter {
            guard let timestamp = isoDate($0.timestamp) else { return false }
            return timestamp >= cutoff && timestamp <= latestAllowed
        }
        return TodayLiveUsageReport(
            day: state.day,
            tokens: state.tokens,
            utcDay: state.utcBaselineComplete == true && state.utcDay == utcDay ? utcDay : nil,
            utcTokens: state.utcBaselineComplete == true && state.utcDay == utcDay ? state.utcTokens : nil,
            updatedAt: state.updatedAt,
            counterVersion: state.reportCounterVersion ?? 2,
            validationVersion: state.eventValidationVersion ?? 4,
            recent30MinuteTokens: recent.reduce(0) { $1.confirmed ? $0 + $1.tokens : $0 },
            pendingTokens: state.pendingTokens ?? 0,
            anomalyCount: state.anomalyCount ?? 0
        )
    }

    /// Uses a caller-owned metadata snapshot so a team sync does not enumerate
    /// the same Codex directory once per collector.
    public func collect(
        codexHome: URL,
        sessionFileIndex: CodexSessionFileIndex,
        now: Date = Date()
    ) -> TodayLiveUsageReport {
        let day = dayString(now)
        let utcDay = utcDayString(now)
        let files = recentJSONLFiles(sessionFileIndex: sessionFileIndex, now: now)
        let loadedState = loadState()
        var state = loadedState ?? State(
            initialized: false,
            day: day,
            tokens: 0,
            utcDay: utcDay,
            utcTokens: 0,
            utcBaselineComplete: false,
            updatedAt: isoString(now),
            fileOffsets: [:],
            sessionCumulativeTokens: [:],
            eventValidationVersion: 4,
            reportCounterVersion: 4,
            pendingTokens: 0,
            anomalyCount: 0,
            recentEvents: []
        )
        var stateChanged = loadedState == nil
        if (state.eventValidationVersion ?? 0) < 4 {
            // Preserve the already reported counter. Rebuilding every active
            // file can exceed the sync watchdog; v4 validates all new tails.
            state.eventValidationVersion = 4
            // A legacy same-day total may still contain the spike that an
            // operator already repaired as server-side v3. Do not relabel it
            // as v4 and resurrect the bad value.
            state.reportCounterVersion = state.reportCounterVersion ?? 2
            state.pendingTokens = state.pendingTokens ?? 0
            state.anomalyCount = state.anomalyCount ?? 0
            state.recentEvents = state.recentEvents ?? []
            stateChanged = true
        }

        if state.day != day {
            state.day = day
            state.tokens = 0
            state.reportCounterVersion = 4
            state.pendingTokens = 0
            state.anomalyCount = 0
            stateChanged = true
        }
        if state.utcDay == nil {
            // A pre-1.2.75 state has no trustworthy UTC-day baseline. Start
            // tracking now, but do not report it as complete until rollover.
            state.utcDay = utcDay
            state.utcTokens = 0
            state.utcBaselineComplete = false
            stateChanged = true
        } else if state.utcDay != utcDay {
            state.utcDay = utcDay
            state.utcTokens = 0
            state.utcBaselineComplete = true
            stateChanged = true
        }

        if !state.initialized {
            for file in files {
                state.fileOffsets[file.stableKey] = file.size
            }
            state.initialized = true
            state.eventValidationVersion = 4
            state.reportCounterVersion = 4
            stateChanged = true
        } else {
            let previousUpdate = isoDate(state.updatedAt) ?? now
            var candidates: [CandidateEvent] = []
            for file in files {
                let key = file.stableKey
                let size = file.size
                let legacyOffset = state.fileOffsets[file.path]
                let knownOffset = state.fileOffsets[key] ?? legacyOffset
                if state.fileOffsets[key] == nil, let legacyOffset {
                    state.fileOffsets[key] = legacyOffset
                    state.fileOffsets.removeValue(forKey: file.path)
                    stateChanged = true
                }
                let startOffset: Int64
                if let knownOffset {
                    startOffset = min(max(0, knownOffset), size)
                } else if file.isArchived,
                          state.sessionCumulativeTokens[sessionID(file)] == nil {
                    // A short session can be created and archived entirely
                    // between two polls. No cumulative state means it has not
                    // been observed before, so read it from the beginning.
                    startOffset = 0
                } else if file.modifiedAt >= previousUpdate && !file.isArchived {
                    startOffset = 0
                } else {
                    // Existing cumulative state identifies a pre-stable-key
                    // move. Baseline its unknown archived path at EOF instead
                    // of risking historical token double-counting.
                    startOffset = size
                }
                guard startOffset < size else {
                    if knownOffset != size { stateChanged = true }
                    state.fileOffsets[key] = size
                    continue
                }
                let result = appendedUsage(
                    file: file.url,
                    from: startOffset,
                    previousCumulative: state.sessionCumulativeTokens[sessionID(file)],
                    minimumCountedAt: knownOffset == nil && startOffset == 0
                        ? newSessionWatermark(file: file, previousUpdate: previousUpdate)
                        : nil
                )
                candidates.append(contentsOf: result.events)
                state.fileOffsets[key] = result.nextOffset
                stateChanged = true
                if let cumulative = result.cumulative {
                    state.sessionCumulativeTokens[sessionID(file)] = cumulative
                }
            }
            if !candidates.isEmpty {
                var recent = (state.recentEvents ?? []).compactMap { stored -> (Date, Int, Bool)? in
                    guard let timestamp = isoDate(stored.timestamp), stored.tokens > 0 else { return nil }
                    return (timestamp, stored.tokens, stored.confirmed)
                }
                for candidate in candidates.sorted(by: { $0.timestamp < $1.timestamp }) {
                    let timestampIsPlausible = candidate.timestamp <= now.addingTimeInterval(5 * 60)
                    let confirmed: Bool
                    if timestampIsPlausible {
                        let cutoff = candidate.timestamp.addingTimeInterval(-Self.recentWindow)
                        recent.removeAll { $0.0 < cutoff }
                        let confirmedInWindow = recent.reduce(0) { partial, item in
                            item.2 && item.0 <= candidate.timestamp ? partial + item.1 : partial
                        }
                        let withinRate = candidate.tokens <= max(0, Self.maximumConfirmedThirtyMinuteTokens - confirmedInWindow)
                        confirmed = candidate.structurallyValid && withinRate
                        recent.append((candidate.timestamp, candidate.tokens, confirmed))
                    } else {
                        // A far-future row is auditable pending usage, but it
                        // must not advance or prune the real rolling window.
                        confirmed = false
                    }
                    if dayString(candidate.timestamp) == day {
                        if confirmed {
                            state.tokens += candidate.tokens
                        } else {
                            state.pendingTokens = (state.pendingTokens ?? 0) + candidate.tokens
                            state.anomalyCount = (state.anomalyCount ?? 0) + 1
                        }
                    }
                    if confirmed, utcDayString(candidate.timestamp) == utcDay {
                        state.utcTokens = (state.utcTokens ?? 0) + candidate.tokens
                    }
                }
                let finalCutoff = now.addingTimeInterval(-Self.recentWindow)
                state.recentEvents = recent.filter { $0.0 >= finalCutoff }.map {
                    RecentTokenEvent(timestamp: isoString($0.0), tokens: $0.1, confirmed: $0.2)
                }
            }
        }

        let finalCutoff = now.addingTimeInterval(-Self.recentWindow)
        let latestAllowed = now.addingTimeInterval(5 * 60)
        let prunedRecent = (state.recentEvents ?? []).filter {
            guard let timestamp = isoDate($0.timestamp) else { return false }
            return timestamp >= finalCutoff && timestamp <= latestAllowed
        }
        if prunedRecent.count != (state.recentEvents ?? []).count {
            state.recentEvents = prunedRecent
            stateChanged = true
        }

        let activeKeys = Set(files.map(\.stableKey))
        let activeSessionIDs = Set(files.map(sessionID))
        let previousOffsetCount = state.fileOffsets.count
        let previousSessionCount = state.sessionCumulativeTokens.count
        state.fileOffsets = state.fileOffsets.filter { activeKeys.contains($0.key) }
        state.sessionCumulativeTokens = state.sessionCumulativeTokens.filter { activeSessionIDs.contains($0.key) }
        if state.fileOffsets.count != previousOffsetCount || state.sessionCumulativeTokens.count != previousSessionCount {
            stateChanged = true
        }
        let collectedAt = isoString(now)
        if stateChanged {
            state.updatedAt = collectedAt
            saveState(state)
        }
        return TodayLiveUsageReport(
            day: day,
            tokens: state.tokens,
            utcDay: state.utcBaselineComplete == true ? utcDay : nil,
            utcTokens: state.utcBaselineComplete == true ? (state.utcTokens ?? 0) : nil,
            updatedAt: collectedAt,
            counterVersion: state.reportCounterVersion ?? 2,
            validationVersion: state.eventValidationVersion ?? 4,
            recent30MinuteTokens: prunedRecent.reduce(0) { $1.confirmed ? $0 + $1.tokens : $0 },
            pendingTokens: state.pendingTokens ?? 0,
            anomalyCount: state.anomalyCount ?? 0
        )
    }

    private func recentJSONLFiles(
        sessionFileIndex: CodexSessionFileIndex,
        now: Date
    ) -> [CodexSessionFileIndex.Entry] {
        let startOfDay = Calendar(identifier: .gregorian).dateComponents(in: timeZone, from: now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let localCutoff = calendar.date(from: DateComponents(
            year: startOfDay.year,
            month: startOfDay.month,
            day: startOfDay.day
        )) ?? now.addingTimeInterval(-86_400)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let utcCutoff = utcCalendar.startOfDay(for: now)
        let cutoff = min(localCutoff, utcCutoff)
        return sessionFileIndex.uniqueFiles(modifiedSince: cutoff)
    }

    private func appendedUsage(
        file: URL,
        from offset: Int64,
        previousCumulative: Int?,
        minimumCountedAt: Date? = nil
    ) -> AppendedUsageResult {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return AppendedUsageResult(events: [], nextOffset: offset, cumulative: previousCumulative)
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.readToEnd() ?? Data()
            guard let lastNewline = data.lastIndex(of: 0x0A) else {
                return AppendedUsageResult(events: [], nextOffset: offset, cumulative: previousCumulative)
            }
            let complete = data.prefix(through: lastNewline)
            var cumulative = previousCumulative
            var candidates: [CandidateEvent] = []
            for rawLine in complete.split(separator: 0x0A) {
                let line = Data(rawLine)
                guard line.range(of: Data("\"token_count\"".utf8)) != nil,
                      let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = event["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let totalUsage = usageSample(info["total_token_usage"]) else { continue }
                guard let timestamp = date(event["timestamp"]) else { continue }
                let current = totalUsage.totalTokens
                guard current > 0 else { continue }
                let lastUsage = usageSample(info["last_token_usage"])
                let candidateTokens: Int
                var cumulativeConsistent = true
                if let cumulative {
                    if current >= cumulative {
                        candidateTokens = current - cumulative
                    } else {
                        candidateTokens = lastUsage?.totalTokens ?? current
                        cumulativeConsistent = false
                    }
                } else {
                    candidateTokens = lastUsage?.totalTokens ?? current
                }
                cumulative = current
                guard candidateTokens > 0 else { continue }
                // A newly discovered fork can contain a byte-for-byte copy of
                // earlier token rows. They establish the cumulative baseline
                // but do not become new work on this device/day.
                if let minimumCountedAt, timestamp < minimumCountedAt { continue }
                let contextWindow = positiveInteger(info["model_context_window"])
                let maximum = contextWindow ?? Self.fallbackMaximumSingleEventTokens
                let lastMatchesDelta = lastUsage.map { $0.totalTokens == candidateTokens } ?? true
                let valid = cumulativeConsistent
                    && candidateTokens <= maximum
                    && usageIsValid(totalUsage)
                    && (lastUsage.map(usageIsValid) ?? true)
                    && lastMatchesDelta
                candidates.append(CandidateEvent(
                    timestamp: timestamp,
                    tokens: candidateTokens,
                    structurallyValid: valid
                ))
            }
            return AppendedUsageResult(
                events: candidates,
                nextOffset: offset + Int64(complete.count),
                cumulative: cumulative
            )
        } catch {
            return AppendedUsageResult(events: [], nextOffset: offset, cumulative: previousCumulative)
        }
    }

    private func usageSample(_ value: Any?) -> UsageSample? {
        guard let raw = value as? [String: Any], let total = nonnegativeInteger(raw["total_tokens"]), total > 0 else {
            return nil
        }
        return UsageSample(
            inputTokens: nonnegativeInteger(raw["input_tokens"]),
            cachedInputTokens: nonnegativeInteger(raw["cached_input_tokens"]),
            cacheWriteInputTokens: nonnegativeInteger(raw["cache_write_input_tokens"]),
            outputTokens: nonnegativeInteger(raw["output_tokens"]),
            reasoningOutputTokens: nonnegativeInteger(raw["reasoning_output_tokens"]),
            totalTokens: total,
            componentsPresent: [
                "input_tokens", "cached_input_tokens", "cache_write_input_tokens",
                "output_tokens", "reasoning_output_tokens",
            ].contains { raw[$0] != nil },
            componentsValid: [
                "input_tokens", "cached_input_tokens", "cache_write_input_tokens",
                "output_tokens", "reasoning_output_tokens",
            ].allSatisfy { raw[$0] == nil || nonnegativeInteger(raw[$0]) != nil }
        )
    }

    private func usageIsValid(_ usage: UsageSample) -> Bool {
        guard usage.componentsValid else { return false }
        if !usage.componentsPresent { return true }
        guard let input = usage.inputTokens, let output = usage.outputTokens else {
            return false
        }
        // Codex occasionally emits last_token_usage with only total_tokens
        // populated while all component counters are zero. The cumulative
        // delta and context limit still authenticate that scalar value.
        if input == 0, output == 0, usage.totalTokens > 0,
           (usage.cachedInputTokens ?? 0) == 0,
           (usage.cacheWriteInputTokens ?? 0) == 0,
           (usage.reasoningOutputTokens ?? 0) == 0 {
            return true
        }
        guard input <= usage.totalTokens, output <= usage.totalTokens,
              input + output == usage.totalTokens else { return false }
        if let cached = usage.cachedInputTokens, cached > input { return false }
        if let cacheWrite = usage.cacheWriteInputTokens, cacheWrite > input { return false }
        if let reasoning = usage.reasoningOutputTokens, reasoning > output { return false }
        return true
    }

    private func newSessionWatermark(file: CodexSessionFileIndex.Entry, previousUpdate: Date) -> Date {
        let filenameStartedAt = CodexSessionFileCounter().timestampFromFilename(file.url.lastPathComponent)
        let lowerBound = max(previousUpdate, filenameStartedAt ?? previousUpdate)
        return lowerBound.addingTimeInterval(-5)
    }

    private func nonnegativeInteger(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            let result = number.intValue
            return result >= 0 ? result : nil
        }
        if let text = value as? String, let result = Int(text), result >= 0 { return result }
        return nil
    }

    private func positiveInteger(_ value: Any?) -> Int? {
        guard let result = nonnegativeInteger(value), result > 0 else { return nil }
        return result
    }

    private func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func saveState(_ state: State) {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: [.atomic])
    }

    private func sessionID(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        return name.range(of: pattern, options: .regularExpression).map { String(name[$0]) } ?? name
    }

    private func sessionID(_ file: CodexSessionFileIndex.Entry) -> String {
        sessionID(file.url)
    }

    private func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private func isoDate(_ value: String) -> Date? {
        date(value)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_CA")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func utcDayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_CA")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
