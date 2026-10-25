import Foundation
import CodexTrafficLightCore

func testNativeUsageReceiptCertification() throws {
    func usage(_ input: Int = 100, _ cached: Int = 40, _ output: Int = 20, _ reasoning: Int = 5) -> [String: Any] {
        ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
         "reasoning_output_tokens": reasoning, "total_tokens": input + output]
    }
    func receipt(_ id: String = "response-1", turn: String = "turn-1", thread: String = "thread-1",
                 values: [String: Any]? = nil) -> [String: Any] {
        ["response_id": id, "turn_id": turn, "thread_id": thread, "usage": values ?? usage()]
    }
    func seeded() -> NativeUsageReceipt {
        var state = NativeUsageReceipt()
        _ = state.consume(current: usage(1000, 400, 200, 50))
        state.startTurn("turn-1")
        return state
    }
    let advanced = usage(1100, 440, 220, 55)
    var state = seeded()
    state.observe(receipt(), canonicalThreadID: "thread-1")
    // No clock or thread_token_usage is needed: receipts survive arbitrary polling delays.
    state = try JSONDecoder().decode(NativeUsageReceipt.self, from: JSONEncoder().encode(state))
    try expect(state.consume(current: advanced), "one owned receipt authenticates the exact cumulative vector delta")
    try expect(!state.consume(current: advanced), "a receipt authenticates at most one snapshot")
    state.observe(receipt(), canonicalThreadID: "thread-1")
    try expect(!state.consume(current: usage(1200, 480, 240, 60)), "consumed response identity cannot authenticate again")

    state = seeded()
    var withUnrelatedTotals = receipt()
    withUnrelatedTotals["thread_token_usage"] = usage(9_000_000, 0, 0, 0)
    state.observe(withUnrelatedTotals, canonicalThreadID: "thread-1")
    try expect(state.consume(current: advanced), "receipt absolute thread totals never override the independently observed baseline")

    for bad in [receipt(turn: "previous-turn"), receipt(thread: "parent-thread"), receipt("")] {
        state = seeded(); state.observe(bad, canonicalThreadID: "thread-1")
        try expect(!state.consume(current: advanced), "foreign thread, stale turn, and absent response identity cannot certify")
    }
    state = seeded()
    try expect(!state.consume(current: advanced), "matching arithmetic without a receipt is not proof")
    state = NativeUsageReceipt(); state.startTurn("turn-1")
    state.observe(receipt(), canonicalThreadID: "thread-1")
    try expect(!state.consume(current: usage()), "a first cumulative snapshot has no certified prior baseline")

    for second in [receipt(), receipt("response-2"), receipt(thread: "parent-thread")] {
        state = seeded(); state.observe(receipt(), canonicalThreadID: "thread-1")
        state.observe(second, canonicalThreadID: "thread-1")
        try expect(!state.consume(current: advanced), "duplicate, multiple, or foreign intervening receipts make attribution ambiguous")
        state.observe(receipt("response-3"), canonicalThreadID: "thread-1")
        try expect(state.consume(current: usage(1200, 480, 240, 60)), "the next complete baseline permits a new unambiguous receipt")
    }
    state = seeded(); state.observe(receipt(), canonicalThreadID: "thread-1")
    state.startTurn("turn-2")
    try expect(!state.consume(current: advanced), "a new turn cannot consume the previous turn receipt")
    state = seeded(); state.observe(receipt(), canonicalThreadID: "thread-1")
    state.startTurn("turn-1")
    try expect(!state.consume(current: advanced), "even a repeated task_started clears the pending receipt")
    state = seeded(); state.observe(receipt(), canonicalThreadID: "thread-1")
    state.invalidate()
    state.observe(receipt("response-2"), canonicalThreadID: "thread-1")
    try expect(!state.consume(current: advanced), "compaction and task-terminal boundaries close certification")

    state = seeded(); state.observe(receipt(), canonicalThreadID: "thread-1")
    state.invalidate(); state.startTurn("turn-1")
    state.observe(receipt(), canonicalThreadID: "thread-1")
    try expect(!state.consume(current: advanced), "a boundary and repeated start cannot revive a used response identity")

    for (field, value) in [("input_tokens", true as Any), ("output_tokens", -1 as Any),
                           ("cached_input_tokens", 101 as Any), ("reasoning_output_tokens", 21 as Any),
                           ("total_tokens", 121 as Any), ("input_tokens", 1.5 as Any),
                           ("total_tokens", Double.infinity as Any),
                           ("total_tokens", 9_007_199_254_740_992 as Any), ("input_tokens", "100" as Any)] {
        var invalid = usage(); invalid[field] = value
        state = seeded(); state.observe(receipt(values: invalid), canonicalThreadID: "thread-1")
        try expect(!state.consume(current: advanced), "invalid \(field) must not authenticate a cumulative delta")
    }
    for field in ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"] {
        var incomplete = usage(); incomplete.removeValue(forKey: field)
        state = seeded(); state.observe(receipt(values: incomplete), canonicalThreadID: "thread-1")
        try expect(!state.consume(current: advanced), "missing \(field) cannot silently default to zero")
    }
    for wrong in [usage(1101, 440, 219, 55), usage(1100, 441, 220, 55), usage(1100, 440, 220, 56),
                  usage(999, 400, 200, 50)] {
        state = seeded(); state.observe(receipt(), canonicalThreadID: "thread-1")
        try expect(!state.consume(current: wrong), "each component must match, including cache and reasoning subsets")
    }
    state = seeded(); state.observe(receipt(), canonicalThreadID: "thread-1")
    try expect(!state.consume(current: nil), "invalid cumulative clears both receipt and baseline")
    state.observe(receipt("response-2"), canonicalThreadID: "thread-1")
    try expect(!state.consume(current: advanced), "a missing baseline cannot be resurrected by a later receipt")
    state.observe(receipt("response-3"), canonicalThreadID: "thread-1")
    try expect(state.consume(current: usage(1200, 480, 240, 60)), "valid baseline recovery resumes certification")

    for delta in [119, 121, 240] {
        state = seeded(); state.observe(receipt(), canonicalThreadID: "thread-1")
        try expect(!state.consume(current: advanced, expectedDelta: delta), "scalar collector delta must equal the certified receipt total")
    }
    state = seeded(); state.observe(receipt(), canonicalThreadID: "thread-1")
    try expect(state.consume(current: advanced, expectedDelta: 120), "matching scalar delta preserves exact certification")
    for value: Any in [true, -1, 101, 1.5, "10", 9_007_199_254_740_992] {
        var invalid = usage(); invalid["cache_write_input_tokens"] = value
        state = seeded(); state.observe(receipt(values: invalid), canonicalThreadID: "thread-1")
        try expect(!state.consume(current: advanced), "present cache write must be a valid integer subset")
    }
    var writing = usage(); writing["cache_write_input_tokens"] = 10
    var written = advanced; written["cache_write_input_tokens"] = 10
    state = seeded(); state.observe(receipt(values: writing), canonicalThreadID: "thread-1")
    try expect(state.consume(current: written), "optional cache write participates in the exact vector delta")
    state = seeded(); state.observe(receipt(values: writing), canonicalThreadID: "thread-1")
    try expect(!state.consume(current: advanced), "missing cumulative cache write cannot certify a nonzero receipt component")

    state = seeded()
    for index in 1...257 {
        state.observe(receipt("response-\(index)"), canonicalThreadID: "thread-1")
        let actual = state.consume(current: usage(1000 + index * 100, 400 + index * 40, 200 + index * 20, 50 + index * 5))
        try expectEqual(actual, index <= 256, "receipt identity storage is bounded and fails closed when full")
    }
    let saved = try JSONEncoder().encode(state)
    try expect(saved.count < 10_000, "persisted receipt state remains bounded")
}

