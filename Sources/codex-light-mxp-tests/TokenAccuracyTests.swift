import Foundation
import CodexTrafficLightCore

private final class TokenAccuracyFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("token-accuracy-\(UUID().uuidString)")
    let start = ISO8601DateFormatter().date(from: "2026-10-26T03:00:00Z")!
    var home: URL { root.appendingPathComponent("codex") }
    var collector: TodayCodexUsageCollector { TodayCodexUsageCollector(stateURL: root.appendingPathComponent("state.json")) }
    init() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        _ = collector.collect(codexHome: home, now: start)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func stamp(_ seconds: Double) -> String { SharedDateFormatters.shared.iso8601Fractional.string(from: start.addingTimeInterval(seconds)) }
    func file(_ id: String) -> URL { home.appendingPathComponent("sessions/rollout-2026-10-26T11-00-00-\(id).jsonl") }
    func meta(_ id: String, parent: String? = nil, created: Double = 0.3, ordinal: Int? = nil) -> [String: Any] {
        var payload: [String: Any] = ["id": id, "timestamp": stamp(created), "source": "cli"]
        if let parent { payload["forked_from_id"] = parent }
        if let ordinal { payload["subagent_history_start_ordinal"] = ordinal }
        return ["type": "session_meta", "timestamp": stamp(created), "ordinal": 0, "payload": payload]
    }
    func usage(_ total: Int, last: Int, at seconds: Double, ordinal: Int? = nil) -> [String: Any] {
        var row: [String: Any] = ["type": "event_msg", "timestamp": stamp(seconds), "payload": [
            "type": "token_count", "info": ["model_context_window": 300_000,
                "last_token_usage": ["total_tokens": last], "total_token_usage": ["total_tokens": total]],
        ]]
        if let ordinal { row["ordinal"] = ordinal }
        return row
    }
    func write(_ rows: [[String: Any]], to file: URL, at seconds: Double, append: Bool = false) throws {
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        if append {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } else { try data.write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(seconds)], ofItemAtPath: file.path)
    }
    func collect(_ seconds: Double) -> TodayLiveUsageReport { collector.collect(codexHome: home, now: start.addingTimeInterval(seconds)) }
}

func testTokenAccuracyHighVolumeAcrossThreadsHasNoRateCeiling() throws {
    let f = try TokenAccuracyFixture()
    for index in 1...4 {
        let id = String(format: "%08d-1111-4111-8111-111111111111", index)
        let rows = [f.meta(id, created: 0)] + (1...65).map { n in f.usage(n * 200_000, last: 200_000, at: Double(n)) }
        try f.write(rows, to: f.file(id), at: 65)
    }
    let report = f.collect(70)
    try expectEqual(report.tokens, 52_000_000, "independent valid requests across four threads exceed the old global cap")
    try expectEqual(report.recent30MinuteTokens, 52_000_000, "the window measures volume, not permission to count")
    try expectEqual(report.pendingTokens, 0, "high volume alone creates no quarantine")
    try expectEqual(report.validationVersion, 6, "the server can distinguish the repaired parser")
    try expectEqual(report.counterVersion, 4, "parser upgrade grants no new replacement authority")
}

func testTokenAccuracyRepairsOnlyVerifiedRatePendingAndSurvivesRetry() throws {
    let f = try TokenAccuracyFixture()
    let id = "11111111-1111-4111-8111-111111111111"
    try f.write([f.meta(id, created: 0), f.usage(100, last: 100, at: 1), f.usage(150, last: 50, at: 2),
        f.usage(18_000_150, last: 18_000_000, at: 3)], to: f.file(id), at: 3)
    _ = f.collect(4)
    let stateURL = f.root.appendingPathComponent("state.json")
    var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
    state["tokens"] = 100; state["utcTokens"] = 100
    state["pendingTokens"] = 18_000_050; state["anomalyCount"] = 2
    state.removeValue(forKey: "repairedRateLimits")
    state["eventValidationVersion"] = 5
    state["recentEvents"] = []
    let oldState = try JSONSerialization.data(withJSONObject: state)
    try oldState.write(to: stateURL)
    let auditURL = f.root.appendingPathComponent("token-audit/2026-10-26.jsonl")
    let lines = try String(contentsOf: auditURL, encoding: .utf8).split(separator: "\n")
    var rewritten = Data()
    for line in lines {
        var row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        if (row["values"] as? [String: Int])?["delta"] == 50 {
            row["kind"] = "pending"; row["reason"] = "rate_limit"
            var values = row["values"] as! [String: Int]; values["counted"] = 0; row["values"] = values
        }
        rewritten.append(try JSONSerialization.data(withJSONObject: row)); rewritten.append(10)
    }
    try rewritten.write(to: auditURL)
    let repaired = f.collect(5)
    try expectEqual(repaired.tokens, 150, "only the raw-log verified rate-limited delta is restored")
    try expectEqual(repaired.pendingTokens, 18_000_000, "a structurally invalid event remains quarantined")
    try expectEqual(repaired.anomalyCount, 1, "repair clears only the rate-limit anomaly")
    try expectEqual(f.collect(6).tokens, 150, "the migration is idempotent")
    // Simulate process loss after audit append and before atomic state save.
    try oldState.write(to: stateURL)
    try expectEqual(f.collect(7).tokens, 150, "an audit-before-state crash does not lose or double the recovery")
    try oldState.write(to: stateURL)
    try FileManager.default.removeItem(at: f.file(id))
    let missing = f.collect(8)
    try expectEqual(missing.tokens, 100, "an audit delta without the original file cannot manufacture spending")
    try expectEqual(missing.pendingTokens, 18_000_050, "unverifiable pending usage remains visible")
}

