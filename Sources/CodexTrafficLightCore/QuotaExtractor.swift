import Foundation

public struct QuotaValues: Equatable, Sendable {
    public var fiveHourRemainingPercent: Int?
    public var weeklyRemainingPercent: Int?
    public var fiveHourResetsAt: Date?
    public var weeklyResetsAt: Date?
    public var primaryWindow: CodexQuotaWindowKind?
    public var planType: String?

    public init(
        weeklyRemainingPercent: Int? = nil,
        weeklyResetsAt: Date? = nil,
        fiveHourRemainingPercent: Int? = nil,
        fiveHourResetsAt: Date? = nil,
        primaryWindow: CodexQuotaWindowKind? = nil,
        planType: String? = nil
    ) {
        self.fiveHourRemainingPercent = fiveHourRemainingPercent.map { min(100, max(0, $0)) }
        self.weeklyRemainingPercent = weeklyRemainingPercent.map { min(100, max(0, $0)) }
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weeklyResetsAt = weeklyResetsAt
        self.primaryWindow = primaryWindow
        self.planType = MembershipPlanType.normalized(planType)
    }

    public var summary: String {
        preferredWindow.map { "\($0.kind.label) \($0.remainingPercent)%" } ?? "--"
    }

    public var preferredWindow: CodexQuotaWindow? {
        if primaryWindow == .fiveHour, let remaining = fiveHourRemainingPercent {
            return CodexQuotaWindow(kind: .fiveHour, remainingPercent: remaining, resetsAt: fiveHourResetsAt)
        }
        if primaryWindow == .weekly, let remaining = weeklyRemainingPercent {
            return CodexQuotaWindow(kind: .weekly, remainingPercent: remaining, resetsAt: weeklyResetsAt)
        }
        if let remaining = fiveHourRemainingPercent {
            return CodexQuotaWindow(kind: .fiveHour, remainingPercent: remaining, resetsAt: fiveHourResetsAt)
        }
        if let remaining = weeklyRemainingPercent {
            return CodexQuotaWindow(kind: .weekly, remainingPercent: remaining, resetsAt: weeklyResetsAt)
        }
        return nil
    }
}

public enum QuotaExtractor {
    private static let fiveHourKeys = ["five_hour_remaining_percent", "fiveHourRemainingPercent"]
    private static let weeklyKeys = ["weekly_remaining_percent", "weeklyRemainingPercent"]
    private static let fiveHourResetKeys = ["five_hour_resets_at", "fiveHourResetsAt", "five_hour_reset_at", "fiveHourResetAt"]
    private static let weeklyResetKeys = ["weekly_resets_at", "weeklyResetsAt", "weekly_reset_at", "weeklyResetAt"]
    private static let primaryWindowKeys = ["primary_window", "primaryWindow"]
    private static let preferredContainerKeys = ["quota", "rate_limits", "rateLimits"]
    private static let planTypeKeys = ["plan_type", "planType"]

    public static func extract(from data: Data) -> QuotaValues? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return extract(from: object)
    }

    public static func extract(from object: Any) -> QuotaValues? {
        if let dictionary = object as? [String: Any] {
            if let limitID = (dictionary["limit_id"] ?? dictionary["limitId"]) as? String,
               !limitID.isEmpty,
               limitID.lowercased() != CodexSessionQuotaCollector.primaryLimitID {
                return nil
            }
            if let values = values(in: dictionary) {
                return values
            }

            for key in preferredContainerKeys {
                if let child = dictionary[key], let values = extract(from: child) {
                    return values
                }
            }

            for key in dictionary.keys.sorted() where !preferredContainerKeys.contains(key) {
                if let child = dictionary[key], let values = extract(from: child) {
                    return values
                }
            }
        }

        if let array = object as? [Any] {
            for child in array {
                if let values = extract(from: child) {
                    return values
                }
            }
        }

        return nil
    }

    private static func values(in dictionary: [String: Any]) -> QuotaValues? {
        let fiveHour = firstPercent(in: dictionary, keys: fiveHourKeys)
        let weekly = firstPercent(in: dictionary, keys: weeklyKeys)
        guard fiveHour != nil || weekly != nil else { return nil }
        return QuotaValues(
            weeklyRemainingPercent: weekly,
            weeklyResetsAt: firstDate(in: dictionary, keys: weeklyResetKeys),
            fiveHourRemainingPercent: fiveHour,
            fiveHourResetsAt: firstDate(in: dictionary, keys: fiveHourResetKeys),
            primaryWindow: firstWindowKind(in: dictionary, keys: primaryWindowKeys),
            planType: firstString(in: dictionary, keys: planTypeKeys)
        )
    }

    private static func firstWindowKind(in dictionary: [String: Any], keys: [String]) -> CodexQuotaWindowKind? {
        guard let raw = firstString(in: dictionary, keys: keys)?.lowercased() else { return nil }
        if ["five_hour", "fivehour", "5h", "300"].contains(raw) { return .fiveHour }
        if ["weekly", "week", "10080"].contains(raw) { return .weekly }
        return nil
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String { return value }
        }
        return nil
    }

    private static func firstPercent(in dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dictionary[key], let percent = percent(from: value) {
                return percent
            }
        }
        return nil
    }

    private static func percent(from value: Any) -> Int? {
        if let integer = value as? Int {
            return integer
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            return Int(number.doubleValue)
        }
        if let string = value as? String,
           let number = Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return Int(number)
        }
        return nil
    }

    private static func firstDate(in dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let value = dictionary[key], let date = date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func date(from value: Any) -> Date? {
        if let integer = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(integer))
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return nil
            }
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Double(trimmed) {
                return Date(timeIntervalSince1970: number)
            }
            return ISO8601DateFormatter().date(from: trimmed)
        }
        return nil
    }
}

public enum MembershipPlanType {
    private static let supported = Set(["plus", "prolite", "pro"])

    public static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return supported.contains(normalized) ? normalized : nil
    }
}
