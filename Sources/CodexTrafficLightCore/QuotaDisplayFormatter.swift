import Foundation

public enum QuotaResetUnitStyle {
    case hoursAndMinutes
    case daysAndHours
}

public enum QuotaDisplayFormatter {
    public static func relativeResetText(until resetsAt: Date, now: Date = Date(), unitStyle: QuotaResetUnitStyle) -> String {
        let seconds = max(0, Int(resetsAt.timeIntervalSince(now).rounded(.up)))
        if seconds <= 0 {
            return "即将恢复"
        }

        switch unitStyle {
        case .daysAndHours:
            return daysAndHoursText(seconds: seconds)
        case .hoursAndMinutes:
            return hoursAndMinutesText(seconds: seconds)
        }
    }

    public static func absoluteDateTimeText(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    private static func daysAndHoursText(seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        if days > 0 {
            if hours > 0 {
                return "还有\(days)天\(hours)小时"
            }
            return "还有\(days)天"
        }

        if hours > 0 {
            return "还有\(hours)小时"
        }

        let minutes = Int(ceil(Double(seconds) / 60.0))
        if minutes > 0 {
            return "还有\(minutes)分"
        }
        return "即将恢复"
    }

    private static func hoursAndMinutesText(seconds: Int) -> String {
        let totalHours = seconds / 3_600
        let minutes = Int(ceil(Double(seconds % 3_600) / 60.0))
        if totalHours > 0 {
            if minutes > 0 {
                return "还有\(totalHours)小时\(minutes)分"
            }
            return "还有\(totalHours)小时"
        }

        if minutes > 0 {
            return "还有\(minutes)分"
        }
        return "即将恢复"
    }
}
