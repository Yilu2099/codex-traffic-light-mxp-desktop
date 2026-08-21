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

func testWaitingTaskWinsOverWorkingAndDone() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let snapshot = StateSnapshot(
        aggregateState: .idle,
        updatedAt: now,
        tasks: [
            "task-working": TaskState(state: .working, workspace: "/tmp/a", source: "test", hookEventName: nil, message: nil, updatedAt: now),
            "task-done": TaskState(state: .done, workspace: "/tmp/b", source: "test", hookEventName: nil, message: nil, updatedAt: now),
            "task-waiting": TaskState(state: .waiting, workspace: "/tmp/c", source: "test", hookEventName: nil, message: nil, updatedAt: now)
        ]
    )

    try expectEqual(snapshot.computedAggregate(now: now), .waiting, "waiting should win over working and done")
}

func testWorkingWinsWhenNoWaitingTaskExists() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let snapshot = StateSnapshot(
        aggregateState: .idle,
        updatedAt: now,
        tasks: [
            "task-working": TaskState(state: .working, workspace: "/tmp/a", source: "test", hookEventName: nil, message: nil, updatedAt: now),
            "task-done": TaskState(state: .done, workspace: "/tmp/b", source: "test", hookEventName: nil, message: nil, updatedAt: now)
        ]
    )

    try expectEqual(snapshot.computedAggregate(now: now), .working, "working should win when no waiting task exists")
}

func testRecentDoneWinsWhenNoWaitingOrWorkingTaskExists() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let snapshot = StateSnapshot(
        aggregateState: .idle,
        updatedAt: now,
        tasks: [
            "task-done": TaskState(state: .done, workspace: "/tmp/b", source: "test", hookEventName: nil, message: nil, updatedAt: now.addingTimeInterval(-599))
        ]
    )

    try expectEqual(snapshot.computedAggregate(now: now), .done, "recent done should win when no waiting or working task exists")
}

func testExpiredDoneDoesNotParticipateInAggregate() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let snapshot = StateSnapshot(
        aggregateState: .idle,
        updatedAt: now,
        tasks: [
            "task-done": TaskState(state: .done, workspace: "/tmp/b", source: "test", hookEventName: nil, message: nil, updatedAt: now.addingTimeInterval(-601))
        ]
    )

    try expectEqual(snapshot.computedAggregate(now: now), .idle, "expired done should not participate in aggregate")
}

func testExpiredWorkingDoesNotParticipateInAggregate() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let snapshot = StateSnapshot(
        aggregateState: .idle,
        updatedAt: now,
        tasks: [
            "task-working": TaskState(state: .working, workspace: "/tmp/a", source: "test", hookEventName: nil, message: nil, updatedAt: now.addingTimeInterval(-91))
        ]
    )

    try expectEqual(snapshot.computedAggregate(now: now, workingTTL: 90), .idle, "expired working should not participate in aggregate")
}

func testPruningExpiredTasksRemovesStaleWorking() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let snapshot = StateSnapshot(
        aggregateState: .working,
        updatedAt: now.addingTimeInterval(-100),
        tasks: [
            "fresh-working": TaskState(state: .working, workspace: "/tmp/a", source: "test", hookEventName: nil, message: nil, updatedAt: now.addingTimeInterval(-10)),
            "stale-working": TaskState(state: .working, workspace: "/tmp/b", source: "test", hookEventName: nil, message: nil, updatedAt: now.addingTimeInterval(-91))
        ]
    )

    let pruned = snapshot.pruningExpiredTasks(now: now, workingTTL: 90)

    try expectEqual(pruned.tasks["fresh-working"]?.state, .working, "fresh working should remain")
    try expectEqual(pruned.tasks["stale-working"] == nil, true, "stale working should be pruned")
    try expectEqual(pruned.aggregateState, .working, "fresh working should keep aggregate working")
}

func testExpiredWaitingDoesNotBlockWorking() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let snapshot = StateSnapshot(
        aggregateState: .waiting,
        updatedAt: now,
        tasks: [
            "stale-waiting": TaskState(state: .waiting, workspace: "/tmp/a", source: "test", hookEventName: nil, message: nil, updatedAt: now.addingTimeInterval(-301)),
            "fresh-working": TaskState(state: .working, workspace: "/tmp/b", source: "test", hookEventName: nil, message: nil, updatedAt: now.addingTimeInterval(-10))
        ]
    )

    let pruned = snapshot.pruningExpiredTasks(now: now, workingTTL: 90, waitingTTL: 300)

    try expectEqual(pruned.tasks["stale-waiting"] == nil, true, "stale waiting should be pruned")
    try expectEqual(pruned.aggregateState, .working, "fresh working should win after stale waiting expires")
}

