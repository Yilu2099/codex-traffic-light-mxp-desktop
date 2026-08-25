import Foundation

public struct HookLogEntry {
    public var timestamp: Date
    public var eventName: String
    public var taskID: String
    public var workspace: String?
    public var result: String
    public var detail: String?
    public var quotaSummary: String?

    public init(
        timestamp: Date = Date(),
        eventName: String,
        taskID: String,
        workspace: String?,
        result: String,
        detail: String?,
        quotaSummary: String? = nil
    ) {
        self.timestamp = timestamp
        self.eventName = eventName
        self.taskID = taskID
        self.workspace = workspace
        self.result = result
        self.detail = detail
        self.quotaSummary = quotaSummary
    }
}

public enum HookLogger {
    public static func defaultLogURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_TRAFFIC_LIGHT_HOOK_LOG_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return StateStore.defaultSupportDirectory().appendingPathComponent("hook-mxp.log")
    }

    public static func format(_ entry: HookLogEntry) -> String {
        var parts = [
            formattedTimestamp(entry.timestamp),
            "event=\(field(entry.eventName))",
            "task=\(field(entry.taskID))",
            "workspace=\(field(entry.workspace ?? "-"))",
            "result=\(field(entry.result))",
            "quota=\(field(entry.quotaSummary ?? "none"))"
        ]
        if let detail = entry.detail, !detail.isEmpty {
            parts.append("detail=\(field(detail))")
        }
        return parts.joined(separator: " ") + "\n"
    }

    public static func append(_ entry: HookLogEntry, to url: URL = defaultLogURL()) {
        BoundedLog.append(format(entry), to: url)
    }

    private static func formattedTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func field(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
