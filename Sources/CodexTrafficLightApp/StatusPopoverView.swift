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

    private let canvas = Color(red: 0.985, green: 0.982, blue: 0.974)
    private let card = Color.white
    private let ink = Color(red: 0.10, green: 0.105, blue: 0.10)
    private let muted = Color(red: 0.43, green: 0.44, blue: 0.42)
    private let line = Color(red: 0.90, green: 0.90, blue: 0.87)
    private let green = Color(red: 0.25, green: 0.52, blue: 0.35)
    private let dayTint = Color(red: 0.985, green: 0.945, blue: 0.84)
    private let dayInk = Color(red: 0.64, green: 0.39, blue: 0.08)
    private let nightTint = Color(red: 0.90, green: 0.92, blue: 0.965)
    private let nightInk = Color(red: 0.16, green: 0.28, blue: 0.48)
    private let roster: [(id: String, name: String, avatar: String)] = [
        ("zlu", "张璐", "58.png"),
        ("qiubo", "仇博", "193.png"),
        ("yangang", "杨昂", "101.png"),
        ("yangke", "杨珂", "codex-01.png"),
        ("liguoqing", "李国庆", "168.png"),
        ("mameng", "马猛", "codex-06.png"),
        ("zhanghaiqiang", "张海强", "codex-07.png"),
        ("huangning", "黄宁", "199.png"),
        ("qiaoyue", "乔月", "201.png"),
        ("lyf", "李阳峰", "169.png")
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
            Group {
                if let logo = brandLogo {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(green)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(green.opacity(0.13))
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(green.opacity(0.12), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text("万合创新局")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                Text("Codex 团队活跃 · 用起来，更要做出结果")
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
                    Label("个人周余额", systemImage: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(muted)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(remaining.map(String.init) ?? "--")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
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
        .background(green.opacity(0.025), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(line, lineWidth: 1))
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
                    .foregroundStyle(green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(green.opacity(0.08), in: Capsule())
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
        }
    }

    private func memberRow(_ member: TeamRankingMember, rank: Int) -> some View {
        Button { openWebsite(member.id) } label: {
            HStack(alignment: .center, spacing: 10) {
                rankedAvatar(member, rank: rank)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Text(displayName(member))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                        Circle()
                            .fill(member.tokens > 0 || member.sessions > 0 ? green : muted.opacity(0.45))
                            .frame(width: 5, height: 5)
                        Text(memberActiveText(member))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        sessionBadge(member)
                    }
                    memberQuotaProgress(member)
                    grindActivityBand(member)
                }
                .layoutPriority(1)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(formatTokens(member.tokens))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(ink)
                    Text("Token")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(muted)
                }
                .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(muted.opacity(0.65))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rankedAvatar(_ member: TeamRankingMember, rank: Int) -> some View {
        ZStack(alignment: .topLeading) {
            avatar(member)
                .padding(.leading, 5)
                .padding(.top, 5)
            Text(String(format: "%02d", rank))
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white)
                .frame(width: 27, height: 27)
                .background(rankColor(rank), in: Circle())
                .overlay(Circle().stroke(card, lineWidth: 2))
        }
        .frame(width: 63, height: 63)
    }

    private func avatar(_ member: TeamRankingMember) -> some View {
        ZStack {
            Circle().fill(green.opacity(0.11))
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
        .frame(width: 58, height: 58)
        .clipShape(Circle())
    }

    private var privacyNote: some View {
        Label("仅上传 Token、会话数和项目简称，不上传 prompt、代码或聊天正文", systemImage: "lock.shield")
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

            Text("v\(ClientVersion.current)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(muted.opacity(0.62))

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

    private func memberActiveText(_ member: TeamRankingMember) -> String {
        if member.tokens <= 0 && member.sessions <= 0 {
            return member.hasEverJoined ? "今日暂无使用" : "还未加入"
        }
        if member.tokenSource == "today_live" {
            if let recentTime = validLastActive(member) {
                return "活跃 \(recentTime)"
            }
            return "今日活跃"
        }
        if let lastActive = member.lastActive, !lastActive.isEmpty, lastActive != "-" {
            return "更新 \(lastActive)"
        }
        return officialDate(member)
    }

    private func validLastActive(_ member: TeamRankingMember) -> String? {
        guard let lastActive = member.lastActive, !lastActive.isEmpty, lastActive != "-" else { return nil }
        return lastActive
    }

    private func sessionBadge(_ member: TeamRankingMember) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(member.sessions)")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
            Text("次")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(green)
        .padding(.horizontal, 7)
        .padding(.vertical, 4.5)
        .background(green.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(green.opacity(0.72), lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func memberQuotaProgress(_ member: TeamRankingMember) -> some View {
        HStack(spacing: 7) {
            if let quota = member.weeklyQuota {
                Text("周余额 \(quota.weeklyRemainingPercent)%")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(green)
                    .fixedSize(horizontal: true, vertical: false)
                ProgressView(value: Double(quota.weeklyRemainingPercent) / 100)
                    .progressViewStyle(.linear)
                    .tint(green)
                    .frame(maxWidth: 54)
                Text(memberQuotaResetText(quota.weeklyResetsAt))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            } else {
                Text("周余额待同步 · 刷新待更新")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(muted)
            }
        }
    }

    private func grindActivityBand(_ member: TeamRankingMember) -> some View {
        HStack(spacing: 0) {
            grindBandSegment(
                icon: "sun.max.fill",
                text: "日搓 \(member.dayGrindTime ?? "--")",
                foreground: dayInk,
                background: dayTint
            )
            grindBandSegment(
                icon: "moon.fill",
                text: "夜搓 \(member.nightGrindTime ?? "--")",
                foreground: nightInk,
                background: nightTint
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(line.opacity(0.6), lineWidth: 0.5))
    }

    private func grindBandSegment(icon: String, text: String, foreground: Color, background: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(foreground)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5.5)
        .background(background)
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
        return BundledAvatarStore.image(for: filename)
    }

    private var brandLogo: NSImage? {
        let url = Bundle.module.url(forResource: "wanhe-app-icon-192", withExtension: "png", subdirectory: "Brand")
            ?? Bundle.module.url(forResource: "wanhe-app-icon-192", withExtension: "png")
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
        case 1: return green
        case 2, 3: return Color(red: 0.34, green: 0.38, blue: 0.36)
        default: return muted
        }
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 100_000_000 {
            return String(format: value >= 1_000_000_000 ? "%.1f亿" : "%.2f亿", Double(value) / 100_000_000)
        }
        if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}
