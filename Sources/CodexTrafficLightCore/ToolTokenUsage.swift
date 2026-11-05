import Foundation

public struct ToolDailyUsage: Codable, Equatable, Sendable {
    public var tool: String
    public var day: String
    // Input includes cached reads. Cache writes are additional; output includes reasoning.
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var cacheWriteInputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int { inputTokens + cacheWriteInputTokens + outputTokens }
    private enum CodingKeys: String, CodingKey { case tool, day, inputTokens, cachedInputTokens, cacheWriteInputTokens, outputTokens, totalTokens }
    public init(tool: String, day: String, inputTokens: Int, cachedInputTokens: Int, cacheWriteInputTokens: Int, outputTokens: Int) {
        self.tool = tool; self.day = day; self.inputTokens = inputTokens; self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens; self.outputTokens = outputTokens
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(tool: try c.decode(String.self, forKey: .tool), day: try c.decode(String.self, forKey: .day), inputTokens: try c.decode(Int.self, forKey: .inputTokens), cachedInputTokens: try c.decode(Int.self, forKey: .cachedInputTokens), cacheWriteInputTokens: try c.decode(Int.self, forKey: .cacheWriteInputTokens), outputTokens: try c.decode(Int.self, forKey: .outputTokens))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tool, forKey: .tool); try c.encode(day, forKey: .day)
        try c.encode(inputTokens, forKey: .inputTokens); try c.encode(cachedInputTokens, forKey: .cachedInputTokens)
        try c.encode(cacheWriteInputTokens, forKey: .cacheWriteInputTokens); try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(totalTokens, forKey: .totalTokens)
    }
}

