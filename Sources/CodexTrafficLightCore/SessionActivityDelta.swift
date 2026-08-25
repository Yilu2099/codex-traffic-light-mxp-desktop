import Foundation

public struct TeamSessionActivityDeltaPlan: Sendable, Equatable {
    public var mode: String
    public var cutoffDay: String
    public var localDay: String
    public var activities: [TeamSessionActivity]
}

/// Tracks only server-acknowledged session metadata. Failed uploads therefore
/// remain eligible for the next delta instead of being lost behind a local
/// cursor advance.
public struct TeamSessionActivityDeltaStore: Sendable {
    private struct State: Codable, Equatable {
        var version: Int
        var lastFullDay: String?
        var acknowledged: [String: TeamSessionActivity]
    }

    private let stateURL: URL
    private let timeZone: TimeZone

    public init(
        stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wanhe-codex-token/session-activity-sync.json"),
        timeZone: TimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    ) {
        self.stateURL = stateURL
        self.timeZone = timeZone
    }

    public func prepare(
        current: [TeamSessionActivity],
        days: Int,
        now: Date = Date(),
        forceFull: Bool = false
    ) -> TeamSessionActivityDeltaPlan {
        let state = loadState() ?? State(version: 1, lastFullDay: nil, acknowledged: [:])
        let currentByID = Dictionary(current.map { ($0.sessionId, $0) }, uniquingKeysWith: newer)
        let localDay = dayString(now)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let cutoffDay = dayString(
            calendar.date(byAdding: .day, value: -max(1, days), to: now)
                ?? now.addingTimeInterval(-Double(max(1, days)) * 86_400)
        )
        let needsFull = forceFull || state.lastFullDay != localDay
        let activities: [TeamSessionActivity]
        if needsFull {
            activities = Array(currentByID.values)
        } else {
            activities = currentByID.compactMap { id, value in
                state.acknowledged[id] == value ? nil : value
            }
        }
        return TeamSessionActivityDeltaPlan(
            mode: needsFull ? "full" : "delta_v1",
            cutoffDay: cutoffDay,
            localDay: localDay,
            activities: activities.sorted { ($0.day, $0.sessionId) < ($1.day, $1.sessionId) }
        )
    }

    public func acknowledge(_ plan: TeamSessionActivityDeltaPlan) {
        let original = loadState() ?? State(version: 1, lastFullDay: nil, acknowledged: [:])
        var state = original
        if plan.mode == "full" {
            state.acknowledged = Dictionary(
                plan.activities.map { ($0.sessionId, $0) },
                uniquingKeysWith: newer
            )
            state.lastFullDay = plan.localDay
        } else {
            for activity in plan.activities {
                state.acknowledged[activity.sessionId] = newer(
                    state.acknowledged[activity.sessionId] ?? activity,
                    activity
                )
            }
        }
        state.acknowledged = state.acknowledged.filter { $0.value.day >= plan.cutoffDay }
        if state != original { saveState(state) }
    }

    private func newer(_ left: TeamSessionActivity, _ right: TeamSessionActivity) -> TeamSessionActivity {
        (left.updatedAt ?? left.startedAt ?? "") >= (right.updatedAt ?? right.startedAt ?? "") ? left : right
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_CA")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func saveState(_ state: State) {
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: [.atomic])
    }
}
