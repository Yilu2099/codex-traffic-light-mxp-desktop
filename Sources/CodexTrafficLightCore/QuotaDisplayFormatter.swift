import Foundation

public enum QuotaDisplayFormatter {
    public static func refreshCountdownText(until resetsAt: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(resetsAt.timeIntervalSince(now).rounded(.up)))
        if seconds <= 0 { return "即将刷新" }

        if seconds >= 86_400 {
            return "\(max(1, seconds / 86_400))天后刷新"
        }
        let totalHours = max(1, Int(ceil(Double(seconds) / 3_600.0)))
        return "\(totalHours)小时后刷新"
    }

    public static func absoluteDateTimeText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}
