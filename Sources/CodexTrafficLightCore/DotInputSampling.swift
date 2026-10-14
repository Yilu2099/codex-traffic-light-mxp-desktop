import Foundation
import CryptoKit

/// Exportable metadata only. The cache envelope (salt and sealed cursors) is never uploaded.
public struct DotInputSnapshot: Codable, Equatable, Sendable {
    public var schema = "dot_human_input_v2"
    public let ownerVerified = true
    enum CodingKeys: String, CodingKey {
        case schema, ownerVerified, accountFingerprint, collectedAt, workdayStartAt, coverageStartAt
        case currentDayCovered, ownerMessages, excludedDotMessages, excludedAutomaticMessages, invalidMessages
    }
    public var accountFingerprint: String
    public var collectedAt: String
    public var workdayStartAt: String
    public var coverageStartAt: String?
    public var currentDayCovered: Bool
    public var ownerMessages: [HumanInputEvent]
    public var excludedDotMessages: Int
    public var excludedAutomaticMessages: Int
    public var invalidMessages: Int
    public var windowLimited: Bool { !currentDayCovered }
    public var lastOwnerMessageAt: String? { ownerMessages.last?.sourceAt }
    public var firstOwnerMessageAt: String? { currentDayCovered ? ownerMessages.first?.sourceAt : nil }
}

