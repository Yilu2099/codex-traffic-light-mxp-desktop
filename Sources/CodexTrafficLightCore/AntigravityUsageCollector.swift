import Foundation
import SQLite3

/// Reads Antigravity conversation SQLite databases (`~/.gemini/antigravity-cli/conversations/*.db`)
/// using the exact protobuf token counters that Antigravity / Zouzhe writes locally.
/// Only numeric counters and timestamps are read; conversation text never leaves this Mac.
public struct AntigravityUsageCollector {
    private struct FileCacheEntry: Codable {
        var signature: String
        var rows: [ToolDailyUsage]
    }

    private struct CacheStore: Codable {
        var version: Int
        var files: [String: FileCacheEntry]
    }

    private struct UsageSample {
        var day: String
        var inputTokens: Int
        var cachedInputTokens: Int
        var cacheWriteInputTokens: Int
        var outputTokens: Int
        var totalTokens: Int { inputTokens + cacheWriteInputTokens + outputTokens }
        var keys: [String]
    }

    private static let cacheVersion = 1
    private static let maxTokens = 1_000_000_000_000

    public init() {}

    public func collect(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        days: Int = 365
    ) -> [ToolDailyUsage] {
        let fm = FileManager.default
        let candidateDirs = ["antigravity-cli", "antigravity", "antigravity-ide"].map {
            home.appendingPathComponent(".gemini/\($0)/conversations", isDirectory: true)
        }
        var seenDirs = Set<String>()
        var dbFiles: [URL] = []
        for dir in candidateDirs {
            guard fm.fileExists(atPath: dir.path) else { continue }
            let canonical = dir.resolvingSymlinksInPath().path
            guard seenDirs.insert(canonical).inserted else { continue }
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for item in items where item.pathExtension == "db" {
                dbFiles.append(item)
            }
        }
        guard !dbFiles.isEmpty else { return [] }

        let cacheURL = home.appendingPathComponent(".wanhe-codex-token/antigravity-usage-cache.json")
        let previous = loadCache(cacheURL)
        var nextFiles: [String: FileCacheEntry] = [:]
        var daily: [String: ToolDailyUsage] = [:]
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let cutoffDay = SharedDateFormatters.shared.shanghaiDay.string(from: cutoff)

        for dbURL in dbFiles {
            let key = dbURL.resolvingSymlinksInPath().path
            let sig = fileSignature(dbURL)
            let rows: [ToolDailyUsage]
            if let cached = previous[key], cached.signature == sig {
                rows = cached.rows
            } else {
                rows = queryConversationDB(dbURL: dbURL, now: now, cutoff: cutoff)
            }
            nextFiles[key] = FileCacheEntry(signature: sig, rows: rows)
            for row in rows where row.day >= cutoffDay && row.totalTokens > 0 {
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
        }

        saveCache(CacheStore(version: Self.cacheVersion, files: nextFiles), to: cacheURL)
        return daily.values.filter { $0.totalTokens > 0 }.sorted { $0.day < $1.day }
    }

    public func queryConversationDB(dbURL: URL, now: Date = Date(), cutoff: Date? = nil) -> [ToolDailyUsage] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 150)

        let tables = existingTables(db)
        guard tables.contains("gen_metadata") || tables.contains("steps") else { return [] }

