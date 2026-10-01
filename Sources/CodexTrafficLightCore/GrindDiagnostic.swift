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
        public var eventHash: String? = nil
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
              ["human_metadata_v2_structured_source", "human_metadata_v3_streaming_identity", "human_metadata_v4_resumable_identity"].contains(summary.classifierVersion),
              summary.scannedFiles >= 0, summary.scannedFiles <= 32, summary.candidateFiles >= summary.scannedFiles,
              summary.readErrors >= 0, summary.eventsInWindow >= events.count, events.count <= 30, files.count <= 32 else { return false }
        let hashPattern = "^[a-f0-9]{12}$"
        for e in events {
            guard e.at.range(of: "^2026-10-01T0[01]:[0-5][0-9]:[0-5][0-9](\\.[0-9]{1,6})?\\+08:00$", options: .regularExpression) != nil,
                  ["response_item", "event_msg", "other"].contains(e.type), ["known_root", "unknown", "subagent"].contains(e.source),
                  e.fileHash.range(of: hashPattern, options: .regularExpression) != nil else { return false }
            if summary.classifierVersion != "human_metadata_v2_structured_source",
               e.eventHash?.range(of: "^[a-f0-9]{64}$", options: .regularExpression) == nil { return false }
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
    private struct Progress: Codable {
        var size: Int64 = 0
        var inode = ""
        var offset: Int64 = 0
        var discarding = false
        var formatIncomplete = false
        var modern: [String: GrindDiagnosticReport.Event] = [:]
        var legacy: [String: GrindDiagnosticReport.Event] = [:]
    }
    private struct Checkpoint: Codable {
        var homeHash: String
        var files: [String: Progress] = [:]
    }
    private let maxBytes: Int64
    private let maxSeconds: TimeInterval
    private let maxRowBytes: Int
    public init(maxBytes: Int64 = 768 * 1024 * 1024, maxSeconds: TimeInterval = 30, maxRowBytes: Int = 4 * 1024 * 1024) {
        self.maxBytes = max(0, min(maxBytes, 768 * 1024 * 1024))
        self.maxSeconds = max(0, min(maxSeconds, 30))
        self.maxRowBytes = max(1, min(maxRowBytes, 4 * 1024 * 1024))
    }
    public func collect(codexHome: URL, index: CodexSessionFileIndex? = nil, stateURL: URL? = nil) -> GrindDiagnosticReport {
        let start = ISO8601DateFormatter().date(from: "2026-09-30T16:00:00Z")!
        let end = ISO8601DateFormatter().date(from: "2026-09-30T18:00:00Z")!
        let files = (index ?? CodexSessionFileIndex(codexHome: codexHome)).uniqueFiles(modifiedSince: start)
            .sorted { $0.modifiedAt == $1.modifiedAt ? $0.stableKey < $1.stableKey : $0.modifiedAt > $1.modifiedAt }
        let homeHash = GrindDiagnosticReport.hash(Data(codexHome.standardizedFileURL.path.utf8))
        var checkpoint = Checkpoint(homeHash: homeHash)
        if let stateURL, (try? stateURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
           let size = (try? stateURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 2 * 1024 * 1024,
           let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(Checkpoint.self, from: data), saved.homeHash == homeHash {
            checkpoint = saved
        }
        var unique: [String: GrindDiagnosticReport.Event] = [:], metadata: [GrindDiagnosticReport.File] = []
        var errors = 0, scanned = 0, consumed: Int64 = 0, limited = files.count > 32
        let began = ProcessInfo.processInfo.systemUptime
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestampPattern = try! NSRegularExpression(pattern: #"^\s*\{\s*"timestamp"\s*:\s*"([^"]+)""#)
        func outsideWindow(_ prefix: Data) -> Bool {
            let text = String(decoding: prefix.prefix(512), as: UTF8.self)
            guard let match = timestampPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return false }
            let t = String(text[range])
            if t.hasSuffix("Z") { return !(t.hasPrefix("2026-09-30T16:") || t.hasPrefix("2026-09-30T17:")) }
            if t.hasSuffix("+08:00") { return !(t.hasPrefix("2026-10-01T00:") || t.hasPrefix("2026-10-01T01:")) }
            return false
        }
        for file in files.prefix(32) {
            var url = file.url, unsafe = false
            while url.standardizedFileURL.path != codexHome.standardizedFileURL.path {
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { unsafe = true; break }
                let parent = url.deletingLastPathComponent()
                if parent.path == url.path { unsafe = true; break }; url = parent
            }
            if (try? codexHome.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { unsafe = true }
            guard !unsafe, let handle = try? FileHandle(forReadingFrom: file.url) else { errors += 1; continue }
            defer { try? handle.close() }
            do {
                let header = try handle.read(upToCount: 64 * 1024) ?? Data()
                let source = Self.source(header)
                let sessionID = Self.sessionID(header) ?? file.stableKey
                let size = Int64(try handle.seekToEnd())
                let hash = String(GrindDiagnosticReport.hash(Data(file.stableKey.utf8)).prefix(12))
                let inode = GrindDiagnosticReport.hash(Data((file.fileIdentifier ?? "").utf8))
                var progress = checkpoint.files[hash] ?? Progress()
                if progress.inode != inode || size < progress.size || progress.offset < 0 || progress.offset > size {
                    progress = Progress()
                }
                progress.size = size; progress.inode = inode
                try handle.seek(toOffset: UInt64(progress.offset))
                var modern = progress.modern, legacy = progress.legacy
                let elsewhere = checkpoint.files.filter { $0.key != hash }.values.reduce(0) { $0 + $1.modern.count + $1.legacy.count }
                var row = Data(), dropping = progress.discarding, truncated = progress.formatIncomplete
                var read = progress.offset, committed = progress.offset
                var formatIncomplete = progress.formatIncomplete
                scanned += 1
                func process(_ line: Data) {
                    if outsideWindow(line) { return }
                    guard let e = CodexGrindHistoryCollector.authoredEventMetadata(line), e.date >= start, e.date < end else { return }
                    if modern.count + legacy.count + elsewhere >= 4096 { limited = true; return }
                    let at = formatter.string(from: e.date)
                    // Supported payload ID, scoped to session. Without an ID use
                    // exact time/type only; never merge nearby millisecond events.
                    let identity = e.identifier.map { "id|\($0)" } ?? "timestamp|\(e.type)|\(e.timestamp)"
                    let id = GrindDiagnosticReport.hash(Data("\(sessionID)|\(identity)".utf8))
                    let event = GrindDiagnosticReport.Event(at: at, type: e.type, source: source, fileHash: hash, eventHash: id)
                    if e.type == "response_item" {
                        if modern[id] == nil || at < modern[id]!.at { modern[id] = event }
                    } else if legacy[id] == nil || at < legacy[id]!.at { legacy[id] = event }
                }
                while read < size {
                    guard consumed < maxBytes, ProcessInfo.processInfo.systemUptime - began < maxSeconds else {
                        limited = true; truncated = true; break
                    }
                    var reachedEnd = false
                    try autoreleasepool {
                        let chunkStart = read
                        let chunk = try handle.read(upToCount: Int(min(256 * 1024, maxBytes - consumed))) ?? Data()
                        if chunk.isEmpty { truncated = read < size; reachedEnd = true; return }
                        read += Int64(chunk.count); consumed += Int64(chunk.count)
                        var cursor = chunk.startIndex
                        while cursor < chunk.endIndex {
                            let newline = chunk[cursor...].firstIndex(of: 10)
                            let stop = newline ?? chunk.endIndex
                            if !dropping {
                                if row.count + stop - cursor <= maxRowBytes { row.append(contentsOf: chunk[cursor..<stop]) }
                                else {
                                    // Keep a small prefix to prove irrelevant timestamps;
                                    // an oversized potentially relevant row stays incomplete.
                                    if row.count < 512 { row.append(contentsOf: chunk[cursor..<min(stop, cursor + 512 - row.count)]) }
                                    if !outsideWindow(row) && !Self.provablyNonHuman(row) { truncated = true; formatIncomplete = true }
                                    dropping = true; row.removeAll(keepingCapacity: true)
                                }
                            }
                            if let newline {
                                if !dropping { autoreleasepool { process(row) } }
                                row.removeAll(keepingCapacity: true); dropping = false; cursor = newline + 1
                                committed = chunkStart + Int64(cursor)
                            } else { break }
                        }
                    }
                    if dropping { committed = read }
                    if reachedEnd { break }
                    // Background utility task, yield between bounded reads.
                    Thread.sleep(forTimeInterval: 0.001)
                }
                var partial = !row.isEmpty || dropping
                if read >= size && !row.isEmpty && (outsideWindow(row) || Self.provablyNonHuman(row)) {
                    committed = read; dropping = true; partial = false
                } else if read >= size && dropping && !formatIncomplete { partial = false }
                progress.offset = committed; progress.discarding = dropping
                progress.formatIncomplete = formatIncomplete; progress.modern = modern; progress.legacy = legacy
                checkpoint.files[hash] = progress
                let finalSize = Int64(try handle.seekToEnd())
                if finalSize != size { truncated = true }
                let chosen = modern.isEmpty ? legacy : modern
                for (id, event) in chosen {
                    if unique.count >= 4096 && unique[id] == nil { limited = true; continue }
                    if unique[id] == nil || event.at < unique[id]!.at || (event.at == unique[id]!.at && event.fileHash < unique[id]!.fileHash) { unique[id] = event }
                }
                metadata.append(.init(fileHash: hash, size: finalSize, unreadBytes: max(0, finalSize - committed), tailScanTruncated: truncated, trailingPartialLine: partial))
            } catch { errors += 1 }
        }
        if let stateURL {
            do {
                let allowed = Set(metadata.map(\.fileHash))
                checkpoint.files = checkpoint.files.filter { allowed.contains($0.key) }
                let data = try JSONEncoder().encode(checkpoint)
                guard data.count <= 2 * 1024 * 1024 else { throw StateStoreError.invalidInput("diagnostic checkpoint size") }
                try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard (try? stateURL.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { throw StateStoreError.invalidInput("diagnostic checkpoint link") }
                try data.write(to: stateURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            } catch { errors += 1 }
        }
        let events = unique.values.sorted { ($0.at, $0.eventHash ?? "") < ($1.at, $1.eventHash ?? "") }
        let summary = GrindDiagnosticReport.Summary(classifierVersion: "human_metadata_v4_resumable_identity", candidateFiles: files.count, scannedFiles: scanned, readErrors: errors,
            scanLimited: limited, eventsInWindow: events.count,
            coverageIncomplete: scanned == 0 || events.isEmpty || limited || errors > 0 || events.count > 30 || metadata.contains { $0.tailScanTruncated || $0.trailingPartialLine } || events.contains { $0.source == "unknown" })
        var report = GrindDiagnosticReport(summary: summary, events: Array(events.suffix(30)), files: metadata.sorted { $0.fileHash < $1.fileHash })
        if let data = try? report.canonicalData(includeID: false) { report.reportId = GrindDiagnosticReport.hash(data) }
        return report
    }
    // Only complete scalar properties preceding content are used. A bounded
    // prefix can prove an assistant/tool row ineligible without reading its text.
    private static func provablyNonHuman(_ data: Data) -> Bool {
        let bytes = Array(data.prefix(512))
        let text = String(decoding: bytes, as: UTF8.self)
        guard let range = text.range(of: #""payload"\s*:\s*\{"#, options: .regularExpression) else { return false }
        var top = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if top.last == "," { top.removeLast() }
        guard let raw = (top + "}").data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: raw) as? [String: Any], let type = envelope["type"] as? String else { return false }
        if !["response_item", "event_msg"].contains(type) { return true }
        let payload = Array(text[range.upperBound...].utf8)
        var i = 0, fields: [String: String] = [:]
        func whitespace() { while i < payload.count && [9, 10, 13, 32].contains(payload[i]) { i += 1 } }
        func string() -> String? {
            whitespace(); guard i < payload.count && payload[i] == 34 else { return nil }
            let begin = i; i += 1; var escaped = false
            while i < payload.count {
                let c = payload[i]; i += 1
                if escaped { escaped = false; continue }
                if c == 92 { escaped = true; continue }
                if c == 34 { return (try? JSONSerialization.jsonObject(with: Data(payload[begin..<i]), options: .fragmentsAllowed)) as? String }
            }
            return nil
        }
        while i < payload.count {
            guard let key = string() else { break }; whitespace()
            guard i < payload.count && payload[i] == 58 else { break }; i += 1; whitespace()
            guard i < payload.count else { break }
            if payload[i] == 34 {
                guard let value = string() else { break }
                if ["type", "role"].contains(key) { fields[key] = value }
            } else if payload[i] == 123 || payload[i] == 91 { break }
            else { while i < payload.count && ![44, 125].contains(payload[i]) { i += 1 } }
            if type == "response_item", let p = fields["type"], p != "message" { return true }
            if type == "response_item", let r = fields["role"], r != "user" { return true }
            if type == "event_msg", let p = fields["type"], p != "user_message" { return true }
            whitespace(); guard i < payload.count && payload[i] == 44 else { break }; i += 1
        }
        return false
    }
    private static func sessionID(_ header: Data) -> String? {
        for line in header.split(separator: 10) {
            guard let v = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], v["type"] as? String == "session_meta",
                  let p = v["payload"] as? [String: Any], let id = p["id"] as? String, !id.isEmpty else { continue }
            return id
        }
        return nil
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
