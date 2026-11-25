import Foundation
import SQLite3

/// Silent local collectors for OpenCode, Qwen Code, Pi, and Cursor desktop/API usage.
/// Also classifies DeepSeek, Zhipu (GLM), and Qwen models into their own tool buckets
/// when used through OpenCode, Qwen Code, Pi, or Cursor.
public struct ExtraToolTokenUsageCollector: Sendable {
    private struct CacheStore: Codable {
        var version: Int
        var files: [String: FileCache]
        var cursorCheckedAt: TimeInterval?
        var cursorRows: [ToolDailyUsage]?
    }
    private struct FileCache: Codable {
        var signature: String
        var rows: [ToolDailyUsage]
    }
    private static let cacheVersion = 1
    private static let maxTokens = 1_000_000_000_000

    public init() {}

    /// Maps model/provider hints to domestic model buckets when applicable.
    public static func classifyTool(model: String?, provider: String?, fallback: String) -> String {
        let hint = "\(provider ?? "") \(model ?? "")".lowercased()
        if hint.contains("deepseek") { return "deepseek" }
        if hint.contains("glm") || hint.contains("zhipu") || hint.contains("bigmodel") || hint.contains("chatglm") { return "zhipu" }
        if hint.contains("qwen") || hint.contains("qwq") || hint.contains("dashscope") { return "qwen" }
        return fallback
    }

    public func collect(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        environment env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ToolDailyUsage] {
        let cacheURL = home.appendingPathComponent(".wanhe-codex-token/extra-tool-usage-cache.json")
        let oldStore = loadCache(cacheURL)
        let oldFiles = oldStore?.files ?? [:]
        var nextFiles: [String: FileCache] = [:]
        var daily: [String: ToolDailyUsage] = [:]

        let cutoff = now.addingTimeInterval(-365 * 86_400)
        let cutoffDay = dayString(cutoff)

        func mergeRows(_ rows: [ToolDailyUsage]) {
            for row in rows where row.day >= cutoffDay && row.totalTokens > 0 {
                let key = "\(row.tool)|\(row.day)"
                var sum = daily[key] ?? ToolDailyUsage(
                    tool: row.tool, day: row.day,
                    inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0
                )
                sum.inputTokens += row.inputTokens
                sum.cachedInputTokens += row.cachedInputTokens
                sum.cacheWriteInputTokens += row.cacheWriteInputTokens
                sum.outputTokens += row.outputTokens
                daily[key] = sum
            }
        }

        // 1. OpenCode (SQLite opencode*.db + legacy storage/message/*.json)
        for root in openCodeRoots(home: home, env: env) {
            let dbFiles = findFiles(in: root, maxDepth: 1) { $0.lastPathComponent.hasPrefix("opencode") && $0.pathExtension == "db" }
            for dbURL in dbFiles {
                let key = "oc-db:\(dbURL.resolvingSymlinksInPath().path)"
                let sig = dbSignature(dbURL)
                if let cached = oldFiles[key], cached.signature == sig {
                    nextFiles[key] = cached
                    mergeRows(cached.rows)
                } else if let rows = parseOpenCodeDB(dbURL, cutoff: cutoff, now: now) {
                    nextFiles[key] = FileCache(signature: sig, rows: rows)
                    mergeRows(rows)
                } else if let cached = oldFiles[key] {
                    nextFiles[key] = cached
                    mergeRows(cached.rows)
                }
            }
            let legacyDir = root.appendingPathComponent("storage/message")
            for jsonURL in findFiles(in: legacyDir, maxDepth: 3, where: { $0.pathExtension == "json" }) {
                let key = "oc-json:\(jsonURL.resolvingSymlinksInPath().path)"
                let sig = singleSignature(jsonURL)
                if let cached = oldFiles[key], cached.signature == sig {
                    nextFiles[key] = cached
                    mergeRows(cached.rows)
                } else {
                    let rows = parseOpenCodeMessageFile(jsonURL, cutoff: cutoff, now: now)
                    nextFiles[key] = FileCache(signature: sig, rows: rows)
                    mergeRows(rows)
                }
            }
        }

        // 2. Qwen Code (~/.qwen/tmp/*/chats/*.json, ~/.qwen/projects/*/chats/*.jsonl, ~/.qwen/sessions/**/*.jsonl)
        let qwenHome = configuredDir(env["QWEN_HOME"], fallback: home.appendingPathComponent(".qwen"))
        let qwenRoots = [
            qwenHome.appendingPathComponent("tmp"),
            qwenHome.appendingPathComponent("projects"),
            qwenHome.appendingPathComponent("sessions"),
        ]
        for root in qwenRoots {
            for file in findFiles(in: root, maxDepth: 4, where: { ["json", "jsonl"].contains($0.pathExtension) }) {
                let key = "qwen:\(file.resolvingSymlinksInPath().path)"
                let sig = singleSignature(file)
                if let cached = oldFiles[key], cached.signature == sig {
                    nextFiles[key] = cached
                    mergeRows(cached.rows)
                } else {
                    let rows = parseQwenFile(file, cutoff: cutoff, now: now)
                    nextFiles[key] = FileCache(signature: sig, rows: rows)
                    mergeRows(rows)
                }
            }
        }

        // 3. Pi (~/.pi/agent/sessions/**/*.jsonl)
        for root in piSessionRoots(home: home, env: env) {
            for file in findFiles(in: root, maxDepth: 4, where: { $0.pathExtension == "jsonl" }) {
                let key = "pi:\(file.resolvingSymlinksInPath().path)"
                let sig = singleSignature(file)
                if let cached = oldFiles[key], cached.signature == sig {
                    nextFiles[key] = cached
                    mergeRows(cached.rows)
                } else {
                    let rows = parsePiFile(file, cutoff: cutoff, now: now)
                    nextFiles[key] = FileCache(signature: sig, rows: rows)
                    mergeRows(rows)
                }
            }
        }

        // 4. Cursor (silent reuse of local desktop state.vscdb token or CURSOR_API_KEY, throttled to 5 min)
        var cursorCheckedAt = oldStore?.cursorCheckedAt
        var cursorRows = oldStore?.cursorRows ?? []
        if cursorCheckedAt == nil || now.timeIntervalSince1970 - (cursorCheckedAt ?? 0) >= 300 {
            if let fresh = fetchCursorUsageSync(home: home, env: env, cutoff: cutoff, now: now) {
                cursorRows = fresh
                cursorCheckedAt = now.timeIntervalSince1970
            } else if cursorCheckedAt == nil {
                cursorCheckedAt = now.timeIntervalSince1970
            }
        }
        mergeRows(cursorRows)

        saveCache(CacheStore(version: Self.cacheVersion, files: nextFiles, cursorCheckedAt: cursorCheckedAt, cursorRows: cursorRows), to: cacheURL)
        return daily.values.filter { $0.totalTokens > 0 }.sorted { ($0.day, $0.tool) < ($1.day, $1.tool) }
    }

