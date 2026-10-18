import Foundation
import Darwin

/// Desktop helper requests have raw usage but no verified account/billing attribution.
/// Preserve them as pending evidence; they never change the normal token counters.
public enum DesktopAuxiliaryTokenAudit {
    public static func record(_ line: String, now: Date = Date()) -> TokenCollectionAudit.Record? {
        guard line.contains("[ephemeral-generation] ephemeral_generation_token_usage "),
              let stamp = line.split(separator: " ").first.map(String.init),
              let date = SharedDateFormatters.shared.iso8601Fractional.date(from: stamp),
              date <= now, date >= now.addingTimeInterval(-7 * 86400) else { return nil }
        var values: [String: Int] = [:]
        for (raw, field) in [("inputTokens", "input"), ("cachedInputTokens", "cached"), ("outputTokens", "output"), ("reasoningOutputTokens", "reasoning"), ("totalTokens", "pending")] {
            guard let range = line.range(of: "\\b\(raw)=([0-9]+)\\b", options: .regularExpression),
                  let n = Int(line[range].split(separator: "=").last!), n <= 9_007_199_254_740_991 else { return nil }
            values[field] = n
        }
        guard values["pending"]! > 0, values["input"]! + values["output"]! == values["pending"]!,
              values["cached"]! <= values["input"]!, values["reasoning"]! <= values["output"]! else { return nil }
        let features = ["ambient_suggestions", "ambient_suggestion_safety", "thread_title", "thread_description"]
        let feature = features.first { line.contains("feature=\($0) ") } ?? "other"
        var r = TokenCollectionAudit.Record(source: "desktop_auxiliary", kind: "pending", reason: "unsupported_source",
            key: TokenCollectionAudit.hash("desktop_auxiliary|" + feature), eventAt: stamp, values: values, now: now)
        r.eventKey = TokenCollectionAudit.hash("desktop_auxiliary|" + line)
        return r
    }

    public static func collect(logRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/com.openai.codex"),
                               audit: TokenCollectionAudit = TokenCollectionAudit(), now: Date = Date()) {
        let fm = FileManager.default, cursor = audit.root.appendingPathComponent("desktop-auxiliary-offsets.json")
        do {
            try fm.createDirectory(at: audit.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = open(cursor.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }; defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { return }; defer { flock(fd, LOCK_UN) }
            var offsets = (try? Data(contentsOf: cursor)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
            guard let files = fm.enumerator(at: logRoot, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])?.allObjects as? [URL] else { return }
            var processed = 0, records: [TokenCollectionAudit.Record] = [], keep = Set<String>()
            for file in files.sorted(by: { $0.path > $1.path }) where file.pathExtension == "log" {
                let meta = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard (meta.contentModificationDate ?? .distantPast) >= now.addingTimeInterval(-8 * 86400) else { continue }
                let key = TokenCollectionAudit.hash(file.path); keep.insert(key)
                guard processed < 8 else { continue }
                let size = meta.fileSize ?? 0, prior = offsets[key] ?? 0, start = prior <= size ? prior : 0
                guard start < size else { continue }
                do {
                    let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
                    try h.seek(toOffset: UInt64(start))
                    let data = try h.read(upToCount: 4 * 1024 * 1024) ?? Data()
                    guard let end = data.lastIndex(of: 10) else { continue }
                    for line in data.prefix(through: end).split(separator: 10) {
                        if let r = record(String(decoding: line, as: UTF8.self), now: now) { records.append(r) }
                    }
                    offsets[key] = start + end + 1; processed += 1
                } catch { records.append(.init(source: "desktop_auxiliary", kind: "failure", reason: "read_failed", key: key, now: now)) }
            }
            guard audit.append(records, now: now) else { return }
            offsets = offsets.filter { keep.contains($0.key) }
            try JSONEncoder().encode(offsets).write(to: cursor, options: .atomic)
        } catch { audit.append([.init(source: "desktop_auxiliary", kind: "failure", reason: "state_write_failed", now: now)], now: now) }
    }
}
