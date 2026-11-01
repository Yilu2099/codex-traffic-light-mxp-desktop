import Foundation
import CodexTrafficLightCore

func testDotReconnectDatesAreIndependent() throws {
    let iso = ISO8601DateFormatter()
    for (start, end, local, utc) in [
        ("2026-10-29T15:59:00Z", "2026-10-29T16:01:00Z", 0, 100),
        ("2026-10-29T23:59:00Z", "2026-10-30T00:01:00Z", 100, 0),
        ("2026-10-29T15:59:00Z", "2026-10-30T00:01:00Z", 0, 0),
    ] {
        let before = iso.date(from: start)!, after = iso.date(from: end)!
        var ledger = DotTokenLedger()
        ledger.observe(key: "thread", total: 100, baseline: true, now: before)
        ledger.observe(key: "thread", total: 200, baseline: true, now: after)
        let day = SharedDateFormatters.shared.shanghaiDay.string(from: after), utcDay = String(end.prefix(10))
        try expectEqual(ledger.entries["thread"]?.local[day], local, "local date is judged independently")
        try expectEqual(ledger.entries["thread"]?.utc[utcDay], utc, "UTC date is judged independently")
        try expectEqual(ledger.entries["thread"]?.pending[day] ?? 0, 100 - local, "retain unresolved local usage")
        try expectEqual(ledger.entries["thread"]?.pendingUTC?[utcDay] ?? 0, 100 - utc, "retain unresolved UTC usage")
        ledger.observe(key: "thread", total: 200, baseline: true, now: after)
        try expectEqual(ledger.entries["thread"]?.utc[utcDay], utc, "reconnect replay is idempotent")
    }
}

func testDotReconnectRecoveryRequiresOriginalEvidenceAndIsIdempotent() throws {
    let iso = ISO8601DateFormatter(), account = String(repeating: "a", count: 64), key = String(repeating: "b", count: 64)
    for (start, end, local, utc) in [
        ("2026-10-29T15:59:00Z", "2026-10-29T16:01:00Z", 0, 100),
        ("2026-10-29T23:59:00Z", "2026-10-30T00:01:00Z", 100, 0),
    ] {
        let before = iso.date(from: start)!, after = iso.date(from: end)!, day = SharedDateFormatters.shared.shanghaiDay.string(from: after), utcDay = String(end.prefix(10))
        var old = DotTokenLedger(); old.accountHash = account
        old.observe(key: key, total: 100, baseline: true, now: before)
        old.observe(key: key, total: 200, baseline: true, now: after)
        // Recreate v162's actual quarantine, without modifying a real cache.
        var entry = old.entries[key]!
        entry.local = [:]; entry.utc = [:]; entry.pending[day] = 100; entry.pendingUTC = nil; entry.anomalies[day] = 1
        old.entries[key] = entry
        let baseline = TokenCollectionAudit.Record(source: "dot_local", kind: "baseline", reason: "audit_enabled", key: key, account: account, eventAt: start, values: ["cumulative": 100], now: after.addingTimeInterval(-1))
        let pending = TokenCollectionAudit.Record(source: "dot_local", kind: "pending", reason: "unattributed_or_large", key: key, account: account,
            values: ["previous": 100, "cumulative": 200, "delta": 100, "pending": 100, "counted": 0, "input": 180, "output": 20, "cached": 160, "reasoning": 2], now: after)
        var ledger = old
        let recovered = ledger.recoverReconnectBoundaries(records: [pending, baseline, pending], now: after.addingTimeInterval(1))
        try expectEqual(recovered.count, 1, "recovery sorts evidence and ignores replayed observations")
        try expectEqual(ledger.entries[key]?.local[day] ?? 0, local, "restore only proven local date")
        try expectEqual(ledger.entries[key]?.utc[utcDay] ?? 0, utc, "restore only proven UTC date")
        try expectEqual(ledger.entries[key]?.pending[day], 100 - local, "unresolved date retains its pending amount")
        try expectEqual(ledger.entries[key]?.total, 200, "recovery cannot change the provider checkpoint")
        try expect(ledger.recoverReconnectBoundaries(records: [baseline, pending], now: after.addingTimeInterval(2)).isEmpty, "restarting cannot recover twice")
        var crashReplay = old
        let replay = crashReplay.recoverReconnectBoundaries(records: [baseline, pending], now: after.addingTimeInterval(3))
        try expectEqual(replay[0].eventKey, recovered[0].eventKey, "audit-before-state crash retains the same spending identity")
        try expect(SharedDateFormatters.shared.iso8601Date(from: recovered[0].at)! > after, "recovery observation time is separate from its source event time")
        for mutation in 0..<4 {
            var bad = pending, badLedger = old
            if mutation == 0 { bad.account = String(repeating: "c", count: 64) }
            if mutation == 1 { bad.values["previous"] = 99 }
            if mutation == 2 { bad.values["input"] = 181 }
            if mutation == 3 { bad.values["utcCounted"] = 100 }
            try expect(badLedger.recoverReconnectBoundaries(records: [baseline, bad], now: after).isEmpty, "unknown account or inconsistent counters cannot create usage")
        }
    }
}
