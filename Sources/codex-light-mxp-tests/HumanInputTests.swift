import Foundation
import CodexTrafficLightCore

private final class InputAsyncBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    func set(_ value: Result<T, Error>) { lock.lock(); defer { lock.unlock() }; result = value }
    func get() throws -> T { lock.lock(); defer { lock.unlock() }; return try result!.get() }
}
private func inputAwait<T: Sendable>(_ block: @escaping @Sendable () async throws -> T) throws -> T {
    let done = DispatchSemaphore(value: 0), box = InputAsyncBox<T>()
    Task.detached { do { box.set(.success(try await block())) } catch { box.set(.failure(error)) }; done.signal() }
    guard done.wait(timeout: .now() + 20) == .success else { throw TestFailure(description: "input test timed out") }
    return try box.get()
}
private actor DotInputFixture: DotInputReadTransport {
    let wrongOwner: Bool
    var requested: [String] = []
    init(wrongOwner: Bool = false) { self.wrongOwner = wrongOwner }
    func route(origin: String, override: String) throws {
        try expectEqual(origin, "https://chatgpt.com", "same-account route")
    }
    func get(_ path: String, query: [String: String]) throws -> Data {
        requested.append(path)
        let value: String
        switch path {
        case "/wham/accounts/check": value = #"{"accounts":[{"id":"account","account_user_id":"workspace-alias","structure":"personal","workspace_backend_origin":"NO_CONSTRAINT","account_routing_override":"NO_CONSTRAINT"}]}"#
        case "/tbo/primary": value = #"{"selection":{"aeon_id":"dot","messaging_room_id":"room","thread_id":"root","available":true},"profile":{"id":"dot","messaging_room_id":"room","active_root_thread_id":"root","messaging_room_preview":"PRIVATE"}}"#
        case "/messaging/rooms/room": value = "{\"id\":\"room\",\"type\":\"DM\",\"app_source\":\"chatgpt:messaging\",\"aeon_id\":\"dot\",\"members\":[{\"account_user_id\":\"\(wrongOwner ? "other" : "user")\"},{\"account_user_id\":\"dot-user\",\"aeon_id\":\"dot\"}]}"
        default:
            value = #"{"items":[{"id":"human","account_user_id":"user","role":"user","created_at":"2026-10-14T17:13:03.734841Z","updated_at":"2026-10-14T20:59:00Z","content":{"text":"PRIVATE PROMPT"}},{"id":"human","account_user_id":"user","role":"user","created_at":"2026-10-14T17:13:03.734841Z"},{"id":"automatic","account_user_id":"user","role":"user","created_at":"2026-10-14T20:59:00Z","message_metadata":{"turn_trigger":"automation_heartbeat_timer"}},{"id":"dot-reply","account_user_id":"dot-user","role":"user","created_at":"2026-10-14T20:59:00Z","content":{"text":"PRIVATE REPLY"}},{"id":"no-time","account_user_id":"user","role":"user"},{"id":"future","account_user_id":"user","role":"user","created_at":"2026-10-16T20:59:00Z"},{"id":"other-room","room_id":"different","account_user_id":"user","role":"user","created_at":"2026-10-14T17:14:00Z"}],"prev_cursor":null}"#
        }
        return Data(value.utf8)
    }
}

func testDotHumanInputReadOnly() throws {
    let report = try inputAwait {
        try await DotInputCollector().collect(identity: DotInputIdentity(account: "account", user: "user"),
            transport: DotInputFixture(), salt: Data(repeating: 7, count: 32), now: DotInputCollector.parse("2026-10-14T21:00:00Z")!)
    }
    try expectEqual(report.ownerMessages.count, 1, "duplicate input only counted once")
    try expectEqual(report.lastOwnerMessageAt, "2026-10-14T17:13:03.734841Z", "keep original creation precision, ignore update time")
    try expectEqual(report.excludedAutomaticMessages, 1, "automatic owner messages excluded")
    try expectEqual(report.excludedDotMessages, 1, "dot can also use role=user; bind actual sender")
    try expectEqual(report.invalidMessages, 3, "missing time, future or wrong room do not fabricate input")
    let encoded = String(data: try JSONEncoder().encode(report), encoding: .utf8)!
    for secret in ["PRIVATE", "workspace-alias", "dot-user", "human\"", "access_token"] {
        try expect(!encoded.contains(secret), "report excludes text and original identity")
    }
    var refused = false
    do {
        _ = try inputAwait { try await DotInputCollector().collect(identity: DotInputIdentity(account: "account", user: "user"), transport: DotInputFixture(wrongOwner: true), salt: Data(repeating: 7, count: 32)) }
    } catch { refused = true }
    try expect(refused, "wrong member must stop before message reads")
}

func testNativeHumanInputProvenance() throws {
    let lines = [
        #"{"timestamp":"2026-10-14T17:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_attribution":{"turn_trigger":"automation_heartbeat_timer"}}}"#,
        #"{"timestamp":"2026-10-14T17:00:01Z","type":"response_item","payload":{"type":"message","role":"user","id":"auto","content":[{"type":"input_text","text":"continue"}]}}"#,
        #"{"timestamp":"2026-10-14T17:01:00Z","type":"response_item","payload":{"type":"message","role":"user","id":"steer","content":[{"type":"input_text","text":"human steering"}]}}"#,
        #"{"timestamp":"2026-10-14T17:02:00Z","type":"event_msg","payload":{"type":"task_started","turn_attribution":{"turn_trigger":"composer"}}}"#,
        #"{"timestamp":"2026-10-14T17:02:01Z","type":"response_item","payload":{"type":"message","role":"user","id":"manual","content":[{"type":"input_text","text":"manual prompt"}]}}"#,
        #"{"timestamp":"2026-10-14T17:03:00Z","type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"timestamp":"2026-10-14T17:03:01Z","type":"response_item","payload":{"type":"message","role":"user","id":"unknown","content":[{"type":"input_text","text":"unknown source"}]}}"#
    ].map { Data($0.utf8) }
    let events = HumanInputProvenanceAudit.project(lines: lines, fileKey: "fixture", salt: Data(repeating: 8, count: 32), now: DotInputCollector.parse("2026-10-14T18:00:00Z")!)
    try expectEqual(events.map(\.classification), ["automatic", "source_unknown", "user_submission", "source_unknown"], "attribute initial input only; do not mislabel later steering or missing source")
    let encoded = String(data: try JSONEncoder().encode(events), encoding: .utf8)!
    try expect(!encoded.contains("manual prompt") && !encoded.contains("human steering"), "never retain user text")
}