        let fallbackDate = (try? dbURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
        let trajectoryDate = tables.contains("trajectory_metadata_blob") ? readTrajectoryTimestamp(db) : nil
        let effectiveCutoff = cutoff ?? now.addingTimeInterval(-365 * 86_400)
        let sessionID = dbURL.deletingPathExtension().lastPathComponent

        var samples: [UsageSample] = []
        if tables.contains("steps") {
            readMetadataRows(
                db: db,
                sql: "SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL",
                isStep: true,
                sessionID: sessionID,
                trajectoryDate: trajectoryDate,
                fallbackDate: fallbackDate,
                cutoff: effectiveCutoff,
                now: now,
                into: &samples
            )
        }
        if tables.contains("gen_metadata") {
            readMetadataRows(
                db: db,
                sql: "SELECT idx, data FROM gen_metadata WHERE data IS NOT NULL",
                isStep: false,
                sessionID: sessionID,
                trajectoryDate: trajectoryDate,
                fallbackDate: fallbackDate,
                cutoff: effectiveCutoff,
                now: now,
                into: &samples
            )
        }

        // Deduplicate samples sharing any Antigravity response/request key across steps and gen_metadata.
        var byKey: [String: UsageSample] = [:]
        var deduped: [UsageSample] = []
        for sample in samples {
            if let primaryKey = sample.keys.first {
                if let existing = byKey[primaryKey] {
                    if sample.totalTokens > existing.totalTokens {
                        byKey[primaryKey] = sample
                    }
                } else {
                    byKey[primaryKey] = sample
                }
            } else {
                deduped.append(sample)
            }
        }
        deduped.append(contentsOf: byKey.values)

        var daily: [String: ToolDailyUsage] = [:]
        for sample in deduped {
            var sum = daily[sample.day] ?? ToolDailyUsage(
                tool: "antigravity", day: sample.day,
                inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0
            )
            sum.inputTokens += sample.inputTokens
            sum.cachedInputTokens += sample.cachedInputTokens
            sum.cacheWriteInputTokens += sample.cacheWriteInputTokens
            sum.outputTokens += sample.outputTokens
            daily[sample.day] = sum
        }
        return daily.values.filter { $0.totalTokens > 0 }.sorted { $0.day < $1.day }
    }

    private func existingTables(_ db: OpaquePointer) -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) {
                result.insert(String(cString: ptr))
            }
        }
        return result
    }

    private func readTrajectoryTimestamp(_ db: OpaquePointer) -> Date? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM trajectory_metadata_blob LIMIT 1", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let bytes = blobData(stmt: stmt, column: 0),
              let root = ProtobufLite.parse(bytes),
              let tsBytes = root.bytes(for: 2) else { return nil }
        return ProtobufLite.timestamp(tsBytes)
    }

    private func readMetadataRows(
        db: OpaquePointer,
        sql: String,
        isStep: Bool,
        sessionID: String,
        trajectoryDate: Date?,
        fallbackDate: Date,
        cutoff: Date,
        now: Date,
        into samples: inout [UsageSample]
    ) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }

        let maxDate = now.addingTimeInterval(300)
        var rowIndex = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            rowIndex += 1
            guard let bytes = blobData(stmt: stmt, column: 1),
                  let root = ProtobufLite.parse(bytes) else { continue }
            let dataMsg: ProtobufLite
            if isStep {
                dataMsg = root
            } else {
                guard let inner = root.bytes(for: 1), let parsed = ProtobufLite.parse(inner) else { continue }
                dataMsg = parsed
            }

            let rowDate: Date
            if isStep {
                rowDate = dataMsg.bytes(for: 8).flatMap(ProtobufLite.timestamp)
                    ?? dataMsg.bytes(for: 1).flatMap(ProtobufLite.timestamp)
                    ?? trajectoryDate
                    ?? fallbackDate
            } else {
                rowDate = dataMsg.bytes(for: 9)
                    .flatMap(ProtobufLite.parse)
                    .flatMap { $0.bytes(for: 4) }
                    .flatMap(ProtobufLite.timestamp)
                    ?? trajectoryDate
                    ?? fallbackDate
            }
            guard rowDate >= cutoff, rowDate <= maxDate else { continue }

            var usageBlobs: [Data] = []
            if let primary = dataMsg.bytes(for: isStep ? 9 : 4) {
                usageBlobs.append(primary)
            }
            for retryBytes in dataMsg.allBytes(for: isStep ? 28 : 17) {
                if let retryMsg = ProtobufLite.parse(retryBytes), let retryUsage = retryMsg.bytes(for: 2) {
                    usageBlobs.append(retryUsage)
                }
            }

            let day = SharedDateFormatters.shared.shanghaiDay.string(from: rowDate)
            for (uIdx, usageBytes) in usageBlobs.enumerated() {
                guard let usage = ProtobufLite.parse(usageBytes) else { continue }
                let uncached = usage.int(for: 2)
                let cached = usage.int(for: 5)
                let cacheWrite = usage.int(for: 4)
                let output = max(usage.int(for: 3), usage.int(for: 9) + usage.int(for: 10))
                let input = uncached + cached
                guard (0...Self.maxTokens).contains(uncached),
                      (0...Self.maxTokens).contains(cached),
                      (0...Self.maxTokens).contains(cacheWrite),
                      (0...Self.maxTokens).contains(output),
                      input + cacheWrite + output > 0 else { continue }
                let keys = [11, 12, 7].compactMap { fieldNum -> String? in
                    guard let text = usage.string(for: fieldNum), !text.isEmpty else { return nil }
                    return "\(fieldNum):\(text)"
                }
                let dedupeKeys = keys.isEmpty ? ["fallback:\(sessionID):\(isStep ? "s" : "g"):\(rowIndex):\(uIdx)"] : keys
                samples.append(UsageSample(
                    day: day,
                    inputTokens: input,
                    cachedInputTokens: cached,
                    cacheWriteInputTokens: cacheWrite,
                    outputTokens: output,
                    keys: dedupeKeys
                ))
            }
        }
    }

    private func blobData(stmt: OpaquePointer, column: Int32) -> Data? {
        guard let ptr = sqlite3_column_blob(stmt, column) else { return nil }
        let length = Int(sqlite3_column_bytes(stmt, column))
        guard length > 0 else { return nil }
        return Data(bytes: ptr, count: length)
    }

    private func fileSignature(_ dbURL: URL) -> String {
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        return "\(singleFileSignature(dbURL))|\(singleFileSignature(walURL))"
    }

    private func singleFileSignature(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            return "missing"
        }
        let size = values.fileSize ?? 0
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(size):\(mtime)"
    }

    private func loadCache(_ url: URL) -> [String: FileCacheEntry] {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(CacheStore.self, from: data),
              store.version == Self.cacheVersion else { return [:] }
        return store.files
    }

    private func saveCache(_ store: CacheStore, to url: URL) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Minimal, allocation-light wire parser for Antigravity protobuf blobs.
