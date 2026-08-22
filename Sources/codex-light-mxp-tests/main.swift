import Foundation
import CodexTrafficLightCore

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

    try expectEqual(result.quotaSummary, "47%", "hook bridge should report weekly quota summary")
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
      "limitId": "codex",
      "limitName": "Codex",
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

    try expectEqual(quota.weeklyRemainingPercent, Optional(48), "mapper should prefer codex weekly window")
}

func testSessionQuotaCollectorUsesNewestCodexRateLimitEvent() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-session-quota-tests-\(UUID().uuidString)", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions/2026/08/22", isDirectory: true)
    let archived = root.appendingPathComponent("archived_sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let older = #"{"timestamp":"2026-08-22T06:20:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":63,"window_minutes":10080,"resets_at":1787561781}}}}"#
    let newer = #"{"timestamp":"2026-08-22T06:30:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":40,"window_minutes":300,"resets_at":1787390000},"secondary":{"used_percent":72,"window_minutes":10080,"resets_at":1787561781}}}}"#
    try Data((older + "\n").utf8).write(to: sessions.appendingPathComponent("rollout-old.jsonl"))
    try Data((newer + "\n").utf8).write(to: archived.appendingPathComponent("rollout-new.jsonl"))

    let observation = CodexSessionQuotaCollector().collect(
        codexHome: root,
        now: Date(timeIntervalSince1970: 1_787_389_000),
        fileMaxAge: 86_400
    )

    try expectEqual(observation?.weeklyRemainingPercent, 28, "session quota should match newest Codex weekly remaining value")
    try expectEqual(observation?.weeklyResetsAt, Date(timeIntervalSince1970: 1_787_561_781), "session quota should keep reset time")
}

func testSessionQuotaCollectorRejectsLegacy300MinuteEvent() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-session-legacy-window-tests-\(UUID().uuidString)", isDirectory: true)
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let event = #"{"timestamp":"2026-08-22T06:30:00.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":0,"window_minutes":300,"resets_at":1787390000}}}}"#
    try Data((event + "\n").utf8).write(to: sessions.appendingPathComponent("rollout-legacy-window.jsonl"))

    let observation = CodexSessionQuotaCollector().collect(
        codexHome: root,
        now: Date(timeIntervalSince1970: 1_787_389_000),
        fileMaxAge: 86_400
    )

    try expectEqual(observation, nil, "a 300 minute quota must never be reported as weekly quota")
}

func testAppServerQuotaMapperFallsBackToTopLevelRateLimits() throws {
    let topLevel = appServerSnapshot(primaryUsed: 39, primaryDuration: 300, secondaryUsed: 65, secondaryDuration: 10_080)
    let data = appServerRateLimitsResponse(rateLimits: topLevel)

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: data)

    try expectEqual(quota.weeklyRemainingPercent, Optional(35), "mapper should read top-level weekly window")
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
}