func testHookMapping() throws {
    try expectEqual(HookMapper.state(for: HookEvent(name: "UserPromptSubmit")), .working, "prompt submit should map to working")
    try expectEqual(HookMapper.state(for: HookEvent(name: "PreToolUse")), .working, "pre tool use should map to working")
    try expectEqual(HookMapper.state(for: HookEvent(name: "PermissionRequest")), .waiting, "permission request should map to waiting")
    try expectEqual(HookMapper.state(for: HookEvent(name: "Stop", lastAssistantMessage: "Implemented and verified.")), .done, "stop should map to done")
    try expectEqual(HookMapper.state(for: HookEvent(name: "Stop", lastAssistantMessage: "需要你确认授权后我才能继续。")), .done, "stop should not infer waiting from assistant text")
    try expectEqual(HookMapper.state(for: HookEvent(name: "Stop", lastAssistantMessage: "已生成配置文件，需要在系统设置里确认一次安装。")), .done, "system-settings confirmation instructions should not make stop waiting")
    try expectEqual(HookMapper.state(for: HookEvent(name: "SubagentStop", lastAssistantMessage: "Waiting for user approval.")), .done, "subagent stop should not infer waiting from assistant text")
}

func testCommandContract() throws {
    try expectEqual(CommandContract.lightCommandName, "codex-light-mxp", "light command should use mxp suffix")
    try expectEqual(CommandContract.hookCommandName, "codex-light-hook-mxp", "hook command should use mxp suffix")
    try expectEqual(CommandContract.quotaCommandName, "quota", "quota command should be named quota")
}

func testQuotaSnapshotClampsPercentValues() throws {
    let updatedAt = Date(timeIntervalSince1970: 1_234)

    let high = QuotaSnapshot(
        fiveHourRemainingPercent: 125,
        weeklyRemainingPercent: 101,
        source: "test",
        updatedAt: updatedAt
    )
    try expectEqual(high.fiveHourRemainingPercent, 100, "five hour quota should clamp high values")
    try expectEqual(high.weeklyRemainingPercent, 100, "weekly quota should clamp high values")

    let low = QuotaSnapshot(
        fiveHourRemainingPercent: -10,
        weeklyRemainingPercent: -1,
        source: "test",
        updatedAt: updatedAt
    )
    try expectEqual(low.fiveHourRemainingPercent, 0, "five hour quota should clamp low values")
    try expectEqual(low.weeklyRemainingPercent, 0, "weekly quota should clamp low values")
}

func testQuotaSnapshotStoresResetDates() throws {
    let updatedAt = Date(timeIntervalSince1970: 1_234)
    let fiveHourReset = Date(timeIntervalSince1970: 1_700)
    let weeklyReset = Date(timeIntervalSince1970: 2_400)

    let quota = QuotaSnapshot(
        fiveHourRemainingPercent: 0,
        weeklyRemainingPercent: 0,
        fiveHourResetsAt: fiveHourReset,
        weeklyResetsAt: weeklyReset,
        source: "test",
        updatedAt: updatedAt
    )

    try expectEqual(quota.fiveHourResetsAt, fiveHourReset, "five hour reset date should be stored")
    try expectEqual(quota.weeklyResetsAt, weeklyReset, "weekly reset date should be stored")
}

func testQuotaExtractorReadsTopLevelSnakeCase() throws {
    let data = """
    {
      "five_hour_remaining_percent": 72,
      "weekly_remaining_percent": 48
    }
    """.data(using: .utf8)!

    let values = QuotaExtractor.extract(from: data)

    try expectEqual(values?.fiveHourRemainingPercent, 72, "extractor should read snake_case five hour percent")
    try expectEqual(values?.weeklyRemainingPercent, 48, "extractor should read snake_case weekly percent")
}

func testQuotaExtractorReadsNestedCamelCaseAndClamps() throws {
    let data = """
    {
      "rateLimits": {
        "fiveHourRemainingPercent": 125,
        "weeklyRemainingPercent": -4
      }
    }
    """.data(using: .utf8)!

    let values = QuotaExtractor.extract(from: data)

    try expectEqual(values?.fiveHourRemainingPercent, 100, "extractor should clamp high five hour percent")
    try expectEqual(values?.weeklyRemainingPercent, 0, "extractor should clamp low weekly percent")
}

func testQuotaExtractorReadsQuotaAndRateLimitsNesting() throws {
    let quotaData = """
    {
      "metadata": {
        "quota": {
          "five_hour_remaining_percent": 64,
          "weekly_remaining_percent": 36
        }
      }
    }
    """.data(using: .utf8)!
    let rateLimitsData = """
    {
      "payload": {
        "rate_limits": {
          "five_hour_remaining_percent": "61",
          "weekly_remaining_percent": "35"
        }
      }
    }
    """.data(using: .utf8)!

    try expectEqual(QuotaExtractor.extract(from: quotaData)?.fiveHourRemainingPercent, 64, "extractor should recurse into quota objects")
    try expectEqual(QuotaExtractor.extract(from: quotaData)?.weeklyRemainingPercent, 36, "extractor should recurse into quota objects")
    try expectEqual(QuotaExtractor.extract(from: rateLimitsData)?.fiveHourRemainingPercent, 61, "extractor should recurse into rate_limits objects")
    try expectEqual(QuotaExtractor.extract(from: rateLimitsData)?.weeklyRemainingPercent, 35, "extractor should parse numeric string percents")
}

