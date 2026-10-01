import Foundation
import CryptoKit

public struct GrindDiagnosticReport: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var start = "2026-10-01T00:00:00+08:00"
        public var end = "2026-10-01T02:00:00+08:00"
        public var businessDay = "2026-09-30"
    }
    public struct Summary: Codable, Equatable, Sendable {
        public var classifierVersion = "human_metadata_v2_structured_source"
        public var candidateFiles: Int
        public var scannedFiles: Int
        public var readErrors: Int
        public var scanLimited: Bool
        public var eventsInWindow: Int
        public var coverageIncomplete: Bool
    }
    public struct Event: Codable, Equatable, Sendable {
        public var at: String
        public var type: String
        public var source: String
        public var fileHash: String
        public var recognized: Bool = true
    }
    public struct File: Codable, Equatable, Sendable {
        public var fileHash: String
        public var size: Int64
        public var storedOffset: Int64? = nil
        public var unreadBytes: Int64? = nil
        public var tailScanTruncated: Bool
        public var trailingPartialLine: Bool
        private enum CodingKeys: String, CodingKey { case fileHash, size, storedOffset, unreadBytes, tailScanTruncated, trailingPartialLine }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(fileHash, forKey: .fileHash); try c.encode(size, forKey: .size)
            try c.encode(storedOffset, forKey: .storedOffset); try c.encode(unreadBytes, forKey: .unreadBytes)
            try c.encode(tailScanTruncated, forKey: .tailScanTruncated); try c.encode(trailingPartialLine, forKey: .trailingPartialLine)
        }
    }
    public var schema = "grind_diagnostic_v2"
    public var origin = "installed_client"
    // Automated local collection is not a human attestation about last night's device.
    public var actualComputerConfirmed = false
    public var window = Window()
    public var summary: Summary
    public var events: [Event]
    public var files: [File]
    public var reportId: String = ""

    public func canonicalData(includeID: Bool = true) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(self)
        if includeID { return encoded }
        var body = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        body.removeValue(forKey: "reportId")
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public var validForUpload: Bool {
        guard schema == "grind_diagnostic_v2", origin == "installed_client", !actualComputerConfirmed, window == Window(),
              summary.classifierVersion == "human_metadata_v2_structured_source",
              summary.scannedFiles >= 0, summary.scannedFiles <= 32, summary.candidateFiles >= summary.scannedFiles,
              summary.readErrors >= 0, summary.eventsInWindow >= events.count, events.count <= 30, files.count <= 32 else { return false }
        let hashPattern = "^[a-f0-9]{12}$"
        for e in events {
            guard e.at.range(of: "^2026-10-01T0[01]:[0-5][0-9]:[0-5][0-9](\\.[0-9]{1,6})?\\+08:00$", options: .regularExpression) != nil,
                  ["response_item", "event_msg", "other"].contains(e.type), ["known_root", "unknown", "subagent"].contains(e.source),
                  e.fileHash.range(of: hashPattern, options: .regularExpression) != nil else { return false }
        }
        for f in files {
            guard f.fileHash.range(of: hashPattern, options: .regularExpression) != nil,
                  f.size >= 0, f.size <= 1_000_000_000_000,
                  [f.storedOffset, f.unreadBytes].allSatisfy({ $0 == nil || ($0! >= 0 && $0! <= 1_000_000_000_000) }) else { return false }
        }
        guard let body = try? canonicalData(includeID: false) else { return false }
        return reportId == Self.hash(body)
    }
}