func testTokenAccuracyForkUsesExactCreationBoundary() throws {
    let f = try TokenAccuracyFixture()
    let parent = "11111111-1111-4111-8111-111111111111", child = "22222222-2222-4222-8222-222222222222"
    try f.write([f.meta(parent, created: 0.05), f.usage(100, last: 100, at: 0.1)], to: f.file(parent), at: 0.1)
    try expectEqual(f.collect(0.2).tokens, 100, "parent work is counted once")
    try f.write([f.meta(child, parent: parent), f.usage(100, last: 100, at: 0.1), f.usage(150, last: 50, at: 0.4)], to: f.file(child), at: 0.4)
    let result = f.collect(0.5)
    try expectEqual(result.tokens, 150, "copied history within the old five-second window must not count again")
    try expectEqual(result.pendingTokens, 0, "inherited history is a baseline, not anomalous usage")
}

func testTokenAccuracyOrdinalSurvivesPollsWithoutParent() throws {
    let f = try TokenAccuracyFixture()
    let parent = "11111111-1111-4111-8111-111111111111", child = "22222222-2222-4222-8222-222222222222"
    // Copied records can be re-timestamped during persistence. The explicit
    // protocol ordinal remains authoritative even when the parent is absent.
    var metadata = f.meta(child, parent: parent, ordinal: 10)
    var payload = metadata["payload"] as! [String: Any]
    payload["base_instructions"] = String(repeating: "x", count: 128 * 1024)
    metadata["payload"] = payload
    try f.write([metadata, f.usage(100, last: 100, at: 3, ordinal: 9)], to: f.file(child), at: 3)
    try expectEqual(f.collect(3.5).tokens, 0, "a re-timestamped inherited row stays out of child usage")
    try f.write([f.usage(150, last: 50, at: 4, ordinal: 10)], to: f.file(child), at: 4, append: true)
    try expectEqual(f.collect(5).tokens, 50, "the persisted inherited baseline allows the first own delta after restart")
    try expectEqual(f.collect(6).tokens, 50, "a repeated poll never recounts the child suffix")
}

func testTokenAccuracyIndependentSiblingsKeepEqualEvents() throws {
    let f = try TokenAccuracyFixture()
    let parent = "11111111-1111-4111-8111-111111111111"
    for id in ["22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"] {
        try f.write([f.meta(id, parent: parent, ordinal: 10), f.usage(100, last: 100, at: 3, ordinal: 9), f.usage(150, last: 50, at: 4, ordinal: 10)], to: f.file(id), at: 4)
    }
    try expectEqual(f.collect(5).tokens, 100, "equal tokens and timestamps in independent children are both legitimate")
}

func testTokenAccuracyIgnoresAncestorMetadata() throws {
    let f = try TokenAccuracyFixture()
    let parent = "11111111-1111-4111-8111-111111111111", child = "22222222-2222-4222-8222-222222222222"
    try f.write([f.meta(child, parent: parent, ordinal: 10), f.meta(parent, ordinal: 1000), f.usage(100, last: 100, at: 3, ordinal: 9), f.usage(150, last: 50, at: 4, ordinal: 10)], to: f.file(child), at: 4)
    try expectEqual(f.collect(5).tokens, 50, "embedded parent metadata cannot replace the canonical child boundary")
}

func testTokenAccuracyRejectsNonIntegerCounters() throws {
    for value: Any in [true, 100.9, 9_007_199_254_740_992 as Int, "9007199254740992"] {
        let f = try TokenAccuracyFixture()
        let id = "11111111-1111-4111-8111-111111111111"
        let invalid: [String: Any] = ["type": "event_msg", "timestamp": f.stamp(1), "payload": [
            "type": "token_count", "info": ["last_token_usage": ["total_tokens": value], "total_token_usage": ["total_tokens": value]],
        ]]
        try f.write([f.meta(id), invalid], to: f.file(id), at: 1)
        let result = f.collect(2)
        try expectEqual(result.tokens, 0, "boolean, fractional and unsafe integers cannot be truncated into usage")
        try expectEqual(result.pendingTokens, 0, "an unparseable count cannot create a fabricated numeric pending amount")
        try f.write([f.usage(50, last: 50, at: 3)], to: f.file(id), at: 3, append: true)
        try expectEqual(f.collect(4).tokens, 50, "invalid counters must not poison the next valid baseline")
    }
    let f = try TokenAccuracyFixture()
    let id = "11111111-1111-4111-8111-111111111111"
    let compatible: [String: Any] = ["type": "event_msg", "timestamp": f.stamp(1), "payload": [
        "type": "token_count", "info": ["last_token_usage": ["total_tokens": "100"], "total_token_usage": ["total_tokens": "100"]],
    ]]
    try f.write([f.meta(id), compatible], to: f.file(id), at: 1)
    try expectEqual(f.collect(2).tokens, 100, "legacy nonnegative integer strings remain supported")
}

