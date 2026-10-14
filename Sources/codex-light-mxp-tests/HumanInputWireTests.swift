import Foundation
import CodexTrafficLightCore

func testHumanInputWireSeparatesConfirmedAndUnknown() throws {
    let fixture = #"{"collector":"fixture","collectedAt":"2026-10-14T12:00:00Z","profile":{"userId":"fixture","userName":"F","team":"T","role":"T","avatar":"F"},"device":{"id":"fixture","kind":"mac","name":"F","modelIdentifier":"T","legacyIds":[]},"todayLiveUsage":{"day":"2026-10-14","tokens":0,"updatedAt":"2026-10-14T12:00:00Z","source":"test"},"sessionActivity":[],"interactionSummary":[],"grindHistory":[],"grindHistoryMode":"interaction_v8","projects":[],"inputEvents":[],"sessions":[]}"#.data(using: .utf8)!
    var payload = try JSONDecoder().decode(TeamUsagePayload.self, from: fixture)
    payload.interactionSummary = [
        TeamSessionInteractionSummary(sessionId: "private-session-identity", day: "2026-10-14", firstDayUserAt: "2026-10-14T01:00:00Z", lastDayUserAt: "2026-10-14T02:00:00Z", inputProvenance: "user_submission"),
        TeamSessionInteractionSummary(sessionId: "unknown-session-identity", day: "2026-10-14", lastNightUserAt: "2026-10-14T20:59:00Z", inputProvenance: "legacy_unknown"),
    ]
    payload.humanInputMetadata = HumanInputMetadata(nativeCoverage: NativeInputCoverage(complete: true, startDay: "2026-10-14", endDay: "2026-10-14"))
    let data = try JSONEncoder().encode(payload)
    let raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let summary = raw["interactionSummary"] as! [[String: Any]]
    try expectEqual(summary.count, 1, "only confirmed source reaches the authoritative summary")
    try expectEqual(summary[0]["sessionId"] as? String, "workday", "private session identities stay local")
    try expect(summary[0]["lastNightUserAt"] == nil, "unknown automatic-looking history cannot extend finish")
    try expectEqual(summary[0]["inputProvenance"] as? String, "user_submission", "server receives explicit provenance")
    payload.interactionSummary = []
    let empty = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as! [String: Any]
    try expectEqual((empty["interactionSummary"] as? [Any])?.count, 0, "empty complete replay can retract old contamination")
    try expectEqual(empty["grindHistoryMode"] as? String, "interaction_v8", "empty replay retains its version")
    let text = String(data: data, encoding: .utf8)!
    try expect(!text.contains("private-session") && !text.contains("unknown-session"), "no raw conversation identities are exported")
}