func testQuotaExtractorRequiresBothWindows() throws {
    let data = """
    {
      "quota": {
        "five_hour_remaining_percent": 72
      }
    }
    """.data(using: .utf8)!

    try expectEqual(QuotaExtractor.extract(from: data) == nil, true, "extractor should ignore incomplete quota data")
}

func testQuotaExtractorReadsZeroPercentAndResetDates() throws {
    let data = """
    {
      "quota": {
        "five_hour_remaining_percent": 0,
        "weekly_remaining_percent": 0,
        "five_hour_resets_at": 1781189000,
        "weekly_resets_at": 1781275400
      }
    }
    """.data(using: .utf8)!

    let quota = QuotaExtractor.extract(from: data)

    try expectEqual(quota?.fiveHourRemainingPercent, 0, "extractor should read exhausted 5 hour quota")
    try expectEqual(quota?.weeklyRemainingPercent, 0, "extractor should read exhausted weekly quota")
    try expectEqual(quota?.fiveHourResetsAt, Date(timeIntervalSince1970: 1_781_189_000), "extractor should read five hour reset date")
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

    try expectEqual(snapshot.aggregateState, .idle, "old JSON should decode aggregate state")
    try expectEqual(snapshot.updatedAt, Date(timeIntervalSince1970: 1_000), "old JSON should decode updated_at")
    try expectEqual(snapshot.tasks.isEmpty, true, "old JSON should decode tasks")
    try expectEqual(snapshot.quota == nil, true, "old JSON without quota should decode nil quota")
    try expectEqual(snapshot.providerQuotas.isEmpty, true, "old JSON should default providerQuotas to empty")
}

func testStateStoreUpdatesProviderQuotaWithoutReplacingOtherProviderData() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-provider-quota-tests-\(UUID().uuidString)", isDirectory: true)
    let store = StateStore(stateURL: directory.appendingPathComponent("state.json"))
    _ = try store.updateQuota(
        fiveHourPercent: 72,
        weeklyPercent: 48,
        source: "codex"
    )
    let updated = try store.updateProviderQuota(
        providerID: ProviderQuotaSnapshot.claudeProviderID,
        sessionPercent: 44,
        source: "claude"
    )

    try expectEqual(updated.providerQuota(for: ProviderQuotaSnapshot.codexProviderID)?.fiveHourRemainingPercent, 72, "codex quota should remain after claude update")
    try expectEqual(updated.providerQuota(for: ProviderQuotaSnapshot.claudeProviderID)?.sessionRemainingPercent, 44, "claude session quota should be written")
    try expectEqual(updated.providerQuota(for: ProviderQuotaSnapshot.claudeProviderID)?.weeklyRemainingPercent, nil, "claude weekly quota should stay nil when not updated")
    try expectEqual(updated.providerQuotas.keys.contains(ProviderQuotaSnapshot.codexProviderID), true, "provider map should keep codex key")
    try expectEqual(updated.providerQuotas.keys.contains(ProviderQuotaSnapshot.claudeProviderID), true, "provider map should keep claude key")
}

func testClaudeUsageQuotaParseSessionAndWeekly() throws {
    let output = """
    Current session:
    Used: 72%, left: 28%.
    Resets in 3 hours 12 minutes.

    Current week:
    Remaining: 68%.
    Resets: Fri, Jul 6, 8:30 PM
    """

    let values = try ClaudeUsageQuotaCollector.parse(output)
    try expectEqual(values.sessionRemainingPercent, 28, "session parse should read percent")
    try expectEqual(values.weeklyRemainingPercent, 68, "weekly parse should read percent")
    try expectEqual(values.sessionResetsAt == nil, false, "session reset time should parse")
    try expectEqual(values.weeklyResetsAt == nil, false, "weekly reset time should parse")
}

func testStateStoreClearAndIdleTaskRemoval() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-tests-\(UUID().uuidString)", isDirectory: true)
    let store = StateStore(stateURL: directory.appendingPathComponent("state.json"))
    let now = Date()

    _ = try store.updateTask(
        taskID: "task-1",
        state: .waiting,
        workspace: "/tmp/project",
        source: "test",
        hookEventName: "PermissionRequest",
        message: "needs approval",
        now: now
    )
    try expectEqual(store.read().aggregateState, .waiting, "waiting task should make aggregate waiting")

    _ = try store.updateTask(
        taskID: "task-1",
        state: .idle,
        workspace: "/tmp/project",
        source: "test",
        hookEventName: nil,
        message: nil,
        now: now.addingTimeInterval(1)
    )
    try expectEqual(store.read().tasks.isEmpty, true, "idle should remove one task")
    try expectEqual(store.read().aggregateState, .idle, "idle after removing last task")

    _ = try store.updateTask(
        taskID: "task-2",
        state: .working,
        workspace: "/tmp/project",
        source: "test",
        hookEventName: "PreToolUse",
        message: nil,
        now: now.addingTimeInterval(2)
    )
    _ = try store.clear(now: now.addingTimeInterval(3))
    try expectEqual(store.read().tasks.isEmpty, true, "clear should remove all tasks")
    try expectEqual(store.read().aggregateState, .idle, "clear should set aggregate idle")
}

