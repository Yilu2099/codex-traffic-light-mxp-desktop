import Foundation

public enum GrindDisplayFormatter {
    public static func start(_ time: String?) -> String {
        guard let time = normalized(time) else { return "待开工" }
        return "开工 \(time)"
    }

    public static func finish(_ time: String?) -> String {
        guard let time = normalized(time) else { return "收工未记录" }
        return "收工 \(time)"
    }

    /// Mirrors the website: show the current workday from 14:00 through 04:59.
    public static func status(lastMessageAt: String?, previousFinish: String?, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!
        let hour = calendar.component(.hour, from: now)
        if hour >= 5 && hour < 14 { return finish(previousFinish) }

        let day = calendar.startOfDay(for: now)
        let workday = calendar.date(byAdding: .day, value: hour < 5 ? -1 : 0, to: day)!
        let start = calendar.date(byAdding: .hour, value: 5, to: workday)!
        let parser = ISO8601DateFormatter()
        let raw = lastMessageAt ?? ""
        let wholeSeconds = parser.date(from: raw)
        parser.formatOptions.insert(.withFractionalSeconds)
        guard let last = wholeSeconds ?? parser.date(from: raw), last >= start, last <= now else {
            return "未记录"
        }
        if now.timeIntervalSince(last) <= 30 * 60 { return "进行中" }
        let time = calendar.dateComponents([.hour, .minute], from: last)
        return String(format: "%02d:%02d", time.hour!, time.minute!)
    }

    private static func normalized(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