/// Parses only usage metadata. No credentials, conversation text or directory paths are uploaded.
public struct ToolTokenUsageCollector {
    private struct CachedFile: Codable { var signature: String; var records: [String: ToolDailyUsage] }
    public init() {}
    public func collect(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> [ToolDailyUsage] {
        let cache = home.appendingPathComponent(".wanhe-codex-token/tool-usage-cache.json")
        let old = (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode([String: CachedFile].self, from: $0) } ?? [:]
        var next: [String: CachedFile] = [:]
        var records: [String: ToolDailyUsage] = [:]
        let env = ProcessInfo.processInfo.environment
        let roots = [("kimi", URL(fileURLWithPath: env["KIMI_SHARE_DIR"] ?? home.appendingPathComponent(".kimi").path).appendingPathComponent("sessions")),
                     ("kimi", home.appendingPathComponent(".kimi-code/sessions")),
                     ("muse", URL(fileURLWithPath: env["XDG_DATA_HOME"] ?? home.appendingPathComponent(".local/share").path).appendingPathComponent("muse/sessions"))]
        let cutoff = now.addingTimeInterval(-45 * 86400)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        for (tool, root) in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { continue }
            for case let file as URL in files where file.lastPathComponent == (tool == "kimi" ? "wire.jsonl" : "session.jsonl") {
                guard let v = try? file.resourceValues(forKeys: keys), v.isRegularFile == true,
                      (v.contentModificationDate ?? .distantPast) >= cutoff else { continue }
                let signature = "v2:\(v.fileSize ?? 0):\((v.contentModificationDate ?? .distantPast).timeIntervalSince1970)"
                let entry = old[file.path].flatMap { $0.signature == signature ? $0 : nil }
                    ?? CachedFile(signature: signature, records: parse(file: file, tool: tool, cutoff: cutoff, now: now))
                next[file.path] = entry
                for (id, row) in entry.records where row.day >= day(cutoff) {
                    if row.totalTokens > (records[id]?.totalTokens ?? -1) { records[id] = row }
                }
            }
        }
        if let data = try? JSONEncoder().encode(next) {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
        }
        var daily: [String: ToolDailyUsage] = [:]
        for row in records.values {
            let key = row.tool + row.day
            var sum = daily[key] ?? ToolDailyUsage(tool: row.tool, day: row.day, inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0)
            sum.inputTokens += row.inputTokens; sum.cachedInputTokens += row.cachedInputTokens
            sum.cacheWriteInputTokens += row.cacheWriteInputTokens; sum.outputTokens += row.outputTokens
            daily[key] = sum
        }
        let claude = ClaudeTokenUsageCollector().collect(root: URL(fileURLWithPath: env["CLAUDE_CONFIG_DIR"] ?? home.appendingPathComponent(".claude").path).appendingPathComponent("projects"), cacheURL: home.appendingPathComponent(".wanhe-codex-token/claude-usage-cache.json"))
        return (Array(daily.values) + claude.map { ToolDailyUsage(tool: "claude", day: $0.day, inputTokens: $0.inputTokens + $0.cachedInputTokens, cachedInputTokens: $0.cachedInputTokens, cacheWriteInputTokens: $0.cacheWriteInputTokens, outputTokens: $0.outputTokens) }).filter { $0.totalTokens > 0 }.sorted { ($0.day, $0.tool) < ($1.day, $1.tool) }
    }
    private func parse(file: URL, tool: String, cutoff: Date, now: Date) -> [String: ToolDailyUsage] {
        guard let h = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? h.close() }
        var pending = Data(), result: [String: ToolDailyUsage] = [:]
        var lineIndex = 0
        func read(_ line: Data) {
            lineIndex += 1
            guard let text = String(data: line, encoding: .utf8),
                  text.contains(tool == "muse" ? "model_completed" : "usage"),
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            var items = [obj]
            if tool == "muse", let children = obj["children"] as? [[String: Any]] {
                items = children.compactMap { child in (child["record_json"] as? String)?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
            }
            for item in items {
                guard let (id, date, row) = parseRecord(item, tool: tool, fallbackID: file.resolvingSymlinksInPath().path + ":" + String(lineIndex)), date >= cutoff, date <= now else { continue }
                if row.totalTokens > (result[id]?.totalTokens ?? -1) { result[id] = row }
            }
        }
        while let chunk = try? h.read(upToCount: 65536), !chunk.isEmpty {
            pending.append(chunk)
            while let n = pending.firstIndex(of: 10) { read(pending.subdata(in: pending.startIndex..<n)); pending.removeSubrange(pending.startIndex...n) }
        }
        // Do not parse an unfinished tail while the agent is writing it.
        return result
    }
    func parseRecord(_ item: [String: Any], tool: String, fallbackID: String) -> (String, Date, ToolDailyUsage)? {
        func n(_ o: [String: Any], _ k: String) -> Int { min(1_000_000_000_000, max(0, (o[k] as? NSNumber)?.intValue ?? 0)) }
        var usage: [String: Any], date: Date, id = fallbackID
        var input = 0, cached = 0, write = 0, output = 0
        if tool == "muse" {
            guard item["payload_type"] as? String == "runtime.session", let payload = item["payload"] as? [String: Any],
                  let event = payload["event"] as? [String: Any], event["kind"] as? String == "model_completed",
                  let raw = event["usage"] as? [String: Any], let stamp = item["recorded_at"] as? NSNumber else { return nil }
            usage = raw; date = Date(timeIntervalSince1970: stamp.doubleValue / 1_000_000)
            let stream = item["stream"] as? [String: Any]
            id = (item["id"] as? String) ?? ((stream?["id"] as? String).map { $0 + ":" + String(n(item, "sequence")) } ?? fallbackID)
            input = n(usage, "input_tokens"); cached = min(input, max(n(usage, "cache_read_tokens"), n(usage, "cached_tokens")))
            write = n(usage, "cache_write_tokens"); output = n(usage, "output_tokens")
        } else if item["type"] as? String == "usage.record" {
            guard item["usageScope"] as? String == "turn", let raw = item["usage"] as? [String: Any], let time = item["time"] as? NSNumber else { return nil }
            usage = raw; date = Date(timeIntervalSince1970: time.doubleValue / 1000)
            if let agent = item["agentId"] as? String { id = agent + ":" + time.stringValue }
            cached = n(usage, "inputCacheRead"); input = n(usage, "inputOther") + cached
            write = n(usage, "inputCacheCreation"); output = n(usage, "output")
        } else {
            guard let message = item["message"] as? [String: Any], message["type"] as? String == "StatusUpdate",
                  let payload = message["payload"] as? [String: Any], let raw = payload["token_usage"] as? [String: Any], let time = item["timestamp"] as? NSNumber else { return nil }
            usage = raw; date = Date(timeIntervalSince1970: time.doubleValue)
            if let messageID = payload["message_id"] as? String { id = messageID }
            cached = n(usage, "input_cache_read"); input = n(usage, "input_other") + cached
            write = n(usage, "input_cache_creation"); output = n(usage, "output")
        }
        let row = ToolDailyUsage(tool: tool, day: day(date), inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: write, outputTokens: output)
        return row.totalTokens > 0 ? (tool + ":" + id, date, row) : nil
    }
    private func day(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_CA"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