func testStateFileUsesPlannedJSONKeys() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-json-tests-\(UUID().uuidString)", isDirectory: true)
    let stateURL = directory.appendingPathComponent("state.json")
    let store = StateStore(stateURL: stateURL)
    _ = try store.updateTask(
        taskID: "workspace:/tmp/project:default",
        state: .working,
        workspace: "/tmp/project",
        source: "codex-hook",
        hookEventName: "PreToolUse",
        message: "Codex traffic light: working",
        now: Date(timeIntervalSince1970: 3_000)
    )

    let body = try String(contentsOf: stateURL, encoding: .utf8)
    if !body.contains("\"aggregate_state\"") || !body.contains("\"hook_event_name\"") || !body.contains("\"updated_at\"") {
        throw TestFailure(description: "state JSON should use planned snake_case keys: \(body)")
    }
}

func testReadPreservesQuitAggregateState() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-quit-tests-\(UUID().uuidString)", isDirectory: true)
    let store = StateStore(stateURL: directory.appendingPathComponent("state.json"))
    let now = Date(timeIntervalSince1970: 4_000)
    _ = try store.updateTask(
        taskID: "task-running",
        state: .working,
        workspace: "/tmp/project",
        source: "test",
        hookEventName: nil,
        message: nil,
        now: now
    )
    _ = try store.updateTask(
        taskID: "manual",
        state: .quit,
        workspace: "/tmp/project",
        source: "test",
        hookEventName: nil,
        message: "quit",
        now: now.addingTimeInterval(1)
    )

    try expectEqual(store.read().aggregateState, .quit, "read should preserve quit aggregate state")
}

func testUpdateQuotaPreservesTasksAndAggregateState() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-quota-update-tests-\(UUID().uuidString)", isDirectory: true)
    let store = StateStore(stateURL: directory.appendingPathComponent("state.json"))
    let now = Date()
    _ = try store.updateTask(
        taskID: "task-1",
        state: .waiting,
        workspace: "/tmp/project",
        source: "test",
        hookEventName: "PermissionRequest",
        message: "needs approval",
        now: now
    )

    let snapshot = try store.updateQuota(
        fiveHourPercent: 72,
        weeklyPercent: 48,
        fiveHourResetsAt: now.addingTimeInterval(301),
        weeklyResetsAt: now.addingTimeInterval(10_081),
        source: "test",
        now: now.addingTimeInterval(1)
    )

    try expectEqual(snapshot.aggregateState, .waiting, "quota update should preserve aggregate state")
    try expectEqual(snapshot.tasks.count, 1, "quota update should preserve tasks")
    try expectEqual(snapshot.tasks["task-1"]?.state, .waiting, "quota update should preserve task state")
    try expectEqual(snapshot.quota?.fiveHourRemainingPercent, 72, "quota update should set five hour percent")
    try expectEqual(snapshot.quota?.weeklyRemainingPercent, 48, "quota update should set weekly percent")
    try expectEqual(snapshot.quota?.source, "test", "quota update should set source")
    try expectEqual(snapshot.quota?.updatedAt, now.addingTimeInterval(1), "quota update should set quota updatedAt")
    try expectEqual(snapshot.quota?.fiveHourResetsAt, now.addingTimeInterval(301), "quota update should set five hour reset date")
    try expectEqual(snapshot.quota?.weeklyResetsAt, now.addingTimeInterval(10_081), "quota update should set weekly reset date")
}

func testClearPreservesQuota() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-quota-clear-tests-\(UUID().uuidString)", isDirectory: true)
    let store = StateStore(stateURL: directory.appendingPathComponent("state.json"))
    let now = Date(timeIntervalSince1970: 7_000)
    _ = try store.updateTask(
        taskID: "task-1",
        state: .working,
        workspace: "/tmp/project",
        source: "test",
        hookEventName: "PreToolUse",
        message: nil,
        now: now
    )
    let withQuota = try store.updateQuota(
        fiveHourPercent: 34,
        weeklyPercent: 88,
        source: "test",
        now: now.addingTimeInterval(1)
    )

    let snapshot = try store.clear(now: now.addingTimeInterval(2))

    try expectEqual(snapshot.tasks.isEmpty, true, "clear should remove tasks")
    try expectEqual(snapshot.aggregateState, .idle, "clear should set aggregate idle")
    try expectEqual(snapshot.quota, withQuota.quota, "clear should preserve quota")
}

func testFloatingWidgetLayoutKeepsQuotaHudClearOfGreenLight() throws {
    let layout = TrafficLightLayout.default

    try expect(
        layout.hudRect.minX >= layout.bodyRect.minX
            && layout.hudRect.maxX <= layout.bodyRect.maxX
            && layout.hudRect.minY >= layout.bodyRect.minY
            && layout.hudRect.maxY <= layout.bodyRect.maxY,
        "HUD background should stay inside the traffic light body"
    )
    for slot in TrafficLightSlot.allCases {
        let glow = layout.glowRect(for: slot)
        try expect(
            !glow.intersects(layout.statusRect),
            "\(slot.rawValue) glow should not overlap status text"
        )
        for row in layout.quotaRows {
            try expect(
                !glow.intersects(row.textRect) && !glow.intersects(row.progressRect),
                "\(slot.rawValue) glow should not overlap quota row \(row.label)"
            )
        }
    }

    for row in layout.quotaRows {
        try expect(
            !layout.statusRect.intersects(row.textRect) && !layout.statusRect.intersects(row.progressRect),
            "status text should not overlap quota row \(row.label)"
        )
        try expect(
            row.textRect.minY >= layout.bodyRect.minY + layout.bottomSafeInset,
            "quota row \(row.label) should stay above bottom safe inset"
        )
        try expect(
            row.progressRect.minY >= layout.bodyRect.minY + layout.bottomSafeInset,
            "quota progress \(row.label) should stay above bottom safe inset"
        )
        try expect(
            row.valueRect.width >= layout.minimumPercentTextWidth,
            "quota value column should fit 100%"
        )
    }
}