/// Runs on a background worker. Requests always use the read-only authenticated transport.
public actor DotInputSampler {
    private struct Segment: Codable {
        var cursor: String
        var stopAt: Date
        var historical: Bool
        var upperAt: Date?
    }
    private struct Cache: Codable {
        var version = 2
        var salt: Data
        var binding: String
        var snapshot: DotInputSnapshot
        var sealedSegments: Data
        var newestAt: Date?
        var boundaryReached: Bool
        var timestampsReliable: Bool
    }
    private var sampling = false
    private let cacheURL: URL
    public init(cacheURL: URL) { self.cacheURL = cacheURL }
    public nonisolated static func defaultCacheURL(codexHome: URL) -> URL {
        codexHome.appendingPathComponent("wanhe-dot-human-input.json")
    }

    public nonisolated static func fingerprint(identity: DotInputIdentity) -> String {
        SHA256.hash(data: Data((identity.account + "|" + identity.user).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public nonisolated static func workdayStart(now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Hong_Kong")!
        let morning = calendar.date(byAdding: .hour, value: 5, to: calendar.startOfDay(for: now))!
        return now < morning ? calendar.date(byAdding: .day, value: -1, to: morning)! : morning
    }
    public nonisolated static func read(cacheURL: URL, identity: DotInputIdentity, now: Date = Date(), maxAge: TimeInterval = 300) -> DotInputSnapshot? {
        guard let cache = load(cacheURL), cache.snapshot.accountFingerprint == fingerprint(identity: identity),
              let sampled = DotInputCollector.parse(cache.snapshot.collectedAt),
              sampled <= now.addingTimeInterval(5), now.timeIntervalSince(sampled) <= maxAge,
              DotInputCollector.parse(cache.snapshot.workdayStartAt) == workdayStart(now: now) else { return nil }
        return cache.snapshot
    }

    public func sample(identity: DotInputIdentity, transport: any DotInputReadTransport,
                       maxPages: Int = 3, now: Date = Date()) async throws -> DotInputSnapshot {
        guard !sampling else { throw DotInputError.unavailable("sampling_in_progress") }
        sampling = true; defer { sampling = false }
        let fingerprint = Self.fingerprint(identity: identity), start = Self.workdayStart(now: now)
        var cache = Self.load(cacheURL)
        if cache?.snapshot.accountFingerprint != fingerprint { cache = nil }
        let salt = cache?.salt ?? Self.randomSalt()
        let collector = DotInputCollector()
        let head = try await collector.window(identity: identity, transport: transport, salt: salt, maxPages: 1, now: now)
        if cache?.binding != head.binding { cache = nil }
        var segments: [Segment] = []
        if let existing = cache {
            do { segments = try Self.open(existing.sealedSegments, salt: salt) }
            catch { cache = nil }
        }
        var snapshot = DotInputSnapshot(accountFingerprint: fingerprint, collectedAt: head.report.collectedAt,
            workdayStartAt: Self.iso(start), coverageStartAt: nil, currentDayCovered: false, ownerMessages: [],
            excludedDotMessages: 0, excludedAutomaticMessages: 0, invalidMessages: 0)
        var reached = cache?.boundaryReached ?? false
        var reliable = cache?.timestampsReliable ?? true
        if let prior = cache, DotInputCollector.parse(prior.snapshot.workdayStartAt) == start {
            snapshot = prior.snapshot
        } else {
            // A new workday starts a new bounded sweep; yesterday's coverage never certifies today.
            cache = nil; segments = []; reached = false; reliable = true
        }
        snapshot.excludedDotMessages = 0; snapshot.excludedAutomaticMessages = 0; snapshot.invalidMessages = 0
        var events = Dictionary(snapshot.ownerMessages.map { ($0.eventKey, $0) }, uniquingKeysWith: { _, new in new })
        func merge(_ window: DotInputCollector.Window) {
            for event in window.report.ownerMessages {
                if let date = DotInputCollector.parse(event.sourceAt), date >= start, date <= now { events[event.eventKey] = event }
            }
            snapshot.excludedDotMessages += window.report.excludedDotMessages
            snapshot.excludedAutomaticMessages += window.report.excludedAutomaticMessages
            snapshot.invalidMessages += window.report.invalidMessages
            // Unparseable owner timestamps leave coverage uncertain. Counts are per most recent batch, not totals.
            reliable = reliable && window.ordered && window.report.invalidMessages == 0
            if let oldest = window.oldestAt {
                let previous = snapshot.coverageStartAt.flatMap(DotInputCollector.parse)
                snapshot.coverageStartAt = Self.iso(min(previous ?? oldest, oldest))
            }
        }
        merge(head)
        let priorNewest = cache?.newestAt
        if head.exhausted || (head.ordered && head.oldestAt.map { $0 <= start } == true) { reached = true }
        else if let cursor = head.nextCursor {
            if let priorNewest {
                if head.oldestAt.map({ $0 > priorNewest }) ?? true {
                    segments.insert(Segment(cursor: cursor, stopAt: priorNewest, historical: false, upperAt: head.oldestAt), at: 0)
                }
            } else {
                segments = [Segment(cursor: cursor, stopAt: start, historical: true, upperAt: head.oldestAt)]
            }
        }
        var budget = max(1, min(maxPages, 5)) - 1
        while budget > 0, !segments.isEmpty {
            var segment = segments.removeFirst()
            let window: DotInputCollector.Window
            do {
                window = try await collector.window(identity: identity, transport: transport, salt: salt,
                    maxPages: 1, now: now, before: segment.cursor)
            } catch {
                // Preserve the successful newest-page sample and resume this exact cursor next poll.
                segments.insert(segment, at: 0); break
            }
            guard window.binding == head.binding else { throw DotInputError.unavailable("room_changed") }
            if let upper = segment.upperAt, let newer = window.newestAt, newer > upper { reliable = false }
            merge(window); budget -= 1
            if window.exhausted || (window.ordered && window.oldestAt.map({ $0 <= segment.stopAt }) == true) {
                if segment.historical { reached = true }
            } else if let cursor = window.nextCursor, cursor != segment.cursor {
                segment.cursor = cursor; segment.upperAt = window.oldestAt; segments.insert(segment, at: 0)
            } else { reliable = false }
        }
        guard segments.count <= 64 else { throw DotInputError.unavailable("sampling_backlog") }
        snapshot.collectedAt = head.report.collectedAt
        snapshot.ownerMessages = events.values.sorted { (DotInputCollector.parse($0.sourceAt) ?? .distantPast) < (DotInputCollector.parse($1.sourceAt) ?? .distantPast) }
        snapshot.currentDayCovered = reached && segments.allSatisfy(\.historical) && reliable
        if snapshot.currentDayCovered {
            // Exhausted room history also proves absence before its oldest message, including an empty room.
            snapshot.coverageStartAt = Self.iso(min(snapshot.coverageStartAt.flatMap(DotInputCollector.parse) ?? start, start))
        }
        let saved = Cache(salt: salt, binding: head.binding, snapshot: snapshot,
            sealedSegments: try Self.seal(segments, salt: salt), newestAt: head.newestAt ?? priorNewest,
            boundaryReached: reached, timestampsReliable: reliable)
        try Self.save(saved, to: cacheURL)
        return snapshot
    }

    private nonisolated static func randomSalt() -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    private nonisolated static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private nonisolated static func seal(_ segments: [Segment], salt: Data) throws -> Data {
        try AES.GCM.seal(JSONEncoder().encode(segments), using: SymmetricKey(data: salt)).combined!
    }
    private nonisolated static func open(_ sealed: Data, salt: Data) throws -> [Segment] {
        try JSONDecoder().decode([Segment].self, from: AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: salt)))
    }
    private nonisolated static func load(_ url: URL) -> Cache? {
        guard let data = try? Data(contentsOf: url), data.count <= 8 * 1024 * 1024,
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshot = envelope["snapshot"] as? [String: Any], snapshot["ownerVerified"] as? Bool == true,
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 2, cache.salt.count == 32 else { return nil }
        return cache
    }
    private nonisolated static func save(_ cache: Cache, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".dot-cache-" + UUID().uuidString)
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw DotInputError.unavailable("cache_write")
        }
        defer { try? fm.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: JSONEncoder().encode(cache)); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: url) }
    }
}
