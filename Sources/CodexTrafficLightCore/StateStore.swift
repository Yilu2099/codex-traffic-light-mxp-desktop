import Foundation

public enum StateStoreError: Error, CustomStringConvertible {
    case invalidInput(String)

    public var description: String {
        switch self {
        case .invalidInput(let value): return value
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
        return (try? decoder.decode(StateSnapshot.self, from: data)) ?? .empty()
    }

    @discardableResult
    public func updateQuota(
        weeklyPercent: Int,
        weeklyResetsAt: Date? = nil,
        source: String,
        now: Date = Date()
    ) throws -> StateSnapshot {
        var snapshot = read()
        snapshot.quota = QuotaSnapshot(
            weeklyRemainingPercent: weeklyPercent,
            weeklyResetsAt: weeklyResetsAt,
            source: source,
            updatedAt: now
        )
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
