import Foundation

public struct HookBridgeResult: Equatable, Sendable {
    public var eventName: String
    public var taskID: String
    public var workspace: String?
    public var quotaSummary: String?
    public var recordedProject: Bool

    public init(
        eventName: String,
        taskID: String,
        workspace: String?,
        quotaSummary: String?,
        recordedProject: Bool
    ) {
        self.eventName = eventName
        self.taskID = taskID
        self.workspace = workspace
        self.quotaSummary = quotaSummary
        self.recordedProject = recordedProject
    }
}

public enum HookBridge {
    @discardableResult
    public static func apply(
        input: Data,
        fallbackName: String?,
        store: StateStore = StateStore(),
        now: Date = Date()
    ) throws -> HookBridgeResult {
        let event = HookEvent.parse(jsonData: input, fallbackName: fallbackName)
        let quota = QuotaExtractor.extract(from: input)
        let workspace = ContextResolver.workspace(explicitWorkspace: nil, hookEvent: event)
        let taskID = ContextResolver.taskID(explicitTaskID: nil, workspace: workspace, hookEvent: event)
        if let quota {
            if quota.preferredWindow != nil {
                _ = try store.updateQuota(
                    weeklyPercent: quota.weeklyRemainingPercent,
                    weeklyResetsAt: quota.weeklyResetsAt,
                    fiveHourPercent: quota.fiveHourRemainingPercent,
                    fiveHourResetsAt: quota.fiveHourResetsAt,
                    primaryWindow: quota.primaryWindow,
                    source: "codex-hook",
                    planType: quota.planType,
                    now: now
                )
            }
        }

        var recordedProject = false
        if let auditWorkspace = event.workspace ?? event.cwd, !auditWorkspace.isEmpty {
            let activityURL = store.stateURL.deletingLastPathComponent().appendingPathComponent("project-activity.json")
            if (try? ProjectActivityStore(activityURL: activityURL).record(workspace: auditWorkspace, taskID: taskID, now: now)) != nil {
                recordedProject = true
            }
        }

        return HookBridgeResult(
            eventName: event.name,
            taskID: taskID,
            workspace: workspace,
            quotaSummary: quota?.summary,
            recordedProject: recordedProject
        )
    }
}