func testHookLogLineIncludesEventStateAndTask() throws {
    let entry = HookLogEntry(
        timestamp: Date(timeIntervalSince1970: 5_000),
        eventName: "Stop",
        state: .done,
        taskID: "session:abc",
        workspace: "/tmp/project",
        result: "ok",
        detail: nil
    )

    let line = HookLogger.format(entry)
    if !line.contains("event=Stop")
        || !line.contains("state=done")
        || !line.contains("task=session:abc")
        || !line.contains("workspace=/tmp/project")
        || !line.contains("result=ok") {
        throw TestFailure(description: "hook log line should include event, state, task, workspace, and result: \(line)")
    }
}

func testHookLogLineIncludesQuotaSummary() throws {
    let entry = HookLogEntry(
        timestamp: Date(timeIntervalSince1970: 5_001),
        eventName: "PreToolUse",
        state: .working,
        taskID: "session:abc",
        workspace: "/tmp/project",
        result: "ok",
        detail: nil,
        quotaSummary: "72/48"
    )

    let line = HookLogger.format(entry)

    if !line.contains("quota=72/48") {
        throw TestFailure(description: "hook log line should include quota summary: \(line)")
    }
}

func testHookBridgeUpdatesTaskAndQuotaFromPayload() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-hook-quota-tests-\(UUID().uuidString)", isDirectory: true)
    let store = StateStore(stateURL: directory.appendingPathComponent("state.json"))
    let input = """
    {
      "hook_event_name": "PreToolUse",
      "session_id": "abc",
      "cwd": "/tmp/project",
      "quota": {
        "fiveHourRemainingPercent": 71,
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

    try expectEqual(result.quotaSummary, "71/47", "hook bridge should report quota summary")
    try expectEqual(snapshot.aggregateState, .working, "hook bridge should preserve task mapping")
    try expectEqual(snapshot.tasks["session:abc"]?.state, .working, "hook bridge should update task")
    try expectEqual(snapshot.quota?.fiveHourRemainingPercent, 71, "hook bridge should update five hour quota")
    try expectEqual(snapshot.quota?.weeklyRemainingPercent, 47, "hook bridge should update weekly quota")
    try expectEqual(snapshot.quota?.source, "codex-hook", "hook bridge should mark quota source")
}

func testHookBridgeQuotaOnlyEventDoesNotCreateTask() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-quota-only-hook-tests-\(UUID().uuidString)", isDirectory: true)
    let store = StateStore(stateURL: directory.appendingPathComponent("state.json"))
    let now = Date()
    _ = try store.updateTask(
        taskID: "task-1",
        state: .waiting,
        workspace: "/tmp/project",
        source: "test",
        hookEventName: "PermissionRequest",
        message: nil,
        now: now
    )
    let input = """
    {
      "hook_event_name": "account/rateLimits/updated",
      "rate_limits": {
        "five_hour_remaining_percent": 69,
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

    try expectEqual(result.updatedTask, false, "quota-only event should not update a task")
    try expectEqual(snapshot.tasks.count, 1, "quota-only event should not create a task")
    try expectEqual(snapshot.aggregateState, .waiting, "quota-only event should not change aggregate priority")
    try expectEqual(snapshot.quota?.fiveHourRemainingPercent, 69, "quota-only event should update five hour quota")
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

    try expectEqual(quota.fiveHourRemainingPercent, Optional(72), "mapper should prefer codex 5 hour window")
    try expectEqual(quota.weeklyRemainingPercent, Optional(48), "mapper should prefer codex weekly window")
}

func testAppServerQuotaMapperFallsBackToTopLevelRateLimits() throws {
    let topLevel = appServerSnapshot(primaryUsed: 39, primaryDuration: 300, secondaryUsed: 65, secondaryDuration: 10_080)
    let data = appServerRateLimitsResponse(rateLimits: topLevel)

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: data)

    try expectEqual(quota.fiveHourRemainingPercent, Optional(61), "mapper should read top-level 5 hour window")
    try expectEqual(quota.weeklyRemainingPercent, Optional(35), "mapper should read top-level weekly window")
}

