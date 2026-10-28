import Foundation
import CodexTrafficLightCore

private final class UTCDailyFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("utc-daily-\(UUID().uuidString)")
    var home: URL { root.appendingPathComponent("codex") }
    var state: URL { root.appendingPathComponent("state.json") }
    var file: URL { home.appendingPathComponent("sessions/rollout-2026-10-26T23-59-00-11111111-1111-4111-8111-111111111111.jsonl") }
    var collector: TodayCodexUsageCollector { TodayCodexUsageCollector(stateURL: state) }
    init() throws { try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func date(_ stamp: String) -> Date { SharedDateFormatters.shared.iso8601Date(from: stamp)! }
    func collect(_ stamp: String) -> TodayLiveUsageReport { collector.collect(codexHome: home, now: date(stamp)) }
    func append(total: Int, last: Int, at stamp: String, modified: String? = nil, newline: Bool = true) throws {
        let row: [String: Any] = ["type": "event_msg", "timestamp": stamp, "payload": ["type": "token_count", "info": [
            "model_context_window": 300_000, "total_token_usage": ["total_tokens": total], "last_token_usage": ["total_tokens": last]]]]
        var data = try JSONSerialization.data(withJSONObject: row)
        if newline { data.append(10) }
        if FileManager.default.fileExists(atPath: file.path) {
            let h = try FileHandle(forWritingTo: file); defer { try? h.close() }; try h.seekToEnd(); try h.write(contentsOf: data)
        } else { try data.write(to: file) }
        try FileManager.default.setAttributes([.modificationDate: date(modified ?? stamp)], ofItemAtPath: file.path)
    }
    func row(_ report: TodayLiveUsageReport, _ day: String) -> UTCDailyUsageReport? { report.utcDailyUsage?.first { $0.day == day } }
}

func testUTCDailyRetainsLateTailAcrossMidnightAndRestart() throws {
    let f = try UTCDailyFixture()
    _ = f.collect("2026-10-26T23:59:00Z")
    try f.append(total: 100, last: 100, at: "2026-10-26T23:59:20Z")
    _ = f.collect("2026-10-26T23:59:30Z")
    try f.append(total: 150, last: 50, at: "2026-10-26T23:59:59Z")
    try f.append(total: 170, last: 20, at: "2026-10-27T00:00:01Z")
    let report = f.collect("2026-10-27T00:00:10Z")
    try expectEqual(f.row(report, "2026-10-26")?.tokens, 150, "late previous UTC tail belongs to its source day")
    try expectEqual(f.row(report, "2026-10-27")?.tokens, 20, "new UTC day stays separate")
    try expectEqual(report.utcTokens, 20, "existing live UTC counter is unchanged")
    try expectEqual(report.counterVersion, 4, "diagnostics grant no replacement authority")
    try expectEqual(f.row(f.collect("2026-10-27T00:00:11Z"), "2026-10-26")?.tokens, 150, "restart and repeated polling cannot recount old tails")
    try expectEqual(f.row(report, "2026-10-26")?.coverageFrom, "2026-10-26T23:59:00.000Z", "initial day remains visibly partial")
    try expectEqual(f.row(report, "2026-10-26")?.throughAt, "2026-10-27T00:00:00.000Z", "successful tail read closes the UTC window")
}

func testUTCDailyLocalMidnightAndSleepCatchup() throws {
    let f = try UTCDailyFixture()
    _ = f.collect("2026-10-26T15:59:00Z")
    try f.append(total: 100, last: 100, at: "2026-10-26T15:59:59Z")
    let midnight = f.collect("2026-10-26T16:00:01Z")
    try expectEqual(midnight.tokens, 0, "late prior local day must not inflate today's live total")
    try expectEqual(f.row(midnight, "2026-10-26")?.tokens, 100, "UTC diagnostic retains the local-midnight tail")
    try f.append(total: 150, last: 50, at: "2026-10-27T02:00:00Z")
    // The file is not modified on wake-up day; the prior checkpoint must select it.
    let resumed = f.collect("2026-10-29T02:00:00Z")
    try expectEqual(f.row(resumed, "2026-10-27")?.tokens, 50, "sleep does not hide old unconsumed file tails")
    try expectEqual(f.row(resumed, "2026-10-28")?.tokens, 0, "a successfully scanned quiet UTC day is explicit")
    try expectEqual(f.row(resumed, "2026-10-27")?.coverageFrom, "2026-10-27T00:00:00.000Z", "observed full days have precise start boundaries")
    try expectEqual(f.row(resumed, "2026-10-27")?.throughAt, "2026-10-28T00:00:00.000Z", "full day's tail is read before coverage completes")
}

