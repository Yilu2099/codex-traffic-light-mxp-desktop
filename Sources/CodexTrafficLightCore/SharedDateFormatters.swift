import Foundation

/// Process-wide formatters shared by the session-log parsing hot paths.
/// DateFormatter and ISO8601DateFormatter are thread-safe for parse/format
/// calls on macOS 10.9+, and these instances are never mutated after init.
public struct SharedDateFormatters: @unchecked Sendable {
    public static let shared = SharedDateFormatters()

    public let iso8601Fractional: ISO8601DateFormatter
    public let iso8601Plain: ISO8601DateFormatter
    public let shanghaiDay: DateFormatter
    public let utcDay: DateFormatter

    private init() {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso8601Fractional = fractional
        iso8601Plain = ISO8601DateFormatter()

        shanghaiDay = Self.makeDayFormatter(timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        utcDay = Self.makeDayFormatter(timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    public func iso8601Date(from value: String) -> Date? {
        iso8601Fractional.date(from: value) ?? iso8601Plain.date(from: value)
    }

    private static func makeDayFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_CA")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