public struct GrindDiagnosticCollector: Sendable {
    public init() {}
    public func collect(codexHome: URL, index: CodexSessionFileIndex? = nil) -> GrindDiagnosticReport {
        let start = ISO8601DateFormatter().date(from: "2026-09-30T16:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-09-30T18:00:00Z")!
        let files = (index ?? CodexSessionFileIndex(codexHome: codexHome)).uniqueFiles(modifiedSince: start)
            .sorted { $0.modifiedAt == $1.modifiedAt ? $0.stableKey < $1.stableKey : $0.modifiedAt > $1.modifiedAt }
        var events: [GrindDiagnosticReport.Event] = [], metadata: [GrindDiagnosticReport.File] = []
        var errors = 0, scanned = 0
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for file in files.prefix(32) {
            var url = file.url
            var unsafe = false
            while url.standardizedFileURL.path != codexHome.standardizedFileURL.path {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { unsafe = true; break }
                let parent = url.deletingLastPathComponent()
                if parent.path == url.path { unsafe = true; break }
                url = parent
            }
            if (try? codexHome.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { unsafe = true }
            guard !unsafe, let handle = try? FileHandle(forReadingFrom: file.url) else { errors += 1; continue }
            defer { try? handle.close() }
            scanned += 1
            do {
                let header = try handle.read(upToCount: 64 * 1024) ?? Data()
                let source = Self.source(header)
                let size = Int64(try handle.seekToEnd())
                let offset = max(0, size - 4 * 1024 * 1024)
                try handle.seek(toOffset: UInt64(offset))
                var tail = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
                if offset > 0 { tail = tail.firstIndex(of: 10).map { Data(tail.dropFirst($0 + 1)) } ?? Data() }
                let hash = String(GrindDiagnosticReport.hash(Data(file.stableKey.utf8)).prefix(12))
                var modern: [Date] = [], legacy: [Date] = []
                // Ignore incomplete final rows; do not promote partial or malformed data.
                if let lastNewline = tail.lastIndex(of: 10) {
                    for line in tail.prefix(through: lastNewline).split(separator: 10) {
                        guard let e = CodexGrindHistoryCollector.authoredEventMetadata(Data(line)), e.date >= start, e.date < end else { continue }
                        if e.type == "response_item" { modern.append(e.date) } else { legacy.append(e.date) }
                    }
                }
                let dates = Array(Set(modern.isEmpty ? legacy : modern)).sorted()
                guard !dates.isEmpty else { continue }
                events += dates.map { .init(at: formatter.string(from: $0), type: modern.isEmpty ? "event_msg" : "response_item", source: source, fileHash: hash) }
                metadata.append(.init(fileHash: hash, size: size, tailScanTruncated: offset > 0, trailingPartialLine: tail.last != 10))
            } catch { errors += 1 }
        }
        events.sort { ($0.at, $0.fileHash) < ($1.at, $1.fileHash) }
        let total = events.count
        let summary = GrindDiagnosticReport.Summary(candidateFiles: files.count, scannedFiles: scanned, readErrors: errors,
            scanLimited: files.count > 32, eventsInWindow: total,
            coverageIncomplete: scanned == 0 || total == 0 || files.count > 32 || errors > 0 || total > 30 || metadata.contains { $0.tailScanTruncated || $0.trailingPartialLine } || events.contains { $0.source == "unknown" })
        var report = GrindDiagnosticReport(summary: summary, events: Array(events.suffix(30)), files: metadata.sorted { $0.fileHash < $1.fileHash })
        if let data = try? report.canonicalData(includeID: false) { report.reportId = GrindDiagnosticReport.hash(data) }
        return report
    }
    private static func source(_ header: Data) -> String {
        for line in header.split(separator: 10) {
            guard let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  value["type"] as? String == "session_meta", let payload = value["payload"] as? [String: Any] else { continue }
            if let source = payload["source"] as? [String: Any], source["subagent"] != nil { return "subagent" }
            if let source = payload["source"] as? String {
                if source == "subagent" { return "subagent" }
                if ["cli", "vscode", "desktop"].contains(source) { return "known_root" }
            }
            return "unknown"
        }
        return "unknown"
    }
}

public struct GrindDiagnosticReceipt: Codable, Equatable, Sendable {
    public var reportId: String
    public var status: String
    public var receivedAt: String
    public init(reportId: String, status: String, receivedAt: String) {
        self.reportId = reportId; self.status = status; self.receivedAt = receivedAt
    }
    public func confirms(_ report: GrindDiagnosticReport) -> Bool {
        reportId == report.reportId && ["received", "duplicate"].contains(status) && ISO8601DateFormatter.fractionalDate(receivedAt) != nil
    }
}
private extension ISO8601DateFormatter {
    static func fractionalDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

public struct GrindDiagnosticQueue: Sendable {
    struct State: Codable { var scope: String; var report: GrindDiagnosticReport; var receipt: GrindDiagnosticReceipt? }
    public var url: URL
    public init(url: URL) { self.url = url }
    public func pending(scope: String, collect: () -> GrindDiagnosticReport) throws -> GrindDiagnosticReport? {
        if let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(State.self, from: data), state.scope == scope, state.report.validForUpload {
            return state.receipt?.confirms(state.report) == true ? nil : state.report
        }
        let report = collect()
        guard report.validForUpload else { throw StateStoreError.invalidInput("diagnostic metadata invalid") }
        try save(.init(scope: scope, report: report, receipt: nil))
        return report
    }
    public func acknowledge(scope: String, report: GrindDiagnosticReport, receipt: GrindDiagnosticReceipt) throws {
        guard receipt.confirms(report) else { throw StateStoreError.invalidInput("diagnostic receipt mismatch") }
        try save(.init(scope: scope, report: report, receipt: receipt))
    }
    private func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