func testUTCDailyMigrationAndIncompleteTailCoverage() throws {
    let f = try UTCDailyFixture()
    _ = f.collect("2026-10-26T23:59:00Z")
    try f.append(total: 100, last: 100, at: "2026-10-26T23:59:10Z")
    _ = f.collect("2026-10-26T23:59:20Z")
    var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: f.state)) as! [String: Any]
    legacy.removeValue(forKey: "utcDailyLedger")
    try JSONSerialization.data(withJSONObject: legacy).write(to: f.state)
    let migration = f.collect("2026-10-26T23:59:30Z")
    try expectEqual(f.row(migration, "2026-10-26")?.tokens, 100, "upgrade preserves the recorded counter")
    try expectEqual(f.row(migration, "2026-10-26")?.coverageFrom, "2026-10-26T23:59:30.000Z", "upgrade cannot invent pre-upgrade coverage")
    try f.append(total: 150, last: 50, at: "2026-10-26T23:59:59Z", newline: false)
    let blocked = f.collect("2026-10-27T00:00:01Z")
    try expectEqual(f.row(blocked, "2026-10-26")?.throughAt, "2026-10-26T23:59:30.000Z", "incomplete tail freezes coverage")
    let h = try FileHandle(forWritingTo: f.file); try h.seekToEnd(); try h.write(contentsOf: Data([10])); try h.close()
    try FileManager.default.setAttributes([.modificationDate: f.date("2026-10-27T00:00:02Z")], ofItemAtPath: f.file.path)
    let recovered = f.collect("2026-10-27T00:00:03Z")
    try expectEqual(f.row(recovered, "2026-10-26")?.tokens, 150, "completed tail recovers only the proven event")
    try expect(f.row(recovered, "2026-10-26")?.throughAt != "2026-10-27T00:00:00.000Z", "recovery cannot silently bridge an unverified coverage gap")
    try expectEqual(f.row(recovered, "2026-10-27")?.coverageFrom, "2026-10-27T00:00:03.000Z", "coverage resumes at successful recovery")
}

func testUTCDailyRetentionAndDotObservedMerge() throws {
    let f = try UTCDailyFixture()
    _ = f.collect("2026-10-26T23:59:00Z")
    try f.append(total: 100, last: 100, at: "2026-10-26T23:59:10Z")
    _ = f.collect("2026-10-26T23:59:20Z")
    let resumed = f.collect("2026-11-15T01:00:00Z")
    try expect((resumed.utcDailyUsage?.count ?? 0) <= 14, "retention remains bounded")
    try expect(resumed.utcDailyUsage?.allSatisfy { $0.day >= "2026-11-02" } == true, "long sleep does not replay unlimited history")
    try expectEqual(f.row(resumed, "2026-11-15")?.coverageFrom, "2026-11-15T01:00:00.000Z", "long sleep is an explicit coverage restart")
    var ledger = DotTokenLedger()
    let before = f.date("2026-10-27T01:00:00Z"), after = f.date("2026-10-27T01:01:00Z")
    ledger.observe(key: "dot", total: 100, baseline: true, now: before)
    ledger.observe(key: "dot", total: 130, baseline: false, now: after)
    let native = TodayLiveUsageReport(day: "2026-10-27", tokens: 7, utcDay: "2026-10-27", utcTokens: 7, updatedAt: "2026-10-27T01:01:00Z", utcDailyUsage: [
        .init(day: "2026-10-27", tokens: 7, updatedAt: "2026-10-27T01:01:00Z", coverageFrom: "2026-10-27T00:00:00Z", throughAt: "2026-10-27T01:01:00Z")])
    let combined = ledger.merging(native, now: after)
    try expectEqual(combined.utcDailyUsage?.first?.tokens, 37, "Dot recorded UTC increments merge by UTC key")
    try expect(combined.utcDailyUsage?.first?.coverageFrom == nil && combined.utcDailyUsage?.first?.throughAt == nil, "observation timestamps cannot certify request-time coverage")
    try expectEqual(ledger.merging(native, now: after, nativeKeys: ["dot"]), native, "native overlap remains excluded including diagnostics")
}

