import Foundation
import CodexTrafficLightCore

private actor SamplingFixture: DotInputReadTransport {
    var historyFails: Bool
    let headCount: Int?
    var calls: [String] = []
    init(historyFails: Bool = false, headCount: Int? = nil) { self.historyFails = historyFails; self.headCount = headCount }
    func requests() -> [String] { calls }
    func route(origin: String, override: String) throws {}
    func get(_ path: String, query: [String: String]) throws -> Data {
        calls.append(path + (query["before"] ?? ""))
        var object: [String: Any]
        switch path {
        case "/wham/accounts/check": object = ["accounts": [["id": "account", "account_user_id": "unused-alias", "structure": "personal", "workspace_backend_origin": "NO_CONSTRAINT", "account_routing_override": "NO_CONSTRAINT"]]]
        case "/tbo/primary": object = ["selection": ["aeon_id": "dot", "messaging_room_id": "private-room", "thread_id": "root", "available": true], "profile": ["id": "dot", "messaging_room_id": "private-room", "active_root_thread_id": "root"]]
        case "/messaging/rooms/private-room": object = ["id": "private-room", "type": "DM", "app_source": "chatgpt:messaging", "aeon_id": "dot", "members": [["account_user_id": "owner"], ["account_user_id": "dot-user", "aeon_id": "dot"]]]
        default:
            let before = query["before"]
            if before != nil && historyFails { throw DotInputError.unavailable("transport") }
            let offset = before == nil ? 40 : (before == "cursor40" ? 20 : 0)
            let values: [[String: Any]] = (offset..<(offset + (headCount ?? 20))).map { i in
                ["id": "private-message-\(i)", "account_user_id": i % 3 == 0 ? "dot-user" : "owner", "role": "user",
                 "created_at": "2026-10-15T\(offset == 0 ? "20" : "22"):\(String(format: "%02d", i)):00Z", "content": ["text": "SECRET CHAT"]]
            }
            object = ["items": values, "prev_cursor": offset == 40 ? "cursor40" : "cursor20"]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

func testDotSamplingRecoveryAndPrivacy() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dot-sampling-\(UUID().uuidString)/sample.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let now = DotInputCollector.parse("2026-10-15T23:30:00Z")!
    let identity = DotInputIdentity(account: "account", user: "owner")
    let done = DispatchSemaphore(value: 0)
    let outcome = SamplingTestResult()
    Task.detached {
        do {
            let first = try await DotInputSampler(cacheURL: url).sample(identity: identity, transport: SamplingFixture(), maxPages: 1, now: now)
            try expect(!first.currentDayCovered && first.firstOwnerMessageAt == nil, "partial window cannot claim first-of-day")
            try expect(first.lastOwnerMessageAt != nil, "partial window still supplies observed latest input")
            let recovered = try await DotInputSampler(cacheURL: url).sample(identity: identity, transport: SamplingFixture(), maxPages: 3, now: now)
            try expect(recovered.currentDayCovered, "restart resumes encrypted cursor through 05:00 boundary")
            try expect(recovered.firstOwnerMessageAt != nil, "complete day permits first input")
            try expectEqual(first.ownerMessages.last?.eventKey, recovered.ownerMessages.last?.eventKey, "stable HMAC across restart")
            try expect(DotInputSampler.read(cacheURL: url, identity: identity, now: now) != nil, "fresh account-bound cache readable")
            try expect(DotInputSampler.read(cacheURL: url, identity: DotInputIdentity(account: "other", user: "owner"), now: now) == nil, "changed account fails closed")
            try expect(DotInputSampler.read(cacheURL: url, identity: identity, now: now.addingTimeInterval(301)) == nil, "stale cache fails closed")
            let bytes = String(data: try Data(contentsOf: url), encoding: .utf8)!
            for privateValue in ["SECRET CHAT", "private-room", "private-message", "cursor40", "unused-alias", "dot-user"] {
                try expect(!bytes.contains(privateValue), "no raw content or identity persists")
            }
            let exported = String(data: try JSONEncoder().encode(recovered), encoding: .utf8)!
            try expect(!exported.contains("salt") && !exported.contains("sealedSegments"), "recovery keys never exported")
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            try expectEqual(mode?.intValue, 0o600, "owner-only recovery cache")
            let original = try Data(contentsOf: url)
            var envelope = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            var unverified = envelope["snapshot"] as! [String: Any]
            unverified["ownerVerified"] = false; envelope["snapshot"] = unverified
            try JSONSerialization.data(withJSONObject: envelope).write(to: url)
            try expect(DotInputSampler.read(cacheURL: url, identity: identity, now: now) == nil, "unverified owner cache rejected")
            try original.write(to: url)
            let warmFixture = SamplingFixture()
            _ = try await DotInputSampler(cacheURL: url).sample(identity: identity, transport: warmFixture, maxPages: 3, now: now)
            let warmCalls = await warmFixture.requests()
            try expectEqual(warmCalls.filter { $0.contains("/messages") }.count, 1, "watermark overlap avoids replaying history")
            try FileManager.default.removeItem(at: url)
            let interrupted = try await DotInputSampler(cacheURL: url).sample(identity: identity, transport: SamplingFixture(historyFails: true), maxPages: 3, now: now)
            try expect(!interrupted.currentDayCovered && interrupted.lastOwnerMessageAt != nil, "failed backfill preserves newest verified input")
            let resumed = try await DotInputSampler(cacheURL: url).sample(identity: identity, transport: SamplingFixture(), maxPages: 3, now: now)
            try expect(resumed.currentDayCovered, "failed exact cursor resumes successfully next poll")
            for count in [0, 2] {
                let freshURL = url.deletingLastPathComponent().appendingPathComponent("new-room-\(count).json")
                let fresh = try await DotInputSampler(cacheURL: freshURL).sample(identity: identity,
                    transport: SamplingFixture(headCount: count), maxPages: 1, now: now)
                try expect(fresh.currentDayCovered, "empty or short new room exhausts history")
                try expectEqual(fresh.coverageStartAt, fresh.workdayStartAt, "exhausted history proves coverage back to workday boundary")
                if count == 0 { try expect(fresh.firstOwnerMessageAt == nil && fresh.lastOwnerMessageAt == nil, "empty room never invents input") }
                else { try expect(fresh.firstOwnerMessageAt != nil, "new room first input permitted by exhausted history") }
            }
            outcome.finish(nil)
        } catch { outcome.finish(error) }
        done.signal()
    }
    try expect(done.wait(timeout: .now() + 20) == .success, "sampling test completes")
    if let error = outcome.error { throw error }
}
private final class SamplingTestResult: @unchecked Sendable {
    private let lock = NSLock(); private var value: Error?
    func finish(_ error: Error?) { lock.lock(); value = error; lock.unlock() }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return value }
}
