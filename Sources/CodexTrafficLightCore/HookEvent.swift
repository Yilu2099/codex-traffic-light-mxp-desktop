import Foundation

public struct HookEvent: Equatable, Sendable {
    public var name: String
    public var cwd: String?
    public var workspace: String?
    public var sessionID: String?
    public var threadID: String?

    public static func parse(jsonData: Data, fallbackName: String? = nil) -> HookEvent {
        guard !jsonData.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return HookEvent(name: fallbackName ?? "")
        }
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        return HookEvent(
            name: string("hook_event_name") ?? fallbackName ?? "",
            cwd: string("cwd", "current_dir"),
            workspace: string("workspace", "workspace_root"),
            sessionID: string("session_id", "conversation_id"),
            threadID: string("thread_id", "turn_id")
        )
    }
}