func testAppServerQuotaMapperRejectsWindowsWithoutWeeklyDuration() throws {
    let codex = appServerSnapshot(primaryUsed: 30, primaryDuration: nil, secondaryUsed: 55, secondaryDuration: nil)
    let data = appServerRateLimitsResponse(rateLimitsByLimitId: #"{"codex": \#(codex)}"#)

    do {
        _ = try CodexAppServerQuotaMapper.quotaValues(from: data)
        throw TestFailure(description: "mapper should reject windows without an explicit weekly duration")
    } catch let error as CodexAppServerQuotaError {
        try expect(error.summaryKey == "missingQuota", "mapper should report missing weekly quota")
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
    try expectEqual(sessions.count, 2, "collector should split one session at Hong Kong midnight")
    try expectEqual(sessions.map(\.day), ["2026-08-21", "2026-08-22"], "collector should use Hong Kong calendar days")
    try expectEqual(sessions.map(\.utcDay), ["2026-08-21", "2026-08-21"], "collector should retain the matching official UTC bucket")
    try expectEqual(sessions.map(\.totalTokens), [180, 40], "collector should add cumulative deltas without double counting")
    try expectEqual(sessions.first?.model, "gpt-5.6-sol", "collector should preserve the session model")
    try expectEqual(sessions.first?.deviceId, "mac-1", "collector should use the hardware device id")
}

func testTeamQuotaReportUsesWeeklyPercentAndReset() throws {
    let reset = Date(timeIntervalSince1970: 2_000)
    let report = TeamQuotaReport(weeklyRemainingPercent: 79, weeklyResetsAt: reset, updatedAt: Date(timeIntervalSince1970: 1_000))
    try expectEqual(report.weeklyRemainingPercent, 79, "team quota should keep weekly remaining percent")
    try expectEqual(report.weeklyUsedPercent, 21, "team quota should derive weekly used percent")
    try expect(report.weeklyResetsAt != nil, "team quota should include reset time")
}

func testTeamRankingURLUsesWebsiteOrigin() throws {
    let configuration = TeamSyncConfiguration(
        endpoint: URL(string: "https://meet.example.com/api/usage")!, token: "test", userID: "lu", userName: "张璐",
        team: "万合创新局", role: "Codex 使用者", codexHome: URL(fileURLWithPath: "/tmp/codex")
    )
    let service = TeamUsageSyncService(configuration: configuration)
    try expectEqual(service.websiteURL.absoluteString, "https://meet.example.com/", "website link should use the ranking origin")
    try expectEqual(service.rankingsURL().absoluteString, "https://meet.example.com/api/rankings?range=today", "menu should fetch today's ranking")
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

func testTeamRankingDecodesMemberWeeklyQuota() throws {
    let data = """
    {"updatedAt":"2026-08-21 13:50","members":[{"id":"zlu","name":"张璐","tokens":1200,"sessions":12,"weeklyQuota":{"weeklyRemainingPercent":75,"weeklyUsedPercent":25,"weeklyResetsAt":"2026-08-27T03:33:23.000Z","updatedAt":"2026-08-21T08:50:31.586Z"}}]}
    """.data(using: .utf8)!
    let ranking = try JSONDecoder().decode(TeamRankingSnapshot.self, from: data)
    try expectEqual(ranking.members.first?.weeklyQuota?.weeklyRemainingPercent, 75, "team ranking should expose each member's weekly remaining percent")
    try expectEqual(ranking.members.first?.weeklyQuota?.weeklyResetsAt, "2026-08-27T03:33:23.000Z", "team ranking should expose each member's weekly reset time")
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
        #"{"timestamp":"2026-08-22T01:05:00.000Z","type":"response_item","payload":{"type":"message","role":"user","private":"do not inspect"}}"#,
    ].joined(separator: "\n")
        .write(to: morningFile, atomically: true, encoding: .utf8)
    let now = ISO8601DateFormatter().date(from: "2026-08-22T04:00:00Z")!
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: morningFile.path)

    let history = CodexGrindHistoryCollector().collect(codexHome: root, days: 30, now: now)
    try expectEqual(history, [
        TeamGrindHistoryDay(grindDay: "2026-08-21", dayGrindTime: nil, nightGrindTime: "02:04"),
        TeamGrindHistoryDay(grindDay: "2026-08-22", dayGrindTime: "09:05", nightGrindTime: nil),
    ], "grind history should use the first user prompt even in an older conversation")
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
    let unchanged = collector.collect(codexHome: root.appendingPathComponent("codex"), now: now.addingTimeInterval(120))
    try expectEqual(unchanged.tokens, 50, "collector should not count an appended event twice")
    let persisted = try String(contentsOf: stateURL, encoding: .utf8)
    try expect(!persisted.contains("private text"), "collector state must never persist conversation text")
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

let tests: [(String, () throws -> Void)] = [
    ("command contract", testCommandContract),
    ("quota snapshot clamps", testQuotaSnapshotClampsPercentValues),
    ("quota snapshot stores reset dates", testQuotaSnapshotStoresResetDates),
    ("quota extractor reads top-level snake case", testQuotaExtractorReadsTopLevelSnakeCase),
    ("quota extractor reads nested camel case and clamps", testQuotaExtractorReadsNestedCamelCaseAndClamps),
    ("quota extractor reads quota and rate limits nesting", testQuotaExtractorReadsQuotaAndRateLimitsNesting),
    ("quota extractor requires weekly data", testQuotaExtractorRequiresBothWindows),
    ("quota extractor reads zero percent and reset dates", testQuotaExtractorReadsZeroPercentAndResetDates),
    ("old JSON decodes without quota", testStateSnapshotDecodesOldJSONWithoutQuota),
    ("legacy provider quota migrates", testStateSnapshotMigratesLegacyCodexProviderQuota),
    ("state JSON contains only current quota", testStateFileContainsOnlyCurrentQuotaKeys),
    ("hook log line", testHookLogLineIncludesEventAndTask),
    ("hook log line includes quota summary", testHookLogLineIncludesQuotaSummary),
    ("hook bridge updates quota and project audit", testHookBridgeUpdatesQuotaAndProjectAudit),
    ("hook bridge quota-only event skips project", testHookBridgeQuotaOnlyEventDoesNotRecordProject),
    ("session quota collector uses newest Codex event", testSessionQuotaCollectorUsesNewestCodexRateLimitEvent),
    ("session quota collector rejects legacy 300-minute event", testSessionQuotaCollectorRejectsLegacy300MinuteEvent),
    ("app-server quota mapper reads codex limit", testAppServerQuotaMapperReadsCodexLimitByExactDurations),
    ("app-server quota mapper falls back top-level", testAppServerQuotaMapperFallsBackToTopLevelRateLimits),
    ("app-server quota mapper clamps remaining", testAppServerQuotaMapperClampsRemainingPercent),
    ("app-server quota mapper reads reset times", testAppServerQuotaMapperReadsResetTimes),
    ("app-server quota mapper allows weekly-only window", testAppServerQuotaMapperAllowsWeeklyOnlyWindow),
    ("app-server quota mapper requires explicit weekly duration", testAppServerQuotaMapperRejectsWindowsWithoutWeeklyDuration),
    ("app-server quota mapper ignores individual limit", testAppServerQuotaMapperIgnoresIndividualLimitRemainingPercent),
    ("app-server JSON-RPC line codec builds request", testAppServerJSONRPCLineCodecBuildsRequest),
    ("app-server JSON-RPC line codec decodes target response", testAppServerJSONRPCLineCodecDecodesMessagesAndFindsTargetResponse),
    ("app-server quota collector uses transport fixture", testAppServerQuotaCollectorUsesTransportFixture),
    ("app-server quota collector preserves old quota on failure", testAppServerQuotaCollectorPropagatesMissingQuotaWithoutClearingStore),
    ("app-server quota errors describe specific timeouts", testAppServerQuotaErrorsDescribeSpecificTimeouts),
    ("app-server quota collector retries and succeeds", testAppServerQuotaCollectorRetriesTwiceAndSucceedsOnThirdAttempt),
    ("app-server quota collector exhausts retries", testAppServerQuotaCollectorFailsAfterThreeAttemptsAndPreservesQuota),
    ("quota refresh coordinator prevents concurrent refreshes", testQuotaRefreshCoordinatorPreventsConcurrentRefreshes),
    ("quota refresh coordinator throttles repeated logs", testQuotaRefreshCoordinatorThrottlesRepeatedFailureLogs),
    ("quota refresh countdown uses hours below one day", testQuotaRefreshCountdownUsesHoursBelowOneDay),
    ("quota display formatter uses natural date", testQuotaDisplayFormatterUsesNaturalChineseDate),
    ("team sync parses environment", testTeamSyncParsesEnvironmentFile),
    ("team device uses hardware names", testTeamDeviceUsesHardwareFamilyNames),
    ("team usage collector aggregates deltas", testTeamUsageCollectorBuildsDailySessionDelta),
    ("team quota report uses weekly data", testTeamQuotaReportUsesWeeklyPercentAndReset),
    ("team ranking URL uses website origin", testTeamRankingURLUsesWebsiteOrigin),
    ("team ranking decodes legacy today activity", testTeamRankingDecodesLegacyTodayActivity),
    ("team ranking decodes member weekly quota", testTeamRankingDecodesMemberWeeklyQuota),
    ("team ranking distinguishes joined members", testTeamRankingDistinguishesJoinedMemberFromInvitePlaceholder),
    ("avatar disk cache persists by URL", testAvatarDiskCachePersistsByRemoteURL),
    ("official Codex usage parses daily buckets", testOfficialCodexUsageParsesDailyBuckets),
    ("session counter uses local filename and metadata only", testSessionCounterUsesLocalFilenameAndMetadataWithoutReadingContents),
    ("grind history reads event timestamps only", testGrindHistoryCollectorReadsOnlyEventTimestamps),
    ("today live collector tails appended usage only", testTodayLiveCollectorStartsAtEOFAndCountsOnlyAppendedUsage),
    ("project audit sanitizes workspace and session", testProjectActivityStoreKeepsOnlySanitizedProjectAudit),
    ("desktop monitor installer migrates packaged monitor", testDesktopMonitorInstallerMigratesPackagedMonitor),
    ("client version comparison", testClientVersionComparison),
    ("client update signature verification", testClientUpdateVerifierAcceptsReleaseSignature),
    ("client update configuration", testClientUpdateConfigurationUsesTeamServerOrigin)
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
