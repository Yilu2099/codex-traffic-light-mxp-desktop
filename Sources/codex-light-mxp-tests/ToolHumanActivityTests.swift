import Foundation
import CodexTrafficLightCore

func testToolHumanActivityProvenanceAndBoundaries() throws {
    let fixtureURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("test-fixtures/tool-human-events.json")
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
    let now = ISO8601DateFormatter().date(from: fixture["now"] as! String)!
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("tool-human-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    for (tool, path) in [("claude", ".claude/projects/a/log.jsonl"), ("kimi", ".kimi-code/sessions/a/wire.jsonl"), ("muse", ".local/share/muse/sessions/a/session.jsonl")] {
        let rows = (fixture["rows"] as! [[String: Any]]).filter { $0["tool"] as? String == tool }
        let text = try rows.map { String(data: try JSONSerialization.data(withJSONObject: $0["item"]!), encoding: .utf8)! }.joined(separator: "\n") + "\n"
        for suffix in ["", ".copy"] {
            let file = home.appendingPathComponent(path.replacingOccurrences(of: "/a/", with: "/a\(suffix)/"))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (text + "{\"incomplete\":").write(to: file, atomically: true, encoding: .utf8)
        }
    }
    let collector = ToolHumanActivityCollector(), rows = collector.collect(home: home, now: now)
    try expectEqual(rows.count, 5, "automation and future rows do not create extra days")
    try expect(rows.contains { $0.day == "2026-07-01" }, "retained history older than thirty days is backfilled")
    let claude = rows.first { $0.sessionId.contains("claude") && $0.day == "2026-11-05" }!
    try expectEqual(claude.dayTurnCount, 2, "copied logs, tools, SDK and notifications do not add human turns")
    try expectEqual(claude.firstDayUserAt, "2026-11-05T00:30:00.000Z", "start comes from the earliest verified user")
    try expectEqual(claude.lastDayUserAt, "2026-11-05T01:00:00.000Z", "finish comes from a later verified user")
    try expectEqual(rows.first { $0.sessionId.contains("muse") }?.nightTurnCount, 1, "retained frames count once and unproven Muse sources stay excluded")
    try expectEqual(rows.first { $0.day == "2026-11-05" && $0.sessionId.contains("kimi") }?.lastNightUserAt, "2026-11-05T20:59:00.000Z", "04:59 remains in the previous workday")
    try expectEqual(rows.first { $0.day == "2026-11-06" }?.firstDayUserAt, "2026-11-05T21:00:00.000Z", "05:00 opens the new workday")
    try expectEqual(collector.collect(home: home, now: now), rows, "cached replays are idempotent")
    let cached = try String(contentsOf: home.appendingPathComponent(".wanhe-codex-token/tool-human-cache.json"), encoding: .utf8)
    let encoded = String(data: try JSONEncoder().encode(rows), encoding: .utf8)!
    for secret in ["PRIVATE_MESSAGE", "private-human-id", "private-prompt", home.path] {
        try expect(!cached.contains(secret) && !encoded.contains(secret), "private text, IDs and paths stay out of metadata")
    }
}
