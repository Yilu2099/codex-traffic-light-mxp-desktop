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
    /// Version 2 rebuilds the current day from validated per-turn deltas. The
    /// server may use a newer counter version to replace an inflated legacy
    /// cumulative value instead of applying the normal same-day monotonic max.
    public var counterVersion: Int?

    public init(
        day: String,
        tokens: Int,
        utcDay: String? = nil,
        utcTokens: Int? = nil,
        updatedAt: String,
        source: String = "local_live_increment",
        counterVersion: Int? = 2
    ) {
        self.day = day
        self.tokens = max(0, tokens)
        self.utcDay = utcDay
        self.utcTokens = utcTokens.map { max(0, $0) }
        self.updatedAt = updatedAt
        self.source = source
        self.counterVersion = counterVersion
    }
}

/// Counts only token usage events appended after the collector starts. Existing files are
/// baselined at EOF, so historical conversations are never rescanned.
public struct TodayCodexUsageCollector: Sendable {
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
    }

    /// One Codex request cannot legitimately account for tens of millions of
    /// tokens. Forked/continued sessions can occasionally expose an inherited
    /// cumulative total as `last_token_usage`; count the day without that one
    /// impossible event while retaining the new cumulative baseline.
    private static let maximumSingleEventTokens = 20_000_000

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
            eventValidationVersion: 2
        )
        var stateChanged = loadedState == nil
        if (state.eventValidationVersion ?? 0) < 2 {
            // Do not rescan a whole active day during an upgrade. Some members
            // have very large session files, and a full rebuild can exceed the
            // sync watchdog. New files are validated at their first read.
            state.eventValidationVersion = 2
            stateChanged = true
        }

        if state.day != day {
            state.day = day
            state.tokens = 0
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
            state.eventValidationVersion = 2
            stateChanged = true
        } else {
            let previousUpdate = isoDate(state.updatedAt) ?? now
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
                    expectedLocalDay: day,
                    expectedUTCDay: utcDay,
                    previousCumulative: state.sessionCumulativeTokens[sessionID(file)]
                )
                let isFirstRead = knownOffset == nil && startOffset == 0
                if !isFirstRead || isPlausibleInitialRead(result, file: file) {
                    state.tokens += result.localTokens
                    state.utcTokens = (state.utcTokens ?? 0) + result.utcTokens
                }
                state.fileOffsets[key] = result.nextOffset
                stateChanged = true
                if let cumulative = result.cumulative {
                    state.sessionCumulativeTokens[sessionID(file)] = cumulative
                }
            }
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
            updatedAt: collectedAt
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
        expectedLocalDay: String,
        expectedUTCDay: String,
        previousCumulative: Int?
    ) -> (
        localTokens: Int,
        utcTokens: Int,
        nextOffset: Int64,
        cumulative: Int?,
        firstUsageAt: Date?,
        lastUsageAt: Date?
    ) {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return (0, 0, offset, previousCumulative, nil, nil)
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.readToEnd() ?? Data()
            guard let lastNewline = data.lastIndex(of: 0x0A) else {
                return (0, 0, offset, previousCumulative, nil, nil)
            }
            let complete = data.prefix(through: lastNewline)
            var localAdded = 0
            var utcAdded = 0
            var cumulative = previousCumulative
            var firstUsageAt: Date?
            var lastUsageAt: Date?
            for rawLine in complete.split(separator: 0x0A) {
                let line = Data(rawLine)
                guard line.range(of: Data("\"token_count\"".utf8)) != nil,
                      let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = event["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let totalUsage = info["total_token_usage"] as? [String: Any] else { continue }
                guard let timestamp = date(event["timestamp"]) else { continue }
                if firstUsageAt == nil || timestamp < firstUsageAt! { firstUsageAt = timestamp }
                if lastUsageAt == nil || timestamp > lastUsageAt! { lastUsageAt = timestamp }
                let current = integer(totalUsage["total_tokens"])
                guard current > 0 else { continue }
                let delta: Int
                if let cumulative {
                    if current >= cumulative { delta = current - cumulative }
                    else { delta = integer((info["last_token_usage"] as? [String: Any])?["total_tokens"]) }
                } else {
                    delta = integer((info["last_token_usage"] as? [String: Any])?["total_tokens"])
                }
                cumulative = current
                guard delta > 0, delta <= Self.maximumSingleEventTokens else { continue }
                if dayString(timestamp) == expectedLocalDay { localAdded += delta }
                if utcDayString(timestamp) == expectedUTCDay { utcAdded += delta }
            }
            return (
                max(0, localAdded),
                max(0, utcAdded),
                offset + Int64(complete.count),
                cumulative,
                firstUsageAt,
                lastUsageAt
            )
        } catch {
            return (0, 0, offset, previousCumulative, nil, nil)
        }
    }

    private func isPlausibleInitialRead(
        _ result: (
            localTokens: Int,
            utcTokens: Int,
            nextOffset: Int64,
            cumulative: Int?,
            firstUsageAt: Date?,
            lastUsageAt: Date?
        ),
        file: CodexSessionFileIndex.Entry
    ) -> Bool {
        let first = result.firstUsageAt ?? file.modifiedAt
        let last = max(result.lastUsageAt ?? file.modifiedAt, file.modifiedAt)
        let duration = max(0, last.timeIntervalSince(first))
        // This is intentionally a very generous session-rate ceiling rather
        // than a daily limit: 20M base plus 1M per elapsed second. It rejects
        // a billion inherited tokens written in a few seconds while allowing
        // long-running, genuinely heavy sessions to accumulate without a cap.
        let allowed = 20_000_000 + Int(min(duration, 86_400).rounded(.up)) * 1_000_000
        return max(result.localTokens, result.utcTokens) <= allowed
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

    private func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
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
