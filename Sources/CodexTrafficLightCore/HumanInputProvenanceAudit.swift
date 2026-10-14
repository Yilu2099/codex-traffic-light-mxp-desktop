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
        report.inputs = report.inputs.filter { seen.insert($0.eventKey).inserted }.sorted { (DotInputCollector.parse($0.sourceAt) ?? .distantPast) < (DotInputCollector.parse($1.sourceAt) ?? .distantPast) }
        if report.inputs.count > 200 { report.coverageIncomplete = true; report.inputs = Array(report.inputs.suffix(200)) }
        report.automaticInputsExcluded = report.inputs.filter { $0.classification == "automatic" }.count
        report.sourceUnknown = report.inputs.filter { $0.classification == "source_unknown" }.count
        return report
    }

    public static func project(lines: [Data], fileKey: String, salt: Data, now: Date) -> [HumanInputEvent] {
        var state = NativeInputTurnState()
        // project is also used by fixtures without session_meta; collect validates roots separately.
        state.rootSource = "fixture"
        var modern: [HumanInputEvent] = [], legacy: [HumanInputEvent] = []
        for line in lines {
            guard let event = state.consume(line), event.date <= now.addingTimeInterval(5),
                  event.date >= now.addingTimeInterval(-2 * 86400) else { continue }
            let classification = event.classification == "legacy_unknown" ? "source_unknown" : event.classification
            let key = HMAC<SHA256>.authenticationCode(for: Data([fileKey, event.identifier ?? event.timestamp].joined(separator: "|").utf8), using: SymmetricKey(data: salt)).map { String(format: "%02x", $0) }.joined()
            let record = HumanInputEvent(eventKey: key, sourceAt: event.timestamp, source: "codex_local", classification: classification,
                                        trigger: classification == "source_unknown" ? nil : (classification == "automatic" ? "automatic" : event.trigger))
            if event.type == "response_item" { modern.append(record) } else { legacy.append(record) }
        }
        return modern.isEmpty ? legacy : modern
    }
}


/// Cursor attribution contains protocol metadata only; never persists message content.
struct NativeInputTurnState: Codable, Sendable {
    var malformedRowSeen = false
    var rootSource: String?
    var isSubagent = false
    var turnID: String?
    var trigger: String?
    var initialInputSeen = false
    var initialLegacyInputSeen = false
    var discardingOversizedRow = false
    var hasModernMessages = false
    var recentEventKeys: [String] = []

    struct Input {
        var date: Date
        var timestamp: String
        var identifier: String?
        var type: String
        var classification: String
        var trigger: String?
    }

    mutating func consume(_ data: Data) -> Input? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = raw["payload"] as? [String: Any] else { malformedRowSeen = true; return nil }
        let type = raw["type"] as? String
        if type == "session_meta" {
            if let source = payload["source"] as? String {
                rootSource = ["cli", "vscode", "exec", "appServer", "desktop"].contains(source) ? source : nil
            }
            let source = payload["source"] as? [String: Any]
            isSubagent = isSubagent || source?["subagent"] != nil || source?["subAgent"] != nil || payload["thread_source"] as? String == "subagent"
            return nil
        }
        if type == "event_msg", payload["type"] as? String == "task_started" {
            turnID = payload["turn_id"] as? String
            trigger = (payload["turn_attribution"] as? [String: Any])?["turn_trigger"] as? String
            initialInputSeen = false; initialLegacyInputSeen = false
            return nil
        }
        if type == "event_msg", ["task_complete", "task_completed", "turn_aborted"].contains(payload["type"] as? String ?? "") {
            trigger = nil; turnID = nil; initialInputSeen = false; initialLegacyInputSeen = false
            return nil
        }
        guard !isSubagent, let event = CodexGrindHistoryCollector.authoredEventMetadata(data) else { return nil }
        // An explicit per-message source wins over the turn's initial source.
        let explicitTrigger = (payload["turn_attribution"] as? [String: Any])?["turn_trigger"] as? String
            ?? (payload["message_metadata"] as? [String: Any])?["turn_trigger"] as? String
        let alreadySeen = event.type == "response_item" ? initialInputSeen : initialLegacyInputSeen
        let currentTrigger = explicitTrigger ?? (alreadySeen && Self.isAutomatic(trigger) ? nil : trigger)
        let classification: String
        if Self.isAutomatic(currentTrigger) { classification = "automatic" }
        else if rootSource != nil, HumanInputSource.classification(trigger: currentTrigger) == "user_submission" { classification = "user_submission" }
        else { classification = "legacy_unknown" }
        if event.type == "response_item" { initialInputSeen = true } else { initialLegacyInputSeen = true }
        let wasModern = hasModernMessages
        if event.type == "response_item" { hasModernMessages = true }
        if event.type != "response_item", wasModern { return nil }
        let key = event.identifier ?? event.timestamp
        guard !recentEventKeys.contains(key) else { return nil }
        recentEventKeys.append(key)
        recentEventKeys = Array(recentEventKeys.suffix(64))
        return Input(date: event.date, timestamp: event.timestamp, identifier: event.identifier,
                     type: event.type, classification: classification, trigger: currentTrigger)
    }

    static func isAutomatic(_ trigger: String?) -> Bool {
        trigger == "goal" || HumanInputSource.automatic(trigger)
    }
}