func testAppServerQuotaMapperClampsRemainingPercent() throws {
    let codex = appServerSnapshot(primaryUsed: -20, primaryDuration: 300, secondaryUsed: 125, secondaryDuration: 10_080)
    let data = appServerRateLimitsResponse(rateLimitsByLimitId: #"{"codex": \#(codex)}"#)

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: data)

    try expectEqual(quota.fiveHourRemainingPercent, Optional(100), "mapper should clamp remaining above 100")
    try expectEqual(quota.weeklyRemainingPercent, Optional(0), "mapper should clamp remaining below 0")
}

func testAppServerQuotaMapperReadsResetTimes() throws {
    let codex = appServerSnapshot(primaryUsed: 100, primaryDuration: 300, secondaryUsed: 100, secondaryDuration: 10_080)
    let data = appServerRateLimitsResponse(rateLimitsByLimitId: #"{"codex": \#(codex)}"#)

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: data)

    try expectEqual(quota.fiveHourRemainingPercent, Optional(0), "mapper should read exhausted 5 hour quota")
    try expectEqual(quota.weeklyRemainingPercent, Optional(0), "mapper should read exhausted weekly quota")
    try expectEqual(quota.fiveHourResetsAt, Date(timeIntervalSince1970: 1_781_189_000), "mapper should read five hour reset date")
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

    try expectEqual(quota.fiveHourRemainingPercent, nil, "mapper should keep weekly-only result with missing five-hour")
    try expectEqual(quota.weeklyRemainingPercent, Optional(45), "mapper should read weekly percent when weekly-only window is present")
}

func testAppServerQuotaMapperFallsBackToPrimarySecondaryWhenDurationsAreMissing() throws {
    let codex = appServerSnapshot(primaryUsed: 30, primaryDuration: nil, secondaryUsed: 55, secondaryDuration: nil)
    let data = appServerRateLimitsResponse(rateLimitsByLimitId: #"{"codex": \#(codex)}"#)

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: data)

    try expectEqual(quota.fiveHourRemainingPercent, Optional(70), "mapper should use primary as 5 hour when durations are missing")
    try expectEqual(quota.weeklyRemainingPercent, Optional(45), "mapper should use secondary as weekly when durations are missing")
}

func testAppServerQuotaMapperIgnoresIndividualLimitRemainingPercent() throws {
    let codex = appServerSnapshot(primaryUsed: 28, primaryDuration: 300, secondaryUsed: 52, secondaryDuration: 10_080, individualRemaining: 3)
    let data = appServerRateLimitsResponse(rateLimitsByLimitId: #"{"codex": \#(codex)}"#)

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: data)

    try expectEqual(quota.fiveHourRemainingPercent, Optional(72), "mapper should not use individual limit for 5 hour quota")
    try expectEqual(quota.weeklyRemainingPercent, Optional(48), "mapper should not use individual limit for weekly quota")
}

func testAppServerJSONRPCFramerBuildsContentLengthRequest() throws {
    let request = try CodexAppServerJSONRPCFramer.encodeRequest(id: 2, method: "account/rateLimits/read")
    let text = String(data: request, encoding: .utf8) ?? ""
    let messages = try CodexAppServerJSONRPCFramer.decodeMessages(from: request)
    let body = try JSONSerialization.jsonObject(with: messages[0]) as? [String: Any]

    try expect(text.hasPrefix("Content-Length: "), "framer should write a content length header")
    try expect(text.contains("\r\n\r\n"), "framer should separate headers from JSON body")
    try expectEqual(body?["id"] as? Int, 2, "framer should include request id")
    try expectEqual(body?["method"] as? String, "account/rateLimits/read", "framer should include method")
}

func testAppServerJSONRPCFramerDecodesMessagesAndFindsTargetResponse() throws {
    let notification = try CodexAppServerJSONRPCFramer.encodeMessage([
        "jsonrpc": "2.0",
        "method": "account/rateLimits/updated",
        "params": ["rateLimits": ["primary": NSNull()]]
    ])
    let response = try CodexAppServerJSONRPCFramer.encodeMessage([
        "jsonrpc": "2.0",
        "id": 2,
        "result": [
            "rateLimits": NSNull(),
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex",
                    "limitName": "Codex",
                    "primary": ["usedPercent": 28, "windowDurationMins": 300, "resetsAt": 1781189000],
                    "secondary": ["usedPercent": 52, "windowDurationMins": 10_080, "resetsAt": 1781189000],
                    "credits": NSNull(),
                    "individualLimit": NSNull(),
                    "planType": NSNull(),
                    "rateLimitReachedType": NSNull()
                ]
            ]
        ]
    ])
    let messages = try CodexAppServerJSONRPCFramer.decodeMessages(from: notification + response)
    let target = try CodexAppServerJSONRPCFramer.resultData(forID: 2, in: messages)

    let quota = try CodexAppServerQuotaMapper.quotaValues(from: target)

    try expectEqual(messages.count, 2, "framer should decode both framed messages")
    try expectEqual(quota.fiveHourRemainingPercent, Optional(72), "framer should select target response result")
    try expectEqual(quota.weeklyRemainingPercent, Optional(48), "framer should select target response result")
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
    try expectEqual(quota.fiveHourRemainingPercent, Optional(70), "line codec should select target response result")
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

    try expectEqual(quota.fiveHourRemainingPercent, Optional(72), "collector should return mapped 5 hour quota")
    try expectEqual(quota.weeklyRemainingPercent, Optional(48), "collector should return mapped weekly quota")
}

