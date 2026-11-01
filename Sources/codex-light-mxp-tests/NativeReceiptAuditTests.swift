import Foundation
import CodexTrafficLightCore

func testNativeReceiptAuditUsesCanonicalRequestsWithoutChangingCounters() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    let id = "11111111-1111-4111-8111-111111111111", parent = "22222222-2222-4222-8222-222222222222"
    let file = root.appendingPathComponent("sessions/rollout-\(id).jsonl")
    func receipt(_ response: String, _ total: Any = 100, owner: String = id, ordinal: Int = 3) -> [String: Any] {
        ["type": "token_usage_record", "timestamp": "2026-10-29T03:00:00Z", "ordinal": ordinal,
            "payload": ["thread_id": owner, "response_id": response, "usage": [
                "input_tokens": 90, "cached_input_tokens": 80, "output_tokens": 10,
                "reasoning_output_tokens": 1, "total_tokens": total]]]
    }
    let rows: [[String: Any]] = [
        ["type": "session_meta", "timestamp": "2026-10-29T02:00:00Z", "payload": ["id": id, "subagent_history_start_ordinal": 3, "forked_from_id": parent]],
        receipt("copied", owner: id, ordinal: 2), receipt("foreign", owner: parent),
        ["type": "response_item", "timestamp": "2026-10-29T03:00:00Z", "payload": ["body": String(repeating: "x", count: 800_000)]],
        receipt("normal"), receipt("normal"),
        receipt("compaction"),
        // The receipt remains evidence even if the compaction marker is delayed.
        ["type": "compacted", "timestamp": "2026-10-29T04:00:00Z", "payload": ["compaction_response_id": "compaction"]],
        receipt("bad", true),
        ["type": "event_msg", "timestamp": "2026-10-29T05:00:00Z", "payload": ["type": "task_started", "turn_id": "external-import-history"]],
        receipt("imported")
    ]
    var bytes = Data()
    for row in rows { bytes.append(try JSONSerialization.data(withJSONObject: row)); bytes.append(10) }
    try bytes.write(to: file)
    let state = root.appendingPathComponent("state.json"), before = Data(#"{"utcDailyLedger":{"tokens":{"2026-10-29":100}}}"#.utf8)
    try before.write(to: state)
    let report = NativeReceiptAudit.scan(index: CodexSessionFileIndex(codexHome: root), nativeState: state)
    try expect(report.complete, "bounded selected-file scan completes")
    try expectEqual(report.days["2026-10-29"]?.receiptTokens, 200, "count each canonical response once, including compaction")
    try expectEqual(report.days["2026-10-29"]?.compactionTokens, 100, "compaction pairing uses identity rather than a five-second guess")
    try expectEqual(report.days["2026-10-29"]?.nativeLedgerTokens, 100, "retain actual accepted counter independently")
    try expectEqual(try Data(contentsOf: state), before, "diagnosis does not mutate the counter")
    let limited = NativeReceiptAudit.scan(index: CodexSessionFileIndex(codexHome: root), nativeState: state, deadline: .distantPast)
    try expect(!limited.complete, "timeout cannot claim complete evidence")
}
