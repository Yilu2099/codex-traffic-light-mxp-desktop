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

    private let tailBytes: UInt64
    private let maximumFiles: Int

    public init(tailBytes: UInt64 = 1_048_576, maximumFiles: Int = 200) {
        self.tailBytes = max(65_536, tailBytes)
        self.maximumFiles = max(1, maximumFiles)
    }

    public func collect(codexHome: URL, now: Date = Date(), fileMaxAge: TimeInterval = 2 * 86_400) -> CodexSessionQuotaObservation? {
        let cutoff = now.addingTimeInterval(-fileMaxAge)
        let roots = ["sessions", "archived_sessions"].map { codexHome.appendingPathComponent($0) }
        var files: [(url: URL, modifiedAt: Date)] = []

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }
                let modifiedAt = values.contentModificationDate ?? .distantPast
                if modifiedAt >= cutoff { files.append((url, modifiedAt)) }
            }
        }

        files.sort { $0.modifiedAt > $1.modifiedAt }
        var newest: CodexSessionQuotaObservation?
        for file in files.prefix(maximumFiles) {
            guard let observation = newestObservation(in: file.url) else { continue }
            if newest == nil || observation.observedAt > newest!.observedAt { newest = observation }
        }
        return newest
    }

    private func newestObservation(in url: URL) -> CodexSessionQuotaObservation? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > tailBytes ? end - tailBytes : 0
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.readToEnd(), !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            if start > 0, !text.hasPrefix("\n"), !lines.isEmpty { lines.removeFirst() }
            for line in lines.reversed() {
                guard line.contains("\"type\":\"token_count\""), line.contains("\"rate_limits\""),
                      let observation = parse(line: line) else { continue }
                return observation
            }
        } catch {
            return nil
        }
        return nil
    }

    private func parse(line: Substring) -> CodexSessionQuotaObservation? {
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
        if observation.observedAt > existing.updatedAt { return true }

        let age = now.timeIntervalSince(observation.observedAt)
        guard age >= -60,
              age <= freshness,
              existing.weeklyRemainingPercent >= 99,
              observation.weeklyRemainingPercent < 99,
              let existingReset = existing.weeklyResetsAt,
              let observedReset = observation.weeklyResetsAt else { return false }
        return existingReset.timeIntervalSince(observedReset) > 12 * 60 * 60
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
