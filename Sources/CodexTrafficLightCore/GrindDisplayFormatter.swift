import Foundation

public enum GrindDisplayFormatter {
    public static func start(_ time: String?) -> String {
        guard let time = normalized(time) else { return "待开工" }
        return "今日开工 \(time)"
    }

    public static func finish(_ time: String?) -> String {
        guard let time = normalized(time) else { return "收工未记录" }
        return "收工 \(time)"
    }

    private static func normalized(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
