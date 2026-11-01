import Foundation

public enum DotReconnectRecovery {
    public struct Preview: Codable {
        public var localRecovered: [String: Int] = [:]
        public var utcRecovered: [String: Int] = [:]
        public var records = 0
    }
    public static func records(root: URL, now: Date) throws -> [TokenCollectionAudit.Record] {
        let cutoff = UTCDailyUsageLedger.day(UTCDailyUsageLedger.cutoff(now))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.prefix(10) >= cutoff }
        var records: [TokenCollectionAudit.Record] = []
        for file in files {
            let data = try Data(contentsOf: file)
            if let end = data.lastIndex(of: 10) {
                records += try data.prefix(upTo: end).split(separator: 10).map { try JSONDecoder().decode(TokenCollectionAudit.Record.self, from: Data($0)) }
            }
        }
        return records
    }
    public static func preview(stateURL: URL, now: Date = Date()) throws -> Preview {
        var ledger = try JSONDecoder().decode(DotTokenLedger.self, from: Data(contentsOf: stateURL))
        let recovered = ledger.recoverReconnectBoundaries(records: try records(root: stateURL.deletingLastPathComponent().appendingPathComponent("token-audit"), now: now), now: now)
        var result = Preview(); result.records = recovered.count
        for r in recovered {
            let date = SharedDateFormatters.shared.iso8601Date(from: r.eventAt!)!
            result.localRecovered[SharedDateFormatters.shared.shanghaiDay.string(from: date), default: 0] += r.values["counted"] ?? 0
            result.utcRecovered[UTCDailyUsageLedger.day(date), default: 0] += r.values["utcCounted"] ?? 0
        }
        return result
    }
}

extension DotTokenLedger {
    /// Recover only a pending increment with a matching witnessed previous
    /// counter/time. Account totals never manufacture a device delta.
    public mutating func recoverReconnectBoundaries(records: [TokenCollectionAudit.Record], now: Date) -> [TokenCollectionAudit.Record] {
        guard reconnectBoundaryRepairVersion != 1, !accountHash.isEmpty else { return [] }
        var previous: [String: (Int, Date)] = [:], seen = Set<String>(), result: [TokenCollectionAudit.Record] = []
        let localCutoff = SharedDateFormatters.shared.shanghaiDay.string(from: now.addingTimeInterval(-3 * 86400))
        let utcCutoff = UTCDailyUsageLedger.day(UTCDailyUsageLedger.cutoff(now))
        for r in records.sorted(by: { $0.at < $1.at }) where r.source == "dot_local" && r.account == accountHash {
            guard let key = r.key, let total = r.values["cumulative"], seen.insert(r.id).inserted else { continue }
            if r.kind == "baseline" {
                if let stamp = r.eventAt.flatMap(SharedDateFormatters.shared.iso8601Date) { previous[key] = (total, stamp) }
                continue
            }
            guard ["increment", "pending", "excluded"].contains(r.kind),
                  let stamp = SharedDateFormatters.shared.iso8601Date(from: r.at) else { continue }
            let prior = previous[key]; previous[key] = (total, stamp)
            guard r.kind == "pending", r.reason == "unattributed_or_large", let prior,
                  prior.1 <= stamp, stamp <= now,
                  let delta = r.values["delta"], (1...20_000_000).contains(delta),
                  r.values["pending"] == delta, (r.values["counted"] ?? 0) == 0,
                  r.values["utcCounted"] == nil, r.values["utcPending"] == nil,
                  r.values["previous"] == prior.0, total >= prior.0, total - prior.0 == delta,
                  let input = r.values["input"], let output = r.values["output"], input + output == total,
                  let cached = r.values["cached"], cached <= input,
                  let reasoning = r.values["reasoning"], reasoning <= output,
                  var entry = entries[key] else { continue }
            let day = SharedDateFormatters.shared.shanghaiDay.string(from: stamp), utc = UTCDailyUsageLedger.day(stamp)
            guard (entry.pending[day] ?? 0) >= delta, utc >= utcCutoff else { continue }
            let localKnown = SharedDateFormatters.shared.shanghaiDay.string(from: prior.1) == day && day >= localCutoff
            let utcKnown = UTCDailyUsageLedger.day(prior.1) == utc
            guard localKnown != utcKnown else { continue }
            if localKnown {
                entry.local[day, default: 0] += delta
                entry.pending[day, default: 0] -= delta
                entry.anomalies[day] = max(0, (entry.anomalies[day] ?? 0) - 1)
                entry.pendingUTC = entry.pendingUTC ?? [:]
                entry.pendingUTC?[utc, default: 0] += delta
            }
            if utcKnown { entry.utc[utc, default: 0] += delta }
            entries[key] = entry
            let identity = "dot-boundary-recovery-v1|\(accountHash)|\(r.id)"
            var e = TokenCollectionAudit.Record(source: "dot_local", kind: "increment", reason: "boundary_recovery",
                key: key, account: accountHash, eventAt: r.at,
                values: ["delta": delta, "counted": localKnown ? delta : 0, "utcCounted": utcKnown ? delta : 0,
                    "pendingCleared": utcKnown ? delta : 0],
                now: now)
            e.eventKey = TokenCollectionAudit.hash(identity)
            result.append(e)
        }
        reconnectBoundaryRepairVersion = 1
        return result
    }
}