func testUTCDailyIncompleteInventoryPreservesOffsetsAndCoverage() throws {
    let f = try UTCDailyFixture()
    _ = f.collect("2026-10-26T23:58:00Z")
    try f.append(total: 100, last: 100, at: "2026-10-26T23:58:10Z")
    _ = f.collect("2026-10-26T23:58:20Z")
    _ = f.collect("2026-10-26T23:59:00Z")
    try expectEqual(f.collector.cachedReport(now: f.date("2026-10-26T23:59:00Z"))?.utcDailyUsage?.first?.throughAt,
        "2026-10-26T23:59:00.000Z", "a quiet successful scan persists its exact coverage checkpoint")
    try f.append(total: 150, last: 50, at: "2026-10-26T23:59:59Z")
    let missing = CodexSessionFileIndex(codexHome: f.home, files: [], enumerationComplete: false)
    let failed = f.collector.collect(codexHome: f.home, sessionFileIndex: missing, now: f.date("2026-10-27T00:00:01Z"))
    try expectEqual(f.row(failed, "2026-10-26")?.throughAt, "2026-10-26T23:59:00.000Z", "an unreadable directory cannot be mistaken for an empty complete scan")
    let recovered = f.collect("2026-10-27T00:00:02Z")
    try expectEqual(f.row(recovered, "2026-10-26")?.tokens, 150, "missing inventory preserves the original offset for retry")
    try expectEqual(f.row(recovered, "2026-10-27")?.coverageFrom, "2026-10-27T00:00:02.000Z", "successful retry opens a new coverage interval")
    let absent = f.root.appendingPathComponent("missing-codex")
    try expect(!CodexSessionFileIndex(codexHome: absent).enumerationComplete, "a missing source directory cannot establish zero usage")
    try FileManager.default.removeItem(at: f.file)
    let removed = f.collect("2026-10-27T00:00:03Z")
    try expectEqual(f.row(removed, "2026-10-27")?.throughAt, "2026-10-27T00:00:02.000Z", "a previously tracked file disappearing breaks coverage")
}

func testUTCDailyNearFutureDayIsRetainedWithoutCertification() throws {
    let f = try UTCDailyFixture()
    _ = f.collect("2026-10-26T23:59:00Z")
    try f.append(total: 50, last: 50, at: "2026-10-27T00:01:00Z")
    let early = f.collect("2026-10-26T23:59:50Z")
    try expect(f.row(early, "2026-10-27") == nil, "future UTC dates are not published prematurely")
    try expectEqual(f.row(early, "2026-10-26")?.throughAt, "2026-10-26T23:59:00.000Z", "near-future crossing cannot certify the current window")
    let after = f.collect("2026-10-27T00:02:00Z")
    try expectEqual(f.row(after, "2026-10-27")?.tokens, 50, "the previously consumed future row survives rollover exactly once")
    try expectEqual(f.row(after, "2026-10-27")?.coverageFrom, "2026-10-27T00:02:00.000Z", "coverage resumes only after a successful current scan")
    try expectEqual(f.row(f.collect("2026-10-27T00:02:01Z"), "2026-10-27")?.tokens, 50, "persisted future-day receipt is never replayed")
}

func testUTCDailyMalformedUsageLineBreaksCoverageWithoutChangingCounts() throws {
    let f = try UTCDailyFixture()
    _ = f.collect("2026-10-26T23:59:00Z")
    try f.append(total: 100, last: 100, at: "2026-10-26T23:59:10Z")
    _ = f.collect("2026-10-26T23:59:20Z")
    func raw(_ line: String, at stamp: String) throws {
        let handle = try FileHandle(forWritingTo: f.file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data((line + "\n").utf8))
        try FileManager.default.setAttributes([.modificationDate: f.date(stamp)], ofItemAtPath: f.file.path)
    }
    try raw(#"{"type":"event_msg","payload":{"type":"token_count",broken}}"#, at: "2026-10-26T23:59:30Z")
    let malformed = f.collect("2026-10-26T23:59:40Z")
    try expectEqual(f.row(malformed, "2026-10-26")?.tokens, 100, "malformed numeric evidence cannot fabricate spending")
    try expectEqual(f.row(malformed, "2026-10-26")?.throughAt, "2026-10-26T23:59:20.000Z", "a consumed complete malformed usage line breaks coverage")
    let resumed = f.collect("2026-10-26T23:59:45Z")
    try raw(#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#, at: "2026-10-26T23:59:46Z")
    let quotaOnly = f.collect("2026-10-26T23:59:50Z")
    try expectEqual(quotaOnly.utcDailyUsage?.first?.coverageFrom, resumed.utcDailyUsage?.first?.coverageFrom, "normal quota-only notifications do not create artificial gaps")
    try expectEqual(quotaOnly.utcDailyUsage?.first?.throughAt, "2026-10-26T23:59:50.000Z", "normal quota-only rows permit a completed scan")
}
