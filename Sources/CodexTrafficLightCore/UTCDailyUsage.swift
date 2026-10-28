import Foundation

/// Diagnostic event-time ledger. It never grants authority to replace ranking history.
public struct UTCDailyUsageReport: Codable, Equatable, Sendable {
    public var day: String
    public var tokens: Int
    public var updatedAt: String
    public var coverageFrom: String?
    public var throughAt: String?

    public init(day: String, tokens: Int, updatedAt: String, coverageFrom: String?, throughAt: String?) {
        self.day = day; self.tokens = tokens; self.updatedAt = updatedAt
        self.coverageFrom = coverageFrom; self.throughAt = throughAt
    }

    enum CodingKeys: String, CodingKey { case day, tokens, updatedAt, coverageFrom, throughAt }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(day, forKey: .day)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(coverageFrom, forKey: .coverageFrom)
        try container.encode(throughAt, forKey: .throughAt)
    }
}

/// Retain only fourteen UTC dates, including today. Coverage starts when this
/// ledger is enabled; an imported current counter does not certify earlier hours.
struct UTCDailyUsageLedger: Codable, Sendable {
    struct Coverage: Codable, Sendable { var from: Date; var through: Date }
    var tokens: [String: Int] = [:]
    var coverageFrom: Date
    var throughAt: Date
    var interrupted: Bool? = false
    var completedCoverage: [String: Coverage]? = [:]

    init(now: Date, seedDay: String?, seedTokens: Int?) {
        coverageFrom = now; throughAt = now
        if let seedDay, let seedTokens, seedTokens >= 0 { tokens[seedDay] = seedTokens }
    }

    static func day(_ date: Date) -> String { SharedDateFormatters.shared.utcDay.string(from: date) }
    static func start(_ day: String) -> Date? { SharedDateFormatters.shared.iso8601Date(from: day + "T00:00:00Z") }
    static func cutoff(_ now: Date) -> Date { start(day(now))!.addingTimeInterval(-13 * 86400) }

    mutating func record(_ amount: Int, at date: Date, now: Date) {
        guard amount > 0, date >= Self.cutoff(now), date <= now.addingTimeInterval(300) else { return }
        tokens[Self.day(date), default: 0] += amount
    }

    mutating func finish(now: Date, fullyRead: Bool) {
        let cutoff = Self.cutoff(now)
        // Keep a plausible near-midnight future row until its source UTC day
        // arrives. Reports omit future dates; discarding it here would lose it.
        tokens = tokens.filter { $0.key >= Self.day(cutoff) && $0.key <= Self.day(now.addingTimeInterval(300)) }
        completedCoverage = completedCoverage?.filter { $0.key >= Self.day(cutoff) }
        guard fullyRead else { interrupted = true; return }
        // An unread/invalid tail or a pause exceeding retention breaks the
        // certified window. Recovered numbers survive, but not a false bridge.
        if interrupted == true || throughAt < cutoff { coverageFrom = now }
        interrupted = false
        throughAt = max(throughAt, now)
        let first = max(cutoff, Self.start(Self.day(coverageFrom))!), today = Self.start(Self.day(now))!
        if first < today {
            for step in 0..<Int(today.timeIntervalSince(first) / 86400) {
                let start = first.addingTimeInterval(Double(step) * 86400)
                completedCoverage?[Self.day(start)] = Coverage(from: max(coverageFrom, start), through: start.addingTimeInterval(86400))
            }
        }
    }

    func reports(now: Date) -> [UTCDailyUsageReport] {
        let cutoff = Self.cutoff(now), latest = Self.start(Self.day(now))!
        let first = max(cutoff, Self.start(Self.day(coverageFrom))!)
        var days = Set(tokens.keys).union(completedCoverage?.keys.map { $0 } ?? [])
        if first <= latest {
            for step in 0...Int(latest.timeIntervalSince(first) / 86400) {
                days.insert(Self.day(first.addingTimeInterval(Double(step) * 86400)))
            }
        }
        let iso = SharedDateFormatters.shared.iso8601Fractional
        return days.sorted().compactMap { day in
            guard let start = Self.start(day), start >= cutoff, start <= latest else { return nil }
            let completed = completedCoverage?[day]
            let from = completed?.from ?? max(coverageFrom, start)
            let through = completed?.through ?? min(throughAt, start.addingTimeInterval(86400))
            let covered = through >= from
            return UTCDailyUsageReport(day: day, tokens: tokens[day] ?? 0, updatedAt: iso.string(from: now),
                coverageFrom: covered ? iso.string(from: from) : nil,
                throughAt: covered ? iso.string(from: through) : nil)
        }
    }
}
