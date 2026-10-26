import Foundation
import CodexTrafficLightCore

func testUpdaterHealthCacheIsBoundedAndFresh() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("updater-health-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = home.appendingPathComponent(".wanhe-codex-token")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("updater-health.json")
    let now = ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!
    func write(_ status: String, _ checkedAt: String) throws {
        try JSONSerialization.data(withJSONObject: ["status": status, "checkedAt": checkedAt, "path": "private-local-path"])
            .write(to: file)
    }
    try expect(TeamUpdaterHealth.cached(home: home, now: now) == nil, "absent inspection is unknown")
    try write("healthy", "2026-10-26T11:59:00Z")
    try expectEqual(TeamUpdaterHealth.cached(home: home, now: now)?.status, "healthy", "recent actual inspection is available")
    for (status, stamp) in [("healthy", "2026-10-26T11:29:59Z"), ("healthy", "2026-10-26T12:00:01Z"),
                            ("notInstalled", "2026-10-26T11:59:00Z"), ("private-error", "2026-10-26T11:59:00Z"), ("healthy", "invalid")] {
        try write(status, stamp)
        try expect(TeamUpdaterHealth.cached(home: home, now: now) == nil, "stale, future, development and invalid results must not imply current health")
    }
    try Data(repeating: 32, count: 4097).write(to: file)
    try expect(TeamUpdaterHealth.cached(home: home, now: now) == nil, "health reads stay bounded")
}
