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

    public init(
        day: String,
        tokens: Int,
        utcDay: String? = nil,
        utcTokens: Int? = nil,
        updatedAt: String,
        source: String = "local_live_increment"
    ) {
        self.day = day
        self.tokens = max(0, tokens)
        self.utcDay = utcDay
        self.utcTokens = utcTokens.map { max(0, $0) }
        self.updatedAt = updatedAt
        self.source = source
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
    }

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
        let day = dayString(now)
        let utcDay = utcDayString(now)
        let files = recentJSONLFiles(codexHome: codexHome, now: now)
        var state = loadState() ?? State(
            initialized: false,
            day: day,
            tokens: 0,
            utcDay: utcDay,
            utcTokens: 0,
            utcBaselineComplete: false,
            updatedAt: isoString(now),
            fileOffsets: [:],
            sessionCumulativeTokens: [:]
        )

        if state.day != day {
            state.day = day
            state.tokens = 0
        }
        if state.utcDay != utcDay {
            state.utcDay = utcDay
            state.utcTokens = 0
            state.utcBaselineComplete = true
        }

        if !state.initialized {
            for file in files {
                state.fileOffsets[file.path] = fileSize(file)
            }
            state.initialized = true
        } else {
            let previousUpdate = isoDate(state.updatedAt) ?? now
            for file in files {
                let size = fileSize(file)
                let knownOffset = state.fileOffsets[file.path]
                let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let startOffset: Int64
                if let knownOffset {
                    startOffset = min(max(0, knownOffset), size)
                } else if modifiedAt >= previousUpdate && !file.path.contains("/archived_sessions/") {
                    startOffset = 0
                } else {
                    startOffset = size
                }
                guard startOffset < size else {
                    state.fileOffsets[file.path] = size
                    continue
                }
                let result = appendedUsage(
                    file: file,
                    from: startOffset,
                    expectedLocalDay: day,
                    expectedUTCDay: utcDay,
                    previousCumulative: state.sessionCumulativeTokens[sessionID(file)]
                )
                state.tokens += result.localTokens
                state.utcTokens = (state.utcTokens ?? 0) + result.utcTokens
                state.fileOffsets[file.path] = result.nextOffset
                if let cumulative = result.cumulative {
                    state.sessionCumulativeTokens[sessionID(file)] = cumulative
                }
            }
        }

        let activePaths = Set(files.map(\.path))
        state.fileOffsets = state.fileOffsets.filter { activePaths.contains($0.key) }
        state.updatedAt = isoString(now)
        saveState(state)
        return TodayLiveUsageReport(
            day: day,
            tokens: state.tokens,
            utcDay: state.utcBaselineComplete == true ? utcDay : nil,
            utcTokens: state.utcBaselineComplete == true ? (state.utcTokens ?? 0) : nil,
            updatedAt: state.updatedAt
        )
    }

    private func recentJSONLFiles(codexHome: URL, now: Date) -> [URL] {
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
        var result: [URL] = []
        for folder in ["sessions", "archived_sessions"] {
            let root = codexHome.appendingPathComponent(folder)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if (modified ?? .distantPast) >= cutoff { result.append(file) }
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private func appendedUsage(
        file: URL,
        from offset: Int64,
        expectedLocalDay: String,
        expectedUTCDay: String,
        previousCumulative: Int?
    ) -> (localTokens: Int, utcTokens: Int, nextOffset: Int64, cumulative: Int?) {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return (0, 0, offset, previousCumulative)
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.readToEnd() ?? Data()
            guard let lastNewline = data.lastIndex(of: 0x0A) else {
                return (0, 0, offset, previousCumulative)
            }
            let complete = data.prefix(through: lastNewline)
            var localAdded = 0
            var utcAdded = 0
            var cumulative = previousCumulative
            for rawLine in complete.split(separator: 0x0A) {
                let line = Data(rawLine)
                guard line.range(of: Data("\"token_count\"".utf8)) != nil,
                      let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = event["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let totalUsage = info["total_token_usage"] as? [String: Any] else { continue }
                guard let timestamp = date(event["timestamp"]) else { continue }
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
                if dayString(timestamp) == expectedLocalDay { localAdded += delta }
                if utcDayString(timestamp) == expectedUTCDay { utcAdded += delta }
            }
            return (max(0, localAdded), max(0, utcAdded), offset + Int64(complete.count), cumulative)
        } catch {
            return (0, 0, offset, previousCumulative)
        }
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

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func sessionID(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
        return name.range(of: pattern, options: .regularExpression).map { String(name[$0]) } ?? name
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
