import Foundation

public struct ClaudeDailyTokens: Codable, Equatable, Sendable {
    public var day: String
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var cacheWriteInputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
}

/// Reads usage metadata only. Conversation text and project paths never leave this Mac.
public struct ClaudeTokenUsageCollector {
    private struct Message: Codable {
        var day: String
        var input: Int
        var cached: Int
        var written: Int
        var output: Int
        var total: Int { input + cached + written + output }
    }

    private struct CachedFile: Codable {
        var signature: String
        var messages: [String: Message]
    }

    public init() {}

    public func collect(
        root: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
            .appendingPathComponent("projects"),
        days: Int = 45,
        cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wanhe-codex-token/claude-usage-cache.json")
    ) -> [ClaudeDailyTokens] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let old = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: CachedFile].self, from: $0) } ?? [:]
        let earliestDay = dayString(cutoff)
        var next: [String: CachedFile] = [:]
        var messages: [String: Message] = [:]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]) else { return [] }
        for case let file as URL in files where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.contentModificationDate ?? .distantPast) >= cutoff else { continue }
            let signature = "\(values.fileSize ?? 0):\((values.contentModificationDate ?? .distantPast).timeIntervalSince1970)"
            let entry = old[file.path].flatMap { $0.signature == signature ? $0 : nil }
                ?? CachedFile(signature: signature, messages: parse(file: file, cutoff: cutoff))
            next[file.path] = entry
            for (id, message) in entry.messages where message.day >= earliestDay {
                if message.total > (messages[id]?.total ?? -1) { messages[id] = message }
            }
        }
        if let data = try? JSONEncoder().encode(next) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: [.atomic])
        }
        var daily: [String: ClaudeDailyTokens] = [:]
        for message in messages.values {
            var row = daily[message.day] ?? ClaudeDailyTokens(day: message.day, inputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 0, totalTokens: 0)
            row.inputTokens += message.input
            row.cachedInputTokens += message.cached
            row.cacheWriteInputTokens += message.written
            row.outputTokens += message.output
            row.totalTokens += message.total
            daily[message.day] = row
        }
        return daily.values.sorted { $0.day < $1.day }
    }

    private func parse(file: URL, cutoff: Date) -> [String: Message] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [:] }
        defer { try? handle.close() }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_CA")
        dayFormatter.timeZone = TimeZone(identifier: "Asia/Hong_Kong")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        var result: [String: Message] = [:]
        var pending = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                readLine(pending.subdata(in: pending.startIndex..<newline), cutoff: cutoff, iso: iso, dayFormatter: dayFormatter, into: &result)
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty { readLine(pending, cutoff: cutoff, iso: iso, dayFormatter: dayFormatter, into: &result) }
        return result
    }

    private func readLine(_ line: Data, cutoff: Date, iso: ISO8601DateFormatter, dayFormatter: DateFormatter, into result: inout [String: Message]) {
        guard let text = String(data: line, encoding: .utf8), text.contains("\"usage\""),
              let item = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              item["type"] as? String == "assistant",
              let raw = item["message"] as? [String: Any],
              let id = raw["id"] as? String, !id.isEmpty,
              let usage = raw["usage"] as? [String: Any],
              let stamp = item["timestamp"] as? String,
              let date = iso.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp),
              date >= cutoff else { return }
        func count(_ key: String) -> Int { max(0, (usage[key] as? NSNumber)?.intValue ?? 0) }
        let message = Message(day: dayFormatter.string(from: date), input: count("input_tokens"), cached: count("cache_read_input_tokens"), written: count("cache_creation_input_tokens"), output: count("output_tokens"))
        if message.total > (result[id]?.total ?? -1) { result[id] = message }
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_CA")
        formatter.timeZone = TimeZone(identifier: "Asia/Hong_Kong")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

}
