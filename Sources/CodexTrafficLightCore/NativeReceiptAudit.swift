import Foundation
import Darwin

/// A fixed, read-only reconciliation window. These observations never mutate usage.
public struct NativeReceiptAudit {
    public static let scope = "native-receipts-20261029-31-v1"
    public struct Day: Codable, Equatable {
        public var receiptTokens = 0
        public var receiptCount = 0
        public var compactionTokens = 0
        public var nativeLedgerTokens = 0
    }
    public struct Report: Codable {
        public var days: [String: Day]
        public var files = 0
        public var failures = 0
        public var failureReasons: [String: Int] = [:]
        public var conflicts = 0
        public var complete = true
    }

    /// The helper is separate from the sync watchdog and guarded by its own lock.
    public static func schedule(configuration: TeamSyncConfiguration) {
        guard ["zlu", "qiubo"].contains(configuration.userID),
              let installed = TeamSyncConfiguration.load(), installed.token == configuration.token,
              installed.codexHome.standardizedFileURL == configuration.codexHome.standardizedFileURL,
              configuration.endpoint.absoluteString == "https://c.wanhe.cn/api/usage",
              !FileManager.default.fileExists(atPath: marker.path) else { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("codex-light-mxp")
        child.arguments = ["token-receipt-audit"]
        child.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CODEX_HOME": configuration.codexHome.path]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try? child.run()
    }

    private static var marker: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wanhe-codex-token/\(scope).json") }

    public static func run(codexHome: URL) throws -> Report? {
        let lock = open(marker.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(lock, LOCK_UN) }
        guard !FileManager.default.fileExists(atPath: marker.path) else { return nil }
        let root = marker.deletingLastPathComponent(), index = CodexSessionFileIndex(codexHome: codexHome)
        let report = scan(index: index, nativeState: root.appendingPathComponent("today-live.json"))
        let account = TokenCollectionAudit.account(codexHome)
        let records = report.days.sorted { $0.key < $1.key }.map { day, row -> TokenCollectionAudit.Record in
            var e = TokenCollectionAudit.Record(source: "native_receipt_audit", kind: "baseline", reason: "snapshot",
                key: TokenCollectionAudit.hash(scope + "|" + day), account: account, eventAt: day + "T00:00:00Z",
                values: ["receiptTokens": row.receiptTokens, "receiptCount": row.receiptCount,
                    "compactionTokens": row.compactionTokens, "nativeLedgerTokens": row.nativeLedgerTokens,
                    "auditFiles": report.files, "auditReadFailures": report.failures,
                    "auditConflicts": report.conflicts, "auditComplete": report.complete ? 1 : 0])
            e.eventKey = TokenCollectionAudit.hash(scope + "|" + (account ?? "unknown") + "|" + day)
            return e
        }
        guard TokenCollectionAudit().append(records) else { throw CocoaError(.fileWriteUnknown) }
        // Partial scans remain visibly partial; rerunning cannot add usage to rankings.
        try JSONEncoder().encode(report).write(to: marker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        return report
    }

    public static func scan(index: CodexSessionFileIndex, nativeState: URL, deadline: Date = Date().addingTimeInterval(120)) -> Report {
        let from = "2026-10-29", through = "2026-11-01"
        var report = Report(days: Dictionary(uniqueKeysWithValues: [from, "2026-10-30", "2026-10-31"].map { ($0, Day()) }))
        let markers = ["\"token_usage_record\"", "\"compacted\"", "\"task_started\"", "\"task_complete\"", "\"turn_aborted\""].map { Data($0.utf8) }
        func relevant(_ line: Data) -> Bool { markers.contains { line.prefix(1024).range(of: $0) != nil } }
        report.complete = index.enumerationComplete
        let cutoff = SharedDateFormatters.shared.iso8601Date(from: from + "T00:00:00Z")!
        var seen: [String: [Int]] = [:], compacted = Set<String>(), receipts: [String: (String, Int)] = [:]
        for file in index.uniqueFiles(modifiedSince: cutoff) {
            guard Date() < deadline else { report.complete = false; break }
            report.files += 1
            guard let handle = try? FileHandle(forReadingFrom: file.url) else { report.failures += 1; report.failureReasons["open", default: 0] += 1; report.complete = false; continue }
            defer { try? handle.close() }
            var buffer = Data(), first = true, owner: String?, boundary: Int?, created: String?, imported = false, skippingBody = false
            var remaining = file.size
            do {
                while remaining > 0 {
                    guard Date() < deadline else { report.complete = false; break }
                    var bytes = try handle.read(upToCount: Int(min(262144, remaining))) ?? Data()
                    guard !bytes.isEmpty else { report.failures += 1; report.failureReasons["short_read", default: 0] += 1; report.complete = false; break }
                    remaining -= Int64(bytes.count)
                    if skippingBody {
                        guard let end = bytes.firstIndex(of: 10) else { continue }
                        bytes.removeSubrange(...end); skippingBody = false
                    }
                    buffer.append(bytes)
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer.prefix(upTo: end)); buffer.removeSubrange(...end)
                        guard first || relevant(line) else { continue }
                        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let p = event["payload"] as? [String: Any] else {
                            report.failures += 1; report.failureReasons["json", default: 0] += 1; report.complete = false; first = false; continue
                        }
                        if first {
                            first = false
                            guard event["type"] as? String == "session_meta", let id = p["id"] as? String,
                                  file.url.lastPathComponent.lowercased().contains(id.lowercased()) else { report.failures += 1; report.failureReasons["identity", default: 0] += 1; report.complete = false; continue }
                            owner = id; boundary = p["subagent_history_start_ordinal"] as? Int
                            if p["forked_from_id"] is String { created = p["timestamp"] as? String }
                        }
                        guard let owner, let stamp = event["timestamp"] as? String,
                              SharedDateFormatters.shared.iso8601Date(from: stamp) != nil else { continue }
                        if let boundary, let ordinal = event["ordinal"] as? Int, ordinal < boundary { continue }
                        if boundary == nil, let created, stamp < created { continue }
                        if p["type"] as? String == "task_started" { imported = (p["turn_id"] as? String)?.hasPrefix("external-import-") == true }
                        if ["task_complete", "turn_aborted"].contains(p["type"] as? String ?? "") { imported = false }
                        if event["type"] as? String == "compacted", let id = p["compaction_response_id"] as? String { compacted.insert(TokenCollectionAudit.hash(owner + "|" + id)) }
                        let day = String(stamp.prefix(10))
                        guard !imported, day >= from, day < through, event["type"] as? String == "token_usage_record",
                              (p["thread_id"] as? String)?.lowercased() == owner.lowercased(),
                              let id = p["response_id"] as? String, !id.isEmpty,
                              let usage = p["usage"] as? [String: Any], let total = validTotal(usage) else { continue }
                        let key = TokenCollectionAudit.hash(owner + "|" + id)
                        let vector = ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens", "cache_write_input_tokens"].map { (usage[$0] as? NSNumber)?.intValue ?? 0 }
                        if let previous = seen[key] { if previous != vector { report.conflicts += 1; report.complete = false }; continue }
                        seen[key] = vector; receipts[key] = (day, total)
                        report.days[day]!.receiptTokens += total; report.days[day]!.receiptCount += 1
                    }
                    // Images and tool output can occupy tens of MB on one line.
                    // Once its header proves it is not an accounting event, stream past it.
                    if !first, buffer.count > 1024, !relevant(buffer) {
                        buffer.removeAll(); skippingBody = true
                    }
                    // An unbounded accounting/metadata line stays an explicit coverage gap.
                    if buffer.count > 32 * 1024 * 1024 { report.failureReasons["line_limit", default: 0] += 1; report.failures += 1; report.complete = false; break }
                }
                if !buffer.isEmpty { report.complete = false }
            } catch { report.failureReasons["read", default: 0] += 1; report.failures += 1; report.complete = false }
        }
        for key in compacted { if let (day, total) = receipts[key] { report.days[day]!.compactionTokens += total } }
        if let data = try? Data(contentsOf: nativeState), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ledger = state["utcDailyLedger"] as? [String: Any], let days = ledger["tokens"] as? [String: Int] {
            for day in report.days.keys { report.days[day]!.nativeLedgerTokens = days[day] ?? 0 }
        } else { report.failureReasons["state", default: 0] += 1; report.complete = false; report.failures += 1 }
        return report
    }

    private static func validTotal(_ raw: [String: Any]) -> Int? {
        var values: [String: Int] = [:]
        for field in ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"] {
            guard let n = raw[field] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  n.doubleValue >= 0, n.doubleValue <= 9_007_199_254_740_991, n.doubleValue.rounded(.towardZero) == n.doubleValue else { return nil }
            values[field] = n.intValue
        }
        guard values["input_tokens"]! + values["output_tokens"]! == values["total_tokens"]!,
              values["cached_input_tokens"]! <= values["input_tokens"]!, values["reasoning_output_tokens"]! <= values["output_tokens"]! else { return nil }
        return values["total_tokens"]
    }
}
