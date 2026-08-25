import Foundation

public struct CodexSessionQuotaObservation: Sendable, Equatable {
    public var weeklyRemainingPercent: Int
    public var weeklyResetsAt: Date?
    public var observedAt: Date

    public init(
        weeklyRemainingPercent: Int,
        weeklyResetsAt: Date?,
        observedAt: Date
    ) {
        self.weeklyRemainingPercent = min(100, max(0, weeklyRemainingPercent))
        self.weeklyResetsAt = weeklyResetsAt
        self.observedAt = observedAt
    }
}

/// Reads only Codex `token_count` quota metadata from the newest session tails.
/// This provides the same rate-limit value the Codex UI just received, without
/// relying on a second app-server process that can time out behind a proxy.
public struct CodexSessionQuotaCollector: Sendable {
    public static let source = "codex-session-rate-limits"
    public static let primaryLimitID = "codex"

    public static func defaultStateURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/session-quota.json")
    }

    private struct FileCursor: Codable, Equatable {
        var path: String
        var fileIdentifier: String?
        var offset: UInt64
        var size: UInt64
        var modifiedAt: TimeInterval
    }

    private struct PersistedObservation: Codable, Equatable {
        var weeklyRemainingPercent: Int
        var weeklyResetsAt: TimeInterval?
        var observedAt: TimeInterval

        init(_ observation: CodexSessionQuotaObservation) {
            weeklyRemainingPercent = observation.weeklyRemainingPercent
            weeklyResetsAt = observation.weeklyResetsAt?.timeIntervalSince1970
            observedAt = observation.observedAt.timeIntervalSince1970
        }

        var observation: CodexSessionQuotaObservation {
            CodexSessionQuotaObservation(
                weeklyRemainingPercent: weeklyRemainingPercent,
                weeklyResetsAt: weeklyResetsAt.map { Date(timeIntervalSince1970: $0) },
                observedAt: Date(timeIntervalSince1970: observedAt)
            )
        }
    }

    private struct State: Codable, Equatable {
        var version: Int
        var files: [String: FileCursor]
        var latest: PersistedObservation?
    }

    private let tailBytes: UInt64
    private let maximumFiles: Int
    private let stateURL: URL

    public init(
        tailBytes: UInt64 = 1_048_576,
        maximumFiles: Int = 200,
        stateURL: URL = CodexSessionQuotaCollector.defaultStateURL()
    ) {
        self.tailBytes = max(65_536, tailBytes)
        self.maximumFiles = max(1, maximumFiles)
        self.stateURL = stateURL
    }

    public func collect(codexHome: URL, now: Date = Date(), fileMaxAge: TimeInterval = 2 * 86_400) -> CodexSessionQuotaObservation? {
        collect(
            sessionFileIndex: CodexSessionFileIndex(codexHome: codexHome),
            now: now,
            fileMaxAge: fileMaxAge
        )
    }

    public func collect(
        sessionFileIndex: CodexSessionFileIndex,
        now: Date = Date(),
        fileMaxAge: TimeInterval = 2 * 86_400
    ) -> CodexSessionQuotaObservation? {
        let cutoff = now.addingTimeInterval(-fileMaxAge)
        var uniqueFiles: [String: CodexSessionFileIndex.Entry] = [:]
        for file in sessionFileIndex.files where file.modifiedAt >= cutoff {
            let key = file.stableKey
            if let existing = uniqueFiles[key], existing.modifiedAt >= file.modifiedAt { continue }
            uniqueFiles[key] = file
        }
        let files = uniqueFiles.values.sorted { $0.modifiedAt > $1.modifiedAt }
        let original = loadState() ?? State(version: 1, files: [:], latest: nil)
        var state = original
        var newest = state.latest?.observation
        if let observation = newest, observation.observedAt > now.addingTimeInterval(60) {
            newest = nil
        }
        let activeKeys = Set(files.prefix(maximumFiles).map(\.stableKey))

        for file in files.prefix(maximumFiles) {
            let key = file.stableKey
            let size = UInt64(max(0, file.size))
            let modifiedAt = file.modifiedAt.timeIntervalSince1970
            if var cursor = state.files[key],
               cursor.size == size,
               cursor.modifiedAt == modifiedAt {
                // Moving a rollout from sessions to archived_sessions preserves
                // its stable filename and therefore does not trigger a reread.
                cursor.path = file.path
                cursor.fileIdentifier = file.fileIdentifier
                state.files[key] = cursor
                continue
            }

            let previous = state.files[key]
            let isSameFile = previous.map {
                guard let previousID = $0.fileIdentifier,
                      let currentID = file.fileIdentifier else { return $0.path == file.path }
                return previousID == currentID
            } ?? false
            let isAppend = previous.map {
                isSameFile && size > $0.size && $0.offset <= $0.size
            } ?? false
            let start: UInt64
            let discardLeadingPartial: Bool
            if isAppend, let previous {
                start = min(previous.offset, size)
                discardLeadingPartial = false
            } else {
                start = size > tailBytes ? size - tailBytes : 0
                discardLeadingPartial = start > 0
            }

            guard let result = observations(
                in: file.url,
                from: start,
                discardLeadingPartial: discardLeadingPartial
            ) else { continue }
            for observation in result.values
            where observation.observedAt <= now.addingTimeInterval(60)
                && (newest == nil || observation.observedAt > newest!.observedAt) {
                newest = observation
            }
            state.files[key] = FileCursor(
                path: file.path,
                fileIdentifier: file.fileIdentifier,
                offset: result.nextOffset,
                size: size,
                modifiedAt: modifiedAt
            )
        }

        state.files = state.files.filter { activeKeys.contains($0.key) }
        state.latest = newest.map(PersistedObservation.init)
        if state != original { saveState(state) }
        return newest
    }

    private func observations(
        in url: URL,
        from start: UInt64,
        discardLeadingPartial: Bool
    ) -> (values: [CodexSessionQuotaObservation], nextOffset: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            guard !data.isEmpty else { return ([], start) }
            guard let newline = data.lastIndex(of: 0x0A) else { return ([], start) }
            let complete = data.prefix(through: newline)
            var lines = complete.split(separator: 0x0A, omittingEmptySubsequences: true)
            if discardLeadingPartial, !lines.isEmpty { lines.removeFirst() }
            var values: [CodexSessionQuotaObservation] = []
            for line in lines {
                guard line.range(of: Data("\"type\":\"token_count\"".utf8)) != nil,
                      line.range(of: Data("\"rate_limits\"".utf8)) != nil,
                      let observation = parse(line: String(decoding: line, as: UTF8.self)) else { continue }
                values.append(observation)
            }
            return (values, start + UInt64(complete.count))
        } catch {
            return nil
        }
    }

    private func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func saveState(_ state: State) {
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: [.atomic])
    }

    private func parse(line: String) -> CodexSessionQuotaObservation? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let timestamp = object["timestamp"] as? String,
              let observedAt = Self.isoDate(timestamp),
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any],
              Self.limitID(in: limits) == Self.primaryLimitID else { return nil }

        let windows = [limits["primary"], limits["secondary"]].compactMap { $0 as? [String: Any] }
        var weekly: [String: Any]?
        for window in windows {
            let minutes = Self.int(window["window_minutes"] ?? window["windowDurationMins"])
            if minutes == 10_080 { weekly = window }
        }
        guard let weekly, let weeklyUsed = Self.double(weekly["used_percent"] ?? weekly["usedPercent"]) else { return nil }
        return CodexSessionQuotaObservation(
            weeklyRemainingPercent: Self.remainingPercent(weeklyUsed),
            weeklyResetsAt: Self.resetDate(weekly),
            observedAt: observedAt
        )
    }

    private static func remainingPercent(_ used: Double) -> Int {
        min(100, max(0, Int((100 - used).rounded())))
    }

    private static func limitID(in limits: [String: Any]) -> String? {
        let value = limits["limit_id"] ?? limits["limitId"]
        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func shouldApply(
        _ observation: CodexSessionQuotaObservation,
        over existing: QuotaSnapshot?,
        now: Date,
        freshness: TimeInterval = 15 * 60
    ) -> Bool {
        guard let existing else { return true }
        let age = now.timeIntervalSince(observation.observedAt)
        if existing.limitID != primaryLimitID {
            return age >= -60 && age <= freshness
        }
        if observation.observedAt > existing.updatedAt { return true }

        guard age >= -60,
              age <= freshness,
              existing.weeklyRemainingPercent >= 99,
              observation.weeklyRemainingPercent < 99,
              let existingReset = existing.weeklyResetsAt,
              let observedReset = observation.weeklyResetsAt else { return false }
        return existingReset.timeIntervalSince(observedReset) > 12 * 60 * 60
    }

    public static func isFresh(
        _ observation: CodexSessionQuotaObservation,
        now: Date,
        freshness: TimeInterval = 15 * 60
    ) -> Bool {
        let age = now.timeIntervalSince(observation.observedAt)
        return age >= -60 && age <= freshness
    }

    private static func resetDate(_ window: [String: Any]) -> Date? {
        guard let seconds = double(window["resets_at"] ?? window["resetsAt"]) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func isoDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