private final class NativeReceiptFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-receipt-\(UUID().uuidString)")
    let start = ISO8601DateFormatter().date(from: "2026-10-26T03:00:00Z")!
    let id = "11111111-1111-4111-8111-111111111111"
    var home: URL { root.appendingPathComponent("codex") }
    var file: URL { home.appendingPathComponent("sessions/rollout-2026-10-26T11-00-00-\(id).jsonl") }
    func stamp(_ seconds: Double) -> String { SharedDateFormatters.shared.iso8601Fractional.string(from: start.addingTimeInterval(seconds)) }
    func vector(_ scale: Int) -> [String: Any] {
        ["input_tokens": 100 * scale, "cached_input_tokens": 40 * scale, "output_tokens": 20 * scale,
         "reasoning_output_tokens": 5 * scale, "total_tokens": 120 * scale, "cache_write_input_tokens": 10 * scale]
    }
    func event(_ payload: [String: Any], at seconds: Double) -> [String: Any] {
        ["type": "event_msg", "timestamp": stamp(seconds), "payload": payload]
    }
    func count(_ scale: Int, last: Int = 10, at seconds: Double) -> [String: Any] {
        event(["type": "token_count", "info": ["total_token_usage": vector(scale), "last_token_usage": vector(last), "model_context_window": 300_000]], at: seconds)
    }
    func receipt(_ response: String = "response-1", thread: String? = nil, invalid: Bool = false) -> [String: Any] {
        var usage = vector(1)
        if invalid { usage["cache_write_input_tokens"] = true }
        return ["type": "token_usage_record", "timestamp": stamp(2), "payload": [
            "thread_id": thread ?? id, "turn_id": "turn-1", "response_id": response,
            "usage": usage, "thread_token_usage": vector(99)]]
    }
    init() throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        _ = collect(0)
        try write([["type": "session_meta", "timestamp": stamp(0.1), "payload": ["id": id, "timestamp": stamp(0.1), "source": "cli"]],
                   event(["type": "task_started", "turn_id": "turn-1"], at: 0.2), count(10, at: 1)], at: 1, append: false)
        try expectEqual(collect(1.5).tokens, 1200, "fixture establishes a complete owned baseline")
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func write(_ rows: [[String: Any]], at seconds: Double, append: Bool = true) throws {
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        if append {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } else { try data.write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(seconds)], ofItemAtPath: file.path)
    }
    func collect(_ seconds: Double) -> TodayLiveUsageReport {
        TodayCodexUsageCollector(stateURL: root.appendingPathComponent("state.json")).collect(codexHome: home, now: start.addingTimeInterval(seconds))
    }
}

