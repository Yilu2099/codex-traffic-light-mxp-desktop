import Foundation
import CryptoKit

/// Only verified user timestamps leave the machine. Text and paths are never stored in this cache or payload.
public struct ToolHumanActivityCollector {
    private struct Event: Codable { var id: String; var tool: String; var stamp: Date }
    private struct CachedFile: Codable { var signature: String; var events: [Event] }
    public init() {}
    public func collect(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date(), days: Int = 365) -> [TeamSessionInteractionSummary] {
        let fm = FileManager.default
        let cache = home.appendingPathComponent(".wanhe-codex-token/tool-human-cache.json")
        let old = (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder().decode([String: CachedFile].self, from: $0) } ?? [:]
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        var next: [String: CachedFile] = [:], events: [String: Event] = [:]
        for (tool, root, name) in roots(home) {
            guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]) else { continue }
            for case let file as URL in files {
                if ["subagent", "subagents"].contains(file.lastPathComponent) { files.skipDescendants(); continue }
                guard name.isEmpty ? file.pathExtension == "jsonl" : file.lastPathComponent == name,
                      let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]), v.isRegularFile == true,
                      (v.contentModificationDate ?? .distantPast) >= cutoff else { continue }
                let key = digest(file.path), signature = "v1:\(v.fileSize ?? 0):\((v.contentModificationDate ?? .distantPast).timeIntervalSince1970)"
                let entry = old[key].flatMap { $0.signature == signature ? $0 : nil }
                    ?? CachedFile(signature: signature, events: scan(file, tool: tool, cutoff: cutoff, now: now))
                next[key] = entry
                for e in entry.events where e.stamp >= cutoff && e.stamp <= now { events[e.id] = e }
            }
        }
        if let data = try? JSONEncoder().encode(next) {
            try? fm.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
        }
        var groups: [String: (tool: String, day: String, daytime: [Date], night: [Date])] = [:]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let dayFormatter = DateFormatter(); dayFormatter.calendar = calendar; dayFormatter.locale = Locale(identifier: "en_US_POSIX"); dayFormatter.timeZone = calendar.timeZone; dayFormatter.dateFormat = "yyyy-MM-dd"
        for e in events.values {
            let hour = calendar.component(.hour, from: e.stamp)
            let day = dayFormatter.string(from: hour < 5 ? e.stamp.addingTimeInterval(-86400) : e.stamp), key = e.tool + "|" + day
            var g = groups[key] ?? (e.tool, day, [], [])
            if hour >= 5 { g.daytime.append(e.stamp) }
            if hour >= 23 || hour < 5 { g.night.append(e.stamp) }
            groups[key] = g
        }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func unique(_ dates: [Date]) -> [Date] { dates.sorted().reduce(into: []) { result, date in if result.last.map({ date.timeIntervalSince($0) >= 2.5 }) ?? true { result.append(date) } } }
        return groups.values.map { g in
            let d = unique(g.daytime), n = unique(g.night)
            return TeamSessionInteractionSummary(sessionId: "tool:\(g.tool):human-v1", day: g.day,
                firstDayUserAt: d.first.map(iso.string), lastDayUserAt: d.last.map(iso.string), dayTurnCount: d.count,
                lastNightUserAt: n.last.map(iso.string), nightTurnCount: n.count, inputProvenance: "user_submission")
        }.sorted { ($0.day, $0.sessionId) < ($1.day, $1.sessionId) }
    }
    // File changes only accelerate collection; they never establish human activity.
    public func latestLogChange(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Date? {
        var latest: Date?
        for (_, root, name) in roots(home) {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let file as URL in files {
                if ["subagent", "subagents"].contains(file.lastPathComponent) { files.skipDescendants(); continue }
                guard name.isEmpty ? file.pathExtension == "jsonl" : file.lastPathComponent == name,
                      let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                if latest == nil || date > latest! { latest = date }
            }
        }
        return latest
    }
    private func roots(_ home: URL) -> [(String, URL, String)] {
        let env = ProcessInfo.processInfo.environment
        return [("claude", URL(fileURLWithPath: env["CLAUDE_CONFIG_DIR"] ?? home.appendingPathComponent(".claude").path).appendingPathComponent("projects"), ""),
                     ("kimi", URL(fileURLWithPath: env["KIMI_SHARE_DIR"] ?? home.appendingPathComponent(".kimi").path).appendingPathComponent("sessions"), "wire.jsonl"),
                     ("kimi", home.appendingPathComponent(".kimi-code/sessions"), "wire.jsonl"),
                     ("muse", URL(fileURLWithPath: env["XDG_DATA_HOME"] ?? home.appendingPathComponent(".local/share").path).appendingPathComponent("muse/sessions"), "session.jsonl")]
    }
    private func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func scan(_ file: URL, tool: String, cutoff: Date, now: Date) -> [Event] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        var buffer = Data(), events: [Event] = [], discarding = false
        func read(_ line: Data) {
            guard let item = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            let items: [[String: Any]]
            if tool == "muse", let children = item["children"] as? [[String: Any]] {
                items = children.compactMap { ($0["record_json"] as? String)?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
            } else { items = [item] }
            for item in items { if let e = event(item, tool: tool), e.stamp >= cutoff && e.stamp <= now { events.append(e) } }
        }
        while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                if !discarding && end - buffer.startIndex <= 16 * 1024 * 1024 { read(buffer.subdata(in: buffer.startIndex..<end)) }
                buffer.removeSubrange(buffer.startIndex...end); discarding = false
            }
            if buffer.count > 16 * 1024 * 1024 { buffer.removeAll(keepingCapacity: false); discarding = true }
        }
        return events // An unfinished tail is retried when its file changes.
    }
    private func event(_ o: [String: Any], tool: String) -> Event? {
        var stamp: Date?, id: String?
        func object(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
        if tool == "claude" {
            let message = object(o["message"]), origin = object(o["origin"])["kind"] as? String
            let blocks = message["content"] as? [[String: Any]] ?? []
            let text = message["content"] as? String ?? blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard o["type"] as? String == "user", message["role"] as? String == "user",
                  o["isSidechain"] as? Bool != true, o["isMeta"] as? Bool != true, o["isCompactSummary"] as? Bool != true,
                  origin == nil || origin == "human", (o["turnOrigin"] as? String).map({ $0 == "human" }) ?? true,
                  origin == "human" || !( ["sdk", "system"].contains(o["promptSource"] as? String ?? "") ),
                  origin == "human" || o["turnOrigin"] as? String == "human" || o["entrypoint"] as? String == "claude-desktop",
                  !blocks.contains(where: { $0["type"] as? String == "tool_result" }),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || blocks.contains(where: { $0["type"] as? String == "image" }) else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !["<task-notification>", "<local-command-", "<command-message>", "This session is being continued from a previous conversation"].contains(where: { trimmed.hasPrefix($0) }) else { return nil }
            let raw = o["timestamp"] as? String ?? "", iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            stamp = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw); id = o["uuid"] as? String
        } else if tool == "kimi" {
            let input = o["input"] as? [[String: Any]] ?? []
            let text = (o["input"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let hasInput = !text.isEmpty || input.contains { block in
                (block["type"] as? String == "text" && !(block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                || (block["type"] as? String == "image_url" && block["imageUrl"] != nil)
            }
            guard ["turn.prompt", "turn.steer"].contains(o["type"] as? String ?? ""), object(o["origin"])["kind"] as? String == "user",
                  hasInput, let time = o["time"] as? NSNumber else { return nil }
            stamp = Date(timeIntervalSince1970: time.doubleValue / 1000)
            id = o["promptId"] as? String ?? (o["agentId"] as? String).map { $0 + ":" + time.stringValue }
        } else if tool == "muse" {
            let payload = object(o["payload"]), e = object(payload["event"]), stream = object(o["stream"])
            guard o["payload_type"] as? String == "runtime.session", payload["kind"] as? String == "run", stream["kind"] as? String == "session",
                  e["kind"] as? String == "started", let prompt = e["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ["human", "user"].contains(object(e["origin"])["kind"] as? String ?? ""), e["scheduled"] as? Bool != true, e["automated"] as? Bool != true,
                  let time = o["recorded_at"] as? NSNumber else { return nil }
            stamp = Date(timeIntervalSince1970: time.doubleValue / 1_000_000)
            id = o["id"] as? String ?? (stream["id"] as? String).flatMap { session in (o["sequence"] as? NSNumber).map { session + ":" + $0.stringValue } }
        }
        guard let stamp, let id, !id.isEmpty, stamp.timeIntervalSince1970.isFinite else { return nil }
        return Event(id: digest(tool + "|" + id), tool: tool, stamp: stamp)
    }
}
