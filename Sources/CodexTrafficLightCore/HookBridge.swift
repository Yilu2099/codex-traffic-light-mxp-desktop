import Foundation

public struct HookBridgeResult: Equatable, Sendable {
    public var eventName: String
    public var state: LightState
    public var taskID: String
    public var workspace: String?
    public var quotaSummary: String?
    public var updatedTask: Bool

    public init(
        eventName: String,
        state: LightState,
        taskID: String,
        workspace: String?,
        quotaSummary: String?,
        updatedTask: Bool
    ) {
        self.eventName = eventName
        self.state = state
        self.taskID = taskID
        self.workspace = workspace
        self.quotaSummary = quotaSummary
        self.updatedTask = updatedTask
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
        let quotaOnly = HookMapper.isQuotaOnlyEvent(event.name)
        let workspace = ContextResolver.workspace(explicitWorkspace: nil, hookEvent: event)
        let taskID = ContextResolver.taskID(explicitTaskID: nil, workspace: workspace, hookEvent: event)
        var snapshot = store.read()

        if let quota {
            snapshot = try store.updateQuota(
                fiveHourPercent: quota.fiveHourRemainingPercent,
                weeklyPercent: quota.weeklyRemainingPercent,
                fiveHourResetsAt: quota.fiveHourResetsAt,
                weeklyResetsAt: quota.weeklyResetsAt,
                source: "codex-hook",
                now: now
            )
        }

        if quotaOnly {
            return HookBridgeResult(
                eventName: event.name,
                state: snapshot.aggregateState == .quit ? .idle : snapshot.aggregateState,
                taskID: taskID,
                workspace: workspace,
                quotaSummary: quota?.summary,
                updatedTask: false
            )
        }

        let state = HookMapper.state(for: event)
        let message = event.lastAssistantMessage ?? "Codex traffic light: \(state.rawValue)"
        snapshot = try store.updateTask(
            taskID: taskID,
            state: state,
            workspace: workspace,
            source: "codex-hook",
            hookEventName: event.name,
            message: message,
            now: now
        )

        return HookBridgeResult(
            eventName: event.name,
            state: state,
            taskID: taskID,
            workspace: workspace,
            quotaSummary: quota?.summary,
            updatedTask: true
        )
    }
}