func testAppServerQuotaCollectorPropagatesMissingQuotaWithoutClearingStore() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-app-server-failure-tests-\(UUID().uuidString)", isDirectory: true)
    let store = StateStore(stateURL: directory.appendingPathComponent("state.json"))
    _ = try store.updateQuota(
        fiveHourPercent: 12,
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
    try expectEqual(snapshot.quota?.fiveHourRemainingPercent, 12, "failed app-server fetch should keep previous 5 hour quota")
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
    try expectEqual(quota.fiveHourRemainingPercent, Optional(72), "collector should return quota from successful retry")
    try expectEqual(quota.weeklyRemainingPercent, Optional(48), "collector should return quota from successful retry")
}

func testAppServerQuotaCollectorFailsAfterThreeAttemptsAndPreservesQuota() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-light-mxp-app-server-retry-failure-tests-\(UUID().uuidString)", isDirectory: true)
    let store = StateStore(stateURL: directory.appendingPathComponent("state.json"))
    _ = try store.updateQuota(
        fiveHourPercent: 12,
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
    try expectEqual(snapshot.quota?.fiveHourRemainingPercent, 12, "failed retries should keep previous 5 hour quota")
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

func testQuotaDisplayFormatterOmitsZeroUnits() throws {
    let now = Date(timeIntervalSince1970: 10_000)

    try expectEqual(
        QuotaDisplayFormatter.relativeResetText(until: now.addingTimeInterval(30), now: now, unitStyle: .daysAndHours),
        "还有1分",
        "days-and-hours style should not show 0天0小时"
    )
    try expectEqual(
        QuotaDisplayFormatter.relativeResetText(until: now.addingTimeInterval(3_600), now: now, unitStyle: .daysAndHours),
        "还有1小时",
        "days-and-hours style should omit 0天"
    )
    try expectEqual(
        QuotaDisplayFormatter.relativeResetText(until: now.addingTimeInterval(86_400), now: now, unitStyle: .daysAndHours),
        "还有1天",
        "days-and-hours style should omit 0小时"
    )
    try expectEqual(
        QuotaDisplayFormatter.relativeResetText(until: now.addingTimeInterval(30), now: now, unitStyle: .hoursAndMinutes),
        "还有1分",
        "hours-and-minutes style should not show 0小时0分"
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
    """.data(using: .utf8)!
    let sessions = CodexTeamUsageCollector().parseSessionData(
        data,
        sessionID: "session-1",
        configuration: configuration,
        device: device
    )
    try expectEqual(sessions.count, 1, "collector should aggregate a session into one daily record")
    try expectEqual(sessions.first?.totalTokens, 150, "collector should add cumulative deltas without double counting")
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

func testOfficialCodexUsageParsesDailyBuckets() throws {
    let data = """
    {"summary":{"lifetimeTokens":1200,"peakDailyTokens":700},"dailyUsageBuckets":[{"startDate":"2026-08-20","tokens":500},{"startDate":"2026-08-21","tokens":700}],"threadUsage":null}
    """.data(using: .utf8)!
    let report = try OfficialCodexUsageCollector.parse(data, now: Date(timeIntervalSince1970: 1_000))
    try expectEqual(report.lifetimeTokens, 1_200, "official usage should read lifetime tokens")
    try expectEqual(report.dailyUsageBuckets.last?.tokens, 700, "official usage should read daily token buckets")
    try expectEqual(report.dataThrough, "2026-08-21", "official usage should expose its latest settled day")
}

func testSessionCounterReadsTimestampFromFilenameOnly() throws {
    let counter = CodexSessionFileCounter()
    let date = counter.timestampFromFilename("rollout-2026-08-20T15-20-05-01a01e0a-969e-7b82-82e3-cb289445d9be.jsonl")
    try expect(date != nil, "session counter should read the timestamp encoded in a filename")
    try expectEqual(Int(date!.timeIntervalSince1970), 1_787_239_205, "session counter should parse the filename without opening its contents")
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

let tests: [(String, () throws -> Void)] = [
    ("waiting wins over working and done", testWaitingTaskWinsOverWorkingAndDone),
    ("working wins without waiting", testWorkingWinsWhenNoWaitingTaskExists),
    ("recent done wins", testRecentDoneWinsWhenNoWaitingOrWorkingTaskExists),
    ("expired done idles", testExpiredDoneDoesNotParticipateInAggregate),
    ("expired working idles", testExpiredWorkingDoesNotParticipateInAggregate),
    ("pruning removes stale working", testPruningExpiredTasksRemovesStaleWorking),
    ("expired waiting does not block working", testExpiredWaitingDoesNotBlockWorking),
    ("hook mapping", testHookMapping),
    ("command contract", testCommandContract),
    ("quota snapshot clamps", testQuotaSnapshotClampsPercentValues),
    ("quota snapshot stores reset dates", testQuotaSnapshotStoresResetDates),
    ("quota extractor reads top-level snake case", testQuotaExtractorReadsTopLevelSnakeCase),
    ("quota extractor reads nested camel case and clamps", testQuotaExtractorReadsNestedCamelCaseAndClamps),
    ("quota extractor reads quota and rate limits nesting", testQuotaExtractorReadsQuotaAndRateLimitsNesting),
    ("quota extractor requires both windows", testQuotaExtractorRequiresBothWindows),
    ("quota extractor reads zero percent and reset dates", testQuotaExtractorReadsZeroPercentAndResetDates),
    ("old JSON decodes without quota", testStateSnapshotDecodesOldJSONWithoutQuota),
    ("state store clear and idle", testStateStoreClearAndIdleTaskRemoval),
    ("provider quota update keeps existing providers", testStateStoreUpdatesProviderQuotaWithoutReplacingOtherProviderData),
    ("claude usage parse reads session and weekly", testClaudeUsageQuotaParseSessionAndWeekly),
    ("state JSON keys", testStateFileUsesPlannedJSONKeys),
    ("read preserves quit", testReadPreservesQuitAggregateState),
    ("update quota preserves tasks and aggregate", testUpdateQuotaPreservesTasksAndAggregateState),
    ("clear preserves quota", testClearPreservesQuota),
    ("floating widget layout separates quota HUD", testFloatingWidgetLayoutKeepsQuotaHudClearOfGreenLight),
    ("hook log line", testHookLogLineIncludesEventStateAndTask),
    ("hook log line includes quota summary", testHookLogLineIncludesQuotaSummary),
    ("hook bridge updates task and quota", testHookBridgeUpdatesTaskAndQuotaFromPayload),
    ("hook bridge quota-only event does not create task", testHookBridgeQuotaOnlyEventDoesNotCreateTask),
    ("app-server quota mapper reads codex limit", testAppServerQuotaMapperReadsCodexLimitByExactDurations),
    ("app-server quota mapper falls back top-level", testAppServerQuotaMapperFallsBackToTopLevelRateLimits),
    ("app-server quota mapper clamps remaining", testAppServerQuotaMapperClampsRemainingPercent),
    ("app-server quota mapper reads reset times", testAppServerQuotaMapperReadsResetTimes),
    ("app-server quota mapper allows weekly-only window", testAppServerQuotaMapperAllowsWeeklyOnlyWindow),
    ("app-server quota mapper falls back primary secondary", testAppServerQuotaMapperFallsBackToPrimarySecondaryWhenDurationsAreMissing),
    ("app-server quota mapper ignores individual limit", testAppServerQuotaMapperIgnoresIndividualLimitRemainingPercent),
    ("app-server JSON-RPC framer builds request", testAppServerJSONRPCFramerBuildsContentLengthRequest),
    ("app-server JSON-RPC framer decodes target response", testAppServerJSONRPCFramerDecodesMessagesAndFindsTargetResponse),
    ("app-server JSON-RPC line codec builds request", testAppServerJSONRPCLineCodecBuildsRequest),
    ("app-server JSON-RPC line codec decodes target response", testAppServerJSONRPCLineCodecDecodesMessagesAndFindsTargetResponse),
    ("app-server quota collector uses transport fixture", testAppServerQuotaCollectorUsesTransportFixture),
    ("app-server quota collector preserves old quota on failure", testAppServerQuotaCollectorPropagatesMissingQuotaWithoutClearingStore),
    ("app-server quota errors describe specific timeouts", testAppServerQuotaErrorsDescribeSpecificTimeouts),
    ("app-server quota collector retries and succeeds", testAppServerQuotaCollectorRetriesTwiceAndSucceedsOnThirdAttempt),
    ("app-server quota collector exhausts retries", testAppServerQuotaCollectorFailsAfterThreeAttemptsAndPreservesQuota),
    ("quota refresh coordinator prevents concurrent refreshes", testQuotaRefreshCoordinatorPreventsConcurrentRefreshes),
    ("quota refresh coordinator throttles repeated logs", testQuotaRefreshCoordinatorThrottlesRepeatedFailureLogs),
    ("quota display formatter omits zero units", testQuotaDisplayFormatterOmitsZeroUnits),
    ("quota display formatter uses natural date", testQuotaDisplayFormatterUsesNaturalChineseDate),
    ("team sync parses environment", testTeamSyncParsesEnvironmentFile),
    ("team device uses hardware names", testTeamDeviceUsesHardwareFamilyNames),
    ("team usage collector aggregates deltas", testTeamUsageCollectorBuildsDailySessionDelta),
    ("team quota report uses weekly data", testTeamQuotaReportUsesWeeklyPercentAndReset),
    ("team ranking URL uses website origin", testTeamRankingURLUsesWebsiteOrigin),
    ("team ranking decodes legacy today activity", testTeamRankingDecodesLegacyTodayActivity),
    ("team ranking decodes member weekly quota", testTeamRankingDecodesMemberWeeklyQuota),
    ("official Codex usage parses daily buckets", testOfficialCodexUsageParsesDailyBuckets),
    ("session counter uses filenames only", testSessionCounterReadsTimestampFromFilenameOnly),
    ("today live collector tails appended usage only", testTodayLiveCollectorStartsAtEOFAndCountsOnlyAppendedUsage)
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
