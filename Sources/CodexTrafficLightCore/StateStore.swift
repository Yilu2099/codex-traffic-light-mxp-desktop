import Foundation

public enum StateStoreError: Error, CustomStringConvertible {
    case invalidInput(String)

    public var description: String {
        switch self {
        case .invalidInput(let value): return value
        }
    }
}

public final class StateStore {
    public let stateURL: URL
    public var quotaAnomaliesURL: URL {
        stateURL.deletingLastPathComponent().appendingPathComponent("quota-anomalies.json")
    }

    public init(stateURL: URL = StateStore.defaultStateURL()) {
        self.stateURL = stateURL
    }

    public static func defaultSupportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexTrafficLight", isDirectory: true)
    }

    public static func defaultStateURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_TRAFFIC_LIGHT_STATE_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return defaultSupportDirectory().appendingPathComponent("state.json")
    }

    public func read() -> StateSnapshot {
        guard let data = try? Data(contentsOf: stateURL) else {
            return .empty()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(StateSnapshot.self, from: data)) ?? .empty()
    }

    @discardableResult
    public func updateQuota(
        weeklyPercent: Int,
        weeklyResetsAt: Date? = nil,
        source: String,
        limitID: String? = nil,
        planType: String? = nil,
        now: Date = Date()
    ) throws -> StateSnapshot {
        var snapshot = read()
        let incoming = QuotaSnapshot(
            weeklyRemainingPercent: weeklyPercent,
            weeklyResetsAt: weeklyResetsAt,
            source: source,
            limitID: limitID,
            planType: MembershipPlanType.normalized(planType) ?? snapshot.quota?.planType,
            updatedAt: now
        )
        if let previous = snapshot.quota,
           let reason = Self.quotaAnomalyReason(previous: previous, incoming: incoming, now: now) {
            try recordQuotaAnomaly(QuotaAnomalyRecord(
                previous: previous,
                rejected: incoming,
                reason: reason,
                receivedAt: now
            ))
            return snapshot
        }
        snapshot.quota = incoming
        snapshot.updatedAt = now
        try write(snapshot)
        return snapshot
    }

    public func readQuotaAnomalies() -> [QuotaAnomalyRecord] {
        guard let data = try? Data(contentsOf: quotaAnomaliesURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([QuotaAnomalyRecord].self, from: data)) ?? []
    }

    private static func quotaAnomalyReason(previous: QuotaSnapshot, incoming: QuotaSnapshot, now: Date) -> String? {
        if incoming.limitID == CodexSessionQuotaCollector.primaryLimitID,
           [CodexSessionQuotaCollector.source, CodexAppServerQuotaCollector.source].contains(incoming.source) {
            return nil
        }
        guard let previousReset = previous.weeklyResetsAt,
              now < previousReset.addingTimeInterval(-5 * 60) else { return nil }
        if let incomingReset = incoming.weeklyResetsAt,
           incoming.weeklyRemainingPercent >= 99,
           previous.weeklyRemainingPercent < 99,
           incomingReset.timeIntervalSince(previousReset) > 12 * 60 * 60 {
            return "unexpected_full_quota_before_known_reset"
        }
        if let incomingReset = incoming.weeklyResetsAt,
           abs(incomingReset.timeIntervalSince(previousReset)) <= 5 * 60,
           incoming.weeklyRemainingPercent - previous.weeklyRemainingPercent >= 20 {
            return "unexpected_quota_increase_in_same_window"
        }
        return nil
    }

    private func recordQuotaAnomaly(_ record: QuotaAnomalyRecord) throws {
        var records = readQuotaAnomalies()
        records.append(record)
        records = Array(records.suffix(120))
        try FileManager.default.createDirectory(
            at: quotaAnomaliesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(records).write(to: quotaAnomaliesURL, options: [.atomic])
    }

    public func write(_ snapshot: StateSnapshot) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(snapshot)
        try data.write(to: stateURL, options: [.atomic])
    }
}
