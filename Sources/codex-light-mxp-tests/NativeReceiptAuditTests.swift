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
    try expect(!report.complete, "invalid numeric receipts remain an explicit evidence gap")
    try expectEqual(report.failureReasons["invalid_receipt"], 1, "malformed owned usage cannot silently disappear")
    try expectEqual(report.days["2026-10-29"]?.receiptTokens, 200, "count each canonical response once, including compaction")
    try expectEqual(report.days["2026-10-29"]?.compactionTokens, 100, "compaction pairing uses identity rather than a five-second guess")
    try expectEqual(report.days["2026-10-29"]?.nativeLedgerTokens, 100, "retain actual accepted counter independently")
    try expectEqual(try Data(contentsOf: state), before, "diagnosis does not mutate the counter")
    try expectEqual(report.requests.count, 2, "export numeric request identities for cross-device reconciliation")
    try expect(report.requests.allSatisfy { $0.key.count == 64 }, "raw thread and response identifiers never leave the scanner")
    let limited = NativeReceiptAudit.scan(index: CodexSessionFileIndex(codexHome: root), nativeState: state, deadline: .distantPast)
    try expect(!limited.complete, "timeout cannot claim complete evidence")
}

func testNativeReceiptAuditMergesCopiesAndRejectsConflicts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = "11111111-1111-4111-8111-111111111111"
    let header: [String: Any] = ["type": "session_meta", "payload": ["id": id]]
    func receipt(_ response: String, _ input: Int, at: String = "2026-10-29T03:00:00Z") -> [String: Any] {
        ["type": "token_usage_record", "timestamp": at, "payload": ["thread_id": id, "response_id": response,
            "usage": ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": 10,
                "reasoning_output_tokens": 0, "total_tokens": input + 10]]]
    }
    func write(_ folder: String, _ rows: [[String: Any]]) throws {
        let dir = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var data = Data()
        for row in [header] + rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: dir.appendingPathComponent("rollout-\(id).jsonl"))
    }
    try write("sessions", [receipt("copy", 90), receipt("first-segment", 190)])
    try write("archived_sessions", [receipt("copy", 90), receipt("second-segment", 290)])
    let state = root.appendingPathComponent("state.json")
    try Data(#"{"utcDailyLedger":{"tokens":{}}}"#.utf8).write(to: state)
    var index = CodexSessionFileIndex(codexHome: root)
    let merged = NativeReceiptAudit.scan(index: index, nativeState: state)
    try expect(merged.complete, "all physical copies read successfully")
    try expectEqual(merged.days["2026-10-29"]?.receiptTokens, 600, "both distinct segments survive, shared request counts once")
    try write("sessions/copy-3", [receipt("copy", 91), receipt("first-segment", 190, at: "2026-10-30T03:00:00Z")])
    try write("sessions/copy-4", [receipt("copy", 90)])
    let conflict = NativeReceiptAudit.scan(index: CodexSessionFileIndex(codexHome: root), nativeState: state)
    try expect(!conflict.complete, "timestamp and usage contradictions both invalidate completeness")
    try expectEqual(conflict.conflicts, 2, "conflicts counted by identity")
    try expectEqual(conflict.requests.count, 1, "later clean copies cannot resurrect contradicted identities")
    try expectEqual(conflict.days["2026-10-29"]?.receiptTokens, 300, "contradicted requests excluded from subtotal")
    let compressed = root.appendingPathComponent("sessions/cold.jsonl.zst")
    try Data([1, 2, 3]).write(to: compressed)
    index = CodexSessionFileIndex(codexHome: root)
    let partial = NativeReceiptAudit.scan(index: index, nativeState: state)
    try expectEqual(partial.recentCompressedFiles, 1, "index discovers compressed files without feeding them to live plain reader")
    try expectEqual(partial.failureReasons["compressed_not_read"], 1, "unsupported recent compressed input is explicit")
    try expect(!partial.complete, "compressed input cannot silently produce complete evidence")
    var stale = CodexSessionFileIndex(codexHome: root)
    stale.compressedFiles = []
    stale.files[0].size -= 1
    let changed = NativeReceiptAudit.scan(index: stale, nativeState: state)
    try expect(!changed.complete, "file mutation after the index snapshot invalidates completeness")
    try expectEqual(changed.failureReasons["file_changed"], 1, "detect mismatched physical file snapshot")
}
