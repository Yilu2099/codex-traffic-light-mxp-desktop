import Foundation

public enum CodexQuotaWindowKind: String, Codable, Equatable, Sendable {
    case fiveHour = "five_hour"
    case weekly

    public var label: String {
        switch self {
        case .fiveHour: return "5小时"
        case .weekly: return "周"
        }
    }
}

public struct CodexQuotaWindow: Equatable, Sendable {
    public var kind: CodexQuotaWindowKind
    public var remainingPercent: Int
    public var resetsAt: Date?

    public init(kind: CodexQuotaWindowKind, remainingPercent: Int, resetsAt: Date?) {
        self.kind = kind
        self.remainingPercent = min(100, max(0, remainingPercent))
        self.resetsAt = resetsAt
    }
}

public struct QuotaSnapshot: Codable, Equatable {
    public var fiveHourRemainingPercent: Int?
    public var weeklyRemainingPercent: Int?
    public var fiveHourResetsAt: Date?
    public var weeklyResetsAt: Date?
    public var primaryWindow: CodexQuotaWindowKind?
    public var source: String
    public var limitID: String?
    public var planType: String?
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case fiveHourRemainingPercent = "five_hour_remaining_percent"
        case weeklyRemainingPercent = "weekly_remaining_percent"
        case fiveHourResetsAt = "five_hour_resets_at"
        case weeklyResetsAt = "weekly_resets_at"
        case primaryWindow = "primary_window"
        case source
        case limitID = "limit_id"
        case planType = "plan_type"
        case updatedAt = "updated_at"
    }

    public init(
        weeklyRemainingPercent: Int? = nil,
        weeklyResetsAt: Date? = nil,
        fiveHourRemainingPercent: Int? = nil,
        fiveHourResetsAt: Date? = nil,
        primaryWindow: CodexQuotaWindowKind? = nil,
        source: String,
        limitID: String? = nil,
        planType: String? = nil,
        updatedAt: Date
    ) {
        self.fiveHourRemainingPercent = fiveHourRemainingPercent.map { min(100, max(0, $0)) }
        self.weeklyRemainingPercent = weeklyRemainingPercent.map { min(100, max(0, $0)) }
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weeklyResetsAt = weeklyResetsAt
        self.primaryWindow = primaryWindow
        self.source = source
        self.limitID = limitID
        self.planType = MembershipPlanType.normalized(planType)
        self.updatedAt = updatedAt
    }

    public var availableWindows: [CodexQuotaWindow] {
        var windows: [CodexQuotaWindow] = []
        if let remaining = fiveHourRemainingPercent {
            windows.append(CodexQuotaWindow(kind: .fiveHour, remainingPercent: remaining, resetsAt: fiveHourResetsAt))
        }
        if let remaining = weeklyRemainingPercent {
            windows.append(CodexQuotaWindow(kind: .weekly, remainingPercent: remaining, resetsAt: weeklyResetsAt))
        }
        if let primaryWindow, let index = windows.firstIndex(where: { $0.kind == primaryWindow }), index > 0 {
            windows.swapAt(0, index)
        }
        return windows
    }

    public var preferredWindow: CodexQuotaWindow? {
        availableWindows.first
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
           codex.fiveHourRemainingPercent != nil || codex.weeklyRemainingPercent != nil {
            quota = QuotaSnapshot(
                weeklyRemainingPercent: codex.weeklyRemainingPercent,
                weeklyResetsAt: codex.weeklyResetsAt,
                fiveHourRemainingPercent: codex.fiveHourRemainingPercent,
                fiveHourResetsAt: codex.fiveHourResetsAt,
                primaryWindow: codex.fiveHourRemainingPercent != nil ? .fiveHour : .weekly,
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
    var fiveHourRemainingPercent: Int?
    var weeklyRemainingPercent: Int?
    var fiveHourResetsAt: Date?
    var weeklyResetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case source
        case updatedAt = "updated_at"
        case fiveHourRemainingPercent = "five_hour_remaining_percent"
        case weeklyRemainingPercent = "weekly_remaining_percent"
        case fiveHourResetsAt = "five_hour_resets_at"
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