func testNativeUsageReceiptCollectorIntegration() throws {
    let f = try NativeReceiptFixture()
    try f.write([f.receipt()], at: 2)
    try expectEqual(f.collect(3).tokens, 1200, "receipt alone must never add usage")
    try f.write([f.count(11, at: 20)], at: 20)
    let delayed = f.collect(21)
    try expectEqual(delayed.tokens, 1320, "SpendingOnly stale last is certified across polls and beyond five seconds")
    try expectEqual(delayed.pendingTokens, 0, "exact owned receipt resolves only the mismatched last counter")
    try expectEqual(f.collect(22).tokens, 1320, "repeated poll is idempotent")
    try f.write([f.receipt(), f.count(12, at: 23)], at: 23)
    try expectEqual(f.collect(24).tokens, 1320, "replayed response cannot authenticate a second delta")
    try expectEqual(f.collect(25).pendingTokens, 120, "duplicate receipt remains pending once")

    for mode in ["foreign", "multiple", "invalid", "absent", "boundary", "normal"] {
        let g = try NativeReceiptFixture()
        var rows: [[String: Any]]
        switch mode {
        case "foreign": rows = [g.receipt(thread: "parent-thread")]
        case "multiple": rows = [g.receipt(), g.receipt("response-2")]
        case "invalid": rows = [g.receipt(invalid: true)]
        case "boundary": rows = [g.receipt(), g.event(["type": "task_complete", "turn_id": "turn-1"], at: 2.5)]
        default: rows = []
        }
        try g.write(rows, at: 3)
        _ = g.collect(4)
        try g.write([g.count(11, last: mode == "normal" ? 1 : 10, at: 20)], at: 20)
        let report = g.collect(21)
        try expectEqual(report.tokens, mode == "normal" ? 1320 : 1200, "\(mode) preserves ordinary validation and fails closed for uncertified mismatches")
        try expectEqual(report.pendingTokens, mode == "normal" ? 0 : 120, "\(mode) keeps unknown increments pending")
    }
    let h = try NativeReceiptFixture()
    var invalidTimestamp = h.count(11, at: 2)
    invalidTimestamp["timestamp"] = "invalid"
    try h.write([invalidTimestamp, h.receipt()], at: 3)
    _ = h.collect(4)
    try h.write([h.count(12, at: 20)], at: 20)
    let misaligned = h.collect(21)
    try expectEqual(misaligned.tokens, 1200, "invalid timestamp cannot move only the receipt baseline and certify an oversized legacy delta")
    try expectEqual(misaligned.pendingTokens, 240, "the misaligned cumulative increase remains pending")
}
