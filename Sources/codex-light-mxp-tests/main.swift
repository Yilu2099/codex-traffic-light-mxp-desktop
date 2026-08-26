import Foundation
import CodexTrafficLightCore
import Dispatch

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw TestFailure(description: "\(message): expected \(expected), got \(actual)")
    }
}

func expect(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw TestFailure(description: message)
    }
}

func testCommandContract() throws {
    try expectEqual(CommandContract.clientCommandName, "codex-light-mxp", "client command should preserve installed name")
    try expectEqual(CommandContract.quotaCommandName, "quota", "quota command should be named quota")
    try expectEqual(CommandContract.auditCommandName, "audit", "audit command should be named audit")
}

func testGrindDisplayFormatterUsesConciseLabels() throws {
    try expectEqual(GrindDisplayFormatter.start(nil), "待开工", "missing start should show only the waiting label")
    try expectEqual(GrindDisplayFormatter.start(""), "待开工", "empty start should show only the waiting label")
    try expectEqual(GrindDisplayFormatter.start("08:15"), "开工 08:15", "known start should retain its time")
    try expectEqual(GrindDisplayFormatter.finish(nil), "收工未记录", "missing finish should use a natural empty state")
    try expectEqual(GrindDisplayFormatter.finish("00:49"), "收工 00:49", "finish should not repeat yesterday")
}

func testQuotaSnapshotClampsPercentValues() throws {
    let updatedAt = Date(timeIntervalSince1970: 1_234)

    let high = QuotaSnapshot(
        weeklyRemainingPercent: 101,
        source: "test",
        updatedAt: updatedAt
    )
    try expectEqual(high.weeklyRemainingPercent, 100, "weekly quota should clamp high values")

    let low = QuotaSnapshot(
        weeklyRemainingPercent: -1,
        source: "test",
        updatedAt: updatedAt
    )
    try expectEqual(low.weeklyRemainingPercent, 0, "weekly quota should clamp low values")

    let fiveHour = QuotaSnapshot(
        fiveHourRemainingPercent: 112,
        primaryWindow: .fiveHour,
        source: "test",
        updatedAt: updatedAt
    )
    try expectEqual(fiveHour.fiveHourRemainingPercent, 100, "5-hour quota should clamp high values")
    try expectEqual(fiveHour.preferredWindow?.kind, .fiveHour, "5-hour-only quota should become the preferred window")
}

func testQuotaSnapshotStoresResetDates() throws {
    let updatedAt = Date(timeIntervalSince1970: 1_234)
    let weeklyReset = Date(timeIntervalSince1970: 2_400)

    let quota = QuotaSnapshot(
        weeklyRemainingPercent: 0,
        weeklyResetsAt: weeklyReset,
        source: "test",
        updatedAt: updatedAt
    )

    try expectEqual(quota.weeklyResetsAt, weeklyReset, "weekly reset date should be stored")
}

func testQuotaExtractorReadsTopLevelSnakeCase() throws {
    let data = """
    {
      "weekly_remaining_percent": 48
    }
    """.data(using: .utf8)!

    let values = QuotaExtractor.extract(from: data)

    try expectEqual(values?.weeklyRemainingPercent, 48, "extractor should read snake_case weekly percent")
}

func testQuotaExtractorReadsNestedCamelCaseAndClamps() throws {
    let data = """
    {
      "rateLimits": {
        "weeklyRemainingPercent": -4
      }
    }
    """.data(using: .utf8)!

    let values = QuotaExtractor.extract(from: data)

    try expectEqual(values?.weeklyRemainingPercent, 0, "extractor should clamp low weekly percent")
}

func testQuotaExtractorReadsQuotaAndRateLimitsNesting() throws {
    let quotaData = """
    {
      "metadata": {
        "quota": {
          "weekly_remaining_percent": 36
        }
      }
    }
    """.data(using: .utf8)!
    let rateLimitsData = """
    {
      "payload": {
        "rate_limits": {
          "weekly_remaining_percent": "35"
        }
      }
    }
    """.data(using: .utf8)!

    try expectEqual(QuotaExtractor.extract(from: quotaData)?.weeklyRemainingPercent, 36, "extractor should recurse into quota objects")
    try expectEqual(QuotaExtractor.extract(from: rateLimitsData)?.weeklyRemainingPercent, 35, "extractor should parse numeric string percents")
}

func testQuotaExtractorRejectsSparkLimit() throws {
    let data = """
    {
      "rateLimits": {
        "limit_id": "codex_bengalfox",
        "limit_name": "GPT-5.3-Codex-Spark",
        "weekly_remaining_percent": 100,
        "weekly_resets_at": 1788011074
      }
    }
    """.data(using: .utf8)!

    try expectEqual(QuotaExtractor.extract(from: data), nil, "hook quota extraction must ignore Spark's independent limit")
}

func testQuotaExtractorRequiresBothWindows() throws {
    let data = """
    {
      "quota": {
        "unrelated_percent": 72
      }
    }
    """.data(using: .utf8)!

    try expectEqual(QuotaExtractor.extract(from: data) == nil, true, "extractor should ignore incomplete quota data")
}

func testQuotaExtractorAllowsFiveHourOnlyData() throws {
    let data = #"{"quota":{"fiveHourRemainingPercent":72,"fiveHourResetsAt":1781275400,"primaryWindow":"five_hour"}}"#.data(using: .utf8)!
    let quota = QuotaExtractor.extract(from: data)

    try expectEqual(quota?.fiveHourRemainingPercent, 72, "extractor should read a 5-hour-only allowance")
    try expectEqual(quota?.weeklyRemainingPercent, nil, "5-hour-only allowance must not invent a weekly value")
    try expectEqual(quota?.primaryWindow, .fiveHour, "extractor should preserve the official primary window")
}

func testQuotaExtractorReadsZeroPercentAndResetDates() throws {
    let data = """
    {
      "quota": {
        "weekly_remaining_percent": 0,
        "weekly_resets_at": 1781275400
      }
    }
    """.data(using: .utf8)!

    let quota = QuotaExtractor.extract(from: data)

    try expectEqual(quota?.weeklyRemainingPercent, 0, "extractor should read exhausted weekly quota")
    try expectEqual(quota?.weeklyResetsAt, Date(timeIntervalSince1970: 1_781_275_400), "extractor should read weekly reset date")
}

func testQuotaExtractorReadsSupportedMembershipPlanOnly() throws {
    let supported = #"{"weekly_remaining_percent":42,"planType":"prolite"}"#.data(using: .utf8)!
    let unsupported = #"{"weekly_remaining_percent":42,"planType":"unknown"}"#.data(using: .utf8)!

    try expectEqual(QuotaExtractor.extract(from: supported)?.planType, "prolite", "extractor should preserve an official supported membership plan")
    try expectEqual(QuotaExtractor.extract(from: unsupported)?.planType, nil, "extractor should drop unrecognized membership values")
}

func testStateSnapshotDecodesOldJSONWithoutQuota() throws {
    let data = """
    {
      "aggregate_state": "idle",
      "updated_at": 1000,
      "tasks": {}
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970

    let snapshot = try decoder.decode(StateSnapshot.self, from: data)

    try expectEqual(snapshot.updatedAt, Date(timeIntervalSince1970: 1_000), "old JSON should decode updated_at")
    try expectEqual(snapshot.quota == nil, true, "old JSON without quota should decode nil quota")
}

func testStateSnapshotMigratesLegacyCodexProviderQuota() throws {
    let data = """
    {
      "updated_at": 1000,
      "provider_quotas": {
        "codex": {
          "source": "legacy",
          "updated_at": 1100,
          "weekly_remaining_percent": 28,
          "weekly_resets_at": 2000
        }
      }
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970

    let snapshot = try decoder.decode(StateSnapshot.self, from: data)

    try expectEqual(snapshot.quota?.weeklyRemainingPercent, 28, "legacy codex quota should migrate")
    try expectEqual(snapshot.quota?.source, "legacy", "legacy source should migrate")
    try expectEqual(snapshot.quota?.weeklyResetsAt, Date(timeIntervalSince1970: 2_000), "legacy reset should migrate")
}

func testStateFileContainsOnlyCurrentQuotaKeys() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-json-tests-\(UUID().uuidString)", isDirectory: true)
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(stateURL: stateURL)
    _ = try store.updateQuota(
        weeklyPercent: 47,
        weeklyResetsAt: Date(timeIntervalSince1970: 4_000),
        source: "test",
        now: Date(timeIntervalSince1970: 3_000)
    )

    let body = try String(contentsOf: stateURL, encoding: .utf8)
    try expect(body.contains("\"weekly_remaining_percent\""), "state should contain weekly quota")
    try expect(!body.contains("aggregate_state") && !body.contains("provider_quotas") && !body.contains("tasks"), "state should not persist removed traffic-light data")
}

func testStateStoreRejectsImpossibleFullQuotaBeforeKnownReset() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-quota-anomaly-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StateStore(stateURL: root.appendingPathComponent("state.json"))
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    let knownReset = now.addingTimeInterval(2 * 86_400)
    let wrongReset = now.addingTimeInterval(7 * 86_400)
    _ = try store.updateQuota(
        weeklyPercent: 28,
        weeklyResetsAt: knownReset,
        source: "legacy-unverified",
        now: now
    )
    let protected = try store.updateQuota(
        weeklyPercent: 100,
        weeklyResetsAt: wrongReset,
        source: "legacy-unverified",
        now: now.addingTimeInterval(60)
    )
    try expectEqual(protected.quota?.weeklyRemainingPercent, 28, "impossible 100 percent should keep previous quota")
    try expectEqual(protected.quota?.weeklyResetsAt, knownReset, "impossible reset jump should keep previous reset")
    let anomalies = store.readQuotaAnomalies()
    try expectEqual(anomalies.count, 1, "rejected quota should be recorded locally")
    try expectEqual(anomalies.first?.rejected.weeklyRemainingPercent, 100, "rejected value should remain auditable")
    try expectEqual(anomalies.first?.reason, "unexpected_full_quota_before_known_reset", "rejection reason should be explicit")
}

func testStateStoreAcceptsOfficialCodexReset() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-official-reset-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StateStore(stateURL: root.appendingPathComponent("state.json"))
    let now = Date(timeIntervalSince1970: 1_780_000_000)
    _ = try store.updateQuota(
        weeklyPercent: 28,
        weeklyResetsAt: now.addingTimeInterval(2 * 86_400),
        source: CodexSessionQuotaCollector.source,
        limitID: CodexSessionQuotaCollector.primaryLimitID,
        now: now
    )
    let reset = try store.updateQuota(
        weeklyPercent: 100,
        weeklyResetsAt: now.addingTimeInterval(7 * 86_400),
        source: CodexSessionQuotaCollector.source,
        limitID: CodexSessionQuotaCollector.primaryLimitID,
        now: now.addingTimeInterval(60)
    )

    try expectEqual(reset.quota?.weeklyRemainingPercent, 100, "an exact Codex source should accept an official reset")
    try expectEqual(reset.quota?.weeklyResetsAt, now.addingTimeInterval(7 * 86_400), "official reset should keep the latest reset window")
    try expectEqual(store.readQuotaAnomalies().count, 0, "official Codex resets should not be recorded as anomalies")
}

func testStateStoreKeepsMembershipPlanAcrossSparseQuotaUpdates() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-membership-plan-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StateStore(stateURL: root.appendingPathComponent("state.json"))
    _ = try store.updateQuota(
        weeklyPercent: 40,
        source: CodexAppServerQuotaCollector.source,
        limitID: CodexSessionQuotaCollector.primaryLimitID,
        planType: "prolite",
        now: Date(timeIntervalSince1970: 1_000)
    )
    let sparse = try store.updateQuota(
        weeklyPercent: 39,
        source: CodexSessionQuotaCollector.source,
        limitID: CodexSessionQuotaCollector.primaryLimitID,
        now: Date(timeIntervalSince1970: 1_001)
    )

    try expectEqual(sparse.quota?.planType, "prolite", "a sparse rolling quota update should not erase a known official membership plan")
}

func testHookLogLineIncludesEventAndTask() throws {
    let entry = HookLogEntry(
        timestamp: Date(timeIntervalSince1970: 5_000),
        eventName: "Stop",
        taskID: "session:abc",
        workspace: "/tmp/project",
        result: "ok",
        detail: nil
    )

    let line = HookLogger.format(entry)
    if !line.contains("event=Stop")
        || !line.contains("task=session:abc")
        || !line.contains("workspace=/tmp/project")
        || !line.contains("result=ok") {
        throw TestFailure(description: "hook log line should include event, task, workspace, and result: \(line)")
    }
}

func testHookLogLineIncludesQuotaSummary() throws {
    let entry = HookLogEntry(
        timestamp: Date(timeIntervalSince1970: 5_001),
        eventName: "PreToolUse",
        taskID: "session:abc",
        workspace: "/tmp/project",
        result: "ok",
        detail: nil,
        quotaSummary: "48%"
    )

    let line = HookLogger.format(entry)

    if !line.contains("quota=48%") {
        throw TestFailure(description: "hook log line should include quota summary: \(line)")
    }
}

