import Foundation
import CryptoKit

public struct NativeInputAuditReport: Codable, Sendable {
    public var schema = "native_human_input_pilot_v1"
    public var filesScanned = 0
    public var coverageIncomplete = false
    public var inputs: [HumanInputEvent] = []
    public var automaticInputsExcluded = 0
    public var sourceUnknown = 0
    public init() {}
}

/// Separate shadow audit: never overwrites existing workday history or uploads content.
public struct HumanInputProvenanceAudit: Sendable {
    public init() {}
    public func collect(codexHome: URL, salt: Data, now: Date = Date()) -> NativeInputAuditReport {
        var report = NativeInputAuditReport()
        guard salt.count >= 16 else { report.coverageIncomplete = true; return report }
        let files = CodexSessionFileIndex(codexHome: codexHome).uniqueFiles(modifiedSince: now.addingTimeInterval(-2 * 86400)).sorted { $0.modifiedAt > $1.modifiedAt }
        report.coverageIncomplete = files.count > 16
        for file in files.prefix(16) {
            guard let handle = try? FileHandle(forReadingFrom: file.url) else { report.coverageIncomplete = true; continue }
            defer { try? handle.close() }
            let header = (try? handle.read(upToCount: 1024 * 1024)) ?? Data()
            var knownRoot = false
            if let line = header.split(separator: 10).first,
               let raw = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let payload = raw["payload"] as? [String: Any] {
                knownRoot = ["cli", "vscode", "exec", "appServer", "desktop"].contains(payload["source"] as? String ?? "")
                let source = payload["source"] as? [String: Any]
                if source?["subagent"] != nil || source?["subAgent"] != nil || payload["thread_source"] as? String == "subagent" { continue }
            }
            if !knownRoot { report.coverageIncomplete = true }
            let start = max(0, file.size - 1024 * 1024)
            try? handle.seek(toOffset: UInt64(start))
            let data = (try? handle.read(upToCount: 1024 * 1024)) ?? Data()
            if data.last != 10 { report.coverageIncomplete = true }
            var lines = data.split(separator: 10)
            if start > 0 { report.coverageIncomplete = true; if !lines.isEmpty { lines.removeFirst() } }
            report.filesScanned += 1
            var events = Self.project(lines: lines.map { Data($0) }, fileKey: file.stableKey, salt: salt, now: now)
            if !knownRoot {
                for index in events.indices { events[index].classification = "source_unknown"; events[index].trigger = nil }
            }
            report.inputs += events
        }
        var seen = Set<String>()
        report.inputs = report.inputs.filter { seen.insert($0.eventKey).inserted }.sorted { $0.sourceAt < $1.sourceAt }
        if report.inputs.count > 200 { report.coverageIncomplete = true; report.inputs = Array(report.inputs.suffix(200)) }
        report.automaticInputsExcluded = report.inputs.filter { $0.classification == "automatic" }.count
        report.sourceUnknown = report.inputs.filter { $0.classification == "source_unknown" }.count
        return report
    }

    public static func project(lines: [Data], fileKey: String, salt: Data, now: Date) -> [HumanInputEvent] {
        var trigger: String?, firstUserSeen = false, modern: [HumanInputEvent] = [], legacy: [HumanInputEvent] = []
        for line in lines {
            guard let raw = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = raw["payload"] as? [String: Any] else { continue }
            if raw["type"] as? String == "event_msg", payload["type"] as? String == "task_started" {
                let attribution = payload["turn_attribution"] as? [String: Any]
                trigger = attribution?["turn_trigger"] as? String
                firstUserSeen = false
                continue
            }
            guard let event = CodexGrindHistoryCollector.authoredEventMetadata(line), event.date <= now.addingTimeInterval(5), event.date >= now.addingTimeInterval(-2 * 86400) else { continue }
            // A turn trigger describes its initial input, not later human steering.
            // Later steering in an automatic turn stays unknown; a composer-origin turn remains a UI submission, never physical-human proof.
            let ownTrigger = firstUserSeen && HumanInputSource.automatic(trigger) ? nil : trigger
            let classification = HumanInputSource.classification(trigger: ownTrigger)
            let key = HMAC<SHA256>.authenticationCode(for: Data([fileKey, event.identifier ?? event.timestamp].joined(separator: "|").utf8), using: SymmetricKey(data: salt)).map { String(format: "%02x", $0) }.joined()
            let record = HumanInputEvent(eventKey: key, sourceAt: event.timestamp, source: "codex_local", classification: classification,
                                        trigger: classification == "source_unknown" ? nil : (classification == "automatic" ? "automatic" : ownTrigger))
            if event.type == "response_item" { modern.append(record); firstUserSeen = true }
            else { legacy.append(record) }
        }
        return modern.isEmpty ? legacy : modern
    }
}
