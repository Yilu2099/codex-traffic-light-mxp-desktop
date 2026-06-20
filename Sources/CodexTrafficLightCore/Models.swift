import Foundation

public enum LightState: String, Codable, Equatable, CaseIterable, CustomStringConvertible, Sendable {
    case idle
    case working
    case done
    case waiting
    case quit

    public var description: String { rawValue }

    public var label: String {
        switch self {
        case .idle: return "空闲"
        case .working: return "工作中"
        case .done: return "已完成"
        case .waiting: return "待确认"
        case .quit: return "退出"
        }
    }

    public var sortPriority: Int {
        switch self {
        case .waiting: return 3
        case .working: return 2
        case .done: return 1
        case .idle, .quit: return 0
        }
    }
}

public struct TaskState: Codable, Equatable {
    public var state: LightState
    public var workspace: String?
    public var source: String
    public var hookEventName: String?
    public var message: String?
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case state
        case workspace
        case source
        case hookEventName = "hook_event_name"
        case message
        case updatedAt = "updated_at"
    }

    public init(
        state: LightState,
        workspace: String?,
        source: String,
        hookEventName: String?,
        message: String?,
        updatedAt: Date
    ) {
        self.state = state
        self.workspace = workspace
        self.source = source
        self.hookEventName = hookEventName
        self.message = message
        self.updatedAt = updatedAt
    }
}

public struct QuotaSnapshot: Codable, Equatable {
    public var fiveHourRemainingPercent: Int
    public var weeklyRemainingPercent: Int
    public var source: String
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case fiveHourRemainingPercent = "five_hour_remaining_percent"
        case weeklyRemainingPercent = "weekly_remaining_percent"
        case source
        case updatedAt = "updated_at"
    }

    public init(
        fiveHourRemainingPercent: Int,
        weeklyRemainingPercent: Int,
        source: String,
        updatedAt: Date
    ) {
        self.fiveHourRemainingPercent = min(100, max(0, fiveHourRemainingPercent))
        self.weeklyRemainingPercent = min(100, max(0, weeklyRemainingPercent))
        self.source = source
        self.updatedAt = updatedAt
    }
}

public struct StateSnapshot: Codable, Equatable {
    public var aggregateState: LightState
    public var updatedAt: Date
    public var quota: QuotaSnapshot?
    public var tasks: [String: TaskState]

    enum CodingKeys: String, CodingKey {
        case aggregateState = "aggregate_state"
        case updatedAt = "updated_at"
        case quota
        case tasks
    }

    public init(aggregateState: LightState, updatedAt: Date, quota: QuotaSnapshot? = nil, tasks: [String: TaskState]) {
        self.aggregateState = aggregateState
        self.updatedAt = updatedAt
        self.quota = quota
        self.tasks = tasks
    }

    public static func empty(now: Date = Date()) -> StateSnapshot {
        StateSnapshot(aggregateState: .idle, updatedAt: now, tasks: [:])
    }

    public func computedAggregate(
        now: Date = Date(),
        doneTTL: TimeInterval = Defaults.doneAutoIdleSeconds,
        workingTTL: TimeInterval = Defaults.workingAutoIdleSeconds,
        waitingTTL: TimeInterval = Defaults.waitingAutoIdleSeconds
    ) -> LightState {
        if tasks.values.contains(where: { $0.state == .waiting && now.timeIntervalSince($0.updatedAt) <= waitingTTL }) {
            return .waiting
        }
        if tasks.values.contains(where: { $0.state == .working && now.timeIntervalSince($0.updatedAt) <= workingTTL }) {
            return .working
        }
        let hasRecentDone = tasks.values.contains { task in
            task.state == .done && now.timeIntervalSince(task.updatedAt) <= doneTTL
        }
        return hasRecentDone ? .done : .idle
    }

    public func pruningExpiredTasks(
        now: Date = Date(),
        doneTTL: TimeInterval = Defaults.doneAutoIdleSeconds,
        workingTTL: TimeInterval = Defaults.workingAutoIdleSeconds,
        waitingTTL: TimeInterval = Defaults.waitingAutoIdleSeconds
    ) -> StateSnapshot {
        let activeTasks = tasks.filter { _, task in
            switch task.state {
            case .done:
                return now.timeIntervalSince(task.updatedAt) <= doneTTL
            case .working:
                return now.timeIntervalSince(task.updatedAt) <= workingTTL
            case .waiting:
                return now.timeIntervalSince(task.updatedAt) <= waitingTTL
            case .idle, .quit:
                return true
            }
        }
        return StateSnapshot(
            aggregateState: StateSnapshot(aggregateState: aggregateState, updatedAt: updatedAt, quota: quota, tasks: activeTasks).computedAggregate(now: now, doneTTL: doneTTL, workingTTL: workingTTL, waitingTTL: waitingTTL),
            updatedAt: now,
            quota: quota,
            tasks: activeTasks
        )
    }

    public func pruningExpiredDone(now: Date = Date(), doneTTL: TimeInterval = Defaults.doneAutoIdleSeconds) -> StateSnapshot {
        pruningExpiredTasks(now: now, doneTTL: doneTTL)
    }
}

public enum Defaults {
    public static let doneAutoIdleSeconds: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["CODEX_LIGHT_DONE_IDLE_SECONDS"],
           let seconds = TimeInterval(raw),
           seconds > 0 {
            return seconds
        }
        return 10 * 60
    }()

    public static let waitingAlertSeconds: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["CODEX_LIGHT_WAITING_ALERT_SECONDS"],
           let seconds = TimeInterval(raw),
           seconds > 0 {
            return seconds
        }
        return 10
    }()

    public static let workingAutoIdleSeconds: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["CODEX_LIGHT_WORKING_IDLE_SECONDS"],
           let seconds = TimeInterval(raw),
           seconds > 0 {
            return seconds
        }
        return 90
    }()

    public static let waitingAutoIdleSeconds: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["CODEX_LIGHT_WAITING_IDLE_SECONDS"],
           let seconds = TimeInterval(raw),
           seconds > 0 {
            return seconds
        }
        return 5 * 60
    }()

    public static let appServerQuotaRefreshSeconds: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["CODEX_LIGHT_APP_SERVER_QUOTA_REFRESH_SECONDS"],
           let seconds = TimeInterval(raw),
           seconds > 0 {
            return seconds
        }
        return 60
    }()
}

public enum CommandContract {
    public static let lightCommandName = "codex-light-mxp"
    public static let hookCommandName = "codex-light-hook-mxp"
    public static let quotaCommandName = "quota"
}
