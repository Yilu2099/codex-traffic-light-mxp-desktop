import AppKit
import SwiftUI
import CodexTrafficLightCore

@MainActor
final class StatusPopoverModel: ObservableObject {
    @Published var snapshot: StateSnapshot?
    @Published var ranking: TeamRankingSnapshot?
    @Published var syncDetail: String = "正在读取团队数据…"
    @Published var websiteURL: URL?
}

struct StatusPopoverView: View {
    @ObservedObject var model: StatusPopoverModel
    let openWebsite: (String?) -> Void
    let quit: () -> Void

    private let canvas = Color(red: 0.975, green: 0.965, blue: 0.945)
    private let card = Color(red: 1.0, green: 0.995, blue: 0.985)
    private let ink = Color(red: 0.12, green: 0.115, blue: 0.105)
    private let muted = Color(red: 0.49, green: 0.47, blue: 0.43)
    private let line = Color(red: 0.88, green: 0.85, blue: 0.79)
    private let green = Color(red: 0.18, green: 0.54, blue: 0.32)
    private let warm = Color(red: 0.82, green: 0.43, blue: 0.20)
    private let roster: [(id: String, name: String, avatar: String)] = [
        ("zlu", "张璐", "codex-04.png"),
        ("qiubo", "仇博", "codex-01.png"),
        ("yangang", "杨昂", "codex-02.png"),
        ("yangke", "杨珂", "codex-03.png"),
        ("liguoqing", "李国庆", "codex-05.png"),
        ("mameng", "马猛", "codex-06.png"),
        ("zhanghaiqiang", "张海强", "codex-07.png"),
        ("huangning", "黄宁", "codex-08.png"),
        ("qiaoyue", "乔月", "codex-11.png"),
        ("lyf", "李阳峰", "codex-10.png")
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    quotaCard
                    rankingSection
                    privacyNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 16)
            }
            footer
        }
        .frame(width: 456, height: 640)
        .background(canvas)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(green.opacity(0.13))
                Image(systemName: "bolt.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(green)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex 团队活跃")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                Text("用起来，更要做出结果")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(muted)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(green).frame(width: 7, height: 7)
                Text(syncStatus)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(green)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(green.opacity(0.09), in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(card)
        .overlay(alignment: .bottom) { line.frame(height: 1) }
    }

    private var quotaCard: some View {
        let quota = weeklyQuota
        let remaining = quota?.remainingPercent
        let used = Double(100 - (remaining ?? 0)) / 100
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("个人周额度", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(muted)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(remaining.map(String.init) ?? "--")
                            .font(.system(size: 39, weight: .heavy, design: .rounded))
                            .foregroundStyle(ink)
                        Text("% 剩余")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(muted)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("下次刷新")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(muted)
                    Text(resetRelativeText)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(ink)
                    Text(resetAbsoluteText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(muted)
                }
            }
            ProgressView(value: max(0, min(1, used)))
                .tint(green)
                .scaleEffect(x: 1, y: 1.7, anchor: .center)
            HStack {
                Text("已用 \(remaining.map { 100 - $0 } ?? 0)%")
                Spacer()
                Text("额度不参与排名")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
        }
        .padding(18)
        .background(card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(line, lineWidth: 1))
        .shadow(color: ink.opacity(0.045), radius: 12, y: 5)
    }

    private var rankingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("今日团队活跃")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(ink)
                    Text("按 Token 用量排名 · 点击查看成员详情")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(muted)
                }
                Spacer()
                Text("实时")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(warm)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(warm.opacity(0.10), in: Capsule())
            }

            VStack(spacing: 0) {
                let members = rankedMembers
                if !members.isEmpty {
                    ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                        memberRow(member, rank: index + 1)
                        if index < members.count - 1 { line.frame(height: 1) }
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(model.syncDetail)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(muted)
                        Spacer()
                    }
                    .padding(18)
                }
            }
            .background(card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(line, lineWidth: 1))
            .shadow(color: ink.opacity(0.04), radius: 10, y: 4)
        }
    }

    private func memberRow(_ member: TeamRankingMember, rank: Int) -> some View {
        Button { openWebsite(member.id) } label: {
            HStack(spacing: 12) {
                Text(String(format: "%02d", rank))
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(rankColor(rank))
                    .frame(width: 26)
                avatar(member)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName(member))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                    Text(memberActivity(member))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                    Text(memberQuotaText(member))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(member.weeklyQuota == nil ? muted : green)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(formatTokens(member.tokens))
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(ink)
                    Text("Token")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(muted)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(muted.opacity(0.65))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func avatar(_ member: TeamRankingMember) -> some View {
        ZStack {
            Circle().fill(rankColor(abs(member.id.hashValue) % 3 + 1).opacity(0.14))
            if let image = localAvatar(member) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let url = avatarURL(member) {
                PersistentAvatarImage(url: url, fallbackText: String(displayName(member).prefix(1)))
                    .id(url.absoluteString)
                    .foregroundStyle(ink)
            } else {
                Text(String(displayName(member).prefix(1)))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(ink)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
    }

    private var privacyNote: some View {
        Label("仅上传 Token 合计和会话数，不上传 prompt、代码或聊天正文", systemImage: "lock.shield")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { openWebsite(nil) } label: {
                Label("打开团队排行榜", systemImage: "safari")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(green)
            .disabled(model.websiteURL == nil)

            Button(action: quit) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .help("退出")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(card)
        .overlay(alignment: .top) { line.frame(height: 1) }
    }

    private var rankedMembers: [TeamRankingMember] {
        let incoming = Dictionary(uniqueKeysWithValues: (model.ranking?.members ?? []).map { ($0.id.lowercased(), $0) })
        return roster.enumerated().map { index, entry in
            var member = incoming[entry.id] ?? TeamRankingMember(id: entry.id, name: entry.name)
            if member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                member.name = entry.name
            }
            if member.avatar?.isEmpty != false {
                member.avatar = "/avatars/\(entry.avatar)"
            }
            return (index, member)
        }
        .sorted { left, right in
            if left.1.hasEverJoined != right.1.hasEverJoined { return left.1.hasEverJoined }
            if left.1.tokens != right.1.tokens { return left.1.tokens > right.1.tokens }
            if left.1.sessions != right.1.sessions { return left.1.sessions > right.1.sessions }
            return left.0 < right.0
        }
        .map(\.1)
    }

    private func displayName(_ member: TeamRankingMember) -> String {
        let serverName = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverName.isEmpty { return serverName }
        return roster.first(where: { $0.id == member.id.lowercased() })?.name ?? member.id
    }

    private func memberActivity(_ member: TeamRankingMember) -> String {
        if member.tokens <= 0 && member.sessions <= 0 {
            return member.hasEverJoined ? "今日暂无使用" : "还未加入"
        }
        if let lastActive = member.lastActive, !lastActive.isEmpty, lastActive != "-" {
            return "\(member.sessions) 次会话 · 更新至 \(lastActive)"
        }
        let detail = member.tokenSource == "today_live" ? "实时更新" : officialDate(member)
        return "\(member.sessions) 次会话 · \(detail)"
    }

    private func memberQuotaText(_ member: TeamRankingMember) -> String {
        guard let quota = member.weeklyQuota else {
            return "周额度待同步 · 刷新待更新"
        }
        return "周额度 \(quota.weeklyRemainingPercent)% · \(memberQuotaResetText(quota.weeklyResetsAt))"
    }

    private func memberQuotaResetText(_ value: String?) -> String {
        guard let value else { return "刷新时间待更新" }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let relaxed = ISO8601DateFormatter()
        relaxed.formatOptions = [.withInternetDateTime]
        guard let date = precise.date(from: value) ?? relaxed.date(from: value) else {
            return "刷新时间待更新"
        }
        return QuotaDisplayFormatter.refreshCountdownText(until: date)
    }

    private func localAvatar(_ member: TeamRankingMember) -> NSImage? {
        let serverFilename = member.avatar?.split(separator: "/").last.map(String.init)
        guard let filename = serverFilename ?? roster.first(where: { $0.id == member.id.lowercased() })?.avatar else { return nil }
        let parts = filename.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let url = Bundle.module.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Avatars")
            ?? Bundle.module.url(forResource: parts[0], withExtension: parts[1])
        return url.flatMap(NSImage.init(contentsOf:))
    }

    private var weeklyQuota: (remainingPercent: Int?, resetsAt: Date?)? {
        guard let snapshot = model.snapshot else { return nil }
        if let codex = snapshot.providerQuota(for: ProviderQuotaSnapshot.codexProviderID) {
            return (codex.weeklyRemainingPercent, codex.weeklyResetsAt)
        }
        guard let legacy = snapshot.quota else { return nil }
        return (legacy.weeklyRemainingPercent, legacy.weeklyResetsAt)
    }

    private var resetRelativeText: String {
        guard let date = weeklyQuota?.resetsAt else { return "暂无数据" }
        return QuotaDisplayFormatter.refreshCountdownText(until: date)
    }

    private var resetAbsoluteText: String {
        guard let date = weeklyQuota?.resetsAt else { return "—" }
        return QuotaDisplayFormatter.absoluteDateTimeText(date)
    }

    private var syncStatus: String {
        if model.ranking != nil { return model.syncDetail.isEmpty ? "已连接" : model.syncDetail }
        return "同步中"
    }

    private func officialDate(_ member: TeamRankingMember) -> String {
        if let day = member.officialUsage?.dataThrough {
            return "官方至 " + day.dropFirst(5).replacingOccurrences(of: "-", with: "/")
        }
        if let lastActive = member.lastActive, !lastActive.isEmpty, lastActive != "-" {
            return "更新至 \(lastActive)"
        }
        return member.tokens > 0 ? "今日已统计" : "今日暂无使用"
    }

    private func avatarURL(_ member: TeamRankingMember) -> URL? {
        guard var base = model.websiteURL else { return nil }
        if let path = member.avatar, path.hasPrefix("/") {
            base.append(path: String(path.dropFirst()))
            return base
        }
        let value = member.id.unicodeScalars.reduce(0) { (($0 << 5) - $0 + Int($1.value)) & 0x7fffffff }
        base.append(path: "avatars/codex-\(String(format: "%02d", value % 16 + 1)).png")
        return base
    }

    private func rankColor(_ rank: Int) -> Color {
        switch rank {
        case 1: return warm
        case 2: return Color(red: 0.38, green: 0.45, blue: 0.50)
        case 3: return Color(red: 0.66, green: 0.42, blue: 0.26)
        default: return muted
        }
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 100_000_000 {
            return String(format: value >= 1_000_000_000 ? "%.1f 亿" : "%.2f 亿", Double(value) / 100_000_000)
        }
        if value >= 10_000 { return String(format: "%.1f 万", Double(value) / 10_000) }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}