enum ProtobufLiteValue {
    case varint(UInt64)
    case bytes(Data)
}

struct ProtobufLite {
    let fields: [Int: [ProtobufLiteValue]]

    static func parse(_ data: Data) -> ProtobufLite? {
        var offset = 0
        let count = data.count
        var result: [Int: [ProtobufLiteValue]] = [:]

        func readVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while offset < count && shift < 70 {
                let byte = data[data.startIndex + offset]
                offset += 1
                if shift == 63 && byte > 1 { return nil }
                value |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return value }
                shift += 7
            }
            return nil
        }

        while offset < count {
            guard let tag = readVarint() else { return nil }
            let fieldNumber = Int(tag >> 3)
            let wireType = Int(tag & 0x07)
            guard fieldNumber > 0 else { return nil }
            switch wireType {
            case 0:
                guard let v = readVarint() else { return nil }
                result[fieldNumber, default: []].append(.varint(v))
            case 1:
                guard offset + 8 <= count else { return nil }
                offset += 8
            case 5:
                guard offset + 4 <= count else { return nil }
                offset += 4
            case 2:
                guard let lenU64 = readVarint(), lenU64 <= UInt64(count - offset) else { return nil }
                let len = Int(lenU64)
                let start = data.startIndex + offset
                let slice = Data(data[start..<(start + len)])
                offset += len
                result[fieldNumber, default: []].append(.bytes(slice))
            default:
                return nil
            }
        }
        return ProtobufLite(fields: result)
    }

    func int(for field: Int) -> Int {
        guard case .varint(let v)? = fields[field]?.first else { return 0 }
        return v > UInt64(Int.max) ? 0 : Int(v)
    }

    func bytes(for field: Int) -> Data? {
        guard case .bytes(let d)? = fields[field]?.first else { return nil }
        return d
    }

    func allBytes(for field: Int) -> [Data] {
        (fields[field] ?? []).compactMap {
            if case .bytes(let d) = $0 { return d }
            return nil
        }
    }

    func string(for field: Int) -> String? {
        guard let d = bytes(for: field) else { return nil }
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func timestamp(_ data: Data) -> Date? {
        guard let msg = parse(data) else { return nil }
        let seconds = msg.int(for: 1)
        guard seconds > 0 else { return nil }
        let nanos = msg.int(for: 2)
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000.0)
    }
}