    // MARK: - OpenCode

    private func openCodeRoots(home: URL, env: [String: String]) -> [URL] {
        if let custom = env["OPENCODE_DATA_DIR"], !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom.split(separator: ",").map { URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces), isDirectory: true) }
        }
        let xdg = configuredDir(env["XDG_DATA_HOME"], fallback: home.appendingPathComponent(".local/share"))
        return [xdg.appendingPathComponent("opencode")]
    }

    private func parseOpenCodeDB(_ dbURL: URL, cutoff: Date, now: Date) -> [ToolDailyUsage]? {
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let walSize = (try? walURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("wanhe-oc-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tempDir) }
            let dst = tempDir.appendingPathComponent(dbURL.lastPathComponent)
            try fm.copyItem(at: dbURL, to: dst)
            if walSize > 0, fm.fileExists(atPath: walURL.path) {
                try? fm.copyItem(at: walURL, to: URL(fileURLWithPath: dst.path + "-wal"))
            }
            var db: OpaquePointer?
            guard sqlite3_open_v2(dst.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
                if let db { sqlite3_close(db) }
                return nil
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 150)

            var tables = Set<String>()
            var tblStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &tblStmt, nil) == SQLITE_OK, let tblStmt {
                defer { sqlite3_finalize(tblStmt) }
                while sqlite3_step(tblStmt) == SQLITE_ROW {
                    if let p = sqlite3_column_text(tblStmt, 0) { tables.insert(String(cString: p)) }
                }
            }
            var byID: [String: ToolDailyUsage] = [:]
            for table in ["message", "session_message"] where tables.contains(table) {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT id, data FROM \(table) WHERE data IS NOT NULL", -1, &stmt, nil) == SQLITE_OK, let stmt else { continue }
                defer { sqlite3_finalize(stmt) }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let rowID = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    guard let ptr = sqlite3_column_text(stmt, 1) else { continue }
                    let text = String(cString: ptr)
                    guard text.contains("\"tokens\""),
                          let data = text.data(using: .utf8),
                          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          let (id, usage) = parseOpenCodeMessage(obj, fallbackID: "\(table):\(rowID)", cutoff: cutoff, now: now) else { continue }
                    if usage.totalTokens > (byID[id]?.totalTokens ?? -1) { byID[id] = usage }
                }
            }
            return aggregate(Array(byID.values))
        } catch {
            return nil
        }
    }

    private func parseOpenCodeMessageFile(_ url: URL, cutoff: Date, now: Date) -> [ToolDailyUsage] {
        guard let data = try? Data(contentsOf: url), data.count <= 2_097_152,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let (_, usage) = parseOpenCodeMessage(obj, fallbackID: url.lastPathComponent, cutoff: cutoff, now: now) else { return [] }
        return [usage]
    }

    public func parseOpenCodeMessage(_ obj: [String: Any], fallbackID: String, cutoff: Date, now: Date) -> (String, ToolDailyUsage)? {
        if let role = obj["role"] as? String, role != "assistant" { return nil }
        guard let tokens = obj["tokens"] as? [String: Any] else { return nil }
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        let uncached = intVal(tokens["input"])
        let cached = intVal(cache["read"])
        let cacheWrite = intVal(cache["write"])
        let output = intVal(tokens["output"]) + intVal(tokens["reasoning"])
        let input = uncached + cached
        guard input + cacheWrite + output > 0 else { return nil }

        let timeObj = obj["time"] as? [String: Any]
        guard let tsDate = parseDate(timeObj?["created"] ?? obj["createdAt"] ?? obj["timestamp"]),
              tsDate >= cutoff, tsDate <= now.addingTimeInterval(300) else { return nil }

        let modelObj = obj["model"] as? [String: Any]
        let model = (modelObj?["id"] as? String) ?? (modelObj?["modelID"] as? String) ?? (obj["modelID"] as? String)
        let provider = (modelObj?["providerID"] as? String) ?? (obj["providerID"] as? String)
        let tool = Self.classifyTool(model: model, provider: provider, fallback: "opencode")
        let id = (obj["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackID
        return (id, ToolDailyUsage(
            tool: tool, day: dayString(tsDate),
            inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: cacheWrite, outputTokens: output
        ))
    }

    // MARK: - Qwen Code

    private func parseQwenFile(_ url: URL, cutoff: Date, now: Date) -> [ToolDailyUsage] {
        guard let data = try? Data(contentsOf: url), data.count <= 20_000_000 else { return [] }
        var rows: [ToolDailyUsage] = []
        if url.pathExtension == "json" {
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let messages = root["messages"] as? [[String: Any]] else { return [] }
            let fallbackDate = parseDate(root["lastUpdated"] ?? root["startTime"])
            for msg in messages {
                if let row = parseQwenMessage(msg, fallbackDate: fallbackDate, cutoff: cutoff, now: now) {
                    rows.append(row)
                }
            }
        } else {
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            for line in text.split(whereSeparator: \.isNewline) {
                guard line.contains("tokens") || line.contains("usage"),
                      let ld = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: ld)) as? [String: Any] else { continue }
                if let row = parseQwenMessage(obj, fallbackDate: nil, cutoff: cutoff, now: now) {
                    rows.append(row)
                }
            }
        }
        return aggregate(rows)
    }

    private func parseQwenMessage(_ obj: [String: Any], fallbackDate: Date?, cutoff: Date, now: Date) -> ToolDailyUsage? {
        if let type = obj["type"] as? String, type == "user" { return nil }
        if let role = obj["role"] as? String, role == "user" { return nil }
        let usage = (obj["tokens"] as? [String: Any])
            ?? (obj["usage"] as? [String: Any])
            ?? ((obj["usageMetadata"] as? [String: Any]))
        guard let usage else { return nil }
        let rawInput = intVal(usage["input"] ?? usage["promptTokenCount"] ?? usage["input_tokens"])
        let cached = intVal(usage["cached"] ?? usage["cachedContentTokenCount"] ?? usage["cache_read_input_tokens"])
        let cacheWrite = intVal(usage["cacheWrite"] ?? usage["cache_creation_input_tokens"])
        let output = intVal(usage["output"] ?? usage["candidatesTokenCount"] ?? usage["output_tokens"])
            + intVal(usage["thoughts"] ?? usage["thoughtsTokenCount"] ?? usage["reasoning"])
        let input = max(rawInput, cached)
        guard input + cacheWrite + output > 0 else { return nil }
        guard let date = parseDate(obj["timestamp"] ?? obj["createdAt"]) ?? fallbackDate,
              date >= cutoff, date <= now.addingTimeInterval(300) else { return nil }
        let model = (obj["model"] as? String) ?? (obj["modelID"] as? String)
        let provider = obj["provider"] as? String
        let tool = Self.classifyTool(model: model, provider: provider, fallback: "qwen")
        return ToolDailyUsage(
            tool: tool, day: dayString(date),
            inputTokens: input, cachedInputTokens: min(cached, input), cacheWriteInputTokens: cacheWrite, outputTokens: output
        )
    }

    // MARK: - Pi

    private func piSessionRoots(home: URL, env: [String: String]) -> [URL] {
        if let dir = env["PI_CODING_AGENT_SESSION_DIR"], !dir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [URL(fileURLWithPath: dir, isDirectory: true)]
        }
        if let base = env["PI_CODING_AGENT_DIR"], !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("sessions")]
        }
        return [home.appendingPathComponent(".pi/agent/sessions")]
    }

    private func parsePiFile(_ url: URL, cutoff: Date, now: Date) -> [ToolDailyUsage] {
        guard let data = try? Data(contentsOf: url), data.count <= 20_000_000,
              let text = String(data: data, encoding: .utf8) else { return [] }
        var rows: [ToolDailyUsage] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.contains("\"usage\""),
                  let ld = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: ld)) as? [String: Any],
                  let row = parsePiEntry(obj, cutoff: cutoff, now: now) else { continue }
            rows.append(row)
        }
        return aggregate(rows)
    }

    public func parsePiEntry(_ obj: [String: Any], cutoff: Date, now: Date) -> ToolDailyUsage? {
        guard let type = obj["type"] as? String,
              ["message", "usage", "compaction", "branch_summary"].contains(type),
              let date = parseDate(obj["timestamp"]),
              date >= cutoff, date <= now.addingTimeInterval(300) else { return nil }
        let source = (type == "message" ? (obj["message"] as? [String: Any]) : obj) ?? [:]
        guard let usage = source["usage"] as? [String: Any] else { return nil }
        let uncached = intVal(usage["input"])
        let cached = intVal(usage["cacheRead"])
        let cacheWrite = intVal(usage["cacheWrite"])
        let output = intVal(usage["output"]) + intVal(usage["reasoning"])
        let input = uncached + cached
        guard input + cacheWrite + output > 0 else { return nil }
        let model = (source["responseModel"] as? String) ?? (source["model"] as? String)
        let provider = source["provider"] as? String
        let tool = Self.classifyTool(model: model, provider: provider, fallback: "pi")
        return ToolDailyUsage(
            tool: tool, day: dayString(date),
            inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: cacheWrite, outputTokens: output
        )
    }

    // MARK: - Cursor (silent local desktop credential reuse)

    private func readCursorAccessToken(home: URL, env: [String: String]) -> String? {
        if let key = env["CURSOR_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        let dbURL = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let ptr = sqlite3_column_text(stmt, 0) else { return nil }
        let token = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func fetchCursorUsageSync(home: URL, env: [String: String], cutoff: Date, now: Date) -> [ToolDailyUsage]? {
        guard let token = readCursorAccessToken(home: home, env: env),
              let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetFilteredUsageEvents") else { return nil }
        let startMs = Int64(max(cutoff.timeIntervalSince1970, now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970) * 1000)
        let endMs = Int64(now.timeIntervalSince1970 * 1000)
        let payload: [String: Any] = ["startDate": String(startMs), "endDate": String(endMs), "page": 1, "pageSize": 500]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let sema = DispatchSemaphore(value: 0)
        var fetchedData: Data?
        session.dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { fetchedData = data }
            sema.signal()
        }.resume()
        _ = sema.wait(timeout: .now() + 8)
        guard let data = fetchedData,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let events = root["usageEventsDisplay"] as? [[String: Any]] else { return nil }

        var rows: [ToolDailyUsage] = []
        for ev in events {
            guard let tu = ev["tokenUsage"] as? [String: Any],
                  let date = parseDate(ev["timestamp"]),
                  date >= cutoff, date <= now.addingTimeInterval(300) else { continue }
            let uncached = intVal(tu["inputTokens"])
            let cached = intVal(tu["cacheReadTokens"])
            let cacheWrite = intVal(tu["cacheWriteTokens"])
            let output = intVal(tu["outputTokens"])
            let input = uncached + cached
            guard input + cacheWrite + output > 0 else { continue }
            let tool = Self.classifyTool(model: ev["model"] as? String, provider: nil, fallback: "cursor")
            rows.append(ToolDailyUsage(
                tool: tool, day: dayString(date),
                inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: cacheWrite, outputTokens: output
            ))
        }
        return aggregate(rows)
    }

    // MARK: - Helpers

    private func aggregate(_ rows: [ToolDailyUsage]) -> [ToolDailyUsage] {
        var map: [String: ToolDailyUsage] = [:]
        for row in rows where row.totalTokens > 0 {
            let key = "\(row.tool)|\(row.day)"
            var sum = map[key] ?? ToolDailyUsage(
                tool: row.tool, day: row.day,
                inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0
            )
            sum.inputTokens += row.inputTokens
            sum.cachedInputTokens += row.cachedInputTokens
            sum.cacheWriteInputTokens += row.cacheWriteInputTokens
            sum.outputTokens += row.outputTokens
            map[key] = sum
        }
        return Array(map.values)
    }

    private func intVal(_ raw: Any?) -> Int {
        let v: Int
        if let n = raw as? NSNumber { v = n.intValue }
        else if let s = raw as? String, let parsed = Int(s) { v = parsed }
        else { return 0 }
        return min(Self.maxTokens, max(0, v))
    }

    private func parseDate(_ raw: Any?) -> Date? {
        if let n = raw as? NSNumber {
            let v = n.doubleValue
            guard v.isFinite, v > 1_577_836_800 else { return nil }
            return Date(timeIntervalSince1970: v > 10_000_000_000 ? v / 1000.0 : v)
        }
        if let s = raw as? String {
            if let num = Double(s), num.isFinite, num > 1_577_836_800 {
                return Date(timeIntervalSince1970: num > 10_000_000_000 ? num / 1000.0 : num)
            }
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f1.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return nil
    }

    private func dayString(_ date: Date) -> String {
        SharedDateFormatters.shared.shanghaiDay.string(from: date)
    }

    private func configuredDir(_ raw: String?, fallback: URL) -> URL {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    private func findFiles(in root: URL, maxDepth: Int, where predicate: (URL) -> Bool) -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let baseDepth = root.pathComponents.count
        var result: [URL] = []
        for case let url as URL in enumerator {
            if url.pathComponents.count - baseDepth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard let vals = try? url.resourceValues(forKeys: Set(keys)),
                  vals.isRegularFile == true, vals.isSymbolicLink != true,
                  predicate(url) else { continue }
            result.append(url)
        }
        return result
    }

    private func dbSignature(_ dbURL: URL) -> String {
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        return "\(singleSignature(dbURL))|\(singleSignature(walURL))"
    }

    private func singleSignature(_ url: URL) -> String {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return "missing" }
        return "\(v.fileSize ?? 0):\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    private func loadCache(_ url: URL) -> CacheStore? {
        guard let data = try? Data(contentsOf: url),
              let store = try? JSONDecoder().decode(CacheStore.self, from: data),
              store.version == Self.cacheVersion else { return nil }
        return store
    }

    private func saveCache(_ store: CacheStore, to url: URL) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
