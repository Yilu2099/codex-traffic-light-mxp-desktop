import Foundation

public struct QuotaValues: Equatable, Sendable {
    public var fiveHourRemainingPercent: Int
    public var weeklyRemainingPercent: Int
    public var fiveHourResetsAt: Date?
    public var weeklyResetsAt: Date?

    public init(
        fiveHourRemainingPercent: Int,
        weeklyRemainingPercent: Int,
        fiveHourResetsAt: Date? = nil,
        weeklyResetsAt: Date? = nil
    ) {
        self.fiveHourRemainingPercent = min(100, max(0, fiveHourRemainingPercent))
        self.weeklyRemainingPercent = min(100, max(0, weeklyRemainingPercent))
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weeklyResetsAt = weeklyResetsAt
    }

    public var summary: String {
        "\(fiveHourRemainingPercent)/\(weeklyRemainingPercent)"
    }
}

public enum QuotaExtractor {
    private static let fiveHourKeys = ["five_hour_remaining_percent", "fiveHourRemainingPercent"]
    private static let weeklyKeys = ["weekly_remaining_percent", "weeklyRemainingPercent"]
    private static let fiveHourResetKeys = ["five_hour_resets_at", "fiveHourResetsAt", "five_hour_reset_at", "fiveHourResetAt"]
    private static let weeklyResetKeys = ["weekly_resets_at", "weeklyResetsAt", "weekly_reset_at", "weeklyResetAt"]
    private static let preferredContainerKeys = ["quota", "rate_limits", "rateLimits"]

    public static func extract(from data: Data) -> QuotaValues? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return extract(from: object)
    }

    public static func extract(from object: Any) -> QuotaValues? {
        if let dictionary = object as? [String: Any] {
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
        guard let fiveHour = firstPercent(in: dictionary, keys: fiveHourKeys),
              let weekly = firstPercent(in: dictionary, keys: weeklyKeys) else {
            return nil
        }
        return QuotaValues(
            fiveHourRemainingPercent: fiveHour,
            weeklyRemainingPercent: weekly,
            fiveHourResetsAt: firstDate(in: dictionary, keys: fiveHourResetKeys),
            weeklyResetsAt: firstDate(in: dictionary, keys: weeklyResetKeys)
        )
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