func testTokenAccuracyCompactionMatchesOwnerAndResponse() throws {
    let leaf = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222"
    for (owner, response, expected) in [(other, "request-1", 100), (leaf, "different-request", 100), (leaf, "request-1", 140)] {
        let f = try TokenAccuracyFixture()
        let file = f.file(leaf)
        try f.write([f.meta(leaf), f.usage(100, last: 100, at: 1)], to: file, at: 1)
        try expectEqual(f.collect(1.5).tokens, 100, "baseline inference is present before compaction")
        let request: [String: Any] = ["type": "token_usage_record", "timestamp": f.stamp(2), "payload": [
            "thread_id": owner, "response_id": "request-1",
            "usage": ["input_tokens": 30, "cached_input_tokens": 20, "output_tokens": 10, "total_tokens": 40],
            "thread_token_usage": ["total_tokens": 9000],
        ]]
        try f.write([request], to: file, at: 2, append: true)
        _ = f.collect(2.5)
        let marker: [String: Any] = ["type": "compacted", "timestamp": f.stamp(3), "payload": ["compaction_response_id": response]]
        try f.write([marker, f.usage(100, last: 100, at: 3.01)], to: file, at: 3.01, append: true)
        try expectEqual(f.collect(4).tokens, expected, "only the same thread and exact compaction response may supply a missing receipt")
    }
}

func testTokenAccuracyCompactionNormalEchoCannotReplay() throws {
    for firstTotal in [100, 140] {
        let f = try TokenAccuracyFixture()
        let leaf = "11111111-1111-4111-8111-111111111111"
        let file = f.file(leaf)
        try f.write([f.meta(leaf), f.usage(100, last: 100, at: 1)], to: file, at: 1)
        _ = f.collect(1.5)
        func chain(_ second: Double) -> [[String: Any]] {
            let receipt: [String: Any] = ["type": "token_usage_record", "timestamp": f.stamp(second), "payload": [
                "thread_id": leaf, "response_id": "same-request", "usage": ["input_tokens": 30, "output_tokens": 10, "total_tokens": 40],
            ]]
            let marker: [String: Any] = ["type": "compacted", "timestamp": f.stamp(second + 0.1), "payload": ["compaction_response_id": "same-request"]]
            return [receipt, marker, f.usage(firstTotal, last: firstTotal == 100 ? 100 : 40, at: second + 0.2)]
        }
        try f.write(chain(2), to: file, at: 2.2, append: true)
        try expectEqual(f.collect(3).tokens, 140, "normal cumulative and zero-delta compaction both count the request once")
        try f.write(chain(4), to: file, at: 4.2, append: true)
        try expectEqual(f.collect(5).tokens, 140, "replayed response cannot become a second supplemental charge after restart")
    }
}

func testTokenAccuracyCompactionSupplementThenCumulativeEcho() throws {
    let f = try TokenAccuracyFixture()
    let leaf = "11111111-1111-4111-8111-111111111111", file = f.file("11111111-1111-4111-8111-111111111111")
    func vector(_ input: Int, _ output: Int) -> [String: Int] {
        ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": output,
         "reasoning_output_tokens": 0, "cache_write_input_tokens": 0, "total_tokens": input + output]
    }
    func echo(_ input: Int, _ output: Int, _ last: [String: Int], _ at: Double) -> [String: Any] {
        ["type": "event_msg", "timestamp": f.stamp(at), "payload": ["type": "token_count", "info": [
            "total_token_usage": vector(input, output), "last_token_usage": last]]]
    }
    func chain(_ at: Double, _ total: [String: Any]) -> [[String: Any]] {
        [["type": "token_usage_record", "timestamp": f.stamp(at), "payload": ["thread_id": leaf,
           "response_id": "r", "usage": vector(30, 10)]],
         ["type": "compacted", "timestamp": f.stamp(at + 0.1), "payload": ["compaction_response_id": "r"]], total]
    }
    try f.write([f.meta(leaf), echo(100, 0, vector(100, 0), 1)], to: file, at: 1)
    _ = f.collect(1.5)
    try f.write(chain(2, echo(100, 0, vector(100, 0), 2.2)), to: file, at: 2.2, append: true)
    try expectEqual(f.collect(3).tokens, 140, "supplement is counted once")
    try f.write(chain(4, echo(130, 10, vector(30, 10), 4.2)), to: file, at: 4.2, append: true)
    try expectEqual(f.collect(5).tokens, 140, "same identified response catching up in cumulative usage is not added again")
    try f.write([echo(150, 10, vector(20, 0), 6)], to: file, at: 6, append: true)
    try expectEqual(f.collect(7).tokens, 160, "independent new work remains countable after the replay baseline")
}
