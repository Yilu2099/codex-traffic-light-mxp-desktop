import Foundation

public struct QuotaSnapshot: Codable, Equatable {
    public var weeklyRemainingPercent: Int
    public var weeklyResetsAt: Date?
    public var source: String
    public var limitID: String?
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case weeklyRemainingPercent = "weekly_remaining_percent"
        case weeklyResetsAt = "weekly_resets_at"
        case source
        case limitID = "limit_id"
        case updatedAt = "updated_at"
    }

    public init(
        weeklyRemainingPercent: Int,
        weeklyResetsAt: Date? = nil,
        source: String,
        limitID: String? = nil,
        updatedAt: Date
    ) {
        self.weeklyRemainingPercent = min(100, max(0, weeklyRemainingPercent))
        self.weeklyResetsAt = weeklyResetsAt
        self.source = source
        self.limitID = limitID
        self.updatedAt = updatedAt
    }
}

public struct QuotaAnomalyRecord: Codable, Equatable {
    public var previous: QuotaSnapshot
    public var rejected: QuotaSnapshot
    public var reason: String
    public var receivedAt: Date

    public init(previous: QuotaSnapshot, rejected: QuotaSnapshot, reason: String, receivedAt: Date) {
        self.previous = previous
        self.rejected = rejected
        self.reason = reason
        self.receivedAt = receivedAt
    }
}

public struct StateSnapshot: Codable, Equatable {
    public var updatedAt: Date
    public var quota: QuotaSnapshot?

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case quota
        case providerQuotas = "provider_quotas"
    }

    public init(updatedAt: Date, quota: QuotaSnapshot? = nil) {
        self.updatedAt = updatedAt
        self.quota = quota
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        quota = try container.decodeIfPresent(QuotaSnapshot.self, forKey: .quota)
        if quota == nil,
           let legacyProviders = try container.decodeIfPresent([String: LegacyProviderQuota].self, forKey: .providerQuotas),
           let codex = legacyProviders["codex"],
           let weekly = codex.weeklyRemainingPercent {
            quota = QuotaSnapshot(
                weeklyRemainingPercent: weekly,
                weeklyResetsAt: codex.weeklyResetsAt,
                source: codex.source,
                updatedAt: codex.updatedAt
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(quota, forKey: .quota)
    }

    public static func empty(now: Date = Date()) -> StateSnapshot {
        StateSnapshot(updatedAt: now)
    }
}

private struct LegacyProviderQuota: Decodable {
    var source: String
    var updatedAt: Date
    var weeklyRemainingPercent: Int?
    var weeklyResetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case source
        case updatedAt = "updated_at"
        case weeklyRemainingPercent = "weekly_remaining_percent"
        case weeklyResetsAt = "weekly_resets_at"
    }
}

public enum Defaults {
    public static let appServerQuotaRefreshSeconds: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["CODEX_LIGHT_APP_SERVER_QUOTA_REFRESH_SECONDS"],
           let seconds = TimeInterval(raw),
           seconds > 0 {
            return seconds
        }
        return 60
    }()
}

public enum CommandContract {
    public static let clientCommandName = "codex-light-mxp"
    public static let quotaCommandName = "quota"
    public static let auditCommandName = "audit"
}
