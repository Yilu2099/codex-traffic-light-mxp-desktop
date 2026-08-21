import Foundation

public enum StateStoreError: Error, CustomStringConvertible {
    case invalidState(String)

    public var description: String {
        switch self {
        case .invalidState(let value): return "Unknown state: \(value)"
        }
    }
}

public final class StateStore {
    public let stateURL: URL

    public init(stateURL: URL = StateStore.defaultStateURL()) {
        self.stateURL = stateURL
    }

    public static func defaultSupportDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexTrafficLight", isDirectory: true)
    }

    public static func defaultStateURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CODEX_TRAFFIC_LIGHT_STATE_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return defaultSupportDirectory().appendingPathComponent("state.json")
    }

    public func read() -> StateSnapshot {
        guard let data = try? Data(contentsOf: stateURL) else {
            return .empty()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(StateSnapshot.self, from: data) else {
            return .empty()
        }
        if snapshot.aggregateState == .quit {
            return snapshot
        }
        return snapshot.pruningExpiredDone()
    }

    @discardableResult
    public func updateTask(
        taskID: String,
        state: LightState,
        workspace: String?,
        source: String,
        hookEventName: String?,
        message: String?,
        now: Date = Date()
    ) throws -> StateSnapshot {
        var snapshot = read().pruningExpiredDone(now: now)
        if state == .idle {
            snapshot.tasks.removeValue(forKey: taskID)
        } else if state == .quit {
            snapshot.aggregateState = .quit
            snapshot.updatedAt = now
            try write(snapshot)
            return snapshot
        } else {
            snapshot.tasks[taskID] = TaskState(
                state: state,
                workspace: workspace,
                source: source,
                hookEventName: hookEventName,
                message: message,
                updatedAt: now
            )
        }
        snapshot.aggregateState = snapshot.computedAggregate(now: now)
        snapshot.updatedAt = now
        try write(snapshot)
        return snapshot
    }

    @discardableResult
    public func clear(now: Date = Date()) throws -> StateSnapshot {
        let existing = read()
        let snapshot = StateSnapshot(
            aggregateState: .idle,
            updatedAt: now,
            quota: existing.quota,
            providerQuotas: existing.providerQuotas,
            tasks: [:]
        )
        try write(snapshot)
        return snapshot
    }

    @discardableResult
    public func updateQuota(
        fiveHourPercent: Int,
        weeklyPercent: Int,
        fiveHourResetsAt: Date? = nil,
        weeklyResetsAt: Date? = nil,
        source: String,
        now: Date = Date()
    ) throws -> StateSnapshot {
        var snapshot = read().pruningExpiredDone(now: now)
        let legacy = QuotaSnapshot(
            fiveHourRemainingPercent: fiveHourPercent,
            weeklyRemainingPercent: weeklyPercent,
            fiveHourResetsAt: fiveHourResetsAt,
            weeklyResetsAt: weeklyResetsAt,
            source: source,
            updatedAt: now
        )
        snapshot.quota = legacy
        snapshot.providerQuotas[ProviderQuotaSnapshot.codexProviderID] = ProviderQuotaSnapshot(
            source: source,
            updatedAt: now,
            fiveHourRemainingPercent: legacy.fiveHourRemainingPercent,
            weeklyRemainingPercent: legacy.weeklyRemainingPercent,
            sessionRemainingPercent: nil,
            fiveHourResetsAt: legacy.fiveHourResetsAt,
            weeklyResetsAt: legacy.weeklyResetsAt,
            sessionResetsAt: nil
        )
        snapshot.aggregateState = snapshot.computedAggregate(now: now)
        snapshot.updatedAt = now
        try write(snapshot)
        return snapshot
    }

    @discardableResult
    public func updateProviderQuota(
        providerID: String,
        fiveHourPercent: Int? = nil,
        weeklyPercent: Int? = nil,
        sessionPercent: Int? = nil,
        fiveHourResetsAt: Date? = nil,
        weeklyResetsAt: Date? = nil,
        sessionResetsAt: Date? = nil,
        source: String,
        now: Date = Date()
    ) throws -> StateSnapshot {
        var snapshot = read().pruningExpiredDone(now: now)
        let existing = snapshot.providerQuotas[providerID]
        let next = ProviderQuotaSnapshot(
            source: source,
            updatedAt: now,
            fiveHourRemainingPercent: fiveHourPercent ?? existing?.fiveHourRemainingPercent,
            weeklyRemainingPercent: weeklyPercent ?? existing?.weeklyRemainingPercent,
            sessionRemainingPercent: sessionPercent ?? existing?.sessionRemainingPercent,
            fiveHourResetsAt: fiveHourResetsAt ?? existing?.fiveHourResetsAt,
            weeklyResetsAt: weeklyResetsAt ?? existing?.weeklyResetsAt,
            sessionResetsAt: sessionResetsAt ?? existing?.sessionResetsAt
        )
        snapshot.providerQuotas[providerID] = next

        if providerID == ProviderQuotaSnapshot.codexProviderID,
           let fiveHour = next.fiveHourRemainingPercent,
           let weekly = next.weeklyRemainingPercent {
            snapshot.quota = QuotaSnapshot(
                fiveHourRemainingPercent: fiveHour,
                weeklyRemainingPercent: weekly,
                fiveHourResetsAt: next.fiveHourResetsAt,
                weeklyResetsAt: next.weeklyResetsAt,
                source: source,
                updatedAt: now
            )
        }

        snapshot.aggregateState = snapshot.computedAggregate(now: now)
        snapshot.updatedAt = now
        try write(snapshot)
        return snapshot
    }

    public func write(_ snapshot: StateSnapshot) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(snapshot)
        try data.write(to: stateURL, options: [.atomic])
    }
}

public enum CommandParser {
    public static func state(from command: String) throws -> LightState {
        guard let state = LightState(rawValue: command), state != .quit else {
            if command == "quit" { return .quit }
            throw StateStoreError.invalidState(command)
        }
        return state
    }
}