func testHookBridgeUpdatesQuotaAndProjectAudit() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-hook-quota-tests-\(UUID().uuidString)", isDirectory: true)
    let store = StateStore(stateURL: directory.appendingPathComponent("state.json"))
    let input = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "abc",
      "cwd": "/tmp/project",
      "quota": {
        "weeklyRemainingPercent": 47
      }
    }
    """.data(using: .utf8)!

    let result = try HookBridge.apply(
        input: input,
        fallbackName: "PreToolUse",
        store: store,
        now: Date()
    )
    let snapshot = store.read()

    try expectEqual(result.quotaSummary, "周 47%", "hook bridge should report the actual quota window")
    try expectEqual(snapshot.quota?.weeklyRemainingPercent, 47, "hook bridge should update weekly quota")
    try expectEqual(snapshot.quota?.source, "codex-hook", "hook bridge should mark quota source")
    try expectEqual(result.recordedProject, true, "hook bridge should record current project")
}

func testHookBridgeQuotaOnlyEventDoesNotRecordProject() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-quota-only-hook-tests-\(UUID().uuidString)", isDirectory: true)
    let store = StateStore(stateURL: directory.appendingPathComponent("state.json"))
    let now = Date()
    let input = """
    {
      "hook_event_name": "account/rateLimits/updated",
      "rate_limits": {
        "weekly_remaining_percent": 45
      }
    }
    """.data(using: .utf8)!

    let result = try HookBridge.apply(
        input: input,
        fallbackName: "account/rateLimits/updated",
        store: store,
        now: now.addingTimeInterval(1)
    )
    let snapshot = store.read()

    try expectEqual(result.recordedProject, false, "quota-only event without workspace should not record a project")
    try expectEqual(snapshot.quota?.weeklyRemainingPercent, 45, "quota-only event should update weekly quota")
}

func appServerRateLimitsResponse(
    rateLimitsByLimitId: String? = nil,
    rateLimits: String? = nil
) -> Data {
    let byLimitID = rateLimitsByLimitId ?? "null"
    let topLevel = rateLimits ?? "null"
    return """
    {
      "rateLimits": \(topLevel),
      "rateLimitsByLimitId": \(byLimitID)
    }
    """.data(using: .utf8)!
}

func appServerSnapshot(
    limitID: String = "codex",
    limitName: String = "Codex",
    primaryUsed: Double? = nil,
    primaryDuration: Int? = nil,
    secondaryUsed: Double? = nil,
    secondaryDuration: Int? = nil,
    individualRemaining: Int? = nil
) -> String {
    func window(_ used: Double?, _ duration: Int?) -> String {
        guard let used else { return "null" }
        let durationText = duration.map(String.init) ?? "null"
        return #"{"usedPercent": \#(used), "windowDurationMins": \#(durationText), "resetsAt": 1781189000}"#
    }

    let individual = individualRemaining.map { #"{"limit":"100","used":"1","remainingPercent":\#($0),"resetsAt":1781189000}"# } ?? "null"
    return """
    {
      "limitId": "\(limitID)",
      "limitName": "\(limitName)",
      "primary": \(window(primaryUsed, primaryDuration)),
      "secondary": \(window(secondaryUsed, secondaryDuration)),
      "credits": null,
      "individualLimit": \(individual),
      "planType": null,
      "rateLimitReachedType": null
    }
    """
}

func testAppServerQuotaMapperReadsCodexLimitByExactDurations() throws {
    let codex = appServerSnapshot(primaryUsed: 28, primaryDuration: 300, secondaryUsed: 52, secondaryDuration: 10_080)
    let fallback = appServerSnapshot(primaryUsed: 80, primaryDuration: 300, secondaryUsed: 90, secondaryDuration: 10_080)
    let data = appServerRateLimitsResponse(
        rateLimitsByLimitId: #"{"other": \#(fallback), "codex": \#(codex)}"#,
        rateLimits: fallback
    )

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: data)

    try expectEqual(quota.fiveHourRemainingPercent, Optional(72), "mapper should read the Codex 5-hour window")
    try expectEqual(quota.weeklyRemainingPercent, Optional(48), "mapper should prefer codex weekly window")
    try expectEqual(quota.primaryWindow, .fiveHour, "mapper should preserve the official primary window")
}

func testSessionQuotaCollectorUsesNewestCodexRateLimitEvent() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-session-quota-tests-\(UUID().uuidString)", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions/2026/08/22", isDirectory: true)
    let archived = root.appendingPathComponent("archived_sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let older = #"{"timestamp":"2026-08-22T06:20:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":63,"window_minutes":10080,"resets_at":1787561781}}}}"#
    let newer = #"{"timestamp":"2026-08-22T06:30:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":40,"window_minutes":300,"resets_at":1787390000},"secondary":{"used_percent":72,"window_minutes":10080,"resets_at":1787561781}}}}"#
    try Data((older + "\n").utf8).write(to: sessions.appendingPathComponent("rollout-old.jsonl"))
    try Data((newer + "\n").utf8).write(to: archived.appendingPathComponent("rollout-new.jsonl"))

    let observation = CodexSessionQuotaCollector(
        stateURL: root.appendingPathComponent("quota-state.json")
    ).collect(
        codexHome: root,
        now: Date(timeIntervalSince1970: 1_787_389_000),
        fileMaxAge: 86_400
    )

    try expectEqual(observation?.weeklyRemainingPercent, 28, "session quota should match newest Codex weekly remaining value")
    try expectEqual(observation?.weeklyResetsAt, Date(timeIntervalSince1970: 1_787_561_781), "session quota should keep reset time")
}

func testSessionQuotaCollectorIgnoresSparkRateLimitEvent() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-session-spark-quota-tests-\(UUID().uuidString)", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let codex = #"{"timestamp":"2026-08-22T06:20:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":78,"window_minutes":10080,"resets_at":1787561781}}}}"#
    let spark = #"{"timestamp":"2026-08-22T06:30:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":0,"window_minutes":300,"resets_at":1787390000},"secondary":{"used_percent":0,"window_minutes":10080,"resets_at":1788011074}}}}"#
    try Data((codex + "\n" + spark + "\n").utf8).write(to: sessions.appendingPathComponent("rollout-mixed.jsonl"))

    let observation = CodexSessionQuotaCollector(
        stateURL: root.appendingPathComponent("quota-state.json")
    ).collect(
        codexHome: root,
        now: Date(timeIntervalSince1970: 1_787_389_000),
        fileMaxAge: 86_400
    )

    try expectEqual(observation?.weeklyRemainingPercent, 22, "Spark's independent 100% bucket must not replace the Codex weekly quota")
    try expectEqual(observation?.weeklyResetsAt, Date(timeIntervalSince1970: 1_787_561_781), "collector should retain the Codex reset window")
}

func testSessionQuotaCollectorRepairsNewerSparkContamination() throws {
    let now = Date(timeIntervalSince1970: 1_787_389_000)
    let observation = CodexSessionQuotaObservation(
        weeklyRemainingPercent: 22,
        weeklyResetsAt: Date(timeIntervalSince1970: 1_787_561_781),
        observedAt: now.addingTimeInterval(-60)
    )
    let contaminated = QuotaSnapshot(
        weeklyRemainingPercent: 100,
        weeklyResetsAt: Date(timeIntervalSince1970: 1_788_011_074),
        source: "team-ranking",
        updatedAt: now
    )

    try expectEqual(
        CodexSessionQuotaCollector.shouldApply(observation, over: contaminated, now: now),
        true,
        "a fresh exact Codex observation should repair a newer Spark weekly window"
    )
}

func testSessionQuotaCollectorReplacesFreshUnverifiedCache() throws {
    let now = Date(timeIntervalSince1970: 1_787_389_000)
    let observation = CodexSessionQuotaObservation(
        weeklyRemainingPercent: 37,
        weeklyResetsAt: Date(timeIntervalSince1970: 1_787_561_781),
        observedAt: now.addingTimeInterval(-60)
    )
    let unverified = QuotaSnapshot(
        weeklyRemainingPercent: 89,
        weeklyResetsAt: Date(timeIntervalSince1970: 1_788_011_074),
        source: "legacy",
        updatedAt: now
    )

    try expectEqual(
        CodexSessionQuotaCollector.shouldApply(observation, over: unverified, now: now),
        true,
        "a fresh exact Codex observation should replace any newer cache without a verified limit id"
    )
}

func testSessionQuotaCollectorAcceptsFiveHourOnlyEvent() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-session-legacy-window-tests-\(UUID().uuidString)", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let event = #"{"timestamp":"2026-08-22T06:30:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":0,"window_minutes":300,"resets_at":1787390000}}}}"#
    try Data((event + "\n").utf8).write(to: sessions.appendingPathComponent("rollout-legacy-window.jsonl"))

    let observation = CodexSessionQuotaCollector(
        stateURL: root.appendingPathComponent("quota-state.json")
    ).collect(
        codexHome: root,
        now: Date(timeIntervalSince1970: 1_787_389_000),
        fileMaxAge: 86_400
    )

    try expectEqual(observation?.fiveHourRemainingPercent, 100, "a 300-minute Codex window should be reported as 5-hour quota")
    try expectEqual(observation?.weeklyRemainingPercent, nil, "a 5-hour-only event must not invent a weekly value")
    try expectEqual(observation?.primaryWindow, .fiveHour, "the 5-hour-only window should remain primary")
}

func testSessionQuotaCollectorPersistsOffsetsAndHandlesArchiveAndTruncation() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-session-incremental-tests-\(UUID().uuidString)", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions/2026/08/25", isDirectory: true)
    let archived = root.appendingPathComponent("archived_sessions", isDirectory: true)
    let stateURL = root.appendingPathComponent("state/session-quota.json")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func event(_ timestamp: String, used: Int) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":\#(used),"window_minutes":10080,"resets_at":1788163200}}}}"#
    }

    let formatter = ISO8601DateFormatter()
    let now = formatter.date(from: "2026-08-25T10:00:00Z")!
    let filename = "rollout-2026-08-25T18-00-00-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jsonl"
    var file = sessions.appendingPathComponent(filename)
    try (event("2026-08-25T09:59:00.000Z", used: 30) + "\n").write(
        to: file, atomically: true, encoding: .utf8
    )
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    let collector = CodexSessionQuotaCollector(stateURL: stateURL)

    let first = collector.collect(codexHome: root, now: now, fileMaxAge: 86_400)
    try expectEqual(first?.weeklyRemainingPercent, 70, "initial quota scan should baseline the recent tail")
    let firstInode = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.systemFileNumber] as? NSNumber
    let unchanged = collector.collect(codexHome: root, now: now.addingTimeInterval(30), fileMaxAge: 86_400)
    let unchangedInode = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.systemFileNumber] as? NSNumber
    try expectEqual(unchanged?.weeklyRemainingPercent, 70, "unchanged files should reuse the persisted latest quota")
    try expectEqual(unchangedInode, firstInode, "unchanged quota files must not rewrite the atomic cursor state")

    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((event("2026-08-25T10:01:00.000Z", used: 40) + "\n").utf8))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: file.path)
    let appended = collector.collect(codexHome: root, now: now.addingTimeInterval(60), fileMaxAge: 86_400)
    try expectEqual(appended?.weeklyRemainingPercent, 60, "appended quota bytes should advance the saved offset")

    let moved = archived.appendingPathComponent(filename)
    try FileManager.default.moveItem(at: file, to: moved)
    file = moved
    let movedResult = collector.collect(codexHome: root, now: now.addingTimeInterval(120), fileMaxAge: 86_400)
    try expectEqual(movedResult?.weeklyRemainingPercent, 60, "archiving a rollout must preserve its stable cursor")
    try expect(try String(contentsOf: stateURL, encoding: .utf8).contains("archived_sessions"), "archive moves should update only the persisted path")

    try (event("2026-08-25T10:03:00.000Z", used: 50) + "\n").write(
        to: file, atomically: true, encoding: .utf8
    )
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(180)], ofItemAtPath: file.path)
    let truncated = collector.collect(codexHome: root, now: now.addingTimeInterval(180), fileMaxAge: 86_400)
    try expectEqual(truncated?.weeklyRemainingPercent, 50, "truncated or replaced files should rebaseline only that file tail")
}

func testSessionQuotaCollectorRejectsFutureObservationFreshness() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-session-future-tests-\(UUID().uuidString)", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    let stateURL = root.appendingPathComponent("quota-state.json")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = sessions.appendingPathComponent("rollout-future.jsonl")
    let rows = [
        #"{"timestamp":"2026-08-25T09:59:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":35,"window_minutes":10080,"resets_at":1788163200}}}}"#,
        #"{"timestamp":"2026-08-25T10:10:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":5,"window_minutes":10080,"resets_at":1788163200}}}}"#,
    ].joined(separator: "\n") + "\n"
    try rows.write(to: file, atomically: true, encoding: .utf8)
    let now = ISO8601DateFormatter().date(from: "2026-08-25T10:00:00Z")!
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

    let observation = CodexSessionQuotaCollector(stateURL: stateURL).collect(
        codexHome: root,
        now: now,
        fileMaxAge: 86_400
    )
    try expectEqual(observation?.weeklyRemainingPercent, 65, "a future-dated quota must not replace the newest plausible observation")
    let future = CodexSessionQuotaObservation(
        weeklyRemainingPercent: 95,
        weeklyResetsAt: nil,
        observedAt: now.addingTimeInterval(61)
    )
    try expect(!CodexSessionQuotaCollector.isFresh(future, now: now), "a future event beyond clock tolerance must not suppress app-server fallback")
    let tolerated = CodexSessionQuotaObservation(
        weeklyRemainingPercent: 65,
        weeklyResetsAt: nil,
        observedAt: now.addingTimeInterval(30)
    )
    try expect(CodexSessionQuotaCollector.isFresh(tolerated, now: now), "minor clock skew should remain usable")
}

func testSessionActivityDeltaRequiresAcknowledgementAndDailyFull() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("session-activity-delta-tests-\(UUID().uuidString)", isDirectory: true)
    let stateURL = root.appendingPathComponent("state.json")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TeamSessionActivityDeltaStore(stateURL: stateURL)
    let formatter = ISO8601DateFormatter()
    let now = formatter.date(from: "2026-08-25T02:00:00Z")!
    let first = TeamSessionActivity(
        sessionId: "session-a",
        day: "2026-08-25",
        startedAt: "2026-08-25T01:00:00.000Z",
        updatedAt: "2026-08-25T01:30:00.000Z"
    )
    let second = TeamSessionActivity(
        sessionId: "session-b",
        day: "2026-08-25",
        startedAt: "2026-08-25T01:10:00.000Z",
        updatedAt: "2026-08-25T01:40:00.000Z"
    )

    let initial = store.prepare(current: [first, second], days: 45, now: now)
    try expectEqual(initial.mode, "full", "the first upload of a local day should be a full snapshot")
    try expectEqual(initial.cutoffDay, "2026-07-11", "the session cutoff should use the domestic calendar")
    try expectEqual(store.prepare(current: [first, second], days: 45, now: now).mode, "full", "a failed full upload must remain pending")
    store.acknowledge(initial)

    let unchanged = store.prepare(current: [first, second], days: 45, now: now.addingTimeInterval(60))
    try expectEqual(unchanged.mode, "delta_v1", "acknowledged snapshots should switch to the delta protocol")
    try expect(unchanged.activities.isEmpty, "unchanged sessions should not be uploaded again")
    let compatibilityFull = store.prepare(
        current: [first, second],
        days: 45,
        now: now.addingTimeInterval(90),
        forceFull: true
    )
    try expectEqual(compatibilityFull.mode, "full", "missing server capability must fail closed to a full snapshot")
    try expectEqual(compatibilityFull.activities.count, 2, "compatibility full mode must include every retained session")
    var updated = first
    updated.updatedAt = "2026-08-25T02:01:00.000Z"
    let delta = store.prepare(current: [updated, second], days: 45, now: now.addingTimeInterval(120))
    try expectEqual(delta.activities.map(\.sessionId), ["session-a"], "only changed session metadata should be included")
    try expectEqual(
        store.prepare(current: [updated, second], days: 45, now: now.addingTimeInterval(180)).activities.map(\.sessionId),
        ["session-a"],
        "an unacknowledged delta must be retried after a network failure"
    )
    store.acknowledge(delta)
    try expect(store.prepare(current: [updated, second], days: 45, now: now.addingTimeInterval(240)).activities.isEmpty, "an acknowledged delta should leave no duplicate upload")

    let nextDay = now.addingTimeInterval(24 * 60 * 60)
    let daily = store.prepare(current: [updated, second], days: 45, now: nextDay)
    try expectEqual(daily.mode, "full", "the first successful sync attempt each domestic day should self-heal with a full snapshot")
    try expectEqual(daily.activities.count, 2, "daily full validation should include the retained snapshot")
}

func testTeamServerCapabilityRequiresExactDeltaProtocol() throws {
    let supported = try JSONDecoder().decode(
        TeamServerCapabilities.self,
        from: Data(#"{"status":"ok","sessionActivityProtocol":"delta_v1"}"#.utf8)
    )
    let missing = try JSONDecoder().decode(
        TeamServerCapabilities.self,
        from: Data(#"{"status":"ok"}"#.utf8)
    )
    let unknown = try JSONDecoder().decode(
        TeamServerCapabilities.self,
        from: Data(#"{"sessionActivityProtocol":"delta_v2"}"#.utf8)
    )
    try expect(supported.supportsSessionActivityDelta, "the exact negotiated delta_v1 capability should enable deltas")
    try expect(!missing.supportsSessionActivityDelta, "an older health response must keep full uploads")
    try expect(!unknown.supportsSessionActivityDelta, "an unknown future protocol must not be guessed compatible")

    let legacyResult = try JSONDecoder().decode(
        TeamUsageSyncResult.self,
        from: Data(#"{"status":"ok","accepted":1,"total":1}"#.utf8)
    )
    try expectEqual(legacyResult.sessionActivityModeAccepted, nil, "a legacy response must not acknowledge a local delta cursor")
    try expectEqual(legacyResult.sessionActivityDurable, nil, "a legacy response cannot prove that a delta was durably saved")
    let volatileResult = try JSONDecoder().decode(
        TeamUsageSyncResult.self,
        from: Data(#"{"status":"ok","accepted":1,"total":1,"sessionActivityModeAccepted":"delta_v1","sessionActivityDurable":false}"#.utf8)
    )
    try expectEqual(volatileResult.sessionActivityDurable, false, "an explicitly volatile response must leave the delta pending")
    let acceptedResult = try JSONDecoder().decode(
        TeamUsageSyncResult.self,
        from: Data(#"{"status":"ok","accepted":1,"total":1,"sessionActivityModeAccepted":"delta_v1","sessionActivityDurable":true}"#.utf8)
    )
    try expectEqual(acceptedResult.sessionActivityModeAccepted, "delta_v1", "the server must explicitly echo the accepted activity mode")
    try expectEqual(acceptedResult.sessionActivityDurable, true, "the server must explicitly confirm durable persistence before cursor acknowledgement")
}

func testCollectorsCanReuseOneSessionFileIndexSnapshot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("shared-session-index-tests-\(UUID().uuidString)", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions/2026/08/25", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = ISO8601DateFormatter().date(from: "2026-08-25T03:00:00Z")!
    let first = sessions.appendingPathComponent("rollout-2026-08-25T10-00-00-11111111-1111-1111-1111-111111111111.jsonl")
    try "{}\n".write(to: first, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: first.path)
    let shared = CodexSessionFileIndex(codexHome: root)
    let second = sessions.appendingPathComponent("rollout-2026-08-25T10-30-00-22222222-2222-2222-2222-222222222222.jsonl")
    try "{}\n".write(to: second, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: second.path)

    let counter = CodexSessionFileCounter()
    let sharedResult = counter.collect(codexHome: root, sessionFileIndex: shared, days: 7, now: now)
    let freshResult = counter.collect(codexHome: root, days: 7, now: now)
    try expectEqual(sharedResult.count, 1, "all collectors should observe the caller-owned immutable metadata snapshot")
    try expectEqual(freshResult.count, 2, "the compatibility overload should still build a fresh standalone index")
}

func testAppServerQuotaMapperFallsBackToTopLevelRateLimits() throws {
    let topLevel = appServerSnapshot(primaryUsed: 39, primaryDuration: 300, secondaryUsed: 65, secondaryDuration: 10_080)
    let data = appServerRateLimitsResponse(rateLimits: topLevel)

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: data)

    try expectEqual(quota.weeklyRemainingPercent, Optional(35), "mapper should read top-level weekly window")
}

func testAppServerQuotaMapperRejectsSparkFallback() throws {
    let spark = appServerSnapshot(
        limitID: "codex_bengalfox",
        limitName: "GPT-5.3-Codex-Spark",
        primaryUsed: 0,
        primaryDuration: 300,
        secondaryUsed: 0,
        secondaryDuration: 10_080
    )
    let data = appServerRateLimitsResponse(
        rateLimitsByLimitId: #"{"codex_bengalfox": \#(spark)}"#,
        rateLimits: spark
    )

    do {
        _ = try CodexAppServerQuotaMapper.quotaValues(from: data)
        throw TestFailure(description: "Spark must never be accepted as the primary Codex weekly quota")
    } catch CodexAppServerQuotaError.missingQuota {
        // Expected: wait for an exact Codex bucket instead of publishing 100%.
    }
}

func testAppServerQuotaMapperClampsRemainingPercent() throws {
    let codex = appServerSnapshot(primaryUsed: -20, primaryDuration: 300, secondaryUsed: 125, secondaryDuration: 10_080)
    let data = appServerRateLimitsResponse(rateLimitsByLimitId: #"{"codex": \#(codex)}"#)

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: data)

    try expectEqual(quota.weeklyRemainingPercent, Optional(0), "mapper should clamp remaining below 0")
}

func testAppServerQuotaMapperReadsResetTimes() throws {
    let codex = appServerSnapshot(primaryUsed: 100, primaryDuration: 300, secondaryUsed: 100, secondaryDuration: 10_080)
    let data = appServerRateLimitsResponse(rateLimitsByLimitId: #"{"codex": \#(codex)}"#)

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: data)

    try expectEqual(quota.weeklyRemainingPercent, Optional(0), "mapper should read exhausted weekly quota")
    try expectEqual(quota.weeklyResetsAt, Date(timeIntervalSince1970: 1_781_189_000), "mapper should read weekly reset date")
}

func testAppServerQuotaMapperAllowsWeeklyOnlyWindow() throws {
    let codex = appServerSnapshot(
        primaryUsed: nil,
        primaryDuration: nil,
        secondaryUsed: 55,
        secondaryDuration: 10_080
    )
    let data = appServerRateLimitsResponse(rateLimitsByLimitId: #"{"codex": \#(codex)}"#)

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: data)

    try expectEqual(quota.weeklyRemainingPercent, Optional(45), "mapper should read weekly percent when weekly-only window is present")
    try expectEqual(quota.primaryWindow, .weekly, "a weekly-only response should use the weekly window as primary")
}

func testAppServerQuotaMapperAllowsFiveHourOnlyWindow() throws {
    let codex = appServerSnapshot(
        primaryUsed: 18,
        primaryDuration: 300,
        secondaryUsed: nil,
        secondaryDuration: nil
    )
    let data = appServerRateLimitsResponse(rateLimitsByLimitId: #"{"codex": \#(codex)}"#)

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: data)

    try expectEqual(quota.fiveHourRemainingPercent, Optional(82), "mapper should read a 5-hour-only allowance")
    try expectEqual(quota.weeklyRemainingPercent, nil, "a 5-hour-only response must not invent a weekly value")
    try expectEqual(quota.primaryWindow, .fiveHour, "a 5-hour-only response should use the 5-hour window as primary")
}

func testAppServerQuotaMapperRejectsWindowsWithoutWeeklyDuration() throws {
    let codex = appServerSnapshot(primaryUsed: 30, primaryDuration: nil, secondaryUsed: 55, secondaryDuration: nil)
    let data = appServerRateLimitsResponse(rateLimitsByLimitId: #"{"codex": \#(codex)}"#)

    do {
        _ = try CodexAppServerQuotaMapper.quotaValues(from: data)
        throw TestFailure(description: "mapper should reject windows without an explicit supported duration")
    } catch let error as CodexAppServerQuotaError {
        try expect(error.summaryKey == "missingQuota", "mapper should report missing Codex quota")
    }
}

func testAppServerQuotaMapperIgnoresIndividualLimitRemainingPercent() throws {
    let codex = appServerSnapshot(primaryUsed: 28, primaryDuration: 300, secondaryUsed: 52, secondaryDuration: 10_080, individualRemaining: 3)
    let data = appServerRateLimitsResponse(rateLimitsByLimitId: #"{"codex": \#(codex)}"#)

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: data)

    try expectEqual(quota.weeklyRemainingPercent, Optional(48), "mapper should not use individual limit for weekly quota")
}

func testAppServerJSONRPCLineCodecBuildsRequest() throws {
    let request = try CodexAppServerJSONRPCLineCodec.encodeRequest(id: 2, method: "account/rateLimits/read")
    let text = String(data: request, encoding: .utf8) ?? ""
    let messages = try CodexAppServerJSONRPCLineCodec.decodeMessages(from: request)
    let body = try JSONSerialization.jsonObject(with: messages[0]) as? [String: Any]

    try expect(text.hasSuffix("\n"), "line codec should terminate each JSON-RPC message with newline")
    try expectEqual(body?["id"] as? Int, 2, "line codec should include request id")
    try expectEqual(body?["method"] as? String, "account/rateLimits/read", "line codec should include method")
}

func testAppServerJSONRPCLineCodecDecodesMessagesAndFindsTargetResponse() throws {
    let notification = try CodexAppServerJSONRPCLineCodec.encodeMessage([
        "method": "remoteControl/status/changed",
        "params": ["status": "disabled"]
    ])
    let response = try CodexAppServerJSONRPCLineCodec.encodeMessage([
        "id": 2,
        "result": [
            "rateLimits": NSNull(),
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex",
                    "limitName": NSNull(),
                    "primary": ["usedPercent": 30, "windowDurationMins": 300, "resetsAt": 1781268457],
                    "secondary": ["usedPercent": 5, "windowDurationMins": 10_080, "resetsAt": 1781855629],
                    "credits": NSNull(),
                    "individualLimit": NSNull(),
                    "planType": "plus",
                    "rateLimitReachedType": NSNull()
                ]
            ]
        ]
    ])

    let messages = try CodexAppServerJSONRPCLineCodec.decodeMessages(from: notification + response)
    let target = try CodexAppServerJSONRPCLineCodec.resultData(forID: 2, in: messages)
    let quota = try CodexAppServerQuotaMapper.quotaValues(from: target)

    try expectEqual(messages.count, 2, "line codec should decode each newline-delimited JSON message")
    try expectEqual(quota.weeklyRemainingPercent, Optional(95), "line codec should select target response result")
    try expectEqual(quota.planType, Optional("plus"), "line codec should keep the official membership plan")
}

struct FakeAppServerTransport: CodexAppServerTransport {
    var result: Result<Data, Error>

    func readRateLimits() throws -> Data {
        try result.get()
    }
}

func testAppServerQuotaCollectorUsesTransportFixture() throws {
    let codex = appServerSnapshot(primaryUsed: 28, primaryDuration: 300, secondaryUsed: 52, secondaryDuration: 10_080)
    let data = appServerRateLimitsResponse(rateLimitsByLimitId: #"{"codex": \#(codex)}"#)
    let collector = CodexAppServerQuotaCollector(transport: FakeAppServerTransport(result: .success(data)))

    let quota = try collector.fetchQuota()

    try expectEqual(quota.weeklyRemainingPercent, Optional(48), "collector should return mapped weekly quota")
}

func testAppServerQuotaCollectorPropagatesMissingQuotaWithoutClearingStore() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-app-server-failure-tests-\(UUID().uuidString)", isDirectory: true)
    let store = StateStore(stateURL: directory.appendingPathComponent("state.json"))
    _ = try store.updateQuota(
        weeklyPercent: 34,
        source: "previous",
        now: Date(timeIntervalSince1970: 10_000)
    )
    let collector = CodexAppServerQuotaCollector(transport: FakeAppServerTransport(result: .success(appServerRateLimitsResponse())))

    do {
        _ = try collector.fetchAndUpdate(store: store, now: Date(timeIntervalSince1970: 10_001))
        throw TestFailure(description: "collector should fail when app-server quota is missing")
    } catch CodexAppServerQuotaError.retryExhausted(let attempts, let lastError) {
        try expectEqual(attempts, 3, "missing quota should be retried before failing")
        try expectEqual(lastError.description, CodexAppServerQuotaError.missingQuota.description, "retry error should preserve missing quota final cause")
    }

    let snapshot = store.read()
    try expectEqual(snapshot.quota?.weeklyRemainingPercent, 34, "failed app-server fetch should keep previous weekly quota")
    try expectEqual(snapshot.quota?.source, "previous", "failed app-server fetch should keep previous quota source")
}

func testAppServerQuotaErrorsDescribeSpecificTimeouts() throws {
    try expectEqual(
        CodexAppServerQuotaError.initializeTimedOut(timeout: 50).description,
        "initialize timed out after 50s",
        "initialize timeout should name phase and duration"
    )
    try expectEqual(
        CodexAppServerQuotaError.rateLimitsTimedOut(timeout: 20).description,
        "rate limits read timed out after 20s",
        "rate limits timeout should name phase and duration"
    )
    try expectEqual(
        CodexAppServerQuotaError.retryExhausted(attempts: 3, lastError: .initializeTimedOut(timeout: 50)).description,
        "App-server quota failed after 3 attempts: initialize timed out after 50s",
        "retry exhausted error should include attempts and final cause"
    )
}

func testAppServerBinaryDiscoveryFindsBundledChatGPTCodex() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-binary-discovery-tests-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    let applications = root.appendingPathComponent("Applications", isDirectory: true)
    let bundledCodex = applications.appendingPathComponent("ChatGPT.app/Contents/Resources/codex")
    try FileManager.default.createDirectory(at: bundledCodex.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: bundledCodex)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledCodex.path)
    defer { try? FileManager.default.removeItem(at: root) }

    let discovered = ProcessCodexAppServerTransport.defaultCodexBinary(
        home: home,
        environment: [:],
        applicationDirectories: [applications]
    )

    try expectEqual(discovered, bundledCodex.path, "GUI clients should find the Codex binary bundled inside ChatGPT.app")
}

func testQuotaDiagnosticContainsOnlyStatusCodeAndSource() throws {
    let diagnostic = TeamQuotaDiagnostic(
        status: "unavailable",
        checkedAt: Date(timeIntervalSince1970: 1_787_389_000),
        source: nil,
        errorCode: "retryExhausted:launchFailed"
    )
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnostic)) as? [String: Any]

    try expectEqual(object?["status"] as? String, "unavailable", "quota diagnostic should include availability status")
    try expectEqual(object?["errorCode"] as? String, "retryExhausted:launchFailed", "quota diagnostic should include only a stable error code")
    try expectEqual(Set(object?.keys.map { $0 } ?? []), Set(["status", "checkedAt", "errorCode"]), "quota diagnostic must not include local paths or raw stderr")
}

final class SequencedAppServerTransport: CodexAppServerTransport {
    private var results: [Result<Data, Error>]
    private(set) var attempts = 0

    init(results: [Result<Data, Error>]) {
        self.results = results
    }

    func readRateLimits() throws -> Data {
        attempts += 1
        guard !results.isEmpty else {
            throw CodexAppServerQuotaError.missingQuota
        }
        return try results.removeFirst().get()
    }
}

func testAppServerQuotaCollectorRetriesTwiceAndSucceedsOnThirdAttempt() throws {
    let codex = appServerSnapshot(primaryUsed: 28, primaryDuration: 300, secondaryUsed: 52, secondaryDuration: 10_080)
    let data = appServerRateLimitsResponse(rateLimitsByLimitId: #"{"codex": \#(codex)}"#)
    let transport = SequencedAppServerTransport(results: [
        .failure(CodexAppServerQuotaError.initializeTimedOut(timeout: 50)),
        .failure(CodexAppServerQuotaError.rateLimitsTimedOut(timeout: 20)),
        .success(data)
    ])
    var sleeps: [TimeInterval] = []
    let collector = CodexAppServerQuotaCollector(
        transport: transport,
        retryPolicy: .init(retries: 2, backoffSeconds: [1, 3]),
        sleep: { sleeps.append($0) }
    )

    let quota = try collector.fetchQuota()

    try expectEqual(transport.attempts, 3, "collector should try once plus two retries")
    try expectEqual(sleeps, [1, 3], "collector should use planned retry backoff")
    try expectEqual(quota.weeklyRemainingPercent, Optional(48), "collector should return quota from successful retry")
}

func testAppServerQuotaCollectorFailsAfterThreeAttemptsAndPreservesQuota() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-app-server-retry-failure-tests-\(UUID().uuidString)", isDirectory: true)
    let store = StateStore(stateURL: directory.appendingPathComponent("state.json"))
    _ = try store.updateQuota(
        weeklyPercent: 34,
        source: "previous",
        now: Date(timeIntervalSince1970: 11_000)
    )
    let transport = SequencedAppServerTransport(results: [
        .failure(CodexAppServerQuotaError.initializeTimedOut(timeout: 50)),
        .failure(CodexAppServerQuotaError.initializeTimedOut(timeout: 50)),
        .failure(CodexAppServerQuotaError.initializeTimedOut(timeout: 50))
    ])
    let collector = CodexAppServerQuotaCollector(
        transport: transport,
        retryPolicy: .init(retries: 2, backoffSeconds: [1, 3]),
        sleep: { _ in }
    )

    do {
        _ = try collector.fetchAndUpdate(store: store, now: Date(timeIntervalSince1970: 11_001))
        throw TestFailure(description: "collector should fail after exhausting retries")
    } catch CodexAppServerQuotaError.retryExhausted(let attempts, let lastError) {
        try expectEqual(attempts, 3, "retry error should report total attempts")
        try expectEqual(lastError.description, "initialize timed out after 50s", "retry error should preserve final cause")
    }

    let snapshot = store.read()
    try expectEqual(transport.attempts, 3, "collector should stop after three attempts")
    try expectEqual(snapshot.quota?.weeklyRemainingPercent, 34, "failed retries should keep previous weekly quota")
    try expectEqual(snapshot.quota?.source, "previous", "failed retries should keep previous quota source")
}

func testQuotaRefreshCoordinatorPreventsConcurrentRefreshes() throws {
    let coordinator = QuotaRefreshCoordinator()

    try expectEqual(coordinator.beginRefresh(), true, "first refresh should start")
    try expectEqual(coordinator.beginRefresh(), false, "second refresh should be skipped while in flight")
    coordinator.endRefresh(success: true, now: Date(timeIntervalSince1970: 12_000))
    try expectEqual(coordinator.beginRefresh(), true, "refresh should start after previous one ends")
}

func testQuotaRefreshCoordinatorThrottlesRepeatedFailureLogs() throws {
    let coordinator = QuotaRefreshCoordinator(logThrottleSeconds: 600)
    let now = Date(timeIntervalSince1970: 12_000)

    let first = coordinator.failureLogLine(
        error: CodexAppServerQuotaError.initializeTimedOut(timeout: 50),
        now: now
    )
    let duplicate = coordinator.failureLogLine(
        error: CodexAppServerQuotaError.initializeTimedOut(timeout: 50),
        now: now.addingTimeInterval(60)
    )
    let different = coordinator.failureLogLine(
        error: CodexAppServerQuotaError.rateLimitsTimedOut(timeout: 20),
        now: now.addingTimeInterval(120)
    )
    coordinator.endRefresh(success: true, now: now.addingTimeInterval(180))
    let afterSuccess = coordinator.failureLogLine(
        error: CodexAppServerQuotaError.rateLimitsTimedOut(timeout: 20),
        now: now.addingTimeInterval(240)
    )

    try expectEqual(first != nil, true, "first failure should be logged")
    try expectEqual(duplicate == nil, true, "same failure should be throttled within 10 minutes")
    try expectEqual(different != nil, true, "different failure should bypass throttle")
    try expectEqual(afterSuccess != nil, true, "success should reset failure throttle")
}

func testQuotaRefreshCountdownUsesHoursBelowOneDay() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    try expectEqual(
        QuotaDisplayFormatter.refreshCountdownText(until: now.addingTimeInterval(5 * 86_400 + 18 * 3_600), now: now),
        "5天后刷新",
        "refresh countdown should only show whole days at or above one day"
    )
    try expectEqual(
        QuotaDisplayFormatter.refreshCountdownText(until: now.addingTimeInterval(18 * 3_600), now: now),
        "18小时后刷新",
        "refresh countdown below one day should only show hours"
    )
    try expectEqual(
        QuotaDisplayFormatter.refreshCountdownText(until: now.addingTimeInterval(30), now: now),
        "1小时后刷新",
        "refresh countdown below one hour should round up to one hour"
    )
}

func testQuotaDisplayFormatterUsesNaturalChineseDate() throws {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)
    components.year = 2026
    components.month = 6
    components.day = 3
    components.hour = 9
    components.minute = 5

    let date = components.date!
    let text = QuotaDisplayFormatter.absoluteDateTimeText(date, timeZone: components.timeZone!)

    try expectEqual(text, "6月3日 09:05", "date text should not zero-pad month or day")
}

func testTeamSyncParsesEnvironmentFile() throws {
    let values = TeamSyncConfiguration.parseEnvironmentFile("""
    WANHE_ENDPOINT="https://meet.example.com/api/usage"
    WANHE_USER_NAME='张璐'
    WANHE_COLLECT_DAYS=45
    # ignored
    """)
    try expectEqual(values["WANHE_ENDPOINT"], "https://meet.example.com/api/usage", "team sync should remove double quotes")
    try expectEqual(values["WANHE_USER_NAME"], "张璐", "team sync should remove single quotes")
    try expectEqual(values["WANHE_COLLECT_DAYS"], "45", "team sync should read plain values")
}

func testTeamDeviceUsesHardwareFamilyNames() throws {
    try expectEqual(TeamDeviceIdentity.friendlyProductName(for: "MacBookPro18,3"), "MacBook Pro", "MacBook Pro model should have a readable label")
    try expectEqual(TeamDeviceIdentity.friendlyProductName(for: "MacStudio1,1"), "Mac Studio", "Mac Studio model should have a readable label")
    try expectEqual(TeamDeviceIdentity.friendlyProductName(for: "Macmini9,1"), "Mac mini", "Mac mini model should have a readable label")
}

func testTeamUsageCollectorBuildsDailySessionDelta() throws {
    let configuration = TeamSyncConfiguration(
        endpoint: URL(string: "https://meet.example.com/api/usage")!,
        token: "test",
        userID: "lu",
        userName: "张璐",
        team: "万合创新局",
        role: "Codex 使用者",
        codexHome: URL(fileURLWithPath: "/tmp/codex")
    )
    let device = TeamDeviceIdentity(id: "mac-1", kind: "mac", name: "Mac Studio", modelIdentifier: "Mac14,13")
    let data = """
    {"type":"session_meta","payload":{"model":"gpt-5.6-sol"}}
    {"type":"event_msg","timestamp":"2026-08-21T01:00:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":20,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":5,"total_tokens":100}}}}
    {"type":"event_msg","timestamp":"2026-08-21T02:00:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":120,"cached_input_tokens":30,"cache_write_input_tokens":0,"output_tokens":30,"reasoning_output_tokens":8,"total_tokens":150}}}}
    {"type":"event_msg","timestamp":"2026-08-21T15:59:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":145,"cached_input_tokens":35,"cache_write_input_tokens":0,"output_tokens":36,"reasoning_output_tokens":9,"total_tokens":180}}}}
    {"type":"event_msg","timestamp":"2026-08-21T16:01:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":175,"cached_input_tokens":40,"cache_write_input_tokens":0,"output_tokens":45,"reasoning_output_tokens":11,"total_tokens":220}}}}
    """.data(using: .utf8)!
    let sessions = CodexTeamUsageCollector().parseSessionData(
        data,
        sessionID: "session-1",
        configuration: configuration,
        device: device
    )
    try expectEqual(sessions.count, 2, "collector should split one session at Beijing midnight")
    try expectEqual(sessions.map(\.day), ["2026-08-21", "2026-08-22"], "collector should use Beijing calendar days")
    try expectEqual(sessions.map(\.utcDay), ["2026-08-21", "2026-08-21"], "collector should retain the matching official UTC bucket")
    try expectEqual(sessions.map(\.totalTokens), [180, 40], "collector should add cumulative deltas without double counting")
    try expectEqual(sessions.first?.model, "gpt-5.6-sol", "collector should preserve the session model")
    try expectEqual(sessions.first?.deviceId, "mac-1", "collector should use the hardware device id")
}

func testOneTimeUsageBackfillSelectsOnlyAugust25AndAcknowledges() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("one-time-usage-backfill-\(UUID().uuidString)", isDirectory: true)
    let marker = root.appendingPathComponent("backfill.done")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let template = try JSONDecoder().decode(TeamUsageSession.self, from: Data(#"""
    {
      "userId":"zlu","userName":"张璐","team":"万合创新局","role":"Codex 使用者","avatar":"张璐",
      "deviceId":"mac-1","sessionId":"session-1","day":"2026-08-25","utcDay":"2026-08-25",
      "model":"gpt-5.6-sol","inputTokens":80,"cachedInputTokens":20,"cacheWriteInputTokens":0,
      "outputTokens":20,"reasoningOutputTokens":5,"totalTokens":100,"updatedAt":"2026-08-25T15:59:00.000Z"
    }
    """#.utf8))
    var otherDay = template
    otherDay.day = "2026-08-24"
    let now = ISO8601DateFormatter().date(from: "2026-08-25T17:00:00Z")!
    let store = OneTimeUsageBackfillStore(markerURL: marker)
    try expectEqual(store.selectTargetDay(from: [otherDay, template], now: now), [template], "one-time recovery should upload only August 25")
    store.acknowledge(now: now)
    try expect(store.isAcknowledged, "a successful recovery upload should create its durable marker")
    try expect(store.selectTargetDay(from: [template], now: now).isEmpty, "an acknowledged recovery must not repeat in the two-minute heartbeat")
}

func testTeamQuotaReportUsesWeeklyPercentAndReset() throws {
    let reset = Date(timeIntervalSince1970: 2_000)
    let report = TeamQuotaReport(
        weeklyRemainingPercent: 79,
        weeklyResetsAt: reset,
        updatedAt: Date(timeIntervalSince1970: 1_000),
        source: CodexSessionQuotaCollector.source,
        limitID: CodexSessionQuotaCollector.primaryLimitID,
        planType: "pro"
    )
    try expectEqual(report.weeklyRemainingPercent, 79, "team quota should keep weekly remaining percent")
    try expectEqual(report.weeklyUsedPercent, 21, "team quota should derive weekly used percent")
    try expect(report.weeklyResetsAt != nil, "team quota should include reset time")
    try expectEqual(report.weeklyResetsAtDate, reset, "team quota should parse its reset time for client synchronization")
    try expectEqual(report.updatedAtDate, Date(timeIntervalSince1970: 1_000), "team quota should parse its update time for freshness checks")
    try expectEqual(report.source, CodexSessionQuotaCollector.source, "team quota should preserve its source for server-side echo protection")
    try expectEqual(report.limitID, CodexSessionQuotaCollector.primaryLimitID, "team quota should explicitly identify the primary Codex limit")
    try expectEqual(report.planType, "pro", "team quota should upload the official membership plan")

    let unverified = StateSnapshot(
        updatedAt: Date(timeIntervalSince1970: 1_000),
        quota: QuotaSnapshot(
            weeklyRemainingPercent: 100,
            weeklyResetsAt: reset,
            source: CodexSessionQuotaCollector.source,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    )
    try expectEqual(TeamQuotaReport.from(snapshot: unverified), nil, "a cached quota without an exact Codex limit id must not be uploaded")
}

func testTeamQuotaReportPreservesDualWindowsAndPrimary() throws {
    let fiveHourReset = Date(timeIntervalSince1970: 2_000)
    let weeklyReset = Date(timeIntervalSince1970: 3_000)
    let report = TeamQuotaReport(
        weeklyRemainingPercent: 47,
        weeklyResetsAt: weeklyReset,
        fiveHourRemainingPercent: 82,
        fiveHourResetsAt: fiveHourReset,
        primaryWindow: .fiveHour,
        updatedAt: Date(timeIntervalSince1970: 1_000),
        source: CodexSessionQuotaCollector.source,
        limitID: CodexSessionQuotaCollector.primaryLimitID,
        planType: "plus"
    )

    try expectEqual(report.fiveHourUsedPercent, 18, "team quota should derive 5-hour used percent")
    try expectEqual(report.weeklyUsedPercent, 53, "team quota should derive weekly used percent")
    try expectEqual(report.preferredWindow?.kind, .fiveHour, "team quota should preserve the actual primary window")
    try expectEqual(report.availableWindows.map(\.kind), [.fiveHour, .weekly], "team quota should retain both official windows")
}

func testTeamRankingURLUsesWebsiteOrigin() throws {
    let configuration = TeamSyncConfiguration(
        endpoint: URL(string: "https://meet.example.com/api/usage")!, token: "test", userID: "lu", userName: "张璐",
        team: "万合创新局", role: "Codex 使用者", codexHome: URL(fileURLWithPath: "/tmp/codex")
    )
    let service = TeamUsageSyncService(configuration: configuration)
    try expectEqual(service.websiteURL.absoluteString, "https://meet.example.com/", "website link should use the ranking origin")
    try expectEqual(service.rankingsURL().absoluteString, "https://meet.example.com/api/rankings?range=today", "menu should fetch today's ranking")
    try expectEqual(service.rankingsURL(range: "week").absoluteString, "https://meet.example.com/api/rankings?range=week", "menu should fetch this week's ranking")
    try expectEqual(service.rankingsURL(range: "month").absoluteString, "https://meet.example.com/api/rankings?range=month", "menu should fetch this month's ranking")
    try expectEqual(service.presenceURL.absoluteString, "https://meet.example.com/api/presence", "presence should use a lightweight endpoint on the ranking origin")
    let activeAt = Date(timeIntervalSince1970: 1_700_000_000)
    let taskActiveAt = activeAt.addingTimeInterval(3)
    let payload = service.makePresencePayload(lastActiveAt: activeAt, taskActiveAt: taskActiveAt, now: activeAt.addingTimeInterval(5))
    try expectEqual(payload.collector, "wanhe-codex-mac-presence", "presence payload should identify the lightweight collector")
    try expect(payload.lastActiveAt?.hasPrefix("2023-11-14T22:13:20") == true, "presence payload should contain the latest human activity timestamp")
    try expect(payload.taskActiveAt?.hasPrefix("2023-11-14T22:13:23") == true, "presence payload should contain the latest running-task activity timestamp")
    let marker = TeamUsageSyncService.presenceMarkerURL(home: URL(fileURLWithPath: "/tmp/member-home"))
    try expectEqual(marker.path, "/tmp/member-home/Library/Application Support/CodexTrafficLight/last-activity", "presence should read the monitor marker without scanning sessions")
    let taskMarker = TeamUsageSyncService.taskActivityMarkerURL(home: URL(fileURLWithPath: "/tmp/member-home"))
    try expectEqual(taskMarker.path, "/tmp/member-home/Library/Application Support/CodexTrafficLight/last-task-activity", "presence should read task activity independently from human activity")
}

func testTeamRankingDecodesLegacyTodayActivity() throws {
    let data = """
    {"updatedAt":"2026-08-21 13:50","members":[{"id":"zlu","name":"张璐","tokens":1200,"sessions":12,"lastActive":"13:13"}]}
    """.data(using: .utf8)!
    let ranking = try JSONDecoder().decode(TeamRankingSnapshot.self, from: data)
    try expectEqual(ranking.members.first?.tokens, 1_200, "legacy ranking should preserve today's token total")
    try expectEqual(ranking.members.first?.lastActive, "13:13", "legacy ranking should expose its last update time")
    try expectEqual(ranking.members.first?.officialUsage, nil, "legacy ranking may omit official metadata")
}

func testTeamRankingDecodesRealtimePresence() throws {
    let data = """
    {"updatedAt":"2026-08-22 21:30","members":[{"id":"zlu","name":"张璐","tokens":1200,"sessions":12,"lastActive":"21:30","online":true}]}
    """.data(using: .utf8)!
    let ranking = try JSONDecoder().decode(TeamRankingSnapshot.self, from: data)
    try expectEqual(ranking.members.first?.online, true, "team ranking should expose the realtime presence flag")
}

func testTeamRankingDecodesMemberWeeklyQuota() throws {
    let data = """
    {"updatedAt":"2026-08-21 13:50","members":[{"id":"zlu","name":"张璐","tokens":1200,"sessions":12,"weeklyQuota":{"weeklyRemainingPercent":75,"weeklyUsedPercent":25,"weeklyResetsAt":"2026-08-27T03:33:23.000Z","updatedAt":"2026-08-21T08:50:31.586Z"}}]}
    """.data(using: .utf8)!
    let ranking = try JSONDecoder().decode(TeamRankingSnapshot.self, from: data)
    try expectEqual(ranking.members.first?.weeklyQuota?.weeklyRemainingPercent, 75, "team ranking should expose each member's weekly remaining percent")
    try expectEqual(ranking.members.first?.weeklyQuota?.weeklyResetsAt, "2026-08-27T03:33:23.000Z", "team ranking should expose each member's weekly reset time")
    try expectEqual(ranking.weeklyQuota(for: "ZLU")?.weeklyRemainingPercent, 75, "status bars should resolve the shared member quota case-insensitively")
    try expectEqual(ranking.weeklyQuota(for: "missing"), nil, "unknown members should not inherit another person's quota")
}

func testTeamRankingDecodesFiveHourQuota() throws {
    let data = """
    {"updatedAt":"2026-08-26 13:50","members":[{"id":"zhanghaiqiang","name":"张海强","tokens":1200,"sessions":12,"weeklyQuota":{"fiveHourRemainingPercent":82,"fiveHourUsedPercent":18,"fiveHourResetsAt":"2026-08-26T08:33:23.000Z","primaryWindow":"five_hour","updatedAt":"2026-08-26T03:50:31.586Z","planType":"plus"}}]}
    """.data(using: .utf8)!
    let ranking = try JSONDecoder().decode(TeamRankingSnapshot.self, from: data)
    let quota = ranking.quota(for: "ZHANGHAIQIANG")

    try expectEqual(quota?.fiveHourRemainingPercent, 82, "team ranking should expose a member's 5-hour remaining percent")
    try expectEqual(quota?.weeklyRemainingPercent, nil, "5-hour-only ranking data must not invent a weekly value")
    try expectEqual(quota?.preferredWindow?.kind, .fiveHour, "status bars should display the actual 5-hour primary window")
}

func testTeamRankingDistinguishesJoinedMemberFromInvitePlaceholder() throws {
    let data = """
    {"updatedAt":"2026-08-21 18:30","members":[
      {"id":"qiubo","name":"仇博","tokens":0,"sessions":0,"joined":true,"tokenSource":"collector","devices":[{"id":"device-1","name":"MacBook Pro"}]},
      {"id":"yangang","name":"杨昂","tokens":0,"sessions":0,"joined":false,"tokenSource":"collector","devices":[],"officialUsage":null,"weeklyQuota":null}
    ]}
    """.data(using: .utf8)!
    let ranking = try JSONDecoder().decode(TeamRankingSnapshot.self, from: data)
    try expectEqual(ranking.members[0].hasEverJoined, true, "a registered device means the member has joined even before first usage")
    try expectEqual(ranking.members[1].hasEverJoined, false, "an invite placeholder without device or usage has not joined")
    let sorted = ranking.members.sorted {
        if $0.hasEverJoined != $1.hasEverJoined { return $0.hasEverJoined }
        if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
        return $0.sessions > $1.sessions
    }
    try expectEqual(sorted.map(\.id), ["qiubo", "yangang"], "joined members should rank ahead of invite placeholders even with zero tokens")
}

func testAvatarDiskCachePersistsByRemoteURL() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = AvatarDiskCache(directoryURL: root.appendingPathComponent("avatars"))
    defer { try? FileManager.default.removeItem(at: root) }

    let firstURL = URL(string: "https://c.wanhe.cn/avatars/58.png")!
    let secondURL = URL(string: "https://c.wanhe.cn/avatars/193.png")!
    let imageData = Data([0x89, 0x50, 0x4E, 0x47])
    try cache.store(imageData, for: firstURL)

    try expectEqual(cache.data(for: firstURL), imageData, "avatar cache should return persisted data without a network request")
    try expect(cache.fileURL(for: firstURL) != cache.fileURL(for: secondURL), "different avatar URLs should use different cache files")
    try expectEqual(cache.fileURL(for: firstURL).pathExtension, "png", "avatar cache should preserve a safe image extension")
}

func testOfficialCodexUsageParsesDailyBuckets() throws {
    let data = """
    {"summary":{"lifetimeTokens":1200,"peakDailyTokens":700},"dailyUsageBuckets":[{"startDate":"2026-08-20","tokens":500},{"startDate":"2026-08-21","tokens":700}],"threadUsage":null}
    """.data(using: .utf8)!
    let report = try OfficialCodexUsageCollector.parse(data, now: Date(timeIntervalSince1970: 1_000))
    try expectEqual(report.lifetimeTokens, 1_200, "official usage should read lifetime tokens")
    try expectEqual(report.dailyUsageBuckets.last?.tokens, 700, "official usage should read daily token buckets")
    try expectEqual(report.dataThrough, "2026-08-21", "official usage should expose its latest settled day")
}

func testSessionCounterUsesLocalFilenameAndMetadataWithoutReadingContents() throws {
    let counter = CodexSessionFileCounter()
    let date = counter.timestampFromFilename("rollout-2026-08-20T15-20-05-01a01e0a-969e-7b82-82e3-cb289445d9be.jsonl")
    try expect(date != nil, "session counter should read the timestamp encoded in a filename")
    try expectEqual(Int(date!.timeIntervalSince1970), 1_787_210_405, "session counter should treat the filename timestamp as Shanghai local time")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessions = root.appendingPathComponent("sessions/2026/08/20")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = sessions.appendingPathComponent("rollout-2026-08-20T15-20-05-01a01e0a-969e-7b82-82e3-cb289445d9be.jsonl")
    try "private conversation text that must not be inspected".write(to: file, atomically: true, encoding: .utf8)
    let modifiedAt = ISO8601DateFormatter().date(from: "2026-08-21T14:28:00Z")!
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)

    let activity = counter.collect(codexHome: root, days: 7, now: modifiedAt).first
    try expectEqual(activity?.day, "2026-08-20", "session day should continue to come from the filename")
    let activityFormatter = ISO8601DateFormatter()
    activityFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let activityDate = activity?.updatedAt.flatMap { activityFormatter.date(from: $0) }
    try expectEqual(Int(activityDate?.timeIntervalSince1970 ?? 0), Int(modifiedAt.timeIntervalSince1970), "recent activity should come from file metadata")
    let startedDate = activity?.startedAt.flatMap { activityFormatter.date(from: $0) }
    try expectEqual(Int(startedDate?.timeIntervalSince1970 ?? 0), Int(date!.timeIntervalSince1970), "session start should come from filename metadata")
}

func testGrindHistoryCollectorReadsOnlyEventTimestamps() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessions = root.appendingPathComponent("sessions/2026/08/22")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = sessions.appendingPathComponent("rollout-2026-08-22T00-55-00-01a01e0a-969e-7b82-82e3-cb289445d9be.jsonl")
    let contents = [
        #"{"timestamp":"2026-08-20T22:25:00.000Z","type":"session_meta","payload":{"private":"do not inspect"}}"#,
        #"{"timestamp":"2026-08-21T15:15:00.000Z","type":"event_msg","payload":{"type":"agent_message","private":"do not inspect"}}"#,
        #"{"timestamp":"2026-08-21T17:56:28.000Z","type":"event_msg","payload":{"type":"user_message","private":"do not inspect"}}"#,
        #"{"timestamp":"2026-08-21T18:04:52.000Z","type":"response_item","payload":{"type":"message","role":"user","private":"do not inspect"}}"#,
        #"{"timestamp":"2026-08-21T19:06:08.000Z","type":"event_msg","payload":{"type":"agent_message","private":"do not inspect"}}"#,
        #"{"timestamp":"2026-08-21T22:14:00.000Z","type":"event_msg","payload":{"type":"agent_message","private":"do not inspect"}}"#,
    ].joined(separator: "\n")
    try contents.write(to: file, atomically: true, encoding: .utf8)
    let morningFile = sessions.appendingPathComponent("rollout-2026-08-22T09-42-45-01a02722-77db-79d0-af46-8e9267c19584.jsonl")
    try [
        #"{"timestamp":"2026-08-22T01:42:47.000Z","type":"session_meta","payload":{"private":"do not inspect"}}"#,
        #"{"timestamp":"2026-08-22T02:30:00.000Z","type":"response_item","payload":{"type":"message","role":"user","private":"do not inspect"}}"#,
    ].joined(separator: "\n")
        .write(to: morningFile, atomically: true, encoding: .utf8)
    let continuedConversation = sessions.appendingPathComponent("rollout-2026-08-21T19-30-00-01a025a7-5636-7730-a6f7-b0c98fae3d95.jsonl")
    try [
        #"{"timestamp":"2026-08-21T11:30:00.000Z","type":"session_meta","payload":{}}"#,
        #"{"timestamp":"2026-08-22T02:03:00.000Z","type":"event_msg","payload":{"type":"user_message","message":"first authored turn"}}"#,
        #"{"timestamp":"2026-08-22T02:03:00.500Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"first authored turn"}]}}"#,
        #"{"timestamp":"2026-08-22T02:08:12.000Z","type":"event_msg","payload":{"type":"user_message"}}"#,
        #"{"timestamp":"2026-08-22T02:08:12.400Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"second authored turn"}]}}"#,
    ].joined(separator: "\n")
        .write(to: continuedConversation, atomically: true, encoding: .utf8)
    let environmentOnlyConversation = sessions.appendingPathComponent("rollout-2026-08-22T07-31-00-01a02710-a3b7-7a12-8f5e-1de50869504a.jsonl")
    try #"{"timestamp":"2026-08-21T23:31:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Continue where you left off. The previous model attempt failed or timed out."},{"type":"input_text","text":"自动重放的原始任务内容不应计为真人开工"},{"type":"input_image","image_url":"hidden"}]}}"#
        .write(to: environmentOnlyConversation, atomically: true, encoding: .utf8)
    let laterNewConversation = sessions.appendingPathComponent("rollout-2026-08-22T10-57-13-01a02766-a3b7-7a12-8f5e-1de50869504a.jsonl")
    try [
        #"{"timestamp":"2026-08-22T02:57:13.000Z","type":"session_meta","payload":{}}"#,
        #"{"timestamp":"2026-08-22T02:57:20.000Z","type":"response_item","payload":{"type":"message","role":"user"}}"#,
    ].joined(separator: "\n")
        .write(to: laterNewConversation, atomically: true, encoding: .utf8)
    let afternoonOnly = sessions.appendingPathComponent("rollout-2026-08-23T14-15-00-01a027ce-7a41-75a3-9277-aaf9945bc022.jsonl")
    try #"{"timestamp":"2026-08-23T06:15:09.000Z","type":"response_item","payload":{"type":"message","role":"user"}}"#
        .write(to: afternoonOnly, atomically: true, encoding: .utf8)
    let now = ISO8601DateFormatter().date(from: "2026-08-23T08:00:00Z")!
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: morningFile.path)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: continuedConversation.path)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: environmentOnlyConversation.path)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: laterNewConversation.path)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: afternoonOnly.path)

    let report = CodexGrindHistoryCollector().collectDetailed(codexHome: root, days: 30, now: now)
    try expectEqual(report.history, [
        TeamGrindHistoryDay(grindDay: "2026-08-22", dayGrindTime: "10:03", nightGrindTime: nil),
    ], "grind history should require authored text and ignore attachment-only or environment-only setup")
    let continued = report.sessions.first { $0.sessionId == "01a025a7-5636-7730-a6f7-b0c98fae3d95" && $0.day == "2026-08-22" }
    try expectEqual(continued?.dayTurnCount, 2, "interaction summary should deduplicate duplicate encodings of one user turn")
    try expectEqual(continued?.firstDayUserAt, "2026-08-22T02:03:00.500Z", "interaction summary should retain the first authored turn in an old conversation")
    try expectEqual(continued?.lastDayUserAt, "2026-08-22T02:08:12.400Z", "interaction summary should retain the last authored turn in an old conversation")
}

func testTodayLiveCollectorStartsAtEOFAndCountsOnlyAppendedUsage() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessions = root.appendingPathComponent("codex/sessions/2026/08/21")
    let stateURL = root.appendingPathComponent("state/today-live.json")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = sessions.appendingPathComponent("rollout-2026-08-21T01-00-00-11111111-1111-1111-1111-111111111111.jsonl")
    try "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"private text\"}}\n".write(to: file, atomically: true, encoding: .utf8)
    let formatter = ISO8601DateFormatter()
    let now = formatter.date(from: "2026-08-21T03:00:00Z")!
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    let collector = TodayCodexUsageCollector(stateURL: stateURL)

    let baseline = collector.collect(codexHome: root.appendingPathComponent("codex"), now: now)
    try expectEqual(baseline.tokens, 0, "collector should baseline existing files at EOF")

    let appended = "{\"type\":\"event_msg\",\"timestamp\":\"2026-08-21T03:01:00.000Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":50},\"total_token_usage\":{\"total_tokens\":150}}}}\n"
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(appended.utf8))
    try handle.close()
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: file.path)

    let updated = collector.collect(codexHome: root.appendingPathComponent("codex"), now: now.addingTimeInterval(60))
    try expectEqual(updated.tokens, 50, "collector should count the newly appended turn only")
    try expectEqual(updated.utcDay, nil, "a mid-day baseline must not pretend it observed the whole settlement day")
    try expectEqual(updated.utcTokens, nil, "UTC continuation stays unavailable until the first observed rollover")
    let stateInode = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.systemFileNumber] as? NSNumber
    let unchanged = collector.collect(codexHome: root.appendingPathComponent("codex"), now: now.addingTimeInterval(120))
    let unchangedStateInode = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.systemFileNumber] as? NSNumber
    try expectEqual(unchanged.tokens, 50, "collector should not count an appended event twice")
    try expectEqual(unchangedStateInode, stateInode, "unchanged token tails should not rewrite collector state")
    let persisted = try String(contentsOf: stateURL, encoding: .utf8)
    try expect(!persisted.contains("private text"), "collector state must never persist conversation text")
    try expect(persisted.contains("11111111-1111-1111-1111-111111111111"), "active cumulative session state must survive pruning")
}

func testTodayLiveCollectorSplitsLocalAndUTCDayAtSettlementBoundary() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessions = root.appendingPathComponent("codex/sessions/2026/08/25")
    let stateURL = root.appendingPathComponent("state/today-live.json")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = sessions.appendingPathComponent("rollout-2026-08-25T07-58-00-22222222-2222-2222-2222-222222222222.jsonl")
    try "{\"type\":\"session_meta\",\"payload\":{}}\n".write(to: file, atomically: true, encoding: .utf8)
    let formatter = ISO8601DateFormatter()
    let baselineTime = formatter.date(from: "2026-08-24T23:58:00Z")!
    try FileManager.default.setAttributes([.modificationDate: baselineTime], ofItemAtPath: file.path)
    let collector = TodayCodexUsageCollector(stateURL: stateURL)
    _ = collector.collect(codexHome: root.appendingPathComponent("codex"), now: baselineTime)

    let lines = [
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-08-24T23:59:00.000Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":40},\"total_token_usage\":{\"total_tokens\":100}}}}",
        "{\"type\":\"event_msg\",\"timestamp\":\"2026-08-25T00:01:00.000Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":60},\"total_token_usage\":{\"total_tokens\":160}}}}",
    ].joined(separator: "\n") + "\n"
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(lines.utf8))
    try handle.close()
    let collectedAt = formatter.date(from: "2026-08-25T00:02:00Z")!
    try FileManager.default.setAttributes([.modificationDate: collectedAt], ofItemAtPath: file.path)

    let report = collector.collect(codexHome: root.appendingPathComponent("codex"), now: collectedAt)
    try expectEqual(report.day, "2026-08-25", "local calendar day should remain unchanged across the settlement boundary")
    try expectEqual(report.tokens, 100, "local-day total should include usage on both sides of the boundary")
    try expectEqual(report.utcDay, "2026-08-25", "UTC settlement day should roll over independently")
    try expectEqual(report.utcTokens, 60, "UTC continuation should include only usage after its own rollover")
}

func testTodayLiveCollectorDoesNotTrustLegacyMidDayStateAsUTCBaseline() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let stateURL = root.appendingPathComponent("state/today-live.json")
    try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyState = """
    {"initialized":true,"day":"2026-08-25","tokens":75,"updatedAt":"2026-08-25T02:59:00.000Z","fileOffsets":{},"sessionCumulativeTokens":{"stale-session":123}}
    """
    try legacyState.write(to: stateURL, atomically: true, encoding: .utf8)
    let now = ISO8601DateFormatter().date(from: "2026-08-25T03:00:00Z")!

    let report = TodayCodexUsageCollector(stateURL: stateURL).collect(
        codexHome: root.appendingPathComponent("codex"),
        now: now
    )
    try expectEqual(report.tokens, 75, "legacy local-day usage should survive migration")
    try expectEqual(report.utcDay, nil, "legacy state must not invent a complete UTC-day baseline")
    try expectEqual(report.utcTokens, nil, "legacy state must wait for a real rollover before reporting UTC usage")
    try expect(!(try String(contentsOf: stateURL, encoding: .utf8)).contains("stale-session"), "inactive cumulative sessions should be pruned from collector state")
}

func testGrindHistoryIncrementalCollectorStartsAtEOF() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sessions = root.appendingPathComponent("codex/sessions/2026/08/23")
    let stateURL = root.appendingPathComponent("state/grind-live.json")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = sessions.appendingPathComponent("rollout-2026-08-23T10-00-00-11111111-1111-1111-1111-111111111111.jsonl")
    try #"{"timestamp":"2026-08-23T02:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"历史输入"}]}}"#.write(to: file, atomically: true, encoding: .utf8)
    let now = ISO8601DateFormatter().date(from: "2026-08-23T08:00:00Z")!
    let collector = CodexGrindHistoryCollector()
    let baseline = collector.collectIncremental(codexHome: root.appendingPathComponent("codex"), now: now, stateURL: stateURL)
    try expect(baseline.sessions.isEmpty, "incremental interaction collector must baseline historical files at EOF")
    let appended = #"{"timestamp":"2026-08-23T08:01:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"更新后的输入"}]}}"#
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(("\n" + appended + "\n").utf8))
    try handle.close()
    let updated = collector.collectIncremental(codexHome: root.appendingPathComponent("codex"), now: now.addingTimeInterval(60), stateURL: stateURL)
    try expectEqual(updated.sessions.first?.dayTurnCount, 1, "incremental interaction collector should count only appended turns")
    let stateInode = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.systemFileNumber] as? NSNumber
    let unchanged = collector.collectIncremental(codexHome: root.appendingPathComponent("codex"), now: now.addingTimeInterval(120), stateURL: stateURL)
    let unchangedStateInode = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.systemFileNumber] as? NSNumber
    try expect(unchanged.sessions.isEmpty, "incremental interaction collector must not rescan unchanged files")
    try expectEqual(unchangedStateInode, stateInode, "unchanged interaction tails should not rewrite collector state")
}

func testGrindIncrementalDrainsMoreThanSixteenNewFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("grind-drain-\(UUID().uuidString)")
    let codexHome = root.appendingPathComponent("codex")
    let sessions = codexHome.appendingPathComponent("sessions/2026/08/25")
    let stateURL = root.appendingPathComponent("state/grind.json")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = ISO8601DateFormatter().date(from: "2026-08-25T08:00:00Z")!
    let collector = CodexGrindHistoryCollector()
    _ = collector.collectIncremental(codexHome: codexHome, now: now, stateURL: stateURL)

    for index in 0..<20 {
        let id = String(format: "00000000-0000-0000-0000-%012d", index)
        let file = sessions.appendingPathComponent("rollout-2026-08-25T16-00-00-\(id).jsonl")
        let event = #"{"timestamp":"2026-08-25T08:00:\#(String(format: "%02d", index)).000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"输入\#(index)"}]}}"#
        try (event + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    }

    let first = collector.collectIncremental(codexHome: codexHome, now: now.addingTimeInterval(60), stateURL: stateURL)
    let second = collector.collectIncremental(codexHome: codexHome, now: now.addingTimeInterval(120), stateURL: stateURL)
    let drained = Set((first.sessions + second.sessions).map(\.sessionId))
    try expectEqual(first.sessions.count, 16, "one bounded sync should process at most sixteen changed rollout files")
    try expectEqual(second.sessions.count, 4, "the next sync must drain the remaining registered offsets")
    try expectEqual(drained.count, 20, "advancing global freshness must never baseline pending files at EOF")
}

func testGrindIncrementalReReadsTruncatedReplacement() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("grind-truncate-\(UUID().uuidString)")
    let codexHome = root.appendingPathComponent("codex")
    let sessions = codexHome.appendingPathComponent("sessions")
    let stateURL = root.appendingPathComponent("state/grind.json")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = sessions.appendingPathComponent("rollout-2026-08-25T16-00-00-88888888-8888-8888-8888-888888888888.jsonl")
    try (String(repeating: "x", count: 8_192) + "\n").write(to: file, atomically: true, encoding: .utf8)
    let now = ISO8601DateFormatter().date(from: "2026-08-25T08:00:00Z")!
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    let collector = CodexGrindHistoryCollector()
    _ = collector.collectIncremental(codexHome: codexHome, now: now, stateURL: stateURL)

    let replacement = #"{"timestamp":"2026-08-25T08:01:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"截断替换后的完整输入"}]}}"# + "\n"
    try replacement.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: file.path)
    let report = collector.collectIncremental(
        codexHome: codexHome,
        now: now.addingTimeInterval(60),
        stateURL: stateURL
    )
    try expectEqual(report.sessions.first?.dayTurnCount, 1, "a smaller replacement file must invalidate and restart its old byte offset")
}

func testGrindMigratesLegacyPathCursorAfterArchiveMove() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("grind-legacy-move-\(UUID().uuidString)")
    let codexHome = root.appendingPathComponent("codex")
    let archived = codexHome.appendingPathComponent("archived_sessions")
    let stateURL = root.appendingPathComponent("state/grind.json")
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let filename = "rollout-2026-08-25T16-00-00-99999999-9999-9999-9999-999999999999.jsonl"
    let file = archived.appendingPathComponent(filename)
    let event = #"{"timestamp":"2026-08-25T08:01:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"升级前已归档"}]}}"# + "\n"
    try event.write(to: file, atomically: true, encoding: .utf8)
    let now = ISO8601DateFormatter().date(from: "2026-08-25T08:02:00Z")!
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    let oldLivePath = codexHome.appendingPathComponent("sessions/2026/08/25/\(filename)").path
    let legacyState: [String: Any] = [
        "initialized": true,
        "updatedAt": "2026-08-25T08:00:00.000Z",
        "fileOffsets": [oldLivePath: 0],
    ]
    try JSONSerialization.data(withJSONObject: legacyState).write(to: stateURL, options: [.atomic])

    let report = CodexGrindHistoryCollector().collectIncremental(
        codexHome: codexHome,
        now: now,
        stateURL: stateURL
    )
    try expectEqual(report.sessions.first?.dayTurnCount, 1, "a legacy live-path cursor should migrate by rollout basename after archiving")
    let migrated = try String(contentsOf: stateURL, encoding: .utf8)
    try expect(!migrated.contains(oldLivePath), "the migrated state should discard its obsolete absolute path key")
    try expect(migrated.contains(filename), "the migrated state should persist the stable rollout key")
}

func testTailCollectorsPreservePartialRowsAcrossArchiveMove() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tail-move-\(UUID().uuidString)")
    let codexHome = root.appendingPathComponent("codex")
    let sessions = codexHome.appendingPathComponent("sessions/2026/08/25")
    let archived = codexHome.appendingPathComponent("archived_sessions")
    let grindState = root.appendingPathComponent("state/grind.json")
    let todayState = root.appendingPathComponent("state/today.json")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = ISO8601DateFormatter().date(from: "2026-08-25T03:00:00Z")!

    let grindName = "rollout-2026-08-25T11-00-00-33333333-3333-3333-3333-333333333333.jsonl"
    var grindFile = sessions.appendingPathComponent(grindName)
    try Data().write(to: grindFile)
    let grind = CodexGrindHistoryCollector()
    _ = grind.collectIncremental(codexHome: codexHome, now: now, stateURL: grindState)
    let interaction = #"{"timestamp":"2026-08-25T03:01:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"半行完成"}]}}"#
    try interaction.write(to: grindFile, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: grindFile.path)
    try expect(grind.collectIncremental(codexHome: codexHome, now: now.addingTimeInterval(60), stateURL: grindState).sessions.isEmpty, "an EOF partial interaction row must wait for its newline")
    let movedGrind = archived.appendingPathComponent(grindName)
    try FileManager.default.moveItem(at: grindFile, to: movedGrind)
    grindFile = movedGrind
    let grindHandle = try FileHandle(forWritingTo: grindFile)
    try grindHandle.seekToEnd()
    try grindHandle.write(contentsOf: Data("\n".utf8))
    try grindHandle.close()
    let completed = grind.collectIncremental(codexHome: codexHome, now: now.addingTimeInterval(120), stateURL: grindState)
    try expectEqual(completed.sessions.first?.dayTurnCount, 1, "a stable rollout key must resume the partial row after archiving")
    try expect(grind.collectIncremental(codexHome: codexHome, now: now.addingTimeInterval(180), stateURL: grindState).sessions.isEmpty, "the completed moved row must not be counted twice")

    let tokenName = "rollout-2026-08-25T11-10-00-44444444-4444-4444-4444-444444444444.jsonl"
    var tokenFile = sessions.appendingPathComponent(tokenName)
    try Data().write(to: tokenFile)
    let today = TodayCodexUsageCollector(stateURL: todayState)
    _ = today.collect(codexHome: codexHome, now: now)
    let token = #"{"timestamp":"2026-08-25T03:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":33},"total_token_usage":{"total_tokens":133}}}}"#
    try token.write(to: tokenFile, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(120)], ofItemAtPath: tokenFile.path)
    try expectEqual(today.collect(codexHome: codexHome, now: now.addingTimeInterval(120)).tokens, 0, "an EOF partial token row must not advance its offset")
    let movedToken = archived.appendingPathComponent(tokenName)
    try FileManager.default.moveItem(at: tokenFile, to: movedToken)
    tokenFile = movedToken
    let tokenHandle = try FileHandle(forWritingTo: tokenFile)
    try tokenHandle.seekToEnd()
    try tokenHandle.write(contentsOf: Data("\n".utf8))
    try tokenHandle.close()
    let tokenReport = today.collect(codexHome: codexHome, now: now.addingTimeInterval(180))
    try expectEqual(tokenReport.tokens, 33, "today usage must continue a partial row after sessions-to-archive movement")
    try expectEqual(today.collect(codexHome: codexHome, now: now.addingTimeInterval(240)).tokens, 33, "the moved token row must remain idempotent")
}

func testCollectorsReadSessionFirstDiscoveredAfterArchiving() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("new-archived-session-\(UUID().uuidString)")
    let codexHome = root.appendingPathComponent("codex")
    let sessions = codexHome.appendingPathComponent("sessions")
    let archived = codexHome.appendingPathComponent("archived_sessions")
    let grindState = root.appendingPathComponent("state/grind.json")
    let todayState = root.appendingPathComponent("state/today.json")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = ISO8601DateFormatter().date(from: "2026-08-25T03:00:00Z")!
    let grind = CodexGrindHistoryCollector()
    let today = TodayCodexUsageCollector(stateURL: todayState)
    _ = grind.collectIncremental(codexHome: codexHome, now: now, stateURL: grindState)
    _ = today.collect(codexHome: codexHome, now: now)

    let file = archived.appendingPathComponent(
        "rollout-2026-08-25T11-01-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl"
    )
    let rows = [
        #"{"timestamp":"2026-08-25T03:01:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"短会话输入"}]}}"#,
        #"{"timestamp":"2026-08-25T03:01:30.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":42},"total_token_usage":{"total_tokens":142}}}}"#,
    ].joined(separator: "\n") + "\n"
    try rows.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(90)], ofItemAtPath: file.path)

    let grindReport = grind.collectIncremental(
        codexHome: codexHome,
        now: now.addingTimeInterval(120),
        stateURL: grindState
    )
    let todayReport = today.collect(codexHome: codexHome, now: now.addingTimeInterval(120))
    try expectEqual(grindReport.sessions.first?.dayTurnCount, 1, "a session created and archived between polls must still contribute work activity")
    try expectEqual(todayReport.tokens, 42, "a session first discovered in archived_sessions must still contribute today's tokens")
}

func testGrindOversizedRowDoesNotBlockNewerEvents() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("grind-oversized-\(UUID().uuidString)")
    let codexHome = root.appendingPathComponent("codex")
    let sessions = codexHome.appendingPathComponent("sessions")
    let stateURL = root.appendingPathComponent("state/grind.json")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = sessions.appendingPathComponent("rollout-2026-08-25T12-00-00-55555555-5555-5555-5555-555555555555.jsonl")
    try Data().write(to: file)
    let now = ISO8601DateFormatter().date(from: "2026-08-25T04:00:00Z")!
    let collector = CodexGrindHistoryCollector()
    _ = collector.collectIncremental(codexHome: codexHome, now: now, stateURL: stateURL)
    let event = #"{"timestamp":"2026-08-25T04:01:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"超大行后的正常输入"}]}}"#
    try (String(repeating: "x", count: 300_000) + "\n" + event + "\n").write(
        to: file, atomically: false, encoding: .utf8
    )
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: file.path)
    try expect(collector.collectIncremental(codexHome: codexHome, now: now.addingTimeInterval(60), stateURL: stateURL).sessions.isEmpty, "the first bounded chunk may skip an oversized row")
    let resumed = collector.collectIncremental(codexHome: codexHome, now: now.addingTimeInterval(120), stateURL: stateURL)
    try expectEqual(resumed.sessions.first?.dayTurnCount, 1, "a skipped oversized row must not block later complete JSONL events")
}

func testClientVersionComparison() throws {
    try expectEqual(ClientVersion.compare("1.2.0", "1.1.9"), .orderedDescending, "newer client version should sort after the installed version")
    try expectEqual(ClientVersion.compare("1.0.0", "1.0.0"), .orderedSame, "equal client versions should compare equally")
    try expectEqual(ClientVersion.compare("1.0.9", "1.1.0"), .orderedAscending, "older client version should sort before the required version")
}

func testClientUpdateVerifierAcceptsReleaseSignature() throws {
    let hash = String(repeating: "a", count: 64)
    let signature = "5csOs6BaAKIG34CNd+bW/1Sb1dF6MdWPsJWddjT/uSccAuaaXGVXTe2syUHnwPQz49TExLcwKmPUgDrDggn3Dg=="
    try expect(ClientUpdateVerifier.verify(version: "1.2.3", sha256: hash, signatureBase64: signature), "release signature should validate against the embedded public key")
    try expect(!ClientUpdateVerifier.verify(version: "1.2.4", sha256: hash, signatureBase64: signature), "changing the release version should invalidate the signature")
}

func testClientUpdateManifestDefaultsToFiveMinutes() throws {
    let manifest = ClientUpdateManifest(
        enabled: true,
        updateAvailable: false,
        currentVersion: "1.2.30",
        latestVersion: "1.2.30",
        mandatory: false,
        rolloutEligible: true,
        rolloutPercentage: 100
    )
    try expectEqual(manifest.checkAfterSeconds, 300, "client update checks should default to five minutes")
}

func testUpdateLedgerBacksOffFailingVersion() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-update-ledger-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = UpdateLedger(url: root.appendingPathComponent("update-attempts.json"))
    let start = Date(timeIntervalSince1970: 1_780_000_000)

    try expect(ledger.waitBefore(retrying: "1.2.80", now: start) == nil, "a version with no history should be attempted immediately")

    ledger.recordFailure(version: "1.2.80", now: start)
    try expectEqual(ledger.waitBefore(retrying: "1.2.80", now: start.addingTimeInterval(60)) ?? 0, 240, "the first failure should hold the retry for five minutes")
    try expect(ledger.waitBefore(retrying: "1.2.80", now: start.addingTimeInterval(300)) == nil, "the retry should open once the backoff elapses")
    try expect(ledger.waitBefore(retrying: "1.2.81", now: start) == nil, "a different version must not inherit the backoff")

    // The second failure moves to the 15 minute step instead of repeating the five minute one.
    let second = start.addingTimeInterval(300)
    ledger.recordFailure(version: "1.2.80", now: second)
    try expectEqual(ledger.load()?.failureCount ?? 0, 2, "consecutive failures of one version accumulate")
    try expect(ledger.waitBefore(retrying: "1.2.80", now: second.addingTimeInterval(600)) != nil, "the second failure should still be waiting after ten minutes")
    try expect(ledger.waitBefore(retrying: "1.2.80", now: second.addingTimeInterval(900)) == nil, "the second failure should reopen after fifteen minutes")

    // A newly published version starts its own count rather than stacking onto the old one.
    ledger.recordFailure(version: "1.2.90", now: second)
    try expectEqual(ledger.load()?.failureCount ?? 0, 1, "a new version starts its own backoff")

    ledger.clear()
    var exhausted = start
    for _ in 0..<(UpdateLedger.backoffSeconds.count + 1) {
        ledger.recordFailure(version: "1.2.99", now: exhausted)
        exhausted = exhausted.addingTimeInterval(86_400)
    }
    try expect(ledger.waitBefore(retrying: "1.2.99", now: exhausted)?.isInfinite == true, "a version that burned through every step should stop retrying")

    ledger.clear()
    try expect(ledger.waitBefore(retrying: "1.2.99", now: exhausted) == nil, "a successful install clears the ledger")
}

func testClientReleaseRetentionCleansOnFirstNewAppLaunch() throws {
    let tokenRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-release-retention-tests-\(UUID().uuidString)", isDirectory: true)
    let root = tokenRoot.appendingPathComponent("app", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tokenRoot) }
    let releases = root.appendingPathComponent("releases", isDirectory: true)
    try FileManager.default.createDirectory(at: releases, withIntermediateDirectories: true)
    for name in ["1.2.70", "1.2.72", "1.2.73", "1.2.74", "1.2.98", "1.2.99", "notes"] {
        try FileManager.default.createDirectory(at: releases.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    for name in [
        "failed-1.2.74-123", "staging-abcd", ".install-1.2.74.abcd",
        "replaced-1.2.0-20260822", "pre-auto-update-backup-20260821",
    ] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("staging-active"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: root.appendingPathComponent("current").path,
        withDestinationPath: "releases/1.2.74"
    )
    let staleDate = Date().addingTimeInterval(-90_000)
    for url in [
        root.appendingPathComponent("staging-abcd"),
        root.appendingPathComponent(".install-1.2.74.abcd"),
        releases.appendingPathComponent("1.2.98"),
    ] {
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: url.path
        )
    }
    try Data("legacy".utf8).write(to: tokenRoot.appendingPathComponent("usage-cache.json"))

    let result = ClientReleaseRetention.prune(appRoot: root, currentVersion: "1.2.74")
    let remaining = try FileManager.default.contentsOfDirectory(atPath: releases.path).sorted()
    try expectEqual(remaining, ["1.2.73", "1.2.74", "1.2.99", "notes"], "startup cleanup should protect a fresh newer release during the updater handoff")
    try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("staging-active").path), "an active staging directory must not be removed")
    try expect(result.failures.isEmpty, "startup cleanup should remove test directories without failures")
    try expectEqual(result.removed.count, 9, "startup cleanup should remove stale releases, installer leftovers and legacy cache")
    try expect(!FileManager.default.fileExists(atPath: tokenRoot.appendingPathComponent("usage-cache.json").path), "legacy usage cache should be removed")
}

func testClientReleaseRetentionPreservesOnlyRecoveryCopy() throws {
    let tokenRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-release-recovery-tests-\(UUID().uuidString)", isDirectory: true)
    let root = tokenRoot.appendingPathComponent("app", isDirectory: true)
    let releases = root.appendingPathComponent("releases", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tokenRoot) }
    try FileManager.default.createDirectory(at: releases.appendingPathComponent("1.2.77"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: root.appendingPathComponent("current").path,
        withDestinationPath: "releases/1.2.77"
    )
    for name in ["replaced-1.2.77-reinstall", "pre-auto-update-backup-first-install"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    let result = ClientReleaseRetention.prune(appRoot: root, currentVersion: "1.2.77")
    try expect(result.failures.isEmpty, "a single-release cleanup should not fail")
    try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("replaced-1.2.77-reinstall").path), "the only reinstall recovery copy must remain")
    try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("pre-auto-update-backup-first-install").path), "the only legacy install backup must remain")
}

func testBoundedLogRotatesBeforeExceedingLimit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-log-\(UUID().uuidString)")
    let log = root.appendingPathComponent("test.log")
    defer { try? FileManager.default.removeItem(at: root) }

    BoundedLog.append("first\n", to: log, maximumBytes: 10)
    BoundedLog.append("second\n", to: log, maximumBytes: 10)

    try expectEqual(try String(contentsOf: log, encoding: .utf8), "second\n", "active log should contain the newest segment")
    try expectEqual(try String(contentsOf: log.appendingPathExtension("previous"), encoding: .utf8), "first\n", "one rotated segment should remain available")
}

func testBoundedLogCapsOversizedAndSerializesConcurrentWrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bounded-log-concurrent-\(UUID().uuidString)")
    let oversizedLog = root.appendingPathComponent("oversized.log")
    let concurrentLog = root.appendingPathComponent("concurrent.log")
    defer { try? FileManager.default.removeItem(at: root) }

    BoundedLog.append(Data(repeating: 65, count: 32), to: oversizedLog, maximumBytes: 10)
    try expectEqual((try Data(contentsOf: oversizedLog)).count, 10, "a single oversized entry must be truncated to the hard limit")

    let group = DispatchGroup()
    for index in 0..<100 {
        group.enter()
        DispatchQueue.global().async {
            BoundedLog.append("line-\(index)\n", to: concurrentLog, maximumBytes: 100_000)
            group.leave()
        }
    }
    group.wait()
    let lines = try String(contentsOf: concurrentLog, encoding: .utf8).split(separator: "\n")
    try expectEqual(lines.count, 100, "file locking must preserve every concurrent append")
    try expectEqual(Set(lines).count, 100, "concurrent appends must not overwrite one another")
}

func testClientUpdateConfigurationUsesTeamServerOrigin() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let configURL = root.appendingPathComponent("config.env")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "WANHE_ENDPOINT=\"https://c.wanhe.cn/api/usage\"\nWANHE_INGEST_TOKEN=\"device-token\"\n".write(to: configURL, atomically: true, encoding: .utf8)
    let configuration = ClientUpdateConfiguration.load(from: configURL)
    try expectEqual(configuration?.serverURL.absoluteString, "https://c.wanhe.cn", "updater should derive the website origin from the usage endpoint")
    try expect(configuration?.manifestURL?.absoluteString.contains("/api/client/macos/update?") == true, "updater should build the manifest endpoint")
}

func testProjectActivityStoreKeepsOnlySanitizedProjectAudit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-project-audit-\(UUID().uuidString)")
    let repository = root.appendingPathComponent("创新局")
    let subdirectory = repository.appendingPathComponent("server/private")
    let activityURL = root.appendingPathComponent("support/project-activity.json")
    try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ProjectActivityStore(activityURL: activityURL)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try store.record(workspace: subdirectory.path, taskID: "session:sensitive-session-id", now: now)
    try store.record(workspace: repository.path, taskID: "session:second-session", now: now.addingTimeInterval(60))
    let report = store.report(days: 30, now: now.addingTimeInterval(120))
    try expectEqual(report.count, 1, "project audit should merge subdirectories into their repository")
    try expectEqual(report.first?.name, "创新局", "project audit should upload only the repository name")
    try expectEqual(report.first?.sessionCount, 2, "project audit should count unique hashed sessions")
    let stored = try String(contentsOf: activityURL, encoding: .utf8)
    try expect(!stored.contains(root.path), "project audit ledger must not retain the absolute workspace path")
    try expect(!stored.contains("sensitive-session-id"), "project audit ledger must hash session identifiers")
}

func testProjectActivityBuildsReliableHumanInputOutbox() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-project-summary-\(UUID().uuidString)")
    let repository = root.appendingPathComponent("app")
    let activityURL = root.appendingPathComponent("support/project-activity.json")
    let codexHome = root.appendingPathComponent("codex")
    let sessionURL = codexHome.appendingPathComponent("sessions/2026/08/22/rollout-test.jsonl")
    try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: now)
    let purposeTimestamp = formatter.string(from: now.addingTimeInterval(-60))
    let lines = [
        #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"cwd":"\#(repository.path)","source":"vscode"}}"#,
        #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>自动上下文</environment_context>"}]}}"#,
        #"{"timestamp":"\#(purposeTimestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"这个项目是一个用于客户提交需求和查看进度的服务平台"}]}}"#,
        #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"请修复 /Users/example/private/project 的开工时间并检查 https://internal.example/token，password=secret-123，联系 test@example.com 或 192.168.1.10"}]}}"#,
        #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"这段 Codex 回复绝不能上传"}]}}"#,
        #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"```swift\\nimport Foundation\\nprint(1)\\n```"}]}}"#,
        #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"请检查 `print(1)` 这段内容"}]}}"#,
        #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"</image>"}]}}"#,
    ].joined(separator: "\n")
    try lines.write(to: sessionURL, atomically: true, encoding: .utf8)
    let store = ProjectActivityStore(activityURL: activityURL)
    try store.record(workspace: repository.path, taskID: "session:test", now: now)
    let prepared = store.prepareSync(days: 30, now: now, codexHome: codexHome)
    try expect(prepared.inputEvents.isEmpty, "first run must baseline at EOF without historical prompt backfill")
    let historicalRows = lines.split(separator: "\n").dropFirst().joined(separator: "\n")
    let baselineHandle = try FileHandle(forWritingTo: sessionURL)
    try baselineHandle.seekToEnd()
    try baselineHandle.write(contentsOf: Data(("\n" + historicalRows).utf8))
    try baselineHandle.close()
    let captured = store.prepareSync(days: 30, now: now.addingTimeInterval(1), codexHome: codexHome)
    let report = captured.projects.first
    let combinedInputs = captured.inputEvents.map(\.text).joined(separator: "\n")
    try expectEqual(report?.purpose, nil, "conversation heuristics must not pretend to be a project summary")
    try expectEqual(report?.summary, nil, "the last user message must not be exposed as a project summary")
    try expectEqual(captured.inputEvents.count, 3, "only genuine new human text inputs should enter the upload outbox")
    try expect(combinedInputs.contains("客户提交需求和查看进度"), "human project input should be retained")
    try expect(combinedInputs.contains("/Users/example/private/project"), "authorized input text should remain original")
    try expect(combinedInputs.contains("https://internal.example/token"), "authorized input links should remain original")
    try expect(combinedInputs.contains("test@example.com"), "authorized input text should not be summarized away")
    try expect(combinedInputs.contains("192.168.1.10"), "authorized input text should preserve the original wording")
    try expect(!combinedInputs.contains("environment_context"), "input ledger should ignore injected context")
    try expect(!combinedInputs.contains("secret-123"), "input ledger must still redact credentials")
    try expect(!combinedInputs.contains("Codex 回复"), "assistant replies must never enter input events")
    try expect(!combinedInputs.contains("import Foundation"), "code blocks must never enter input events")
    try expect(!combinedInputs.contains("print(1)"), "inline code must be removed before upload")
    let storedAfterBackfill = try String(contentsOf: activityURL, encoding: .utf8)
    try expect(!storedAfterBackfill.contains(sessionURL.path), "incremental cursor must hash conversation file paths")
    try expect(!storedAfterBackfill.contains("secret-123"), "local input outbox must not retain raw credentials")

    let appendedTimestamp = formatter.string(from: now.addingTimeInterval(60))
    let appended = #"{"timestamp":"\#(appendedTimestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"继续完善客户工单筛选和状态提醒"}]}}"#
    let handle = try FileHandle(forWritingTo: sessionURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(("\n" + appended + "\n").utf8))
    try handle.close()
    let incremental = store.prepareSync(days: 30, now: now.addingTimeInterval(120), codexHome: codexHome)
    try expectEqual(incremental.inputEvents.count, 4, "incremental collector should append only the newly written input")
    try expect(incremental.inputEvents.last?.text.contains("客户工单筛选") == true, "new human input should retain its exact text")
    store.acknowledgeInputEvents(ids: incremental.inputEvents.map(\.id))
    try expect(store.prepareSync(days: 30, now: now.addingTimeInterval(180), codexHome: codexHome).inputEvents.isEmpty, "acknowledged events must leave the reliable outbox")
}

func testProjectInputCursorSurvivesArchiveMoveAndPartialRows() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-move-\(UUID().uuidString)")
    let repository = root.appendingPathComponent("创新局")
    let codexHome = root.appendingPathComponent("codex")
    let sessions = codexHome.appendingPathComponent("sessions/2026/08/25")
    let archived = codexHome.appendingPathComponent("archived_sessions")
    let activityURL = root.appendingPathComponent("support/project.json")
    try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let filename = "rollout-2026-08-25T13-00-00-66666666-6666-6666-6666-666666666666.jsonl"
    var file = sessions.appendingPathComponent(filename)
    try Data().write(to: file)
    let now = Date()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let store = ProjectActivityStore(activityURL: activityURL)
    _ = store.prepareSync(days: 30, now: now, codexHome: codexHome)

    func message(at date: Date, text: String) -> String {
        #"{"timestamp":"\#(formatter.string(from: date))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(text)"}]}}"#
    }
    let meta = #"{"timestamp":"\#(formatter.string(from: now))","type":"session_meta","payload":{"id":"stable-project-session","cwd":"\#(repository.path)","source":"vscode"}}"#
    try (meta + "\n" + message(at: now.addingTimeInterval(1), text: "移动前输入") + "\n").write(
        to: file, atomically: false, encoding: .utf8
    )
    let beforeMove = store.prepareSync(days: 30, now: now.addingTimeInterval(2), codexHome: codexHome)
    try expectEqual(beforeMove.inputEvents.map(\.text), ["移动前输入"], "the live rollout should emit its first appended input once")
    store.acknowledgeInputEvents(ids: beforeMove.inputEvents.map(\.id))

    let moved = archived.appendingPathComponent(filename)
    try FileManager.default.moveItem(at: file, to: moved)
    file = moved
    let moveHandle = try FileHandle(forWritingTo: file)
    try moveHandle.seekToEnd()
    try moveHandle.write(contentsOf: Data((message(at: now.addingTimeInterval(3), text: "归档后输入") + "\n").utf8))
    try moveHandle.close()
    let afterMove = store.prepareSync(days: 30, now: now.addingTimeInterval(4), codexHome: codexHome)
    try expectEqual(afterMove.inputEvents.map(\.text), ["归档后输入"], "archive movement must reuse the stable cursor without replaying acknowledged text")
    store.acknowledgeInputEvents(ids: afterMove.inputEvents.map(\.id))

    let partialHandle = try FileHandle(forWritingTo: file)
    try partialHandle.seekToEnd()
    try partialHandle.write(contentsOf: Data(message(at: now.addingTimeInterval(5), text: "补全后的输入").utf8))
    try partialHandle.close()
    try expect(store.prepareSync(days: 30, now: now.addingTimeInterval(6), codexHome: codexHome).inputEvents.isEmpty, "an EOF partial project row must retain its cursor")
    let newlineHandle = try FileHandle(forWritingTo: file)
    try newlineHandle.seekToEnd()
    try newlineHandle.write(contentsOf: Data("\n".utf8))
    try newlineHandle.close()
    let completed = store.prepareSync(days: 30, now: now.addingTimeInterval(7), codexHome: codexHome)
    try expectEqual(completed.inputEvents.map(\.text), ["补全后的输入"], "the completed project row should be emitted after its newline arrives")
}

func testProjectOversizedRowDoesNotBlockNewerInput() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-oversized-\(UUID().uuidString)")
    let repository = root.appendingPathComponent("创新局")
    let codexHome = root.appendingPathComponent("codex")
    let sessions = codexHome.appendingPathComponent("sessions")
    let activityURL = root.appendingPathComponent("support/project.json")
    try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = sessions.appendingPathComponent("rollout-oversized-77777777-7777-7777-7777-777777777777.jsonl")
    try Data().write(to: file)
    let store = ProjectActivityStore(activityURL: activityURL)
    let now = Date()
    let timestamp = ISO8601DateFormatter().string(from: now)
    _ = store.prepareSync(days: 30, now: now, codexHome: codexHome)
    let meta = #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"oversized-session","cwd":"\#(repository.path)","source":"vscode"}}"#
    let event = #"{"timestamp":"\#(timestamp)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"超大行后的项目输入"}]}}"#
    try (String(repeating: "x", count: 300_000) + "\n" + meta + "\n" + event + "\n").write(
        to: file, atomically: false, encoding: .utf8
    )
    try expect(store.prepareSync(days: 30, now: now.addingTimeInterval(1), codexHome: codexHome).inputEvents.isEmpty, "one oversized chunk may be skipped without advancing to EOF")
    let resumed = store.prepareSync(days: 30, now: now.addingTimeInterval(2), codexHome: codexHome)
    try expectEqual(resumed.inputEvents.map(\.text), ["超大行后的项目输入"], "oversized JSONL rows must not block later human input")
}

func testProjectActivityDoesNotInventPurposeForGenericProjectName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-generic-project-\(UUID().uuidString)")
    let repository = root.appendingPathComponent("Playground")
    let activityURL = root.appendingPathComponent("support/project-activity.json")
    try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ProjectActivityStore(activityURL: activityURL)
    let now = Date()
    try store.record(workspace: repository.path, taskID: "session:test", now: now)
    let purpose = store.report(days: 30, now: now).first?.purpose
    try expectEqual(purpose, nil, "generic project names must wait for a real Codex summary or administrator confirmation")
}

func testProjectActivityUsesNeutralPropertyPurpose() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-property-project-\(UUID().uuidString)")
    let repository = root.appendingPathComponent("香港房产")
    let activityURL = root.appendingPathComponent("support/project-activity.json")
    try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = ProjectActivityStore(activityURL: activityURL)
    let now = Date()
    try store.record(workspace: repository.path, taskID: "session:test", now: now)
    let purpose = store.report(days: 30, now: now).first?.purpose
    try expectEqual(purpose, "楼盘查询、估价与找房服务的产品研发项目", "project purpose should stay neutral for the whole team")
}

func testProjectActivityBaselineIsMetadataOnlyAndBounded() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-light-baseline-\(UUID().uuidString)")
    let codexHome = root.appendingPathComponent("codex")
    let sessions = codexHome.appendingPathComponent("sessions/2026/08/23")
    let activityURL = root.appendingPathComponent("support/project-activity.json")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let historical = #"{"timestamp":"2026-08-23T12:00:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"历史文字不应补采"}]}}"#
    for index in 0..<600 {
        try historical.write(
            to: sessions.appendingPathComponent("rollout-\(index).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }
    let store = ProjectActivityStore(activityURL: activityURL)
    let startedAt = Date()
    let report = store.prepareSync(days: 30, now: Date(), codexHome: codexHome)
    let elapsed = Date().timeIntervalSince(startedAt)
    try expect(report.inputEvents.isEmpty, "metadata baseline must never upload historical prompts")
    try expect(elapsed < 1.0, "600-file metadata baseline should stay below one second")
    let stored = try String(contentsOf: activityURL, encoding: .utf8)
    try expect(stored.contains("\"inputEventCollectionVersion\" : 2"), "metadata baseline should persist the v2 cursor format")
    try expect(!stored.contains("历史文字不应补采"), "metadata baseline must not read prompt text into its ledger")
}

func testDesktopMonitorInstallerMigratesPackagedMonitor() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-monitor-installer-\(UUID().uuidString)")
    let release = root.appendingPathComponent("release")
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: release, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "#!/bin/zsh\necho audit\n".write(
        to: release.appendingPathComponent("codex-light-codex-monitor"), atomically: true, encoding: .utf8
    )
    try "<string>__MONITOR_PATH__</string><string>__HOME__</string>".write(
        to: release.appendingPathComponent("com.codex.traffic-light-codex-monitor.plist.template"), atomically: true, encoding: .utf8
    )

    let installed = try DesktopMonitorInstaller.install(from: release, home: home, restartService: false)
    try expect(installed, "packaged desktop monitor should install on first launch")
    let monitor = home.appendingPathComponent(".codex/bin/codex-light-codex-monitor")
    let plist = home.appendingPathComponent("Library/LaunchAgents/com.codex.traffic-light-codex-monitor.plist")
    try expectEqual(try String(contentsOf: monitor, encoding: .utf8), "#!/bin/zsh\necho audit\n", "installer should copy the packaged monitor")
    let rendered = try String(contentsOf: plist, encoding: .utf8)
    try expect(rendered.contains(monitor.path), "installer should render the exact monitor path")
    try expect(rendered.contains(home.path), "installer should render the exact home path")
    let unchanged = try DesktopMonitorInstaller.install(from: release, home: home, restartService: false)
    try expect(!unchanged, "unchanged monitor installation should not restart or rewrite")
}

func testOfficialUsageRefreshPolicyTracksUTCSettlement() throws {
    let formatter = ISO8601DateFormatter()
    let now = formatter.date(from: "2026-08-23T00:05:00Z")!
    let delayed = OfficialCodexUsageReport(
        lifetimeTokens: 1,
        peakDailyTokens: 1,
        dailyUsageBuckets: [OfficialDailyUsageBucket(startDate: "2026-08-21", tokens: 1)],
        updatedAt: "2026-08-23T00:00:00Z"
    )
    let settled = OfficialCodexUsageReport(
        lifetimeTokens: 1,
        peakDailyTokens: 1,
        dailyUsageBuckets: [OfficialDailyUsageBucket(startDate: "2026-08-22", tokens: 1)],
        updatedAt: "2026-08-23T00:00:00Z"
    )
    try expectEqual(OfficialUsageRefreshPolicy.expectedSettledDay(now: now), "2026-08-22", "expected official day should be the completed UTC day")
    try expectEqual(OfficialUsageRefreshPolicy.cacheAge(for: delayed, now: now), 5 * 60, "delayed bucket should refresh every five minutes after Beijing 08:05")
    try expectEqual(OfficialUsageRefreshPolicy.cacheAge(for: settled, now: now), 2 * 60 * 60, "settled bucket should return to normal cache age")
    let later = formatter.date(from: "2026-08-23T02:00:00Z")!
    try expectEqual(OfficialUsageRefreshPolicy.cacheAge(for: delayed, now: later), 30 * 60, "delayed bucket should reduce polling after Beijing 10:00")
}

let tests: [(String, () throws -> Void)] = [
    ("brand tagline stays aligned", {
        try expectEqual(BrandCopy.tagline, "用 Codex 手搓世界，人人都是造物主", "client tagline should match the approved brand copy")
    }),
    ("command contract", testCommandContract),
    ("grind display formatter", testGrindDisplayFormatterUsesConciseLabels),
    ("quota snapshot clamps", testQuotaSnapshotClampsPercentValues),
    ("quota snapshot stores reset dates", testQuotaSnapshotStoresResetDates),
    ("quota extractor reads top-level snake case", testQuotaExtractorReadsTopLevelSnakeCase),
    ("quota extractor reads nested camel case and clamps", testQuotaExtractorReadsNestedCamelCaseAndClamps),
    ("quota extractor reads quota and rate limits nesting", testQuotaExtractorReadsQuotaAndRateLimitsNesting),
    ("quota extractor rejects Spark limit", testQuotaExtractorRejectsSparkLimit),
    ("quota extractor requires weekly data", testQuotaExtractorRequiresBothWindows),
    ("quota extractor allows 5-hour-only data", testQuotaExtractorAllowsFiveHourOnlyData),
    ("quota extractor reads zero percent and reset dates", testQuotaExtractorReadsZeroPercentAndResetDates),
    ("quota extractor reads supported membership plan", testQuotaExtractorReadsSupportedMembershipPlanOnly),
    ("old JSON decodes without quota", testStateSnapshotDecodesOldJSONWithoutQuota),
    ("legacy provider quota migrates", testStateSnapshotMigratesLegacyCodexProviderQuota),
    ("state JSON contains only current quota", testStateFileContainsOnlyCurrentQuotaKeys),
    ("state store rejects impossible full quota", testStateStoreRejectsImpossibleFullQuotaBeforeKnownReset),
    ("state store accepts official Codex reset", testStateStoreAcceptsOfficialCodexReset),
    ("state store preserves membership plan", testStateStoreKeepsMembershipPlanAcrossSparseQuotaUpdates),
    ("hook log line", testHookLogLineIncludesEventAndTask),
    ("hook log line includes quota summary", testHookLogLineIncludesQuotaSummary),
    ("hook bridge updates quota and project audit", testHookBridgeUpdatesQuotaAndProjectAudit),
    ("hook bridge quota-only event skips project", testHookBridgeQuotaOnlyEventDoesNotRecordProject),
    ("session quota collector uses newest Codex event", testSessionQuotaCollectorUsesNewestCodexRateLimitEvent),
    ("session quota collector ignores Spark limit", testSessionQuotaCollectorIgnoresSparkRateLimitEvent),
    ("session quota collector repairs Spark contamination", testSessionQuotaCollectorRepairsNewerSparkContamination),
    ("session quota collector replaces fresh unverified cache", testSessionQuotaCollectorReplacesFreshUnverifiedCache),
    ("session quota collector accepts 5-hour-only event", testSessionQuotaCollectorAcceptsFiveHourOnlyEvent),
    ("session quota collector persists incremental cursors", testSessionQuotaCollectorPersistsOffsetsAndHandlesArchiveAndTruncation),
    ("session quota rejects future freshness", testSessionQuotaCollectorRejectsFutureObservationFreshness),
    ("app-server quota mapper reads codex limit", testAppServerQuotaMapperReadsCodexLimitByExactDurations),
    ("app-server quota mapper falls back top-level", testAppServerQuotaMapperFallsBackToTopLevelRateLimits),
    ("app-server quota mapper rejects Spark fallback", testAppServerQuotaMapperRejectsSparkFallback),
    ("app-server quota mapper clamps remaining", testAppServerQuotaMapperClampsRemainingPercent),
    ("app-server quota mapper reads reset times", testAppServerQuotaMapperReadsResetTimes),
    ("app-server quota mapper allows weekly-only window", testAppServerQuotaMapperAllowsWeeklyOnlyWindow),
    ("app-server quota mapper allows 5-hour-only window", testAppServerQuotaMapperAllowsFiveHourOnlyWindow),
    ("app-server quota mapper requires explicit supported duration", testAppServerQuotaMapperRejectsWindowsWithoutWeeklyDuration),
    ("app-server quota mapper ignores individual limit", testAppServerQuotaMapperIgnoresIndividualLimitRemainingPercent),
    ("app-server JSON-RPC line codec builds request", testAppServerJSONRPCLineCodecBuildsRequest),
    ("app-server JSON-RPC line codec decodes target response", testAppServerJSONRPCLineCodecDecodesMessagesAndFindsTargetResponse),
    ("app-server quota collector uses transport fixture", testAppServerQuotaCollectorUsesTransportFixture),
    ("app-server quota collector preserves old quota on failure", testAppServerQuotaCollectorPropagatesMissingQuotaWithoutClearingStore),
    ("app-server quota errors describe specific timeouts", testAppServerQuotaErrorsDescribeSpecificTimeouts),
    ("app-server discovers bundled ChatGPT Codex", testAppServerBinaryDiscoveryFindsBundledChatGPTCodex),
    ("quota diagnostic is sanitized", testQuotaDiagnosticContainsOnlyStatusCodeAndSource),
    ("app-server quota collector retries and succeeds", testAppServerQuotaCollectorRetriesTwiceAndSucceedsOnThirdAttempt),
    ("app-server quota collector exhausts retries", testAppServerQuotaCollectorFailsAfterThreeAttemptsAndPreservesQuota),
    ("quota refresh coordinator prevents concurrent refreshes", testQuotaRefreshCoordinatorPreventsConcurrentRefreshes),
    ("quota refresh coordinator throttles repeated logs", testQuotaRefreshCoordinatorThrottlesRepeatedFailureLogs),
    ("quota refresh countdown uses hours below one day", testQuotaRefreshCountdownUsesHoursBelowOneDay),
    ("quota display formatter uses natural date", testQuotaDisplayFormatterUsesNaturalChineseDate),
    ("team sync parses environment", testTeamSyncParsesEnvironmentFile),
    ("team device uses hardware names", testTeamDeviceUsesHardwareFamilyNames),
    ("team usage collector aggregates deltas", testTeamUsageCollectorBuildsDailySessionDelta),
    ("one-time usage backfill selects August 25 once", testOneTimeUsageBackfillSelectsOnlyAugust25AndAcknowledges),
    ("team quota report uses weekly data", testTeamQuotaReportUsesWeeklyPercentAndReset),
    ("team quota report preserves dual windows", testTeamQuotaReportPreservesDualWindowsAndPrimary),
    ("team ranking URL uses website origin", testTeamRankingURLUsesWebsiteOrigin),
    ("team ranking decodes legacy today activity", testTeamRankingDecodesLegacyTodayActivity),
    ("team ranking decodes realtime presence", testTeamRankingDecodesRealtimePresence),
    ("team ranking decodes member weekly quota", testTeamRankingDecodesMemberWeeklyQuota),
    ("team ranking decodes member 5-hour quota", testTeamRankingDecodesFiveHourQuota),
    ("team ranking distinguishes joined members", testTeamRankingDistinguishesJoinedMemberFromInvitePlaceholder),
    ("avatar disk cache persists by URL", testAvatarDiskCachePersistsByRemoteURL),
    ("official Codex usage parses daily buckets", testOfficialCodexUsageParsesDailyBuckets),
    ("official usage refresh tracks UTC settlement", testOfficialUsageRefreshPolicyTracksUTCSettlement),
    ("session counter uses local filename and metadata only", testSessionCounterUsesLocalFilenameAndMetadataWithoutReadingContents),
    ("collectors reuse one session file index", testCollectorsCanReuseOneSessionFileIndexSnapshot),
    ("session activity uses acknowledged daily deltas", testSessionActivityDeltaRequiresAcknowledgementAndDailyFull),
    ("team server capability gates session deltas", testTeamServerCapabilityRequiresExactDeltaProtocol),
    ("grind history reads event timestamps only", testGrindHistoryCollectorReadsOnlyEventTimestamps),
    ("today live collector tails appended usage only", testTodayLiveCollectorStartsAtEOFAndCountsOnlyAppendedUsage),
    ("today live collector splits local and UTC days", testTodayLiveCollectorSplitsLocalAndUTCDayAtSettlementBoundary),
    ("today live collector protects legacy UTC baseline", testTodayLiveCollectorDoesNotTrustLegacyMidDayStateAsUTCBaseline),
    ("grind history collector tails appended interactions only", testGrindHistoryIncrementalCollectorStartsAtEOF),
    ("grind history drains more than sixteen files", testGrindIncrementalDrainsMoreThanSixteenNewFiles),
    ("grind history re-reads truncated replacements", testGrindIncrementalReReadsTruncatedReplacement),
    ("grind history migrates legacy moved cursors", testGrindMigratesLegacyPathCursorAfterArchiveMove),
    ("tail collectors preserve partial rows across moves", testTailCollectorsPreservePartialRowsAcrossArchiveMove),
    ("collectors read newly archived short sessions", testCollectorsReadSessionFirstDiscoveredAfterArchiving),
    ("grind history skips oversized rows without blocking", testGrindOversizedRowDoesNotBlockNewerEvents),
    ("project audit sanitizes workspace and session", testProjectActivityStoreKeepsOnlySanitizedProjectAudit),
    ("project input ledger filters and acknowledges human text", testProjectActivityBuildsReliableHumanInputOutbox),
    ("project input cursor survives archive and partial rows", testProjectInputCursorSurvivesArchiveMoveAndPartialRows),
    ("project input skips oversized rows without blocking", testProjectOversizedRowDoesNotBlockNewerInput),
    ("project audit does not invent generic purpose", testProjectActivityDoesNotInventPurposeForGenericProjectName),
    ("project audit uses neutral property purpose", testProjectActivityUsesNeutralPropertyPurpose),
    ("project input baseline is metadata-only and bounded", testProjectActivityBaselineIsMetadataOnlyAndBounded),
    ("desktop monitor installer migrates packaged monitor", testDesktopMonitorInstallerMigratesPackagedMonitor),
    ("client version comparison", testClientVersionComparison),
    ("client update signature verification", testClientUpdateVerifierAcceptsReleaseSignature),
    ("client update defaults to five minutes", testClientUpdateManifestDefaultsToFiveMinutes),
    ("client update configuration", testClientUpdateConfigurationUsesTeamServerOrigin),
    ("update ledger backs off a failing version", testUpdateLedgerBacksOffFailingVersion),
    ("client release retention cleans on launch", testClientReleaseRetentionCleansOnFirstNewAppLaunch),
    ("client release retention preserves recovery", testClientReleaseRetentionPreservesOnlyRecoveryCopy),
    ("bounded logs rotate", testBoundedLogRotatesBeforeExceedingLimit),
    ("bounded logs cap and serialize", testBoundedLogCapsOversizedAndSerializesConcurrentWrites)
]

var failures = 0
for (name, test) in tests {
    do {
        try test()
        print("PASS \(name)")
    } catch {
        failures += 1
        print("FAIL \(name): \(error)")
    }
}

if failures > 0 {
    exit(1)
}

print("All \(tests.count) tests passed")
