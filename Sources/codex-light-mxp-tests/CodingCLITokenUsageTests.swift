import Foundation
import CodexTrafficLightCore

func testGeminiAndGrokTokenCollection() throws {
    let now = ISO8601DateFormatter().date(from: "2026-11-12T00:00:00Z")!
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("coding-cli-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }

    func write(_ path: String, _ text: String) throws {
        let file = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    let modelMessage = #"{"type":"gemini","id":"private-message-id","timestamp":"2026-11-10T15:59:59.999Z","tokens":{"input":40,"cached":25,"tool":5,"output":9,"thoughts":6,"total":60},"content":"PRIVATE_ASSISTANT_TEXT"}"#
    let amended = modelMessage.replacingOccurrences(of: #""output":9"#, with: #""output":8"#)
        .replacingOccurrences(of: #""total":60"#, with: #""total":59"#)
    let header = #"{"sessionId":"private-session-id"}"#
    let nextDay = #"{"type":"gemini","id":"second","timestamp":"2026-11-10T16:00:00Z","tokens":{"input":8,"cached":20,"output":2,"total":30}}"#
    let malformed = #"{"type":"gemini","id":"invalid","timestamp":"2026-11-10T16:00:00Z","tokens":{"input":8,"cached":20,"output":2,"total":10}}"#
    let userMessage = #"{"type":"user","id":"user","timestamp":"2026-11-10T16:00:00Z","tokens":{"input":999},"content":"PRIVATE_USER_TEXT"}"#
    try write(".gemini/tmp/project/chats/main.json", #"{"sessionId":"private-session-id","messages":["# + modelMessage + "]}")
    let migrated = [header, modelMessage, #"{"$set":{"messages":["# + amended + "]}}", nextDay, malformed, userMessage].joined(separator: "\n") + "\n"
    try write(".gemini/tmp/project/chats/main.jsonl", migrated)
    try write(".cache/.gemini/tmp/project/chats/copy.jsonl", migrated)
    try write(".gemini/tmp/project/other/main.jsonl", migrated.replacingOccurrences(of: "private-session-id", with: "outside-chat"))

    let grok = #"{"timestamp":1794326399,"params":{"sessionId":"private-grok-session","_meta":{"eventId":"private-event-id","agentTimestampMs":1794326400123},"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":40,"outputTokens":10,"totalTokens":50,"modelUsage":{"grok-one":{"inputTokens":30,"cachedReadTokens":20,"cacheCreationTokens":3,"outputTokens":7,"reasoningTokens":4,"totalTokens":37},"grok-two":{"inputTokens":10,"cachedReadTokens":5,"outputTokens":3,"totalTokens":13}}},"text":"PRIVATE_GROK_TEXT"}}}"#
    let older = #"{"timestamp":1794326399,"params":{"sessionId":"private-grok-session","update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":8,"cachedReadTokens":3,"outputTokens":5,"reasoningTokens":2}}}}"#
    let partial = grok.replacingOccurrences(of: "private-event-id", with: "partial-event")
    let contextOnly = grok.replacingOccurrences(of: "turn_completed", with: "usage_update")
        .replacingOccurrences(of: "private-event-id", with: "context-usage")
    let turns = [grok, older, contextOnly].joined(separator: "\n") + "\n"
    try write(".grok/sessions/project/session/updates.jsonl", turns + partial)
    try write(".grok/sessions/copy/session/updates.jsonl", turns)
    try write(".grok/sessions/project/session/signals.json", #"{"contextTokensUsed":1000000}"#)

    let collector = ToolTokenUsageCollector()
    let rows = collector.collect(home: home, now: now, environment: [:])
    let expected = [
        ToolDailyUsage(tool: "gemini", day: "2026-11-10", inputTokens: 45, cachedInputTokens: 25, cacheWriteInputTokens: 0, outputTokens: 14),
        ToolDailyUsage(tool: "grok", day: "2026-11-10", inputTokens: 8, cachedInputTokens: 3, cacheWriteInputTokens: 0, outputTokens: 5),
        ToolDailyUsage(tool: "gemini", day: "2026-11-11", inputTokens: 28, cachedInputTokens: 20, cacheWriteInputTokens: 0, outputTokens: 2),
        ToolDailyUsage(tool: "grok", day: "2026-11-11", inputTokens: 37, cachedInputTokens: 25, cacheWriteInputTokens: 3, outputTokens: 10),
    ]
    try expectEqual(rows, expected, "Gemini and Grok completed usage reconciles and copied logs count once at UTC+8 midnight")
    try expectEqual(collector.collect(home: home, now: now, environment: [:]), rows, "metadata cache remains idempotent")

    try write("alternate-home/.gemini/tmp/project/chats/older.json",
              #"{"sessionId":"legacy-only","messages":["# + malformed.replacingOccurrences(of: #""input":8"#, with: #""input":"invalid""#)
                + "," + modelMessage + "]}")
    try write("alternate-grok/sessions/project/session/updates.jsonl", older + "\n")
    let overrides = ["GEMINI_CLI_HOME": home.appendingPathComponent("alternate-home").path,
                     "GROK_HOME": home.appendingPathComponent("alternate-grok").path]
    let selected = collector.collect(home: home, now: now, environment: overrides)
    try expectEqual(selected.map(\.totalTokens), [60, 13],
                    "tool home overrides select only configured roots and valid legacy messages")

    let encoded = String(data: try JSONEncoder().encode(rows), encoding: .utf8)!
    let cache = try String(contentsOf: home.appendingPathComponent(".wanhe-codex-token/tool-usage-cache.json"), encoding: .utf8)
    for privateValue in ["PRIVATE_", "private-session-id", "private-message-id", "private-grok-session", "private-event-id", home.path] {
        try expect(!encoded.contains(privateValue) && !cache.contains(privateValue), "text and raw session metadata are omitted")
    }
}
