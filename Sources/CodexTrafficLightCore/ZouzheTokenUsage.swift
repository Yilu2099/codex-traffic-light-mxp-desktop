import Foundation
import SQLite3

/// Reads completed Antigravity turn token usage from Zouzhe's local SQLite state.
/// Only usage counters and timestamps are read; conversation text never leaves this Mac.
public struct ZouzheTokenUsageCollector {
    private struct CacheEntry: Codable {
        var signature: String
        var rows: [ToolDailyUsage]
    }

    private struct TurnPayload: Decodable {
        struct TurnTokenUsage: Decodable {
            let usageStatus: String?
            let inputTokens: Int?
            let cachedInputTokens: Int?
            let cacheCreationTokens: Int?
            let outputTokens: Int?
        }

        let turnTokenUsage: TurnTokenUsage?
    }

    private static let maxTokens = 1_000_000_000_000

    public init() {}

    public func collect(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        days: Int = 365
    ) -> [ToolDailyUsage] {
        let dbURL = home.appendingPathComponent(".zouzhe-t3/userdata/statev2.sqlite")
        let walURL = home.appendingPathComponent(".zouzhe-t3/userdata/statev2.sqlite-wal")
        let cacheURL = home.appendingPathComponent(".wanhe-codex-token/zouzhe-usage-cache.json")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return [] }

        let signature = "v1:\(days):\(fileSignature(dbURL)):\(fileSignature(walURL))"
        if let cached = loadCache(cacheURL), cached.signature == signature {
            return cached.rows
        }

        let rows = queryCompletedAntigravity(dbURL: dbURL, now: now, days: days)
        saveCache(CacheEntry(signature: signature, rows: rows), to: cacheURL)
        return rows
    }

    public func queryCompletedAntigravity(dbURL: URL, now: Date = Date(), days: Int = 365) -> [ToolDailyUsage] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        let sql = """
            SELECT provider_turn_id, completed_at, started_at, payload_json
            FROM orchestration_v2_projection_provider_turns
            WHERE provider_turn_id LIKE '%antigravity%' AND status = 'completed'
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }

        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let decoder = JSONDecoder()
        var byTurn: [String: ToolDailyUsage] = [:]

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let turnPtr = sqlite3_column_text(stmt, 0),
                  let payloadPtr = sqlite3_column_text(stmt, 3) else { continue }
            let turnID = String(cString: turnPtr)
            let completedAt = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let startedAt = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            guard let stamp = completedAt ?? startedAt,
                  let date = SharedDateFormatters.shared.iso8601Date(from: stamp),
                  date >= cutoff, date <= now.addingTimeInterval(300) else { continue }

            let payloadData = Data(String(cString: payloadPtr).utf8)
            guard let parsed = try? decoder.decode(TurnPayload.self, from: payloadData),
                  let usage = parsed.turnTokenUsage,
                  usage.usageStatus == "complete" else { continue }

            let input = usage.inputTokens ?? 0
            let cached = min(input, max(0, usage.cachedInputTokens ?? 0))
            let cacheWrite = usage.cacheCreationTokens ?? 0
            let output = usage.outputTokens ?? 0
            guard (0...Self.maxTokens).contains(input),
                  (0...Self.maxTokens).contains(cached),
                  (0...Self.maxTokens).contains(cacheWrite),
                  (0...Self.maxTokens).contains(output),
                  input + cacheWrite + output > 0 else { continue }

            let day = SharedDateFormatters.shared.shanghaiDay.string(from: date)
            let row = ToolDailyUsage(
                tool: "antigravity",
                day: day,
                inputTokens: input,
                cachedInputTokens: cached,
                cacheWriteInputTokens: cacheWrite,
                outputTokens: output
            )
            if row.totalTokens > (byTurn[turnID]?.totalTokens ?? -1) {
                byTurn[turnID] = row
            }
        }

        var daily: [String: ToolDailyUsage] = [:]
        for row in byTurn.values {
            var sum = daily[row.day] ?? ToolDailyUsage(
                tool: "antigravity", day: row.day,
                inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0
            )
            sum.inputTokens += row.inputTokens
            sum.cachedInputTokens += row.cachedInputTokens
            sum.cacheWriteInputTokens += row.cacheWriteInputTokens
            sum.outputTokens += row.outputTokens
            daily[row.day] = sum
        }
        return daily.values.filter { $0.totalTokens > 0 }.sorted { $0.day < $1.day }
    }

    private func fileSignature(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return "0:0" }
        return "\(values.fileSize ?? 0):\((values.contentModificationDate ?? .distantPast).timeIntervalSince1970)"
    }

    private func loadCache(_ url: URL) -> CacheEntry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CacheEntry.self, from: data)
    }

    private func saveCache(_ entry: CacheEntry, to url: URL) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}
