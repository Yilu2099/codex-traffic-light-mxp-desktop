import Foundation
import CryptoKit
import Darwin

/// Numeric observations only. This journal never changes accounting counters.
public struct TokenCollectionAudit: Sendable {
    public struct Record: Codable, Sendable {
        public var id: String
        public var at: String
        public var eventAt: String?
        public var source: String
        public var kind: String
        public var reason: String
        public var origin: String?
        public var parent: String?
        public var eventKey: String?
        public var key: String?
        public var account: String?
        public var version: String
        public var values: [String: Int]
        public init(source: String, kind: String, reason: String, key: String? = nil, account: String? = nil,
                    eventAt: String? = nil, values: [String: Int] = [:], id: String = UUID().uuidString, now: Date = Date()) {
            self.id = id; self.at = SharedDateFormatters.shared.iso8601Fractional.string(from: now)
            self.source = source; self.kind = kind; self.reason = reason; self.key = key?.count == 64 ? key : nil; self.account = account?.count == 64 ? account : nil; self.eventKey = nil; self.origin = nil; self.parent = nil
            self.eventAt = eventAt; self.values = values.filter { $0.value >= 0 && $0.value <= 9_007_199_254_740_991 }; self.version = ClientVersion.current
        }
    }
    public struct Batch: Codable, Sendable {
        public var stream: String
        public var through: Int
        public var events: [Record]
    }
    public let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wanhe-codex-token/token-audit")) { self.root = root }
    public static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func account(_ home: URL) -> String? {
        guard let d = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let a = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = a["tokens"] as? [String: Any], let id = t["account_id"] as? String else { return nil }
        return DotTokenLedger.key(account: id, thread: "account")
    }
    private func locked<T>(_ work: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(root.appendingPathComponent("journal.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        return try work()
    }
    private func status(_ code: String) {
        let d = try? JSONSerialization.data(withJSONObject: ["code": code, "at": SharedDateFormatters.shared.iso8601Fractional.string(from: Date())])
        try? d?.write(to: root.appendingPathComponent("status.json"), options: .atomic)
    }
    @discardableResult
    public func append(_ records: [Record], now: Date = Date()) -> Bool {
        guard !records.isEmpty else { return true }
        do {
            try locked {
                let day = String(SharedDateFormatters.shared.iso8601Fractional.string(from: now).prefix(10))
                let file = root.appendingPathComponent(day + ".jsonl")
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
                let h = try FileHandle(forUpdating: file); defer { try? h.close() }
                let size = try h.seekToEnd()
                var prefix: [Record] = []
                if size > 0 {
                    try h.seek(toOffset: size > 65536 ? size - 65536 : 0)
                    let tail = try h.readToEnd() ?? Data()
                    if tail.last != 10 {
                        let lost = tail.count - (tail.lastIndex(of: 10).map { $0 + 1 } ?? 0)
                        try h.truncate(atOffset: size - UInt64(lost))
                        prefix.append(Record(source: "collector", kind: "failure", reason: "partial_write", values: ["bytesLost": lost], now: now))
                    }
                }
                if try h.seekToEnd() == 0 { prefix.insert(Record(source: "collector", kind: "coverage_start", reason: "audit_enabled", now: now), at: 0) }
                for record in prefix + records {
                    var d = try JSONEncoder().encode(record); d.append(10); try h.write(contentsOf: d)
                }
                try h.synchronize()
            }
            status("ok"); return true
        } catch { status("journal_write_failed"); return false }
    }
    public func nextBatch() throws -> Batch? {
        try locked {
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                let ack = (try? Data(contentsOf: file.appendingPathExtension("ack"))).flatMap { String(data: $0, encoding: .utf8) }.flatMap(Int.init) ?? 0
                let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
                let first = try h.read(upToCount: 8192) ?? Data()
                guard let newline = first.firstIndex(of: 10), let header = try? JSONDecoder().decode(Record.self, from: first.prefix(upTo: newline)) else { throw CocoaError(.fileReadCorruptFile) }
                try h.seek(toOffset: UInt64(max(0, ack)))
                let d = try h.read(upToCount: 256 * 1024) ?? Data()
                if d.isEmpty { continue }
                var records: [Record] = [], bytes = 0
                for line in d.split(separator: 10, omittingEmptySubsequences: false).dropLast() {
                    records.append(try JSONDecoder().decode(Record.self, from: line)); bytes += line.count + 1
                    if records.count == 300 { break }
                }
                guard !records.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                return Batch(stream: file.deletingPathExtension().lastPathComponent + "_" + header.id, through: ack + bytes, events: records)
            }
            return nil
        }
    }
    public func acknowledge(_ batch: Batch) throws {
        try locked {
            let file = root.appendingPathComponent(String(batch.stream.prefix(10)) + ".jsonl")
            let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
            let d = try h.read(upToCount: 8192) ?? Data()
            guard let end = d.firstIndex(of: 10), let first = try? JSONDecoder().decode(Record.self, from: d.prefix(upTo: end)), batch.stream.hasSuffix("_" + first.id) else { throw CocoaError(.fileReadCorruptFile) }
            let previousAck = (try? String(contentsOf: file.appendingPathExtension("ack"), encoding: .utf8)).flatMap(Int.init) ?? 0
            try Data(String(max(previousAck, batch.through)).utf8).write(to: file.appendingPathExtension("ack"), options: .atomic)
            // Keep a month locally; unsent records are never removed by age.
            let cutoff = SharedDateFormatters.shared.iso8601Fractional.string(from: Date().addingTimeInterval(-30 * 86400)).prefix(10)
            for old in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey]) where old.pathExtension == "jsonl" && old.lastPathComponent.prefix(10) < cutoff {
                let sent = (try? String(contentsOf: old.appendingPathExtension("ack"), encoding: .utf8)).flatMap(Int.init) ?? -1
                if sent == (try old.resourceValues(forKeys: [.fileSizeKey])).fileSize {
                    try FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: old.appendingPathExtension("ack"))
                }
            }
        }
    }
    public func upload(configuration: TeamSyncConfiguration) async {
        do {
            for _ in 0..<4 {
                guard let batch = try nextBatch() else { return }
                var url = configuration.endpoint; url.deleteLastPathComponent(); url.appendPathComponent("collector/token-audit")
                var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 15
                req.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization"); req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONEncoder().encode(batch)
                let (data, response) = try await URLSession.shared.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any], receipt["durable"] as? Bool == true,
                      receipt["stream"] as? String == batch.stream, receipt["through"] as? Int == batch.through else { throw CocoaError(.fileWriteUnknown) }
                try acknowledge(batch)
            }
        } catch { status("audit_upload_failed") }
    }
}