func testDeviceInputSignalDoesNotCertifyWork() throws {
    try expectEqual(DeviceInputSnapshot(idleSeconds: 299, onConsole: true, loggedIn: true).state, "recent_input", "recent physical input")
    try expectEqual(DeviceInputSnapshot(idleSeconds: 300, onConsole: true, loggedIn: true).state, "input_idle", "five minute boundary")
    try expectEqual(DeviceInputSnapshot(idleSeconds: 0, onConsole: false, loggedIn: true).state, "session_inactive", "session state takes precedence")
    try expectEqual(DeviceInputSnapshot(idleSeconds: .nan, onConsole: nil, loggedIn: nil).state, "unknown", "missing data is not idle")
    try expectEqual(DeviceInputSnapshot(idleSeconds: 0, onConsole: true, loggedIn: true).interpretation, "device_signal_only_not_human_message_or_work_quality", "do not certify human work")
}

func testHumanWorkdayShadowPreservesMessageBoundary() throws {
    let report = try inputAwait {
        try await DotInputCollector().collect(identity: DotInputIdentity(account: "account", user: "user"), transport: DotInputFixture(), salt: Data(repeating: 7, count: 32), now: DotInputCollector.parse("2026-10-14T21:00:00Z")!)
    }
    var native = NativeInputAuditReport()
    native.inputs = [
        HumanInputEvent(eventKey: "human", sourceAt: "2026-10-14T17:20:00Z", source: "codex_local", classification: "user_submission"),
        HumanInputEvent(eventKey: "auto", sourceAt: "2026-10-14T20:59:00Z", source: "codex_local", classification: "automatic")
    ]
    native.automaticInputsExcluded = 1
    let now = DotInputCollector.parse("2026-10-14T20:59:59Z")!
    let recent = DeviceInputSnapshot(idleSeconds: 0, onConsole: true, loggedIn: true)
    let idle = DeviceInputSnapshot(idleSeconds: 86400, onConsole: true, loggedIn: true)
    let shadow = HumanWorkdayShadow(dot: report, native: native, device: recent, now: now)
    try expectEqual(shadow.workday, "2026-10-14", "04:59 stays in preceding Hong Kong workday")
    try expectEqual(shadow.lastMessageAt, "2026-10-14T17:20:00Z", "automatic 04:59 input cannot extend finish")
    try expectEqual(shadow.lastMessageLocalTime, "2026-10-15 01:20:00", "local time has a date")
    try expectEqual(HumanWorkdayShadow(dot: report, native: native, device: idle, now: now).lastMessageAt, shadow.lastMessageAt, "idle or recent keyboard signals never move message time")
    let morning = HumanWorkdayShadow(dot: report, native: native, device: idle, now: DotInputCollector.parse("2026-10-14T21:00:00Z")!)
    try expectEqual(morning.workday, "2026-10-15", "05:00 starts next Hong Kong workday")
    try expectEqual(morning.lastMessageAt, nil, "yesterday cannot become today's message")
}

func testNativeInputLargeHeaderAndSubagentBoundary() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("input-provenance-\(UUID().uuidString)")
    let sessions = home.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let file = sessions.appendingPathComponent("rollout-fixture.jsonl")
    let header: [String: Any] = ["type": "session_meta", "payload": ["source": "vscode", "base_instructions": String(repeating: "private setup ", count: 4000)]]
    let task = #"{"timestamp":"2026-10-14T17:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_attribution":{"turn_trigger":"composer"}}}"#
    let message = #"{"timestamp":"2026-10-14T17:00:01Z","type":"response_item","payload":{"type":"message","role":"user","id":"fixture-user","content":[{"type":"input_text","text":"private source text"}]}}"#
    var bytes = try JSONSerialization.data(withJSONObject: header)
    bytes.append(Data(("\n" + task + "\n" + message + "\n").utf8))
    try bytes.write(to: file)
    let salt = Data(repeating: 9, count: 32), now = DotInputCollector.parse("2026-10-14T18:00:00Z")!
    let report = HumanInputProvenanceAudit().collect(codexHome: home, salt: salt, now: now)
    try expectEqual(report.inputs.map(\.classification), ["user_submission"], "large first metadata row must not lose verified root source")
    let privateText = String(data: try JSONEncoder().encode(report), encoding: .utf8)!
    try expect(!privateText.contains("private setup") && !privateText.contains("private source"), "header and message content never leave local parsing")
    let subagent: [String: Any] = ["type": "session_meta", "payload": ["source": ["subagent": ["other": "fixture"]]]]
    var excluded = try JSONSerialization.data(withJSONObject: subagent)
    excluded.append(Data(("\n" + task + "\n" + message + "\n").utf8)); try excluded.write(to: file)
    try expectEqual(HumanInputProvenanceAudit().collect(codexHome: home, salt: salt, now: now).inputs.count, 0, "subagent messages cannot become human workday inputs")
}
