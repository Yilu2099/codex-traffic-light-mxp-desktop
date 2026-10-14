import Foundation
import CodexTrafficLightCore

private func nativeFixtureLine(_ type: String, _ payload: [String: Any], at: String = "2026-10-14T17:00:00Z") throws -> Data {
    var value = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": at, "payload": payload])
    value.append(10); return value
}
private func nativeStart(_ trigger: String) throws -> Data {
    try nativeFixtureLine("event_msg", ["type": "task_started", "turn_id": "fixture-turn", "turn_attribution": ["turn_trigger": trigger]])
}
private func nativeMessage(_ id: String, at: String, text: String = "fixture input") throws -> Data {
    try nativeFixtureLine("response_item", ["type": "message", "role": "user", "id": id, "content": [["type": "input_text", "text": text]]], at: at)
}
private func nativeFixtureHome() throws -> (URL, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-v3-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("codex/sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    return (root, sessions.appendingPathComponent("rollout-fixture.jsonl"), root.appendingPathComponent("grind.json"))
}
private func nativeRoot() throws -> Data {
    try nativeFixtureLine("session_meta", ["source": "vscode", "id": "fixture-session"])
}
private func nativeAppend(_ value: Data, to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
    try handle.seekToEnd(); try handle.write(contentsOf: value)
}

func testNativeWorkdayProvenanceSeparatesUnknownAndAutomation() throws {
    let (root, file, _) = try nativeFixtureHome(); defer { try? FileManager.default.removeItem(at: root) }
    var rows = try nativeRoot()
    rows.append(try nativeMessage("unknown", at: "2026-10-14T16:00:00Z"))
    rows.append(try nativeStart("composer"))
    rows.append(try nativeMessage("human", at: "2026-10-14T17:00:00Z"))
    rows.append(try nativeMessage("page", at: "2026-10-14T20:59:00Z", text: "<external_codex_apps_open_page>{\"page_id\":null}</external_codex_apps_open_page>"))
    rows.append(try nativeStart("goal"))
    rows.append(try nativeMessage("automatic", at: "2026-10-14T20:58:00Z"))
    rows.append(try nativeMessage("steer", at: "2026-10-14T20:58:30Z"))
    try rows.write(to: file)
    let report = CodexGrindHistoryCollector().collectDetailed(codexHome: root.appendingPathComponent("codex"), now: DotInputCollector.parse("2026-10-14T20:59:30Z")!)
    try expect(report.coverageComplete, "complete full scan provides authoritative correction coverage")
    try expectEqual(report.sessions.count, 1, "only composer message belongs to confirmed sessions")
    try expectEqual(report.sessions.first?.lastNightUserAt, "2026-10-14T17:00:00.000Z", "automatic or synthetic page cannot extend finish")
    try expectEqual(report.sessions.first?.inputProvenance, "user_submission", "confirmed source remains explicit")
    try expectEqual(report.legacyUnknownSessions.first?.nightTurnCount, 2, "old unknown and unproven steering stay separate")
    try expectEqual(report.legacyUnknownSessions.first?.inputProvenance, "legacy_unknown", "unknown cannot be uploaded as confirmed")
    var subagent = try nativeFixtureLine("session_meta", ["source": ["subagent": ["thread_spawn": ["depth": 1]]]])
    subagent.append(try nativeRoot()) // Forked context repeats parent metadata after the subagent header.
    subagent.append(try nativeStart("composer")); subagent.append(try nativeMessage("copied", at: "2026-10-14T20:59:00Z"))
    try subagent.write(to: file)
    let isolated = CodexGrindHistoryCollector().collectDetailed(codexHome: root.appendingPathComponent("codex"), now: DotInputCollector.parse("2026-10-14T20:59:30Z")!)
    try expect(isolated.sessions.isEmpty && isolated.legacyUnknownSessions.isEmpty, "parent session metadata inside a subagent cannot reset the exclusion boundary")
}

func testNativeWorkdayMigrationOutboxAndCursorAttribution() throws {
    let (root, file, state) = try nativeFixtureHome(); defer { try? FileManager.default.removeItem(at: root) }
    var rows = try nativeRoot(); rows.append(try nativeStart("composer")); rows.append(try nativeMessage("human", at: "2026-10-14T17:00:00Z")); rows.append(try nativeStart("goal"))
    try rows.write(to: file)
    let stale: [String: Any] = ["initialized": true, "updatedAt": "2026-10-14T20:59:00Z", "fileOffsets": [file.lastPathComponent: rows.count], "collectionVersion": 2,
        "pendingHistory": [["grindDay": "2026-10-14", "nightGrindTime": "04:59"]]]
    try JSONSerialization.data(withJSONObject: stale).write(to: state)
    let collector = CodexGrindHistoryCollector(), home = root.appendingPathComponent("codex"), now = DotInputCollector.parse("2026-10-14T20:59:30Z")!
    let first = collector.collectIncremental(codexHome: home, now: now, stateURL: state)
    try expect(first.coverageComplete, "v2 migration fully replays before advancing cursors")
    try expectEqual(first.history.first?.nightGrindTime, "01:00", "pre-provenance polluted pending finish is replaced")
    try nativeAppend(try nativeMessage("goal-auto", at: "2026-10-14T20:58:00Z"), to: file)
    let pending = collector.collectIncremental(codexHome: home, now: now, stateURL: state)
    try expectEqual(pending.sessions, first.sessions, "complete snapshot freezes until successful acknowledgement")
    try expect(pending.coverageComplete, "failed upload must retain its complete coverage")
    collector.acknowledgeUploaded(stateURL: state)
    let delta = collector.collectIncremental(codexHome: home, now: now, stateURL: state)
    try expect(delta.sessions.isEmpty && delta.legacyUnknownSessions.isEmpty, "persisted goal trigger excludes first automatic row across poll boundary")
    try expect(!delta.coverageComplete, "incremental append never claims full historical replacement")
    try nativeAppend(try nativeStart("composer"), to: file)
    _ = collector.collectIncremental(codexHome: home, now: now, stateURL: state)
    try nativeAppend(try nativeMessage("later-human", at: "2026-10-14T20:58:30Z"), to: file)
    let human = collector.collectIncremental(codexHome: home, now: now, stateURL: state)
    try expectEqual(human.sessions.first?.lastNightUserAt, "2026-10-14T20:58:30.000Z", "composer attribution survives a cursor boundary")
    let encoded = String(data: try Data(contentsOf: state), encoding: .utf8)!
    try expect(!encoded.contains("fixture input"), "persistent state never stores source text")
}

func testNativeWorkdayPartialReplayNeverClaimsCoverage() throws {
    let (root, file, state) = try nativeFixtureHome(); defer { try? FileManager.default.removeItem(at: root) }
    var rows = try nativeRoot(); rows.append(try nativeStart("composer"))
    var partial = try nativeMessage("partial", at: "2026-10-14T17:00:00Z"); partial.removeLast(); rows.append(partial)
    try rows.write(to: file)
    let collector = CodexGrindHistoryCollector(), now = DotInputCollector.parse("2026-10-14T20:00:00Z")!, home = root.appendingPathComponent("codex")
    let first = collector.collectIncremental(codexHome: home, now: now, stateURL: state)
    try expect(!first.coverageComplete && first.sessions.isEmpty, "partial JSONL row is neither activity nor complete coverage")
    collector.acknowledgeUploaded(stateURL: state)
    try nativeAppend(Data([10]), to: file)
    let complete = collector.collectIncremental(codexHome: home, now: now, stateURL: state)
    try expect(complete.coverageComplete, "completed EOF row retries full replay rather than permanently losing correction coverage")
    try expectEqual(complete.sessions.first?.nightTurnCount, 1, "completed source row counts once")
}
