import Foundation

public struct MemberHighlight: Equatable, Sendable {
    public let kind: String
    public let label: String
    public let reason: String

    public init(kind: String, label: String, reason: String) {
        self.kind = kind
        self.label = label
        self.reason = reason
    }
}

public enum MemberHighlights {
    public static func workday(at date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let day = hour * 60 + minute < 301 ? calendar.date(byAdding: .day, value: -1, to: date)! : date
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    public static func calculate(
        today: TeamRankingSnapshot,
        week: TeamRankingSnapshot,
        month: TeamRankingSnapshot,
        workday: String
    ) -> [String: MemberHighlight] {
        let weeklyTokens = Dictionary(week.members.map { ($0.id, $0.tokens) }, uniquingKeysWith: { first, _ in first })
        let monthlyTokens = Dictionary(month.members.map { ($0.id, $0.tokens) }, uniquingKeysWith: { first, _ in first })
        let joined = today.members.filter { $0.joined != false }
        var result: [String: MemberHighlight] = [:]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let previousDay = formatter.date(from: workday).flatMap { calendar.date(byAdding: .day, value: -1, to: $0) }.map(formatter.string)

        func award(_ value: (TeamRankingMember) -> Int?, highest: Bool, _ highlight: MemberHighlight) {
            let valid = joined.compactMap { member -> (TeamRankingMember, Int)? in
                value(member).map { (member, $0) }
            }
            guard valid.count >= 2, let best = (highest ? valid.map(\.1).max() : valid.map(\.1).min()) else { return }
            let winner = valid.filter { $0.1 == best && result[$0.0.id] == nil }
                .min { $0.0.id.localizedCompare($1.0.id) == .orderedAscending }
            if let winner { result[winner.0.id] = highlight }
        }

        award({ $0.tokens > 0 ? $0.tokens : nil }, highest: true,
              MemberHighlight(kind: "lead", label: "今日领跑", reason: "今日 Token 用量最高；数值并列时按固定顺序选出唯一一人"))
        award({ (weeklyTokens[$0.id] ?? 0) > 0 ? weeklyTokens[$0.id] : nil }, highest: true,
              MemberHighlight(kind: "range", label: "本周领跑", reason: "本周 Token 用量最高"))
        award({ (monthlyTokens[$0.id] ?? 0) > 0 ? monthlyTokens[$0.id] : nil }, highest: true,
              MemberHighlight(kind: "range", label: "本月领跑", reason: "本月 Token 用量最高"))
        award({ $0.sessions > 0 ? $0.sessions : nil }, highest: true,
              MemberHighlight(kind: "session", label: "对话最多", reason: "今日会话次数最多"))
        award({ $0.dayGrindDay == workday ? workMinutes($0.dayGrindTime) : nil }, highest: false,
              MemberHighlight(kind: "early", label: "起得最早", reason: "当前工作日最早开始真人互动，不代表实际起床时间"))
        award({ $0.nightGrindDay == previousDay ? workMinutes($0.nightGrindTime) : nil }, highest: true,
              MemberHighlight(kind: "late", label: "收工最晚", reason: "上一已结算工作日最晚结束真人互动，不代表睡眠时间"))

        let quotaKinds: [CodexQuotaWindowKind] = [.weekly, .fiveHour].filter { kind in
            joined.filter { $0.weeklyQuota?.preferredWindow?.kind == kind }.count >= 2
        }
        for kind in quotaKinds {
            let windowName = kind == .weekly ? "周" : "5小时"
            award({ member in
                guard let window = member.weeklyQuota?.preferredWindow, window.kind == kind else { return nil }
                return window.remainingPercent
            }, highest: true,
                  MemberHighlight(kind: "quota", label: quotaKinds.count > 1 ? "\(windowName)余额最足" : "余额最足",
                                  reason: "同为\(windowName)窗口的成员中，剩余额度比例最高"))
        }
        let streakWinner = joined.filter { result[$0.id] == nil && ($0.streak ?? 0) >= 7 }
            .sorted { left, right in
                if left.streak != right.streak { return (left.streak ?? 0) > (right.streak ?? 0) }
                return left.id.localizedCompare(right.id) == .orderedAscending
            }.first
        if let streakWinner {
            result[streakWinner.id] = MemberHighlight(kind: "quota", label: "连搓多天", reason: "尚未获得其他标签的成员中，连续活跃天数最高")
        }
        return result
    }

    private static func workMinutes(_ time: String?) -> Int? {
        guard let time, time.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { return nil }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        let value = parts[0] * 60 + parts[1]
        return value < 301 ? value + 1440 : value
    }
}

public enum TeamRoster {
    public typealias Entry = (id: String, name: String, avatar: String)

    /// Merges server members into the fixed roster. IDs match case-insensitively; the first
    /// server copy of a duplicate wins, roster gaps stay as placeholders and members the
    /// roster does not know yet are kept after roster entries.
    public static func merge(_ incoming: [TeamRankingMember], roster: [Entry]) -> [TeamRankingMember] {
        var byKey: [String: TeamRankingMember] = [:]
        var serverOrder: [String] = []
        for member in incoming {
            let key = member.id.lowercased()
            guard byKey[key] == nil else { continue }
            byKey[key] = member
            serverOrder.append(key)
        }
        let rosterKeys = Set(roster.map { $0.id.lowercased() })
        let fixed = roster.map { entry -> TeamRankingMember in
            var member = byKey[entry.id.lowercased()] ?? TeamRankingMember(id: entry.id, name: entry.name)
            if member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                member.name = entry.name
            }
            if member.avatar?.isEmpty != false {
                member.avatar = "/avatars/\(entry.avatar)"
            }
            return member
        }
        let extra = serverOrder.filter { !rosterKeys.contains($0) }.compactMap { byKey[$0] }
        return (fixed + extra).enumerated()
            .sorted { left, right in
                if left.1.hasEverJoined != right.1.hasEverJoined { return left.1.hasEverJoined }
                if left.1.tokens != right.1.tokens { return left.1.tokens > right.1.tokens }
                if left.1.sessions != right.1.sessions { return left.1.sessions > right.1.sessions }
                return left.0 < right.0
            }
            .map(\.1)
    }

    public static func entry(for id: String, in roster: [Entry]) -> Entry? {
        let key = id.lowercased()
        return roster.first { $0.id.lowercased() == key }
    }
}
